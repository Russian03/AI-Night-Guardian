import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Un evento recibido por MQTT, guardado en el historial local.
/// Solo metadatos: nunca audio (privacidad por diseño).
class LoggedEvent {
  final String deviceId;
  final String eventType;
  final double confidence;
  final DateTime at;

  const LoggedEvent({
    required this.deviceId,
    required this.eventType,
    required this.confidence,
    required this.at,
  });

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'eventType': eventType,
        'confidence': confidence,
        'at': at.toIso8601String(),
      };

  factory LoggedEvent.fromJson(Map<String, dynamic> json) => LoggedEvent(
        deviceId: json['deviceId'] as String,
        eventType: json['eventType'] as String? ?? 'desconocido',
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
        at: DateTime.parse(json['at'] as String),
      );
}

class EventLog {
  EventLog._();
  static final EventLog instance = EventLog._();

  static const _key = 'event_log';
  static const _retention = Duration(hours: 24);
  static const _maxPerDevice = 30;

  final List<LoggedEvent> _events = [];
  bool _loaded = false;
  Future<void>? _loading;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loading ??= _loadFromDisk();
    await _loading;
  }

  Future<void> _loadFromDisk() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        _events.addAll(
          list.map((e) => LoggedEvent.fromJson(e as Map<String, dynamic>)),
        );
      } catch (_) {
        // historial corrupto: se descarta
      }
    }
    _prune();
    _loaded = true;
  }

  Future<void> add(LoggedEvent event) async {
    await ensureLoaded();
    _events.add(event);
    _prune();
    await _persist();
  }

  /// Últimos [limit] eventos del dispositivo dentro de [window].
  /// Requiere haber llamado antes a ensureLoaded().
  List<LoggedEvent> recentFor(
    String deviceId, {
    Duration window = const Duration(hours: 8),
    int limit = 4,
  }) {
    final cutoff = DateTime.now().subtract(window);
    final list = _events
        .where((e) => e.deviceId == deviceId && e.at.isAfter(cutoff))
        .toList()
      ..sort((a, b) => b.at.compareTo(a.at));
    return list.take(limit).toList();
  }

  Future<void> clearDevice(String deviceId) async {
    await ensureLoaded();
    _events.removeWhere((e) => e.deviceId == deviceId);
    await _persist();
  }

  void _prune() {
    final cutoff = DateTime.now().subtract(_retention);
    _events.removeWhere((e) => e.at.isBefore(cutoff));

    // Tope por dispositivo, conservando los más recientes.
    final byDevice = <String, List<LoggedEvent>>{};
    for (final e in _events) {
      byDevice.putIfAbsent(e.deviceId, () => []).add(e);
    }
    for (final entry in byDevice.entries) {
      if (entry.value.length <= _maxPerDevice) continue;
      entry.value.sort((a, b) => b.at.compareTo(a.at));
      for (final old in entry.value.skip(_maxPerDevice)) {
        _events.remove(old);
      }
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(_events.map((e) => e.toJson()).toList()),
    );
  }
}