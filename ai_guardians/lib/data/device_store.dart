import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../domain/saved_device.dart';

class DeviceStore {
  static const _key = 'saved_devices';

  static Future<List<SavedDevice>> getAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => SavedDevice.fromJson(e as Map<String, dynamic>)).toList();
  }

  static Future<void> add(SavedDevice device) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await getAll();
    current.removeWhere((d) => d.deviceId == device.deviceId);
    current.add(device);
    await _save(prefs, current);
  }

  static Future<void> remove(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await getAll();
    current.removeWhere((d) => d.deviceId == deviceId);
    await _save(prefs, current);
  }

  /// Cambia el nombre de la habitación conservando la posición en la lista.
  static Future<void> rename(String deviceId, String newRoomName) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await getAll();
    final i = current.indexWhere((d) => d.deviceId == deviceId);
    if (i == -1) return;
    current[i] = SavedDevice(deviceId: deviceId, roomName: newRoomName);
    await _save(prefs, current);
  }

  static Future<void> _save(SharedPreferences prefs, List<SavedDevice> devices) {
    return prefs.setString(_key, jsonEncode(devices.map((d) => d.toJson()).toList()));
  }
}