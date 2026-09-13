import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:easy_localization/easy_localization.dart';

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
      '⚠️ ${'incidence_msg'.tr()} $room',
      '$eventType ${'detected'.tr()} (${'confidence'.tr()} ${(confidence * 100).toStringAsFixed(0)}%)',
      details,
    );
  }

  /// El sensor ha dejado de reportar. Canal aparte y prioridad menor
  /// para no confundirse con una incidencia real.
  static Future<void> showConnectionLost({
    required String room,
    required String deviceId,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'ai_night_guardian_connectivity',
      'Estado de los sensores',
      channelDescription: 'Avisos de pérdida y recuperación de conexión',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );
    const details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      // id estable por dispositivo: al reconectar se reemplaza/cancela.
      _connectionNotificationId(deviceId),
      '📡 ${'signalles'.tr()} $room',
      '${'signalles_err'.tr()}',
      details,
    );
  }

  /// El sensor vuelve a reportar: retira el aviso de sin señal.
  static Future<void> clearConnectionLost(String deviceId) async {
    await _plugin.cancel(_connectionNotificationId(deviceId));
  }

  /// Id determinista y dentro del rango de int32 que exige Android.
  static int _connectionNotificationId(String deviceId) =>
      1000000 + (deviceId.hashCode.abs() % 1000000);
}
