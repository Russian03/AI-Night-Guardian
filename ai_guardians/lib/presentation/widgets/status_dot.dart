import 'package:flutter/material.dart';
import '../../data/mqtt_service.dart';
import '../../theme/app_theme.dart';

/// Estado visual de un dispositivo.
enum DeviceStatus { ok, stale, alert }

const kHeartbeatTimeout = Duration(seconds: 90);

DeviceStatus deviceStatusOf(String deviceId) {
  final mqtt = MqttService.instance;
  if (mqtt.hasActiveIncident(deviceId)) return DeviceStatus.alert;
  final last = mqtt.lastHeartbeatTimeFor(deviceId);
  if (last == null || DateTime.now().difference(last) > kHeartbeatTimeout) {
    return DeviceStatus.stale;
  }
  return DeviceStatus.ok;
}

Color statusColor(DeviceStatus s) {
  switch (s) {
    case DeviceStatus.ok:
      return AppColors.statusSuccess;
    case DeviceStatus.stale:
      return AppColors.statusWarning;
    case DeviceStatus.alert:
      return AppColors.alertCritical;
  }
}

Color statusSurface(DeviceStatus s) {
  switch (s) {
    case DeviceStatus.ok:
      return AppColors.statusSuccessSurface;
    case DeviceStatus.stale:
      return AppColors.statusWarningSurface;
    case DeviceStatus.alert:
      return AppColors.alertCriticalSurface;
  }
}

String statusLabel(DeviceStatus s) {
  switch (s) {
    case DeviceStatus.ok:
      return 'Estable';
    case DeviceStatus.stale:
      return 'Sin señal';
    case DeviceStatus.alert:
      return 'Atención';
  }
}

/// Punto de estado. Emite un halo parpadeante cuando [pulse] es true.
class StatusDot extends StatefulWidget {
  final Color color;
  final bool pulse;
  final double size;

  const StatusDot({
    super.key,
    required this.color,
    required this.pulse,
    this.size = 12,
  });

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    if (widget.pulse) _c.repeat();
  }

  @override
  void didUpdateWidget(covariant StatusDot old) {
    super.didUpdateWidget(old);
    if (widget.pulse && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.pulse && _c.isAnimating) {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final halo = widget.size + 10;
    return SizedBox(
      width: halo,
      height: halo,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (widget.pulse)
            AnimatedBuilder(
              animation: _c,
              builder: (_, __) => Container(
                width: widget.size + (_c.value * 10),
                height: widget.size + (_c.value * 10),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withOpacity((1 - _c.value) * 0.35),
                ),
              ),
            ),
          Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color,
              boxShadow: [BoxShadow(color: widget.color.withOpacity(0.5), blurRadius: 8)],
            ),
          ),
        ],
      ),
    );
  }
}