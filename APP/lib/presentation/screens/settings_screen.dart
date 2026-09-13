import 'package:flutter/material.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../theme/app_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _notificationsEnabled = true;

  @override
  void initState() {
    super.initState();
    _checkNotificationPermission();
  }

  Future<void> _checkNotificationPermission() async {
    final status = await Permission.notification.status;
    if (mounted) setState(() => _notificationsEnabled = status.isGranted);
  }

  Future<void> _toggleNotifications(bool value) async {
    if (value) {
      final status = await Permission.notification.request();
      setState(() => _notificationsEnabled = status.isGranted);
      if (!status.isGranted) {
        // El usuario denegó desde el sistema; le mandamos a ajustes del SO.
        openAppSettings();
      }
    } else {
      openAppSettings();
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = context.locale.languageCode;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('config'.tr(), style: Theme.of(context).textTheme.displayLarge),
        const SizedBox(height: 24),

        _SectionLabel('lang'.tr()),
        _SettingsGroup(children: [
          _LanguageRow(
            label: 'Català',
            locale: const Locale('ca'),
            selected: current == 'ca',
          ),
          _LanguageRow(
            label: 'Español',
            locale: const Locale('es'),
            selected: current == 'es',
          ),
          _LanguageRow(
            label: 'English',
            locale: const Locale('en'),
            selected: current == 'en',
          ),
        ]),
        const SizedBox(height: 20),

        _SectionLabel('notis'.tr()),
        _SettingsGroup(children: [
          _SettingsRow(
            icon: Icons.notifications_active,
            label: 'alert_incidences'.tr(),
            trailing: Switch(
              value: _notificationsEnabled,
              onChanged: _toggleNotifications,
              activeColor: AppColors.primaryContainer,
            ),
          ),
        ]),
        const SizedBox(height: 20),

        _SectionLabel('about'.tr()),
        _SettingsGroup(children: [
          _SettingsRow(
            icon: Icons.info_outline,
            label: 'app_version'.tr(),
            trailingText: 'v0.1.0',
          ),
        ]),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(letterSpacing: 1),
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  final List<Widget> children;
  const _SettingsGroup({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceCard,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          for (int i = 0; i < children.length; i++) ...[
            children[i],
            if (i != children.length - 1)
              const Divider(
                height: 1,
                color: AppColors.surfaceContainerHigh,
                indent: 56,
              ),
          ],
        ],
      ),
    );
  }
}

/// Fila de selección de idioma. El cambio es inmediato: easy_localization
/// reconstruye el árbol y persiste la elección automáticamente.
class _LanguageRow extends StatelessWidget {
  final String label;
  final Locale locale;
  final bool selected;

  const _LanguageRow({
    required this.label,
    required this.locale,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? AppColors.primaryContainer : AppColors.textSecondary,
        size: 20,
      ),
      title: Text(
        label,
        style: TextStyle(
          color: AppColors.textPrimary,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      onTap: () => context.setLocale(locale),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget? trailing;
  final String? trailingText;
  final Color? iconColor;
  final VoidCallback? onTap;

  const _SettingsRow({
    required this.icon,
    required this.label,
    this.trailing,
    this.trailingText,
    this.iconColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: iconColor ?? AppColors.textSecondary, size: 20),
      title: Text(label, style: TextStyle(color: iconColor ?? AppColors.textPrimary)),
      trailing: trailing ??
          (trailingText != null
              ? Text(
                  trailingText!,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: AppColors.textSecondary),
                )
              : (onTap != null
                  ? const Icon(Icons.chevron_right, color: AppColors.textTertiary)
                  : null)),
      onTap: onTap,
    );
  }
}
