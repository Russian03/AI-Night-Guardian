import 'package:flutter/material.dart';
import 'dart:async';
import '../../data/device_store.dart';
import '../../domain/saved_device.dart';
import '../../data/mqtt_service.dart';
import '../../theme/app_theme.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<SavedDevice> _devices = [];
  bool _loading = true;
  StreamSubscription<DeviceMessage>? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = MqttService.instance.messages.listen((_) {
      if (mounted) setState(() {}); // repinta con los últimos datos cacheados
    });
  }

  Future<void> _load() async {
    final devices = await DeviceStore.getAll();
    for (final d in devices) {
      await MqttService.instance.subscribeToDevice(d.deviceId);
    }
    if (!mounted) return;
    setState(() {
      _devices = devices;
      _loading = false;
    });
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour >= 21 || hour < 6) return 'Turno de noche';
    if (hour < 13) return 'Buenos días';
    return 'Buenas tardes';
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_greeting(), style: Theme.of(context).textTheme.displayLarge),
                  const SizedBox(height: 4),
                  Text(
                    '${_devices.length} dispositivo${_devices.length == 1 ? '' : 's'} vinculado${_devices.length == 1 ? '' : 's'}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          ),
          if (_devices.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text('Aún no tienes dispositivos.\nAñade uno desde la pestaña Dispositivos.', textAlign: TextAlign.center)),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) => Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: _LiveDeviceCard(device: _devices[i]),
                  ),
                  childCount: _devices.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _LiveDeviceCard extends StatelessWidget {
  final SavedDevice device;
  const _LiveDeviceCard({required this.device});

  void _showIncidentDialog(BuildContext context) {
    final event = MqttService.instance.lastEventFor(device.deviceId);
    final time = MqttService.instance.lastEventTimeFor(device.deviceId);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceGrouped,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
        title: Row(
          children: [
            const Expanded(child: Text('Última incidencia')),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.warning_amber_rounded, color: AppColors.alertCritical),
                const SizedBox(width: 8),
                Expanded(child: Text(event?['event_type'] ?? 'Desconocido', style: Theme.of(ctx).textTheme.titleMedium)),
              ],
            ),
            const SizedBox(height: 8),
            Text('Habitación: ${event?['room'] ?? device.roomName}'),
            if (event?['confidence'] != null)
              Text('Confianza: ${((event!['confidence'] as num) * 100).toStringAsFixed(0)}%'),
            if (time != null)
              Text('Hora: ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}'),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              MqttService.instance.markIncidentHandled(device.deviceId);
              Navigator.of(ctx).pop();
            },
            child: const Text('Incidencia atendida'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final payload = MqttService.instance.lastHeartbeatFor(device.deviceId);
    final lastSeen = MqttService.instance.lastHeartbeatTimeFor(device.deviceId);
    final hasIncident = MqttService.instance.hasActiveIncident(device.deviceId);

    final isStale = lastSeen == null || DateTime.now().difference(lastSeen) > const Duration(seconds: 45);

    final accentColor = hasIncident
        ? AppColors.alertCritical
        : (isStale ? AppColors.statusWarning : AppColors.statusSuccess);
    final accentSurface = hasIncident
        ? AppColors.alertCriticalSurface
        : (isStale ? AppColors.statusWarningSurface : AppColors.statusSuccessSurface);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: hasIncident ? accentSurface : AppColors.surfaceCard,
        borderRadius: BorderRadius.circular(18),
        border: hasIncident ? Border.all(color: AppColors.alertCritical, width: 1.5) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(device.roomName, style: Theme.of(context).textTheme.titleMedium),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: accentSurface, borderRadius: BorderRadius.circular(20)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, size: 8, color: accentColor),
                    const SizedBox(width: 6),
                    Text(
                      hasIncident ? 'Incidencia activa' : (isStale ? 'Sin conexión' : 'En línea'),
                      style: TextStyle(fontSize: 12, color: accentColor),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (payload != null)
            Row(
              children: [
                _MiniStat(icon: Icons.device_thermostat, value: '${payload['temp_c']}°C'),
                const SizedBox(width: 16),
                _MiniStat(icon: Icons.bedtime, value: '${payload['lux']} Lux'),
                const SizedBox(width: 16),
                _MiniStat(
                  icon: Icons.graphic_eq,
                  value: (payload['listening'] == false) ? 'Apagado' : 'Activo',
                ),
              ],
            )
          else
            Text('Esperando datos...', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary)),
          if (hasIncident) ...[
            const SizedBox(height: 14),
            ElevatedButton.icon(
              onPressed: () => _showIncidentDialog(context),
              icon: const Icon(Icons.notification_important),
              label: const Text('Ver incidencia inmediata'),
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.alertCritical),
            ),
          ],
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final IconData icon;
  final String value;
  const _MiniStat({required this.icon, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: AppColors.textSecondary),
        const SizedBox(width: 4),
        Text(value, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}