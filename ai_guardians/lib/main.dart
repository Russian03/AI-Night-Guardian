import 'package:flutter/material.dart';
import 'presentation/screens/splash_screen.dart';
import 'data/notification_service.dart';
import 'data/mqtt_service.dart';
import 'theme/app_theme.dart';
import 'data/device_store.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.init();
  await MqttService.instance.ensureConnected();
  final devices = await DeviceStore.getAll();
  for (final d in devices) {
    await MqttService.instance.subscribeToDevice(d.deviceId);
  }
  runApp(const AiNightGuardianApp());
}

class AiNightGuardianApp extends StatelessWidget {
  const AiNightGuardianApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Night Guardian',
      theme: AppTheme.dark,
      home: const SplashScreen(),
    );
  }
}