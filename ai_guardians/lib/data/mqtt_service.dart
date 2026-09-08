import 'dart:async';
import 'dart:convert';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'notification_service.dart';

/// Mensaje MQTT ya parseado, con el device_id de origen incluido.
class DeviceMessage {
  final String deviceId;
  final String type; // "heartbeat" | "event" | "incident_cleared"
  final Map<String, dynamic> payload;
  DeviceMessage({required this.deviceId, required this.type, required this.payload});
}

class MqttService {
  MqttService._internal();
  static final MqttService instance = MqttService._internal();

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

  Map<String, dynamic>? lastHeartbeatFor(String deviceId) => _lastHeartbeats[deviceId];
  DateTime? lastHeartbeatTimeFor(String deviceId) => _lastHeartbeatTimes[deviceId];

  Map<String, dynamic>? lastEventFor(String deviceId) => _lastEvents[deviceId];
  DateTime? lastEventTimeFor(String deviceId) => _lastEventTimes[deviceId];
  bool hasActiveIncident(String deviceId) => _activeIncidents.contains(deviceId);

  void markIncidentHandled(String deviceId) {
    _activeIncidents.remove(deviceId);
    _controller.add(DeviceMessage(deviceId: deviceId, type: 'incident_cleared', payload: {}));
  }

  bool get isConnected => _client?.connectionStatus?.state == MqttConnectionState.connected;

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
          _controller.add(DeviceMessage(deviceId: deviceId, type: 'heartbeat', payload: data));
        } else if (kind == 'eventos') {
          _lastEvents[deviceId] = data;
          _lastEventTimes[deviceId] = DateTime.now();
          _activeIncidents.add(deviceId);
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

  void publishConfig(String deviceId, Map<String, dynamic> payload) {
    if (!isConnected) return;
    final topic = 'residencia/$deviceId/config';
    final builder = MqttClientPayloadBuilder();
    builder.addString(jsonEncode({"type": "config", "payload": payload}));
    _client!.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
  }
}