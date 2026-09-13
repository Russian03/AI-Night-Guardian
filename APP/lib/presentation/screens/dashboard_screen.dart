import 'dart:async';
import 'package:flutter/material.dart';
import '../../domain/device_credentials.dart';
import '../../data/mqtt_service.dart';
import '../../theme/app_theme.dart';
import 'package:easy_localization/easy_localization.dart';

class DashboardScreen extends StatefulWidget {
  final DeviceCredentials credentials;
  const DashboardScreen({super.key, required this.credentials});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Map<String, dynamic>? _lastPayload;
  DateTime? _lastHeartbeatAt;
  String _connectionStatus = '${'connecting_broker'.tr()}...';
  Timer? _staleCheckTimer;
  StreamSubscription<DeviceMessage>? _sub;

  static const _staleThreshold = Duration(seconds: 45);

  bool _listening = true;

  @override
  void initState() {
    super.initState();
    _init();
    _staleCheckTimer = Timer.periodic(const Duration(seconds: 5), (_) => _checkStale());
  }

  Future<void> _init() async {
    await MqttService.instance.subscribeToDevice(widget.credentials.deviceId);

    final cachedPayload = MqttService.instance.lastHeartbeatFor(widget.credentials.deviceId);
    final cachedTime = MqttService.instance.lastHeartbeatTimeFor(widget.credentials.deviceId);
    if (cachedPayload != null) {
      setState(() {
        _lastPayload = cachedPayload;
        _lastHeartbeatAt = cachedTime;
        _connectionStatus = '${'online'.tr()}';
        final listeningFromDevice = cachedPayload['listening'] as bool?;
        if (listeningFromDevice != null) _listening = listeningFromDevice;
      });
    } else {
      setState(() => _connectionStatus = '${'waiting_data'.tr()}...');
    }

    _sub = MqttService.instance.messages.listen((msg) {
      if (msg.deviceId != widget.credentials.deviceId) return;
      if (msg.type == 'heartbeat') {
        final listeningFromDevice = msg.payload['listening'] as bool?;
        setState(() {
          _lastPayload = msg.payload;
          _lastHeartbeatAt = DateTime.now();
          _connectionStatus = '${'online'.tr()}';
          if (listeningFromDevice != null) _listening = listeningFromDevice;
        });
      }
      // Los eventos (type == 'event') ya disparan notificación desde MqttService;
      // aquí no hace falta hacer nada más con ellos.
    });
  }

  void _checkStale() {
    if (_lastHeartbeatAt == null) return;
    final elapsed = DateTime.now().difference(_lastHeartbeatAt!);
    final isStale = elapsed > _staleThreshold;
    final label = isStale
        ? '${'connexionless'.tr()}: ${_formatTime(_lastHeartbeatAt!)}'
        : '${'online'.tr()}';
    if (label != _connectionStatus) {
      setState(() => _connectionStatus = label);
    }
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  void _toggleListening() {
    final newValue = !_listening;
    MqttService.instance.publishConfig(widget.credentials.deviceId, {"listening": newValue});
    setState(() => _listening = newValue);
  }

  @override
  void dispose() {
    _staleCheckTimer?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final payload = _lastPayload;
    final isStale = _connectionStatus.startsWith('${'no_connexion'.tr()}');
    final hasAlert = false;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.bgElevated,
        title: Text(payload?['room'] ?? widget.credentials.deviceId),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _StatusBanner(isStale: isStale, hasAlert: hasAlert, statusText: _connectionStatus),
          const SizedBox(height: 20),
          if (payload != null) ...[
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.3,
              children: [
                _MetricCard(icon: Icons.device_thermostat, label: '${'temp'.tr()}', value: '${payload['temp_c']}°C', color: AppColors.primary),
                _MetricCard(icon: Icons.bedtime, label: '${'lux'.tr()}', value: '${payload['lux']} Lux', color: AppColors.statusWarning),
                _MetricCard(icon: Icons.history, label: '${'uptime'.tr()}', value: '${payload['uptime_s']}s', color: AppColors.secondary),
                _MetricCard(icon: Icons.wifi, label: '${'signal'.tr()}', value: '${payload['rssi']} dBm', color: AppColors.primaryContainer),
              ],
            ),
            const SizedBox(height: 20),
          ],
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: AppColors.surfaceCard, borderRadius: BorderRadius.circular(20)),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: AppColors.primaryContainer.withOpacity(0.15), shape: BoxShape.circle),
                  child: const Icon(Icons.graphic_eq, color: AppColors.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${'listening_mode'.tr()}', style: Theme.of(context).textTheme.titleMedium),
                      Text(_listening ? '${'active'.tr()}' : '${'off'.tr()}', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary)),
                    ],
                  ),
                ),
                Switch(value: _listening, onChanged: (_) => _toggleListening(), activeColor: AppColors.primaryContainer),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  final bool isStale;
  final bool hasAlert;
  final String statusText;
  const _StatusBanner({required this.isStale, required this.hasAlert, required this.statusText});

  @override
  Widget build(BuildContext context) {
    final color = hasAlert ? AppColors.alertCritical : (isStale ? AppColors.statusWarning : AppColors.statusSuccess);
    final bgColor = hasAlert ? AppColors.alertCriticalSurface : (isStale ? AppColors.statusWarningSurface : AppColors.statusSuccessSurface);
    final icon = hasAlert ? Icons.warning_amber_rounded : (isStale ? Icons.wifi_off : Icons.check_circle);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(20)),
      child: Row(
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Text(statusText, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  const _MetricCard({required this.icon, required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.surfaceCard, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelSmall),
              Icon(icon, color: color, size: 18),
            ],
          ),
          const Spacer(),
          Text(value, style: Theme.of(context).textTheme.headlineSmall),
        ],
      ),
    );
  }
}
