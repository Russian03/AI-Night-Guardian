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
    await prefs.setString(_key, jsonEncode(current.map((d) => d.toJson()).toList()));
  }

  static Future<void> remove(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await getAll();
    current.removeWhere((d) => d.deviceId == deviceId);
    await prefs.setString(_key, jsonEncode(current.map((d) => d.toJson()).toList()));
  }
}