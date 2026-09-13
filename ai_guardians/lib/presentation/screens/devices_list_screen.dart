import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../../data/device_store.dart';
import '../../data/event_log.dart';
import '../../data/mqtt_service.dart';
import '../../domain/saved_device.dart';
import '../../theme/app_theme.dart';
import '../widgets/status_dot.dart';
import 'device_detail_screen.dart';
import 'qr_scan_screen.dart';
import 'package:easy_localization/easy_localization.dart';

class DevicesListScreen extends StatefulWidget {
  const DevicesListScreen({super.key});

  @override
  State<DevicesListScreen> createState() => _DevicesListScreenState();
}

class _DevicesListScreenState extends State<DevicesListScreen> {
  List<SavedDevice> _devices = [];
  bool _loading = true;

  StreamSubscription<DeviceMessage>? _mqttSub;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _load();

    _mqttSub = MqttService.instance.messages.listen((_) {
      if (mounted) setState(() {});
    });

    // Repinta para detectar heartbeats caducados (verde -> amarillo).
    _refreshTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _mqttSub?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final devices = await DeviceStore.getAll();
    if (!mounted) return;
    setState(() {
      _devices = devices;
      _loading = false;
    });
    for (final d in devices) {
      MqttService.instance.registerRoomName(d.deviceId, d.roomName);
      MqttService.instance.subscribeToDevice(d.deviceId);
    }
  }

  String _subtitleFor(SavedDevice device, DeviceStatus status) {
    final last = MqttService.instance.lastHeartbeatTimeFor(device.deviceId);
    if (status == DeviceStatus.stale || last == null) {
      return 'ID: ${device.deviceId} • ${'no_connexion'.tr()}';
    }
    final diff = DateTime.now().difference(last);
    final ago = diff.inMinutes >= 1 ? '${'min1_ago'.tr()}${diff.inMinutes} ${'min2_ago'.tr()}' : '${'min1_ago'.tr()}${diff.inSeconds}${'s2_ago'.tr()}';
    return 'ID: ${device.deviceId} • $ago';
  }

  Future<void> _openAddDevice() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    _load();
  }

  /// Muestra el pop-up de confirmación. Devuelve true si el usuario confirma.
  Future<bool> _askDelete(SavedDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceGrouped,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text('¿${'del'.tr()} ${device.roomName}?'),
        content: Text(
          '${'actn_desvincular'.tr()}',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('${'cancel'}', style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('${'del'.tr()}', style: TextStyle(color: AppColors.alertCritical)),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  /// Quita la fila del árbol en el mismo frame (lo exige DismissiblePane)
  /// y luego persiste el borrado.
  void _deleteDevice(SavedDevice device) {
    setState(() => _devices.removeWhere((d) => d.deviceId == device.deviceId));
    DeviceStore.remove(device.deviceId);
    EventLog.instance.clearDevice(device.deviceId);
    MqttService.instance.forgetDevice(device.deviceId);
  }

  Future<void> _openDevice(SavedDevice device) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DeviceDetailScreen(device: device)),
    );
    // Recarga por si se renombró o eliminó desde el detalle.
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${'devs'.tr()}', style: Theme.of(context).textTheme.displayLarge),
                    const SizedBox(height: 2),
                    Text(
                      _devices.isEmpty
                          ? '${'gest_sens'.tr()}'
                          : '${_devices.length} ${_devices.length == 1 ? "sensor vinculado" : "sensores vinculados"}',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
              Container(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primaryContainer,
                ),
                child: IconButton(
                  icon: const Icon(Icons.add, color: Colors.white),
                  onPressed: _openAddDevice,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _devices.isEmpty
              ? _EmptyDevicesState(onAdd: _openAddDevice)
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                  itemCount: _devices.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, i) {
                    final device = _devices[i];
                    final status = deviceStatusOf(device.deviceId);
                    return _DeviceCard(
                      key: ValueKey(device.deviceId),
                      device: device,
                      status: status,
                      subtitle: _subtitleFor(device, status),
                      onTap: () => _openDevice(device),
                      onAskDelete: () => _askDelete(device),
                      onDelete: () => _deleteDevice(device),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Tarjeta de dispositivo
// ---------------------------------------------------------------------------

class _DeviceCard extends StatelessWidget {
  final SavedDevice device;
  final DeviceStatus status;
  final String subtitle;
  final VoidCallback onTap;
  final Future<bool> Function() onAskDelete;
  final VoidCallback onDelete;

  const _DeviceCard({
    super.key,
    required this.device,
    required this.status,
    required this.subtitle,
    required this.onTap,
    required this.onAskDelete,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final color = statusColor(status);

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: status == DeviceStatus.alert ? AppColors.alertCriticalGlow : AppColors.borderSubtle,
        ),
        boxShadow: status == DeviceStatus.alert
            ? const [BoxShadow(color: AppColors.alertCriticalSurface, blurRadius: 20, spreadRadius: 1)]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Slidable(
          key: ValueKey('slidable-${device.deviceId}'),
          endActionPane: ActionPane(
            motion: const DrawerMotion(),
            extentRatio: 0.32,
            dismissible: DismissiblePane(
              closeOnCancel: true,
              dismissThreshold: 0.35,
              confirmDismiss: onAskDelete,
              onDismissed: onDelete,
            ),
            children: [
              CustomSlidableAction(
                onPressed: (_) async {
                  if (await onAskDelete()) onDelete();
                },
                backgroundColor: AppColors.alertCritical,
                foregroundColor: Colors.white,
                padding: EdgeInsets.zero,
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.delete_outline, size: 22, color: Colors.white),
                    SizedBox(height: 4),
                    Text(
                      'Eliminar',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  children: [
                    StatusDot(color: color, pulse: status == DeviceStatus.alert),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  device.roomName,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleMedium,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: statusSurface(status),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  statusLabel(status),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.3,
                                    color: color,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            subtitle,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    const _SwipeChevron(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Chevron que apunta a la izquierda mientras el panel de eliminar está abierto.
class _SwipeChevron extends StatelessWidget {
  const _SwipeChevron();

  @override
  Widget build(BuildContext context) {
    final controller = Slidable.of(context);
    if (controller == null) {
      return const Icon(Icons.chevron_right, color: AppColors.textTertiary, size: 20);
    }
    return ValueListenableBuilder<ActionPaneType>(
      valueListenable: controller.actionPaneType,
      builder: (_, type, __) {
        final open = type == ActionPaneType.end;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          child: Icon(
            open ? Icons.chevron_left : Icons.chevron_right,
            key: ValueKey(open),
            color: open ? AppColors.alertCritical : AppColors.textTertiary,
            size: 20,
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Estado vacío
// ---------------------------------------------------------------------------

class _EmptyDevicesState extends StatefulWidget {
  final VoidCallback onAdd;
  const _EmptyDevicesState({required this.onAdd});

  @override
  State<_EmptyDevicesState> createState() => _EmptyDevicesStateState();
}

class _EmptyDevicesStateState extends State<_EmptyDevicesState>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 180,
              height: 180,
              child: AnimatedBuilder(
                animation: _c,
                builder: (_, __) {
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      for (int i = 0; i < 3; i++)
                        _RadarRing(progress: (_c.value + i / 3) % 1.0),
                      Container(
                        width: 76,
                        height: 76,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.surfaceCard,
                          border: Border.all(color: AppColors.borderSubtle),
                        ),
                        child: const Icon(Icons.sensors, size: 36, color: AppColors.primary),
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 28),
            Text(
              '${'no_dev_vinc'.tr()}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              '${'vinc_dev'.tr()}',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: AppColors.textSecondary, height: 1.45),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: 260,
              child: ElevatedButton.icon(
                onPressed: widget.onAdd,
                icon: const Icon(Icons.add, size: 20),
                label: Text('${'add_dev'.tr()}'),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.qr_code_2, size: 16, color: AppColors.textTertiary),
                const SizedBox(width: 6),
                Text(
                  '${'need_qr'.tr()}',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RadarRing extends StatelessWidget {
  final double progress; // 0 -> 1
  const _RadarRing({required this.progress});

  @override
  Widget build(BuildContext context) {
    final size = 76 + (progress * 104);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: AppColors.primary.withOpacity((1 - progress) * 0.35),
          width: 1.2,
        ),
      ),
    );
  }
}
