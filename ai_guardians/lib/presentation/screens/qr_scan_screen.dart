import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../domain/device_credentials.dart';
import '../../theme/app_theme.dart';
import 'ble_scan_screen.dart';
import 'main_shell.dart';

class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  bool _handled = false;
  String? _errorText;
  bool _checkingPermission = true;
  bool _permissionGranted = false;

  @override
  void initState() {
    super.initState();
    _checkPermission();
  }

  Future<void> _checkPermission() async {
    final status = await Permission.camera.request();
    if (!mounted) return;
    setState(() {
      _permissionGranted = status.isGranted;
      _checkingPermission = false;
    });
  }

  void _goBackOrHome() {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const MainShell()),
      );
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final barcode = capture.barcodes.firstOrNull;
    final raw = barcode?.rawValue;
    if (raw == null) return;

    DeviceCredentials credentials;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      credentials = DeviceCredentials.fromJson(json);
    } catch (e) {
      setState(() => _errorText = 'QR no válido para AI Night Guardian');
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _errorText = null);
      });
      return;
    }

    _handled = true;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BleScanScreen(credentials: credentials),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingPermission) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (!_permissionGranted) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.camera_alt_outlined, color: Colors.white54, size: 48),
                const SizedBox(height: 16),
                const Text(
                  'Se necesita acceso a la cámara para escanear el código QR',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: () => openAppSettings(),
                  child: const Text('Abrir ajustes'),
                ),
                TextButton(
                  onPressed: _goBackOrHome,
                  child: const Text('Cancelar', style: TextStyle(color: Colors.white70)),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          MobileScanner(onDetect: _onDetect),
          Container(color: Colors.black.withOpacity(0.35)),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  child: Row(
                    children: [
                      TextButton(
                        onPressed: _goBackOrHome,
                        child: const Text('Cancelar', style: TextStyle(color: Colors.white)),
                      ),
                      const Spacer(),
                      const Text('Añadir dispositivo', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      const SizedBox(width: 72),
                    ],
                  ),
                ),
                Expanded(
                  child: Center(
                    child: Container(
                      width: 260,
                      height: 260,
                      decoration: BoxDecoration(
                        border: Border.all(color: AppColors.primaryContainer, width: 3),
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                  child: Text(
                    _errorText ?? 'Apunta la cámara al código QR del dispositivo',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _errorText != null ? AppColors.alertCritical : Colors.white70,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}