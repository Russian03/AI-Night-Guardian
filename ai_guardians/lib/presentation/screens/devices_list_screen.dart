import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../../data/device_store.dart';
import '../../domain/saved_device.dart';
import '../../domain/device_credentials.dart';
import '../../theme/app_theme.dart';
import 'dashboard_screen.dart';
import 'qr_scan_screen.dart';

class DevicesListScreen extends StatefulWidget {
  const DevicesListScreen({super.key});

  @override
  State<DevicesListScreen> createState() => _DevicesListScreenState();
}

class _DevicesListScreenState extends State<DevicesListScreen> {
  List<SavedDevice> _devices = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final devices = await DeviceStore.getAll();
    if (!mounted) return;
    setState(() {
      _devices = devices;
      _loading = false;
    });
  }

  Future<void> _confirmDelete(SavedDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceGrouped,
        title: Text('¿Eliminar ${device.roomName}?'),
        content: const Text('Esta acción no se puede deshacer.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancelar')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Eliminar', style: TextStyle(color: AppColors.alertCritical)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await DeviceStore.remove(device.deviceId);
      _load();
    }
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
                child: Text('Dispositivos', style: Theme.of(context).textTheme.displayLarge),
              ),
              Container(
                decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.primaryContainer),
                child: IconButton(
                  icon: const Icon(Icons.add, color: Colors.white),
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const QrScanScreen()),
                    );
                    _load();
                  },
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _devices.isEmpty
              ? Center(
                  child: Text('Sin dispositivos', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary)),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: _devices.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.surfaceContainerHigh),
                  itemBuilder: (context, i) {
                    final device = _devices[i];
                    return Slidable(
                      endActionPane: ActionPane(
                        motion: const DrawerMotion(),
                        children: [
                          SlidableAction(
                            onPressed: (_) => _confirmDelete(device),
                            backgroundColor: AppColors.alertCritical,
                            foregroundColor: Colors.white,
                            icon: Icons.delete_outline,
                            label: 'Eliminar',
                          ),
                        ],
                      ),
                      child: ListTile(
                        leading: const Icon(Icons.circle, size: 12, color: AppColors.statusSuccess),
                        title: Text(device.roomName),
                        subtitle: Text(device.deviceId, style: Theme.of(context).textTheme.labelSmall),
                        trailing: const Icon(Icons.chevron_right, color: AppColors.textTertiary),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => DashboardScreen(
                                credentials: DeviceCredentials(deviceId: device.deviceId, provisioningKey: ''),
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}