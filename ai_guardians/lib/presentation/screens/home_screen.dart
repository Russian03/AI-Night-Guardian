import 'package:flutter/material.dart';
import 'dart:async';
import '../../data/device_store.dart';
import '../../domain/saved_device.dart';
import '../../data/mqtt_service.dart';
import '../../theme/app_theme.dart';
import '../widgets/status_dot.dart';
import 'device_detail_screen.dart';
import 'package:easy_localization/easy_localization.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<SavedDevice> _devices = [];
  bool _loading = true;
  StreamSubscription<DeviceMessage>? _sub;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = MqttService.instance.messages.listen((_) {
      if (mounted) setState(() {}); // repinta con los últimos datos cacheados
    });
    // Refresca "actualizado hace Xs" y el paso a estado sin conexión.
    _tick = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _load() async {
    final devices = await DeviceStore.getAll();
    for (final d in devices) {
      MqttService.instance.registerRoomName(d.deviceId, d.roomName);
      await MqttService.instance.subscribeToDevice(d.deviceId);
    }
    MqttService.instance.startConnectivityWatchdog();
    if (!mounted) return;
    setState(() {
      _devices = devices;
      _loading = false;
    });
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour >= 21 || hour < 6) return 'gn'.tr();
    if (hour < 13) return 'gm'.tr();
    return 'ga'.tr();
  }

  String _dateLine() {
    final now = DateTime.now();
    // Corregido el duplicado 'dx' (miércoles) por 'dj' (jueves)
    final days = ['dll'.tr(), 'dm'.tr(), 'dx'.tr(), 'dj'.tr(), 'dv'.tr(), 'ds'.tr(), 'dg'.tr()];
    final months = [
      'gen1'.tr(), 'feb2'.tr(), 'mar3'.tr(), 'abr4'.tr(), 'mai5'.tr(), 'jun6'.tr(),
      'jul7'.tr(), 'ago8'.tr(), 'sep9'.tr(), 'oct10'.tr(), 'nov11'.tr(), 'dec12'.tr(),
    ];
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    return '${days[now.weekday - 1]}, ${now.day} ${months[now.month - 1]} • $hh:$mm';
  }

  /// Segundos desde el heartbeat más reciente de cualquier dispositivo.
  String _lastUpdateLabel() {
    DateTime? newest;
    for (final d in _devices) {
      final t = MqttService.instance.lastHeartbeatTimeFor(d.deviceId);
      if (t != null && (newest == null || t.isAfter(newest!))) newest = t;
    }
    if (newest == null) return 'no_data_yet'.tr();
    final diff = DateTime.now().difference(newest!);
    if (diff.inSeconds < 60) return '${'actu1_ago'.tr()}${diff.inSeconds}${'s2_ago'.tr()}';
    if (diff.inMinutes < 60) return '${'actu1_ago'.tr()}${diff.inMinutes}${'min2_ago'.tr()}';
    return '${'actu1_ago'.tr()}${diff.inHours}${'h2_ago'.tr()}';
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final alerts = _devices.where((d) => MqttService.instance.hasActiveIncident(d.deviceId)).length;
    final offline = _devices.where((d) => MqttService.instance.isOffline(d.deviceId)).length;

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
                  Text(_dateLine(), style: Theme.of(context).textTheme.labelSmall),
                  const SizedBox(height: 2),
                  Text(_greeting(), style: Theme.of(context).textTheme.displayLarge),
                  const SizedBox(height: 16),
                  _ShiftSummary(
                    deviceCount: _devices.length,
                    alerts: alerts,
                    offline: offline,
                  ),
                ],
              ),
            ),
          ),
          if (_devices.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.sensors_off, size: 40, color: AppColors.textTertiary),
                      const SizedBox(height: 12),
                      Text(
                        'no_dev_yet'.tr(),
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
              sliver: SliverToBoxAdapter(
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'mon_rt'.tr(),
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(letterSpacing: 1),
                      ),
                    ),
                    Text(
                      _lastUpdateLabel(),
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: AppColors.primary),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) => Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: _LiveDeviceCard(
                      device: _devices[i],
                      onOpen: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => DeviceDetailScreen(device: _devices[i]),
                          ),
                        );
                        _load();
                      },
                    ),
                  ),
                  childCount: _devices.length,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Resumen del turno
// ---------------------------------------------------------------------------

class _ShiftSummary extends StatelessWidget {
  final int deviceCount;
  final int alerts;
  final int offline;

  const _ShiftSummary({
    required this.deviceCount,
    required this.alerts,
    required this.offline,
  });

  @override
  Widget build(BuildContext context) {
    final Color badgeColor;
    final Color badgeSurface;
    final String badgeText;
    final bool pulse;

    if (alerts > 0) {
      badgeColor = AppColors.alertCritical;
      badgeSurface = AppColors.alertCriticalSurface;
      badgeText = alerts == 1 ? '1 ${'act_alert'.tr()}' : '$alerts ${'act_alerts'.tr()}';
      pulse = true;
    } else if (offline > 0) {
      badgeColor = AppColors.statusWarning;
      badgeSurface = AppColors.statusWarningSurface;
      badgeText = offline == 1 ? '1 ${'no_connexion_minus'.tr()}' : '$offline ${'no_connexion_minus'.tr()}';
      pulse = true;
    } else {
      badgeColor = AppColors.statusSuccess;
      badgeSurface = AppColors.statusSuccessSurface;
      badgeText = 'all_good'.tr();
      pulse = false;
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surfaceContainerHigh,
            ),
            child: const Icon(Icons.monitor_heart, size: 20, color: AppColors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  deviceCount == 1
                      ? '1 ${'hab_monitor'.tr()}'
                      : '$deviceCount ${'hab_monitor'.tr()}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text('nturn'.tr(), style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: badgeSurface,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                StatusDot(color: badgeColor, pulse: pulse, size: 7),
                const SizedBox(width: 2),
                Text(
                  badgeText,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: badgeColor),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tarjeta de monitor en tiempo real
// ---------------------------------------------------------------------------

class _LiveDeviceCard extends StatelessWidget {
  final SavedDevice device;
  final VoidCallback onOpen;
  const _LiveDeviceCard({required this.device, required this.onOpen});

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
            Expanded(child: Text('last_event'.tr())),
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
                Expanded(
                  child: Text(
                    event?['event_type'] ?? 'unknown'.tr(),
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                ),
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
            child: Text('att_alert'.tr()),
          ),
        ],
      ),
    );
  }

  String _offlineSince() {
    final last = MqttService.instance.lastHeartbeatTimeFor(device.deviceId);
    if (last == null) return 'no_connexion'.tr();
    final hh = last.hour.toString().padLeft(2, '0');
    final mm = last.minute.toString().padLeft(2, '0');
    return '${'no_connexion'.tr()} — $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final payload = MqttService.instance.lastHeartbeatFor(device.deviceId);
    final hasIncident = MqttService.instance.hasActiveIncident(device.deviceId);
    final isStale = MqttService.instance.isOffline(device.deviceId);

    final accentColor = hasIncident
        ? AppColors.alertCritical
        : (isStale ? AppColors.statusWarning : AppColors.statusSuccess);
    final accentSurface = hasIncident
        ? AppColors.alertCriticalSurface
        : (isStale ? AppColors.statusWarningSurface : AppColors.statusSuccessSurface);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: hasIncident ? accentSurface : AppColors.surfaceCard,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: hasIncident ? AppColors.alertCritical : AppColors.borderSubtle,
              width: hasIncident ? 1.5 : 1,
            ),
            boxShadow: hasIncident
                ? const [BoxShadow(color: AppColors.alertCriticalSurface, blurRadius: 24, spreadRadius: 1)]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    hasIncident
                        ? Icons.emergency
                        : (isStale ? Icons.wifi_off : Icons.bedroom_parent),
                    size: 22,
                    color: accentColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      device.roomName,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: accentSurface,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        StatusDot(color: accentColor, pulse: hasIncident || isStale, size: 7),
                        const SizedBox(width: 2),
                        Text(
                          hasIncident
                              ? 'act_incidence'.tr()
                              : (isStale ? _offlineSince() : 'online'.tr()),
                          style: TextStyle(fontSize: 12, color: accentColor),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              // Aviso destacado de pérdida de conexión.
              if (isStale && !hasIncident) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.statusWarningSurface,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.signal_wifi_statusbar_connected_no_internet_4,
                          size: 18, color: AppColors.statusWarning),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'signalless_sensor'.tr(),
                          style: const TextStyle(fontSize: 14, color: AppColors.statusWarning),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 14),

              if (payload != null)
                Row(
                  children: [
                    Expanded(
                      child: _MiniStat(
                        icon: Icons.thermostat,
                        label: 'temp'.tr(),
                        value: '${payload['temp_c'] ?? '—'}°C',
                        stale: isStale,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MiniStat(
                        icon: Icons.lightbulb,
                        label: 'lux'.tr(),
                        value: '${payload['lux'] ?? '—'} Lux',
                        stale: isStale,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MiniStat(
                        icon: Icons.graphic_eq,
                        label: 'Audio',
                        value: isStale
                            ? 'unavailable'.tr()
                            : ((payload['listening'] == false) ? 'off'.tr() : 'active'.tr()),
                        stale: isStale,
                        valueColor: isStale
                            ? AppColors.statusWarning
                            : ((payload['listening'] == false) ? null : AppColors.secondary),
                      ),
                    ),
                  ],
                )
              else
                Text(
                  '${'waiting_sensor'.tr()}...',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: AppColors.textSecondary),
                ),

              if (hasIncident) ...[
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => _showIncidentDialog(context),
                    icon: const Icon(Icons.notification_important, size: 20),
                    label: Text('see_incidence'.tr()),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.alertCritical,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool stale;
  final Color? valueColor;

  const _MiniStat({
    required this.icon,
    required this.label,
    required this.value,
    this.stale = false,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: AppColors.textSecondary),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: valueColor ?? (stale ? AppColors.textTertiary : AppColors.textPrimary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
