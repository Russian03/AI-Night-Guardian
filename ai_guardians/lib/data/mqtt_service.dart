import 'dart:async';
import 'dart:convert';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'event_log.dart';
import 'notification_service.dart';

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

  MqttServerClient? _client;
  bool _connecting = false;
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

  /// Nombre de habitación por dispositivo, para poder redactar la notificación.
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
  // Vigilancia de conectividad
  // -------------------------------------------------------------------------

  /// Registra el nombre de habitación para las notificaciones de conectividad.
  void registerRoomName(String deviceId, String roomName) {
    _roomNames[deviceId] = roomName;
  }

  /// Arranca el vigilante que detecta sensores que dejan de reportar.
  /// Idempotente: llamarlo varias veces no crea timers duplicados.
  ///
  /// Limitación conocida: solo funciona mientras la app esté en ejecución.
  /// La detección fiable requiere LWT en el firmware (ver arquitectura, sección 5).
  void startConnectivityWatchdog() {
    _watchdog ??= Timer.periodic(const Duration(seconds: 30), (_) => _checkConnectivity());
  }

  void _checkConnectivity() {
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

  Future<void> ensureConnected() async {
    if (isConnected || _connecting) return;
    _connecting = true;

    _client = MqttServerClient('broker.hivemq.com', 'ai-night-guardian-app-${DateTime.now().millisecondsSinceEpoch}');
    _client!.port = 1883;
    _client!.keepAlivePeriod = 60;
    _client!.logging(on: false);
    _client!.autoReconnect = true;
    _client!.onAutoReconnect = () {};
    _client!.onConnected = () {};

    try {
      await _client!.connect();
    } catch (_) {
      _connecting = false;
      return;
    }

    _client!.updates!.listen((events) {
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
          _lastHeartbeats[deviceId] = data;
          _lastHeartbeatTimes[deviceId] = DateTime.now();

          // Reconexión: retira el aviso de sin señal si lo había.
          if (_offlineDevices.remove(deviceId)) {
            NotificationService.clearConnectionLost(deviceId);
            _controller.add(DeviceMessage(deviceId: deviceId, type: 'connection_restored', payload: {}));
          }

          _controller.add(DeviceMessage(deviceId: deviceId, type: 'heartbeat', payload: data));
        } else if (kind == 'eventos') {
          final now = DateTime.now();
          _lastEvents[deviceId] = data;
          _lastEventTimes[deviceId] = now;
          _activeIncidents.add(deviceId);

          // Historial local para "actividad reciente del turno".
          EventLog.instance.add(LoggedEvent(
            deviceId: deviceId,
            eventType: data['event_type'] as String? ?? 'desconocido',
            confidence: (data['confidence'] as num?)?.toDouble() ?? 0.0,
            at: now,
          ));

          _controller.add(DeviceMessage(deviceId: deviceId, type: 'event', payload: data));
          NotificationService.showEventAlert(
            room: data['room'] ?? 'Desconocida',
            eventType: data['event_type'] ?? 'desconocido',
            confidence: (data['confidence'] as num?)?.toDouble() ?? 0.0,
          );
        }
      } catch (_) {
        // payload no parseable, se ignora
      }
    });

    _connecting = false;
  }

  Future<void> subscribeToDevice(String deviceId) async {
    await ensureConnected();
    if (_subscribedDevices.contains(deviceId)) return;
    _client!.subscribe('residencia/$deviceId/heartbeat', MqttQos.atLeastOnce);
    _client!.subscribe('residencia/$deviceId/eventos', MqttQos.atLeastOnce);
    _subscribedDevices.add(deviceId);
  }

  /// Deja de vigilar un dispositivo eliminado.
  void forgetDevice(String deviceId) {
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

  void publishConfig(String deviceId, Map<String, dynamic> payload) {
    if (!isConnected) return;
    final topic = 'residencia/$deviceId/config';
    final builder = MqttClientPayloadBuilder();
    builder.addString(jsonEncode({"type": "config", "payload": payload}));
    _client!.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
  }
}