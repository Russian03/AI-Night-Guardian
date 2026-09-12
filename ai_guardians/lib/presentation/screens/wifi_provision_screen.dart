import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:wifi_scan/wifi_scan.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../domain/device_credentials.dart';
import '../../data/device_store.dart';
import '../../domain/saved_device.dart';
import '../../data/mqtt_service.dart';
import '../../theme/app_theme.dart';
import 'main_shell.dart';

final Guid charTxUuid = Guid('6e400002-b5a3-f393-e0a9-e50e24dcca9e');
final Guid charStatusUuid = Guid('6e400004-b5a3-f393-e0a9-e50e24dcca9e');

class WifiProvisionScreen extends StatefulWidget {
  final DeviceCredentials credentials;
  final BluetoothDevice device;
  const WifiProvisionScreen({super.key, required this.credentials, required this.device});

  @override
  State<WifiProvisionScreen> createState() => _WifiProvisionScreenState();
}

class _WifiProvisionScreenState extends State<WifiProvisionScreen> {
  final _passCtrl = TextEditingController();
  final _roomCtrl = TextEditingController(text: 'Habitacion 12');
  final _manualSsidCtrl = TextEditingController();

  bool _obscurePassword = true;
  String _status = 'Sin conectar';
  bool _sending = false;
  bool _success = false;

  List<WiFiAccessPoint> _networks = [];
  String? _selectedSsid;
  bool _scanning = false;
  bool _manualEntry = false;

  @override
  void initState() {
    super.initState();
    _scanNetworks();
  }

  @override
  void dispose() {
    _passCtrl.dispose();
    _roomCtrl.dispose();
    _manualSsidCtrl.dispose();
    super.dispose();
  }

  Future<void> _scanNetworks() async {
    setState(() { _scanning = true; _status = 'Buscando redes...'; });

    final status = await Permission.locationWhenInUse.request();
    if (!status.isGranted) {
      setState(() { _scanning = false; _status = 'Permiso de ubicación necesario para buscar redes'; _manualEntry = true; });
      return;
    }

    final can = await WiFiScan.instance.canStartScan();
    if (can != CanStartScan.yes) {
      setState(() { _scanning = false; _status = 'No se pueden escanear redes en este dispositivo'; _manualEntry = true; });
      return;
    }

    await WiFiScan.instance.startScan();
    await Future.delayed(const Duration(seconds: 2));
    final results = await WiFiScan.instance.getScannedResults();

    final seen = <String>{};
    final networks = results.where((r) => r.ssid.isNotEmpty && seen.add(r.ssid)).toList()
      ..sort((a, b) => b.level.compareTo(a.level));

    if (!mounted) return;
    setState(() { _networks = networks; _scanning = false; _status = 'Sin conectar'; });
  }

  IconData _wifiIcon(int level) {
    if (level >= -50) return Icons.wifi;
    if (level >= -70) return Icons.wifi_2_bar;
    return Icons.wifi_1_bar;
  }

  void _selectNetwork(String ssid) {
    setState(() { _selectedSsid = ssid; _manualEntry = false; });
  }

  Future<void> _sendCredentials() async {
    setState(() { _sending = true; _status = 'Conectando por BLE...'; });

    try {
      await widget.device.connect(timeout: const Duration(seconds: 10));
      await widget.device.requestMtu(247);

      final services = await widget.device.discoverServices();
      BluetoothCharacteristic? txChar;
      BluetoothCharacteristic? statusChar;

      for (final s in services) {
        for (final c in s.characteristics) {
          if (c.uuid == charTxUuid) txChar = c;
          if (c.uuid == charStatusUuid) statusChar = c;
        }
      }

      if (txChar == null) {
        setState(() => _status = 'Error: característica TX no encontrada');
        return;
      }

      if (statusChar != null) {
        await statusChar.setNotifyValue(true);
        await Future.delayed(const Duration(milliseconds: 500));
        statusChar.lastValueStream.listen((value) async {
          final text = utf8.decode(value, allowMalformed: true);
          setState(() => _status = 'Arduino dice: $text');
          if (text.contains('"state":"connected"') || text.contains('"state": "connected"')) {
            setState(() => _success = true);
            await DeviceStore.add(SavedDevice(
              deviceId: widget.credentials.deviceId,
              roomName: _roomCtrl.text,
            ));
            await MqttService.instance.subscribeToDevice(widget.credentials.deviceId);
            if (!mounted) return;
            _showSuccessAndGoHome();
          }
        });
      }

      final ssid = _manualEntry ? _manualSsidCtrl.text : (_selectedSsid ?? '');
      final payload = jsonEncode({
        "type": "wifi_provision",
        "ssid": ssid,
        "password": _passCtrl.text,
        "room_name": _roomCtrl.text,
      });

      await txChar.write(utf8.encode(payload), withoutResponse: false);
      setState(() => _status = 'Credenciales enviadas, esperando confirmación...');
    } catch (e) {
      setState(() => _status = 'Error: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _showSuccessAndGoHome() async {
    try {
      await widget.device.disconnect();
    } catch (_) {}

    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const MainShell()),
      (route) => false,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      showDialog(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surfaceGrouped,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle, color: AppColors.statusSuccess, size: 48),
              const SizedBox(height: 16),
              Text('Dispositivo conectado con éxito', textAlign: TextAlign.center, style: Theme.of(ctx).textTheme.titleMedium),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Aceptar'),
            ),
          ],
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(backgroundColor: AppColors.bgElevated, title: const Text('Configurar red WiFi')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.surfaceContainer,
                boxShadow: [
                  BoxShadow(color: AppColors.primaryContainer.withOpacity(0.2), blurRadius: 24, spreadRadius: 2),
                ],
              ),
              child: const Icon(Icons.wifi_tethering, color: AppColors.primary, size: 36),
            ),
          ),
          const SizedBox(height: 20),
          Text('Configurar red WiFi', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            'El dispositivo necesita acceso a tu red WiFi para transmitir alertas en tiempo real.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 28),

          if (_selectedSsid == null && !_manualEntry) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Redes disponibles', style: Theme.of(context).textTheme.titleMedium),
                IconButton(
                  icon: _scanning
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh),
                  onPressed: _scanning ? null : _scanNetworks,
                ),
              ],
            ),
            if (!_scanning && _networks.isEmpty)
              const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('No se encontraron redes')),
            ..._networks.map((n) => Card(
                  color: AppColors.surfaceContainer,
                  child: ListTile(
                    leading: Icon(_wifiIcon(n.level), color: AppColors.primary),
                    title: Text(n.ssid),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _selectNetwork(n.ssid),
                  ),
                )),
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: () => setState(() => _manualEntry = true),
                child: const Text('Introducir red manualmente'),
              ),
            ),
          ] else ...[
            Card(
              color: AppColors.surfaceContainer,
              child: ListTile(
                leading: const Icon(Icons.wifi, color: AppColors.primary),
                title: Text(_manualEntry ? 'Red manual' : _selectedSsid!),
                trailing: TextButton(
                  onPressed: () => setState(() { _selectedSsid = null; _manualEntry = false; }),
                  child: const Text('Cambiar'),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_manualEntry)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextField(
                  controller: _manualSsidCtrl,
                  decoration: const InputDecoration(labelText: 'Nombre de la red (SSID)', prefixIcon: Icon(Icons.wifi)),
                ),
              ),
            TextField(
              controller: _passCtrl,
              obscureText: _obscurePassword,
              decoration: InputDecoration(
                labelText: 'Contraseña',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _roomCtrl,
              decoration: const InputDecoration(labelText: 'Nombre de la habitación', prefixIcon: Icon(Icons.bed_outlined)),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _sending ? null : _sendCredentials,
              icon: _sending
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Icon(_success ? Icons.check_circle : Icons.sensors),
              label: Text(_success ? '¡Conectado!' : 'Conectar dispositivo'),
            ),
          ],

          const SizedBox(height: 16),
          Text(_status, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}