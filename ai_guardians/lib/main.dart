import 'package:flutter/material.dart';
import 'presentation/screens/splash_screen.dart';
import 'data/notification_service.dart';
import 'data/mqtt_service.dart';
import 'theme/app_theme.dart';
import 'data/device_store.dart';
import 'package:easy_localization/easy_localization.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await EasyLocalization.ensureInitialized();
  await NotificationService.init();
  await MqttService.instance.ensureConnected();
  final devices = await DeviceStore.getAll();
  for (final d in devices) {
    await MqttService.instance.subscribeToDevice(d.deviceId);
  }
  runApp(
    EasyLocalization(
      supportedLocales: const [Locale('en'), Locale('es'), Locale('ca')],
      path: 'assets/translations',
      fallbackLocale: const Locale('en'),
      startLocale: const Locale('en'),
      child: const AiNightGuardianApp(),
    ),
  );
}

class AiNightGuardianApp extends StatelessWidget {
  const AiNightGuardianApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
      title: 'AI Night Guardian',
      theme: AppTheme.dark,
      home: const SplashScreen(),
    );
  }
}
