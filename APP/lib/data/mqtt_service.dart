import 'dart:async';
import 'dart:convert';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'event_log.dart';
import 'notification_service.dart';
import 'package:easy_localization/easy_localization.dart';

/// Mensaje MQTT ya parseado, con el device_id de origen incluido.
class DeviceMessage {
  final String deviceId;
  /// "heartbeat" | "event" | "incident_cleared" | "connection_lost" | "connection_restored"
  final String type;
  final Map<String, dynamic> payload;
  DeviceMessage({required this.deviceId, required this.type, required this.payload});
}

class MqttService {
  MqttService._internal();
  static final MqttService instance = MqttService._internal();

  /// Tiempo sin heartbeat tras el cual se considera el sensor sin señal.
  static const offlineTimeout = Duration(seconds: 90);

  /// Claves de sensor que pueden fallar puntualmente en el dispositivo.
  static const _sensorKeys = ['temp_c', 'lux'];

  MqttServerClient? _client;

  /// Conexión en curso. Todas las llamadas concurrentes esperan a este future
  /// en lugar de continuar sobre un cliente a medio conectar.
  Future<void>? _connecting;

  bool _listenerAttached = false;

  final Set<String> _subscribedDevices = {};

  final _controller = StreamController<DeviceMessage>.broadcast();
  Stream<DeviceMessage> get messages => _controller.stream;

  final Map<String, Map<String, dynamic>> _lastHeartbeats = {};
  final Map<String, DateTime> _lastHeartbeatTimes = {};

  final Map<String, Map<String, dynamic>> _lastEvents = {};
  final Map<String, DateTime> _lastEventTimes = {};
  final Set<String> _activeIncidents = {};

  /// Dispositivos por los que ya se ha notificado pérdida de señal
  /// (evita notificar en bucle cada ciclo del watchdog).
  final Set<String> _offlineDevices = {};

  /// Nombre de habitación por dispositivo, para redactar la notificación.
  final Map<String, String> _roomNames = {};

  Timer? _watchdog;

  Map<String, dynamic>? lastHeartbeatFor(String deviceId) => _lastHeartbeats[deviceId];
  DateTime? lastHeartbeatTimeFor(String deviceId) => _lastHeartbeatTimes[deviceId];

  Map<String, dynamic>? lastEventFor(String deviceId) => _lastEvents[deviceId];
  DateTime? lastEventTimeFor(String deviceId) => _lastEventTimes[deviceId];
  bool hasActiveIncident(String deviceId) => _activeIncidents.contains(deviceId);

  bool isOffline(String deviceId) {
    final last = _lastHeartbeatTimes[deviceId];
    return last == null || DateTime.now().difference(last) > offlineTimeout;
  }

  void markIncidentHandled(String deviceId) {
    _activeIncidents.remove(deviceId);
    _controller.add(DeviceMessage(deviceId: deviceId, type: 'incident_cleared', payload: {}));
  }

  bool get isConnected => _client?.connectionStatus?.state == MqttConnectionState.connected;

  // -------------------------------------------------------------------------
  // Conexión
  // -------------------------------------------------------------------------

  /// Conecta si hace falta. Las llamadas concurrentes comparten el mismo
  /// future, de modo que ninguna continúa antes de que el cliente esté listo.
  Future<void> ensureConnected() {
    if (isConnected) return Future.value();
    return _connecting ??= _doConnect().whenComplete(() => _connecting = null);
  }

  Future<void> _doConnect() async {
    final client = MqttServerClient(
      'broker.hivemq.com',
      'ai-night-guardian-app-${DateTime.now().millisecondsSinceEpoch}',
    );
    client.port = 1883;
    client.keepAlivePeriod = 60;
    client.logging(on: false);
    client.autoReconnect = true;

    // Sin esto, autoReconnect recupera la conexión pero deja el cliente SIN
    // ninguna suscripción activa: el heartbeat deja de llegar en silencio.
    client.resubscribeOnAutoReconnect = true;

    client.onAutoReconnected = _resubscribeAll;

    _client = client;

    try {
      await client.connect();
    } catch (_) {
      _client = null;
      return;
    }

    if (client.connectionStatus?.state != MqttConnectionState.connected) {
      _client = null;
      return;
    }

    _attachListener(client);

    // Reaplicar las suscripciones que existían antes de esta conexión.
    _resubscribeAll();
  }

  void _attachListener(MqttServerClient client) {
    if (_listenerAttached) return;
    _listenerAttached = true;

    client.updates!.listen((events) {
      final recMess = events[0].payload as MqttPublishMessage;
      final topic = events[0].topic;
      final payloadStr = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);

      try {
        final json = jsonDecode(payloadStr) as Map<String, dynamic>;
        final data = json['payload'] as Map<String, dynamic>? ?? {};
        final parts = topic.split('/'); // residencia/<deviceId>/heartbeat|eventos
        if (parts.length < 3) return;
        final deviceId = parts[1];
        final kind = parts[2];

        if (kind == 'heartbeat') {
          final merged = _mergeHeartbeat(_lastHeartbeats[deviceId], data);
          _lastHeartbeats[deviceId] = merged;
          _lastHeartbeatTimes[deviceId] = DateTime.now();

          // Reconexión: retira el aviso de sin señal si lo había.
          if (_offlineDevices.remove(deviceId)) {
            NotificationService.clearConnectionLost(deviceId);
            _controller.add(DeviceMessage(deviceId: deviceId, type: 'connection_restored', payload: {}));
          }

          _controller.add(DeviceMessage(deviceId: deviceId, type: 'heartbeat', payload: merged));
        } else if (kind == 'eventos') {
          final now = DateTime.now();
          _lastEvents[deviceId] = data;
          _lastEventTimes[deviceId] = now;
          _activeIncidents.add(deviceId);

          final rawEvent = data['event_type'] as String? ?? 'unknown'.tr();

          EventLog.instance.add(LoggedEvent(
            deviceId: deviceId,
            eventType: rawEvent.tr(),
            confidence: (data['confidence'] as num?)?.toDouble() ?? 0.0,
            at: now,
          ));

          _controller.add(DeviceMessage(deviceId: deviceId, type: 'event', payload: data));
          NotificationService.showEventAlert(
            room: data['room'] ?? 'unknown'.tr(),
            eventType: rawEvent.tr(),
            confidence: (data['confidence'] as num?)?.toDouble() ?? 0.0,
          );
        }
      } catch (_) {
        // payload no parseable, se ignora
      }
    });
  }

  /// Si un sensor llega nulo, conserva la última lectura válida y la marca
  /// con `<clave>_stale: true` para que la UI pueda señalarlo.
  Map<String, dynamic> _mergeHeartbeat(
    Map<String, dynamic>? previous,
    Map<String, dynamic> incoming,
  ) {
    final merged = Map<String, dynamic>.from(incoming);
    for (final key in _sensorKeys) {
      if (merged[key] == null && previous?[key] != null) {
        merged[key] = previous![key];
        merged['${key}_stale'] = true;
      } else if (merged[key] != null) {
        merged['${key}_stale'] = false;
      }
    }
    return merged;
  }

  // -------------------------------------------------------------------------
  // Suscripciones
  // -------------------------------------------------------------------------

  /// Suscribe a los topics de un dispositivo. Segura ante llamadas
  /// concurrentes y ante llamadas repetidas del mismo device_id.
  Future<void> subscribeToDevice(String deviceId) async {
    await ensureConnected();

    final client = _client;
    if (client == null || !isConnected) {
      // No se marca como suscrito: se reintentará en la próxima llamada.
      return;
    }

    if (_subscribedDevices.contains(deviceId)) return;

    try {
      client.subscribe('residencia/$deviceId/heartbeat', MqttQos.atLeastOnce);
      client.subscribe('residencia/$deviceId/eventos', MqttQos.atLeastOnce);
      _subscribedDevices.add(deviceId);
    } catch (_) {
      // Se deja fuera de _subscribedDevices para poder reintentar.
    }
  }

  void _resubscribeAll() {
    final client = _client;
    if (client == null || !isConnected) return;

    for (final deviceId in _subscribedDevices) {
      try {
        client.subscribe('residencia/$deviceId/heartbeat', MqttQos.atLeastOnce);
        client.subscribe('residencia/$deviceId/eventos', MqttQos.atLeastOnce);
      } catch (_) {}
    }
  }

  /// Deja de vigilar un dispositivo eliminado y limpia TODO su estado.
  /// El unsubscribe real en el broker es imprescindible: sin él, volver a
  /// añadir el mismo device_id deja suscripciones duplicadas y un estado
  /// inconsistente entre "está en línea" y "no llegan métricas".
  void forgetDevice(String deviceId) {
    final client = _client;
    if (client != null && isConnected) {
      try {
        client.unsubscribe('residencia/$deviceId/heartbeat');
        client.unsubscribe('residencia/$deviceId/eventos');
      } catch (_) {}
    }

    _subscribedDevices.remove(deviceId);
    _offlineDevices.remove(deviceId);
    _roomNames.remove(deviceId);
    _lastHeartbeats.remove(deviceId);
    _lastHeartbeatTimes.remove(deviceId);
    _lastEvents.remove(deviceId);
    _lastEventTimes.remove(deviceId);
    _activeIncidents.remove(deviceId);
    NotificationService.clearConnectionLost(deviceId);
  }

  /// Descarta los datos cacheados de un dispositivo sin tocar la suscripción.
  /// Se usa al re-vincular el mismo sensor: evita que la app muestre "en
  /// línea" con el heartbeat viejo mientras aún no ha llegado el nuevo.
  void resetDeviceState(String deviceId) {
    _lastHeartbeats.remove(deviceId);
    _lastHeartbeatTimes.remove(deviceId);
    _lastEvents.remove(deviceId);
    _lastEventTimes.remove(deviceId);
    _activeIncidents.remove(deviceId);
    _offlineDevices.remove(deviceId);
  }

  // -------------------------------------------------------------------------
  // Vigilancia de conectividad
  // -------------------------------------------------------------------------

  void registerRoomName(String deviceId, String roomName) {
    _roomNames[deviceId] = roomName;
  }

  /// Arranca el vigilante que detecta sensores que dejan de reportar.
  /// Idempotente: llamarlo varias veces no crea timers duplicados.
  ///
  /// Limitación conocida: solo funciona mientras la app esté en ejecución.
  /// La detección fiable requiere LWT en el firmware.
  void startConnectivityWatchdog() {
    _watchdog ??= Timer.periodic(const Duration(seconds: 30), (_) => _checkConnectivity());
  }

  void _checkConnectivity() {
    // Reintentar suscripciones que fallaron por no haber conexión todavía.
    ensureConnected();

    for (final deviceId in _subscribedDevices) {
      final last = _lastHeartbeatTimes[deviceId];

      // Nunca ha reportado: aún no se puede hablar de "pérdida" de conexión.
      if (last == null) continue;

      final offline = DateTime.now().difference(last) > offlineTimeout;

      if (offline && !_offlineDevices.contains(deviceId)) {
        _offlineDevices.add(deviceId);
        NotificationService.showConnectionLost(
          room: _roomNames[deviceId] ?? deviceId,
          deviceId: deviceId,
        );
        _controller.add(DeviceMessage(deviceId: deviceId, type: 'connection_lost', payload: {}));
      } else if (!offline && _offlineDevices.contains(deviceId)) {
        _offlineDevices.remove(deviceId);
        NotificationService.clearConnectionLost(deviceId);
        _controller.add(DeviceMessage(deviceId: deviceId, type: 'connection_restored', payload: {}));
      }
    }
  }

  // -------------------------------------------------------------------------

  void publishConfig(String deviceId, Map<String, dynamic> payload) {
    final client = _client;
    if (client == null || !isConnected) return;
    final topic = 'residencia/$deviceId/config';
    final builder = MqttClientPayloadBuilder();
    builder.addString(jsonEncode({"type": "config", "payload": payload}));
    client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
  }
}
