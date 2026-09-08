import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: androidSettings);
    await _plugin.initialize(settings);

    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.requestNotificationsPermission();

    _initialized = true;
  }

  static Future<void> showEventAlert({
    required String room,
    required String eventType,
    required double confidence,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'ai_night_guardian_events',
      'Alertas de incidencia',
      channelDescription: 'Notificaciones de eventos detectados',
      importance: Importance.max,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      '⚠️ Incidencia en $room',
      '$eventType detectado (confianza ${(confidence * 100).toStringAsFixed(0)}%)',
      details,
    );
  }
}