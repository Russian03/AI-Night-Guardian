import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
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
import 'package:easy_localization/easy_localization.dart';

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
  /// Margen para que el Arduino conecte al WiFi: 20 s de timeout por intento
  /// x 3 reintentos, más holgura.
  static const _confirmationTimeout = Duration(seconds: 90);

  final _passCtrl = TextEditingController();
  final _roomCtrl = TextEditingController(text: '${'example_room'.tr()}');
  final _manualSsidCtrl = TextEditingController();

  bool _obscurePassword = true;
  String _status = '${'no_connexion'.tr()}';
  bool _sending = false;
  bool _awaiting = false;
  bool _success = false;
  int _elapsed = 0;

  List<WiFiAccessPoint> _networks = [];
  String? _selectedSsid;
  bool _scanning = false;
  bool _manualEntry = false;

  StreamSubscription<List<int>>? _statusSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<DeviceMessage>? _mqttSub;
  Timer? _countdown;

  @override
  void initState() {
    super.initState();
    _scanNetworks();
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _connSub?.cancel();
    _mqttSub?.cancel();
    _countdown?.cancel();
    _passCtrl.dispose();
    _roomCtrl.dispose();
    _manualSsidCtrl.dispose();
    super.dispose();
  }

  void _setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  Future<void> _scanNetworks() async {
    setState(() { _scanning = true; _status = '${'webs'.tr()}...'; });

    final status = await Permission.locationWhenInUse.request();
    if (!status.isGranted) {
      setState(() { _scanning = false; _status = '${'perm_ubi'.tr()}'; _manualEntry = true; });
      return;
    }

    final can = await WiFiScan.instance.canStartScan();
    if (can != CanStartScan.yes) {
      setState(() { _scanning = false; _status = '${'webs_err'.tr()}'; _manualEntry = true; });
      return;
    }

    await WiFiScan.instance.startScan();
    await Future.delayed(const Duration(seconds: 2));
    final results = await WiFiScan.instance.getScannedResults();

    final seen = <String>{};
    final networks = results.where((r) => r.ssid.isNotEmpty && seen.add(r.ssid)).toList()
      ..sort((a, b) => b.level.compareTo(a.level));

    if (!mounted) return;
    setState(() { _networks = networks; _scanning = false; _status = '${'no_connexion'}'; });
  }

  IconData _wifiIcon(int level) {
    if (level >= -50) return Icons.wifi;
    if (level >= -70) return Icons.wifi_2_bar;
    return Icons.wifi_1_bar;
  }

  void _selectNetwork(String ssid) {
    setState(() { _selectedSsid = ssid; _manualEntry = false; });
  }

  // ---------------------------------------------------------------------------
  // Provisioning BLE
  // ---------------------------------------------------------------------------

  Future<void> _writeWithRetry(
    BluetoothCharacteristic c,
    List<int> data, {
    int attempts = 3,
  }) async {
    for (var i = 0; i < attempts; i++) {
      try {
        await c.write(data, withoutResponse: false);
        return;
      } catch (e) {
        if (i == attempts - 1) rethrow;
        _setStatus('Reintentando envío (${i + 2}/$attempts)...');
        await Future.delayed(Duration(milliseconds: 400 * (i + 1)));
      }
    }
  }

  Future<void> _sendCredentials() async {
    final ssid = _manualEntry ? _manualSsidCtrl.text.trim() : (_selectedSsid ?? '');
    if (ssid.isEmpty) {
      _setStatus('${'wifi'.tr()}');
      return;
    }

    final payload = jsonEncode({
      "type": "wifi_provision",
      "ssid": ssid,
      "password": _passCtrl.text,
      "room_name": _roomCtrl.text,
    });
    final bytes = utf8.encode(payload);

    setState(() { _sending = true; _awaiting = false; _status = '${'con_ble'.tr()}...'; });

    try {
      // --- 1. Conectar y esperar estado "connected" real.
      if (!widget.device.isConnected) {
        await widget.device.connect(
          autoConnect: false,
          timeout: const Duration(seconds: 15),
        );
      }
      await widget.device.connectionState
          .firstWhere((s) => s == BluetoothConnectionState.connected)
          .timeout(const Duration(seconds: 15));

      if (Platform.isAndroid) {
        await Future.delayed(const Duration(milliseconds: 600));
      }

      // --- 2. Descubrir servicios ANTES de tocar el MTU.
      _setStatus('${'desc_serv'.tr()}...');
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
        _setStatus('Error: ${'err_tx'.tr()}');
        setState(() => _sending = false);
        return;
      }

      // --- 3. Negociar MTU y esperar confirmación.
      if (Platform.isAndroid && widget.device.mtuNow - 3 < bytes.length) {
        _setStatus('${'negociant'.tr()}...');
        try {
          await widget.device.requestMtu(517);
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 500));
      }

      final maxWrite = widget.device.mtuNow - 3;
      if (maxWrite < bytes.length) {
        _setStatus(
          'Error: ${'err_MTU1'.tr()} ${bytes.length} B ${'err_MTU2'.tr()} $maxWrite B. ${'err_MTU3'.tr()}',
        );
        setState(() => _sending = false);
        return;
      }

      // --- 4. Suscribirse a notificaciones ANTES de escribir.
      if (statusChar != null) {
        await statusChar.setNotifyValue(true);
        await Future.delayed(const Duration(milliseconds: 300));

        await _statusSub?.cancel();
        _statusSub = statusChar.onValueReceived.listen((value) {
          if (!mounted) return;
          final text = utf8.decode(value, allowMalformed: true);
          _setStatus('${'dev_sing'.tr()}: $text');

          if (text.contains('"state":"connected"') || text.contains('"state": "connected"')) {
            _finishSuccess(via: 'BLE');
          } else if (text.contains('wifi_failed') || text.contains('"state":"failed"')) {
            _abortWait('${'err_wifi'.tr()}');
          }
        });
      }

      // --- 5. Escribir.
      _setStatus('${'snd_cred'.tr()}...');
      await _writeWithRetry(txChar, bytes);

      // --- 6. Entrar en espera de confirmación. El botón NO se reactiva.
      _beginWait();
    } on TimeoutException {
      await _cleanupConnection();
      _setStatus('Error: ${'err_close'.tr()}.');
      if (mounted) setState(() => _sending = false);
    } catch (e) {
      await _cleanupConnection();
      _setStatus('Error: $e');
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Espera la confirmación por dos vías simultáneas:
  ///  a) notificación BLE del Arduino (característica STATUS),
  ///  b) primer heartbeat MQTT de ese device_id — prueba directa de que
  ///     el dispositivo ya está en la red aunque la notificación BLE se pierda.
  void _beginWait() {
    if (!mounted) return;
    setState(() { _awaiting = true; _elapsed = 0; });

    // Vía b: heartbeat MQTT.
    MqttService.instance.subscribeToDevice(widget.credentials.deviceId);
    _mqttSub?.cancel();
    _mqttSub = MqttService.instance.messages.listen((msg) {
      if (msg.deviceId == widget.credentials.deviceId && msg.type == 'heartbeat') {
        _finishSuccess(via: 'MQTT');
      }
    });

    // Aviso si el enlace BLE cae durante la espera (no es fatal: MQTT puede salvarlo).
    _connSub?.cancel();
    _connSub = widget.device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected && _awaiting && mounted) {
        _setStatus('Enlace BLE cerrado. Esperando que el dispositivo aparezca en la red...');
      }
    });

    _countdown?.cancel();
    _countdown = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _elapsed++);

      if (_elapsed <= 3) {
        _setStatus('${'wait_conf'.tr()}...');
      }

      if (_elapsed >= _confirmationTimeout.inSeconds) {
        _abortWait(
          '${'err_conf1'.tr()} ${_confirmationTimeout.inSeconds} s. '
          '${'err_conf2'.tr()}',
        );
      }
    });
  }

  void _abortWait(String message) {
    _countdown?.cancel();
    _mqttSub?.cancel();
    _connSub?.cancel();
    if (!mounted) return;
    setState(() { _awaiting = false; _sending = false; });
    _setStatus(message);
  }

  Future<void> _finishSuccess({required String via}) async {
    if (_success || !mounted) return;
    setState(() { _success = true; _awaiting = false; });

    _countdown?.cancel();
    await _mqttSub?.cancel();
    await _connSub?.cancel();
    await _statusSub?.cancel();

    await DeviceStore.add(SavedDevice(
      deviceId: widget.credentials.deviceId,
      roomName: _roomCtrl.text,
    ));
    // Re-vinculación del mismo sensor: descartar heartbeats de la sesión
    // anterior para no mostrar "en línea" con datos caducados.
    MqttService.instance.resetDeviceState(widget.credentials.deviceId);
    MqttService.instance.registerRoomName(widget.credentials.deviceId, _roomCtrl.text);
    await MqttService.instance.subscribeToDevice(widget.credentials.deviceId);

    if (!mounted) return;
    _showSuccessAndGoHome();
  }

  Future<void> _cleanupConnection() async {
    await _statusSub?.cancel();
    _statusSub = null;
    try {
      await widget.device.disconnect();
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 400));
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
              Text('${'success'.tr()}', textAlign: TextAlign.center, style: Theme.of(ctx).textTheme.titleMedium),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('accept'.tr()),
            ),
          ],
        ),
      );
    });
  }

  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final remaining = _confirmationTimeout.inSeconds - _elapsed;

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
          Text('${'conf_wifi'.tr()}', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            '${'err_conf_wifi'.tr()}',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 28),

          if (_selectedSsid == null && !_manualEntry) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('${'redes_disp'.tr()}', style: Theme.of(context).textTheme.titleMedium),
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
                child: Text('${'red_man'.tr()}'),
              ),
            ),
          ] else ...[
            Card(
              color: AppColors.surfaceContainer,
              child: ListTile(
                leading: const Icon(Icons.wifi, color: AppColors.primary),
                title: Text(_manualEntry ? '${'red_man2'.tr()}' : _selectedSsid!),
                trailing: TextButton(
                  onPressed: _awaiting
                      ? null
                      : () => setState(() { _selectedSsid = null; _manualEntry = false; }),
                  child: Text('${'chng'.tr()}'),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_manualEntry)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextField(
                  controller: _manualSsidCtrl,
                  enabled: !_awaiting,
                  decoration: InputDecoration(labelText: '${'nom_red'.tr()} (SSID)', prefixIcon: Icon(Icons.wifi)),
                ),
              ),
            TextField(
              controller: _passCtrl,
              enabled: !_awaiting,
              obscureText: _obscurePassword,
              decoration: InputDecoration(
                labelText: 'psw'.tr(),
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
              enabled: !_awaiting,
              decoration: InputDecoration(labelText: 'hab_name'.tr(), prefixIcon: Icon(Icons.bed_outlined)),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: (_sending || _awaiting) ? null : _sendCredentials,
              icon: (_sending || _awaiting)
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Icon(_success ? Icons.check_circle : Icons.sensors),
              label: Text(
                _success
                    ? '¡${'connected'.tr()}!'
                    : (_awaiting ? '${'wait_dev'.tr()}… ${remaining}s' : '${'con_dev'.tr()}'),
              ),
            ),
            if (_awaiting) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.statusWarningSurface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 18, color: AppColors.statusWarning),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${'err_1min'.tr()} '
                        '${'no_close'.tr()}.',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],

          const SizedBox(height: 16),
          Text(_status, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}
