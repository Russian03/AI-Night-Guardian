import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../domain/device_credentials.dart';
import '../../theme/app_theme.dart';
import 'wifi_provision_screen.dart';
import 'package:easy_localization/easy_localization.dart';


final Guid aingServiceUuid = Guid('6e400001-b5a3-f393-e0a9-e50e24dcca9e');

class BleScanScreen extends StatefulWidget {
  final DeviceCredentials credentials;
  const BleScanScreen({super.key, required this.credentials});

  @override
  State<BleScanScreen> createState() => _BleScanScreenState();
}

class _BleScanScreenState extends State<BleScanScreen> with SingleTickerProviderStateMixin {
  final List<ScanResult> _results = [];
  bool _scanning = false;
  bool _connecting = false;
  late final AnimationController _pulseController;
  StreamSubscription<List<ScanResult>>? _scanSub;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
    _startScan();
  }

  Future<void> _startScan() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    if (!mounted) return;
    setState(() {
      _scanning = true;
      _results.clear();
    });

    // Una sola suscripción viva: reiniciar el escaneo no debe apilar listeners.
    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      if (!mounted) return;
      setState(() {
        _results
          ..clear()
          ..addAll(results);
      });
    });

    await FlutterBluePlus.startScan(
      withServices: [aingServiceUuid],
      timeout: const Duration(seconds: 15),
    );

    if (mounted) setState(() => _scanning = false);
  }

  int _signalBars(int rssi) {
    if (rssi >= -55) return 4;
    if (rssi >= -70) return 3;
    if (rssi >= -85) return 2;
    return 1;
  }

  Future<void> _selectDevice(ScanResult r) async {
    if (_connecting) return;
    setState(() => _connecting = true);

    // Imprescindible: parar el escaneo antes de conectar. Escanear y
    // conectar a la vez es una causa común de GATT_UNLIKELY en Android.
    await _scanSub?.cancel();
    _scanSub = null;
    await FlutterBluePlus.stopScan();

    // El radio no queda libre de inmediato tras stopScan().
    await Future.delayed(const Duration(milliseconds: 500));

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WifiProvisionScreen(
          credentials: widget.credentials,
          device: r.device,
        ),
      ),
    );

    if (mounted) setState(() => _connecting = false);
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    FlutterBluePlus.stopScan();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.bgElevated,
        title: Text('searching_device'.tr()),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 32),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                SizedBox(
                  width: 180,
                  height: 180,
                  child: AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, child) {
                      return Stack(
                        alignment: Alignment.center,
                        children: [
                          _pulseRing(0.0),
                          _pulseRing(0.5),
                          Container(
                            width: 80,
                            height: 80,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColors.primaryContainer,
                            ),
                            child: const Icon(Icons.bluetooth_searching, color: Colors.white, size: 38),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 20),
                Text('${'scanning'.tr()}', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(
                  '${'searching'.tr()} ${widget.credentials.deviceId} ${'nearby'}.tr()...',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '${'detected_devices'.tr()} (${_results.length})',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(letterSpacing: 1),
            ),
          ),
          const SizedBox(height: 10),
          ..._results.map((r) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _DeviceResultCard(
                  result: r,
                  bars: _signalBars(r.rssi),
                  onTap: () => _selectDevice(r),
                ),
              )),
          if (!_scanning) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _connecting ? null : _startScan,
              icon: const Icon(Icons.sync),
              label: Text('retry_search'.tr()),
            ),
          ],
        ],
      ),
    );
  }

  Widget _pulseRing(double delay) {
    final t = (_pulseController.value + delay) % 1.0;
    return Opacity(
      opacity: (1 - t) * 0.4,
      child: Container(
        width: 80 + t * 100,
        height: 80 + t * 100,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.primaryContainer.withOpacity(0.3),
        ),
      ),
    );
  }
}

class _DeviceResultCard extends StatelessWidget {
  final ScanResult result;
  final int bars;
  final VoidCallback onTap;
  const _DeviceResultCard({required this.result, required this.bars, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surfaceCard,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppColors.primaryContainer.withOpacity(0.15),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.bluetooth, color: AppColors.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.device.platformName.isEmpty ? '(sin nombre)' : result.device.platformName,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(result.device.remoteId.str, style: Theme.of(context).textTheme.labelSmall),
                ],
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(4, (i) {
                final active = i < bars;
                return Container(
                  margin: const EdgeInsets.only(left: 2),
                  width: 4,
                  height: 6.0 + i * 4,
                  decoration: BoxDecoration(
                    color: active ? AppColors.statusSuccess : AppColors.surfaceVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}
