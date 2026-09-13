import 'dart:async';
import 'package:flutter/material.dart';
import '../../data/device_store.dart';
import '../../data/event_log.dart';
import '../../data/mqtt_service.dart';
import '../../domain/saved_device.dart';
import '../../theme/app_theme.dart';
import '../widgets/status_dot.dart';
import 'package:easy_localization/easy_localization.dart';

class DeviceDetailScreen extends StatefulWidget {
  final SavedDevice device;
  const DeviceDetailScreen({super.key, required this.device});

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  late SavedDevice _device;
  StreamSubscription<DeviceMessage>? _sub;
  Timer? _timer;
  List<LoggedEvent> _recent = [];
  bool _togglePending = false;

  @override
  void initState() {
    super.initState();
    _device = widget.device;
    MqttService.instance.subscribeToDevice(_device.deviceId);
    _loadEvents();

    _sub = MqttService.instance.messages.listen((msg) {
      if (!mounted) return;
      if (msg.deviceId == _device.deviceId && msg.type == 'event') {
        _loadEvents();
      } else {
        // El heartbeat confirma si el dispositivo aplicó el cambio de escucha.
        if (msg.deviceId == _device.deviceId && msg.type == 'heartbeat') {
          _togglePending = false;
        }
        setState(() {});
      }
    });

    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadEvents() async {
    await EventLog.instance.ensureLoaded();
    if (!mounted) return;
    setState(() {
      _recent = EventLog.instance.recentFor(_device.deviceId);
    });
  }

  // -------------------------------------------------------------------------
  // Acciones
  // -------------------------------------------------------------------------

  Future<void> _toggleListening(bool value) async {
    if (!MqttService.instance.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('broker_connectionless'.tr())),
      );
      return;
    }

    setState(() => _togglePending = true);
    MqttService.instance.publishConfig(_device.deviceId, {'listening': value});

    // El estado real llega en el siguiente heartbeat (hasta 5 s).
    // Si no cambia en 15 s, se asume que el dispositivo no lo aplicó.
    Future.delayed(const Duration(seconds: 15), () {
      if (mounted && _togglePending) setState(() => _togglePending = false);
    });
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: _device.roomName);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceGrouped,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text('rename_room'.tr()),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(hintText: 'example_room'.tr()),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('cancel'.tr(), style: const TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text('save'.tr()),
          ),
        ],
      ),
    );

    if (newName == null || newName.isEmpty || newName == _device.roomName) return;
    await DeviceStore.rename(_device.deviceId, newName);
    MqttService.instance.registerRoomName(_device.deviceId, newName);
    if (!mounted) return;
    setState(() {
      _device = SavedDevice(deviceId: _device.deviceId, roomName: newName);
    });
  }

  void _showTechInfo() {
    final hb = MqttService.instance.lastHeartbeatFor(_device.deviceId) ?? {};
    final lastSeen = MqttService.instance.lastHeartbeatTimeFor(_device.deviceId);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceGrouped,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text('tec_info'.tr()),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _InfoRow('dev_id'.tr(), _device.deviceId),
            _InfoRow('Firmware', hb['fw_version']?.toString() ?? '—'),
            _InfoRow('topic'.tr(), 'residencia/${_device.deviceId}/#'),
            _InfoRow('heartbeat'.tr(), lastSeen == null ? 'never'.tr() : _clock(lastSeen)),
            _InfoRow(
              'sensors_age'.tr(),
              hb['sensor_age_s'] == null ? '—' : '${hb['sensor_age_s']} s',
            ),
            _InfoRow('Broker', MqttService.instance.isConnected ? 'connected'.tr() : 'disconnected'.tr()),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text('close'.tr())),
        ],
      ),
    );
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceGrouped,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text('¿${'del'.tr()} ${_device.roomName}?'),
        content: Text(
          'actn_desvincular'.tr(),
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('cancel'.tr(), style: const TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('del'.tr(), style: const TextStyle(color: AppColors.alertCritical)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await DeviceStore.remove(_device.deviceId);
    await EventLog.instance.clearDevice(_device.deviceId);
    MqttService.instance.forgetDevice(_device.deviceId);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final status = deviceStatusOf(_device.deviceId);
    final hb = MqttService.instance.lastHeartbeatFor(_device.deviceId);

    return Scaffold(
      backgroundColor: AppColors.bgCanvas,
      body: SafeArea(
        child: Column(
          children: [
            _header(status),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
                children: [
                  if (status == DeviceStatus.alert) _alertBanner(),
                  if (status == DeviceStatus.stale) _offlineBanner(),
                  const SizedBox(height: 16),
                  _metricsGrid(hb),
                  const SizedBox(height: 16),
                  _ListeningCard(
                    listening: hb?['listening'] != false,
                    pending: _togglePending,
                    enabled: status != DeviceStatus.stale,
                    onChanged: _toggleListening,
                  ),
                  const SizedBox(height: 24),
                  _activitySection(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(DeviceStatus status) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 12, 12),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back_ios, size: 18, color: AppColors.primary),
            label: Text('back'.tr(), style: const TextStyle(color: AppColors.primary)),
            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
          ),
          Expanded(
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    StatusDot(
                      color: statusColor(status),
                      pulse: status != DeviceStatus.ok,
                      size: 9,
                    ),
                    const SizedBox(width: 2),
                    Flexible(
                      child: Text(
                        _device.roomName,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                  ],
                ),
                Text(
                  _device.deviceId,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(letterSpacing: 0.6),
                ),
              ],
            ),
          ),
          _menuButton(),
        ],
      ),
    );
  }

  Widget _menuButton() {
    return Container(
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.surfaceContainerHigh,
      ),
      child: PopupMenuButton<String>(
        icon: const Icon(Icons.more_horiz, color: AppColors.textPrimary, size: 22),
        color: AppColors.surfaceGrouped,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        onSelected: (v) {
          switch (v) {
            case 'rename':
              _rename();
              break;
            case 'info':
              _showTechInfo();
              break;
            case 'delete':
              _delete();
              break;
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'rename',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.edit, color: AppColors.primary, size: 20),
              title: Text('rename_room'.tr()),
            ),
          ),
          PopupMenuItem(
            value: 'info',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.info_outline, color: AppColors.primary, size: 20),
              title: Text('see_tec_info'.tr()),
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'delete',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.delete_forever, color: AppColors.alertCritical, size: 20),
              title: Text(
                'del_dev'.tr(),
                style: const TextStyle(color: AppColors.alertCritical, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _alertBanner() {
    final event = MqttService.instance.lastEventFor(_device.deviceId) ?? {};
    final at = MqttService.instance.lastEventTimeFor(_device.deviceId);
    final type = event['event_type'] as String? ?? 'unknown'.tr();

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.alertCriticalSurface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.alertCriticalGlow),
        boxShadow: const [
          BoxShadow(color: AppColors.alertCriticalSurface, blurRadius: 24, spreadRadius: 2),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.alertCritical.withOpacity(0.2),
            ),
            child: const Icon(Icons.warning_rounded, color: AppColors.alertCritical, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'act_incidence'.tr(),
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: AppColors.alertCritical,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.alertCritical,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        'urg'.tr(),
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${_eventLabel(type)} • ${at == null ? 'now'.tr() : _ago(at)}',
                  style: const TextStyle(fontSize: 15, color: AppColors.textPrimary),
                ),
                const SizedBox(height: 14),
                ElevatedButton.icon(
                  onPressed: () {
                    MqttService.instance.markIncidentHandled(_device.deviceId);
                    setState(() {});
                  },
                  icon: const Icon(Icons.verified, size: 18),
                  label: Text('att_alert'.tr()),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.alertCritical,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _offlineBanner() {
    final last = MqttService.instance.lastHeartbeatTimeFor(_device.deviceId);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.statusWarningSurface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.statusWarning.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          const Icon(Icons.wifi_off, color: AppColors.statusWarning, size: 24),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'no_signal_sensor'.tr(),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.statusWarning,
                  ),
                ),
                Text(
                  last == null
                      ? 'never_heartbeat'.tr()
                      : '${'last_contact'.tr()}: ${_clock(last)} (${_ago(last)})',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricsGrid(Map<String, dynamic>? hb) {
    final temp = (hb?['temp_c'] as num?)?.toDouble();
    final lux = (hb?['lux'] as num?)?.toInt();
    final uptime = (hb?['uptime_s'] as num?)?.toInt();
    final rssi = (hb?['rssi'] as num?)?.toInt();

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.25,
      children: [
        _MetricCard(
          label: 'temp'.tr(),
          icon: Icons.device_thermostat,
          iconColor: AppColors.primary,
          value: temp == null ? '—' : temp.toStringAsFixed(1),
          unit: '°C',
          caption: hb?['temp_c_stale'] == true
              ? 'last_val_read'.tr()
              : 'amb_temp'.tr(),
        ),
        _MetricCard(
          label: 'lux'.tr(),
          icon: Icons.bedtime,
          iconColor: AppColors.statusWarning,
          value: lux?.toString() ?? '—',
          unit: 'lux',
          caption: hb?['lux_stale'] == true
              ? 'last_val_read'.tr()
              : (lux == null ? 'no_read'.tr() : (lux < 10 ? 'darkness'.tr() : 'light_on'.tr())),
        ),
        _MetricCard(
          label: 'act'.tr(),
          icon: Icons.history,
          iconColor: AppColors.secondary,
          value: uptime == null ? '—' : '${uptime ~/ 3600}h ${(uptime % 3600) ~/ 60}m',
          unit: '',
          caption: 'act_time'.tr(),
        ),
        _MetricCard(
          label: 'cnct'.tr(),
          icon: Icons.wifi,
          iconColor: AppColors.primaryContainer,
          value: rssi?.toString() ?? '—',
          unit: rssi == null ? '' : 'dBm',
          caption: _rssiQuality(rssi),
        ),
      ],
    );
  }

  Widget _activitySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'rec_act'.tr(),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Text('8hr'.tr(), style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceCard,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.borderSubtle),
          ),
          child: _recent.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
                  child: Column(
                    children: [
                      const Icon(Icons.nightlight_round, color: AppColors.textTertiary, size: 30),
                      const SizedBox(height: 10),
                      Text(
                        '8hr_ok'.tr(),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    for (int i = 0; i < _recent.length; i++) ...[
                      if (i > 0) const Divider(height: 1, indent: 64, color: AppColors.borderSubtle),
                      _EventRow(event: _recent[i]),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets
// ---------------------------------------------------------------------------

class _ListeningCard extends StatelessWidget {
  final bool listening;
  final bool pending;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _ListeningCard({
    required this.listening,
    required this.pending,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: listening
                  ? AppColors.primaryContainer.withOpacity(0.2)
                  : AppColors.surfaceContainerHigh,
            ),
            child: Icon(
              listening ? Icons.graphic_eq : Icons.mic_off,
              size: 22,
              color: listening ? AppColors.primary : AppColors.textTertiary,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'acoustic_mode'.tr(),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  pending
                      ? '${'apl_changes'.tr()}…'
                      : (listening ? 'detecting'.tr() : 'det_stopped'.tr()),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: (!listening && !pending) ? AppColors.statusWarning : null,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (pending)
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Switch.adaptive(
              value: listening,
              activeColor: AppColors.primaryContainer,
              onChanged: enabled ? onChanged : null,
            ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color iconColor;
  final String value;
  final String unit;
  final String caption;

  const _MetricCard({
    required this.label,
    required this.icon,
    required this.iconColor,
    required this.value,
    required this.unit,
    required this.caption,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: Theme.of(context).textTheme.labelSmall)),
              Container(
                width: 30,
                height: 30,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.surfaceContainer,
                ),
                child: Icon(icon, size: 17, color: iconColor),
              ),
            ],
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (unit.isNotEmpty) ...[
                  const SizedBox(width: 3),
                  Text(unit, style: const TextStyle(fontSize: 14, color: AppColors.textSecondary)),
                ],
              ],
            ),
          ),
          Text(
            caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
          ),
        ],
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  final LoggedEvent event;
  const _EventRow({required this.event});

  @override
  Widget build(BuildContext context) {
    final color = _eventColor(event.eventType);
    final surface = _eventSurface(event.eventType);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(shape: BoxShape.circle, color: surface),
            child: Icon(_eventIcon(event.eventType), size: 20, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _eventLabel(event.eventType),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  _clock(event.at),
                  style: TextStyle(fontSize: 13, color: color),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(color: surface, borderRadius: BorderRadius.circular(20)),
            child: Text(
              '${(event.confidence * 100).round()}%',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: Theme.of(context).textTheme.labelSmall),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 14, color: AppColors.textPrimary)),
          ),
        ],
      ),
    );
  }
}

// --- Taxonomía de eventos -------------------------------------------------
// Los event_type se normalizan y se mapean a una categoría canónica, así que
// da igual si el firmware publica "caida", "caiguda", "Caída" o "impacte".

/// Quita acentos, pasa a minúsculas y unifica separadores.
String _normalizeType(String type) {
  const accented = 'áàäâãéèëêíìïîóòöôõúùüûñç';
  const plain = 'aaaaaeeeeiiiiooooouuuunc';
  final buf = StringBuffer();
  for (final ch in type.toLowerCase().trim().split('')) {
    final i = accented.indexOf(ch);
    buf.write(i >= 0 ? plain[i] : ch);
  }
  return buf.toString().replaceAll(RegExp(r'[\s\-\.]+'), '_');
}

/// Categoría canónica del evento. Devuelve '' si no se reconoce.
String _canonType(String type) {
  final t = _normalizeType(type);

  const groups = <String, List<String>>{
    'fall': [
      'caida', 'caida_detectada', 'caiguda', 'cop', 'cops', 'golpe',
      'impacte', 'impacto', 'impact', 'fall', 'thump', 'thud', 'bang',
    ],
    'cough': [
      'tos', 'tos_persistente', 'tos_persistent', 'cough', 'coughing',
    ],
    'distress': [
      'grito', 'gritos', 'crit', 'crits', 'scream', 'screaming', 'shout',
      'auxilio', 'socorro', 'help', 'ayuda',
      'angustia', 'voces_angustia', 'voces_de_angustia', 'voz_angustia',
      'veu_angoixa', 'veus_angoixa', 'distress', 'distress_voice',
      'groan', 'quejido',
    ],
    'cry': [
      'plor', 'plors', 'llanto', 'cry', 'crying', 'sob', 'sobbing',
    ],
    'snore': [
      'ronc', 'roncs', 'ronquido', 'snore', 'snoring',
    ],
    'silence': [
      'silencio_anomal', 'silencio_anomalo', 'silenci_anomal', 'silencio',
      'silenci', 'silence', 'anomalous_silence',
    ],
    'light': [
      'luz_encesa', 'luz_encendida', 'llum', 'luz', 'light', 'light_change',
      'cambio_luz', 'canvi_llum',
    ],
    'temp': [
      'temp_fora_rang', 'temp_fuera_rango', 'temperatura', 'temp',
      'temp_out_of_range',
    ],
  };

  for (final entry in groups.entries) {
    if (entry.value.contains(t)) return entry.key;
  }
  return '';
}

/// Formatea un event_type desconocido de forma legible.
String _prettyRaw(String type) {
  final s = type.replaceAll(RegExp(r'[_\-]+'), ' ').trim();
  if (s.isEmpty) return 'undet_event'.tr();
  return s[0].toUpperCase() + s.substring(1);
}

String _eventLabel(String type) {
  switch (_canonType(type)) {
    case 'fall':
      return 'fall'.tr();
    case 'cough':
      return 'cough'.tr();
    case 'distress':
      return 'distress'.tr();
    case 'cry':
      return 'cry'.tr();
    case 'snore':
      return 'snore'.tr();
    case 'silence':
      return 'silence_anomalous'.tr();
    case 'light':
      return 'light_case'.tr();
    case 'temp':
      return 'temp_case'.tr();
    default:
      return _prettyRaw(type);
  }
}

IconData _eventIcon(String type) {
  switch (_canonType(type)) {
    case 'fall':
      return Icons.personal_injury;
    case 'cough':
      return Icons.hearing;
    case 'distress':
      return Icons.campaign;
    case 'cry':
      return Icons.sentiment_dissatisfied;
    case 'snore':
      return Icons.bedtime;
    case 'silence':
      return Icons.volume_off;
    case 'light':
      return Icons.lightbulb;
    case 'temp':
      return Icons.device_thermostat;
    default:
      return Icons.graphic_eq;
  }
}

Color _eventColor(String type) {
  switch (_canonType(type)) {
    case 'fall':
    case 'distress':
      return AppColors.alertCritical;
    case 'cough':
    case 'cry':
    case 'silence':
    case 'temp':
      return AppColors.statusWarning;
    case 'snore':
    case 'light':
      return AppColors.statusSuccess;
    default:
      return AppColors.textSecondary;
  }
}

Color _eventSurface(String type) {
  switch (_canonType(type)) {
    case 'fall':
    case 'distress':
      return AppColors.alertCriticalSurface;
    case 'cough':
    case 'cry':
    case 'silence':
    case 'temp':
      return AppColors.statusWarningSurface;
    case 'snore':
    case 'light':
      return AppColors.statusSuccessSurface;
    default:
      return AppColors.surfaceContainerHigh;
  }
}

String _clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'seconds_ago'.tr();
  if (d.inMinutes < 60) return '${'min1_ago'.tr()}${d.inMinutes} ${'min2_ago'.tr()}';
  return '${'h1_ago'.tr()}${d.inHours} ${'h2_ago'.tr()}';
}

String _rssiQuality(int? rssi) {
  if (rssi == null) return 'no_data'.tr();
  if (rssi > -60) return 'sgnl_exclnt'.tr();
  if (rssi > -75) return 'sgnl_ok'.tr();
  return 'sgnl_bad'.tr();
}
