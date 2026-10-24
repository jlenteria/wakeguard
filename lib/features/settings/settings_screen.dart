import 'package:flutter/material.dart';

import '../../models/app_settings.dart';
import '../../shared/brand.dart';
import '../../shared/theme.dart';
import '../../shared/toast.dart';
import '../challenges/qr_sheet.dart';
import '../support/support_screen.dart';
import 'settings_screen_view_model.dart';
import 'privacy_policy_screen.dart';

/// App-wide preferences, wake-up QR, package information and optional support.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.viewModel});

  final SettingsScreenViewModel viewModel;

  static const _snoozeChoices = [0, 5, 9, 15];

  @override
  Widget build(BuildContext context) {
    final settings = viewModel.value;
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final scheme = theme.colorScheme;
    final tokens = WakeTokens.of(context);
    final light = theme.brightness == Brightness.light;
    // Design 'primary' (#ffc5b1) with 'on-primary' (#591d02) in dark mode.
    final qrBackground = light ? tokens.cta : tokens.dawn;
    final qrForeground = light ? tokens.onCta : const Color(0xff591d02);
    final paragraph = text.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
      height: 1.625,
    );
    return Scaffold(
      appBar: const BrandAppBar(section: 'Settings'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          const _StatusStrip(),
          const SizedBox(height: 16),
          _Section(
            title: 'Appearance',
            subtitle:
                'Match your phone, or keep WakeGuard always light or dark.',
            child: _AppearanceToggle(
              selected: settings.themeMode,
              onChanged: (mode) =>
                  _update(context, settings.copyWith(themeMode: mode)),
            ),
          ),
          _Section(
            title: 'Alarm defaults',
            subtitle:
                'Snooze length for new alarms. You can change it or turn '
                'snooze off for each alarm.',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final minutes in _snoozeChoices)
                  _SnoozeChip(
                    label: SettingsScreenViewModel.snoozeLabel(minutes),
                    selected: settings.defaultSnoozeMinutes == minutes,
                    onSelected: () => _update(
                      context,
                      settings.copyWith(defaultSnoozeMinutes: minutes),
                    ),
                  ),
              ],
            ),
          ),
          _Section(
            title: 'Wake-up QR',
            icon: Icons.qr_code_scanner,
            iconColor: light ? scheme.secondary : const Color(0xff00dce6),
            subtitle:
                'Print once and place it away from bed. New QR alarms use '
                'this code; codes you already set stay as they are.',
            child: DecoratedBox(
              decoration: ShapeDecoration(
                shape: const StadiumBorder(),
                shadows: [
                  BoxShadow(
                    color: tokens.cta.withValues(alpha: 0.25),
                    offset: const Offset(0, 8),
                    blurRadius: 24,
                    spreadRadius: -2,
                  ),
                ],
              ),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: qrBackground,
                  foregroundColor: qrForeground,
                  minimumSize: const Size(0, 50),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 14,
                  ),
                  iconSize: 20,
                  textStyle: text.labelLarge,
                ),
                icon: viewModel.loadingQr
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: qrForeground,
                        ),
                      )
                    : const Icon(Icons.qr_code_2),
                label: Text(
                  viewModel.loadingQr ? 'Opening QR…' : 'Show wake-up QR',
                ),
                onPressed: viewModel.openingQr
                    ? null
                    : () async {
                        if (!viewModel.beginQrOpen()) return;
                        try {
                          final value = await viewModel.wakeUpQrValue();
                          viewModel.finishQrLoad();
                          if (!context.mounted) return;
                          await showModalBottomSheet<void>(
                            context: context,
                            showDragHandle: true,
                            isScrollControlled: true,
                            builder: (_) => QrSheet(value: value),
                          );
                        } catch (error) {
                          if (context.mounted) {
                            showAppToast(
                              context,
                              kind: ToastKind.error,
                              message: 'Could not load wake-up QR',
                              detail: '$error',
                            );
                          }
                        } finally {
                          viewModel.endQrOpen();
                        }
                      },
              ),
            ),
          ),
          SurfaceCard(
            radius: 32,
            padding: const EdgeInsets.all(24),
            margin: const EdgeInsets.only(bottom: 16),
            color: scheme.surfaceContainerLow,
            borderColor: Colors.transparent,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ABOUT',
                  style: text.labelSmall?.copyWith(
                    color: tokens.dawn,
                    letterSpacing: 0.55,
                  ),
                ),
                const SizedBox(height: 4),
                Text('WakeGuard', style: text.headlineSmall),
                const SizedBox(height: 4),
                Text(
                  'Version ${viewModel.version}',
                  style: text.labelMedium?.copyWith(color: scheme.outline),
                ),
                const SizedBox(height: 16),
                Text(
                  'Offline alarms, wake-up challenges and optional Stay Awake '
                  'check-ins that help you start the day on purpose.',
                  style: paragraph,
                ),
                const SizedBox(height: 16),
                Text(
                  'No ads or accounts. Your alarms and history stay '
                  'on your phone. Camera challenges run on-device; images are '
                  'never saved or uploaded by WakeGuard. The Privacy policy '
                  'explains what app tools may send for troubleshooting.',
                  style: paragraph,
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      IconWell(
                        icon: Icons.shield_outlined,
                        color: tokens.cyan,
                        background: tokens.cyan.withValues(alpha: 0.15),
                        size: 40,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Zero Data Collection',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.labelMedium,
                            ),
                            Text(
                              'Strict local sandboxed execution',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SurfaceCard(
            radius: 32,
            padding: EdgeInsets.zero,
            color: scheme.surfaceContainerLow,
            borderColor: Colors.transparent,
            child: Column(
              children: [
                _LinkRow(
                  icon: Icons.info_outlined,
                  iconColor: tokens.dawn,
                  title: 'Privacy policy',
                  subtitle: 'How your data and camera images are handled',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const PrivacyPolicyScreen(),
                    ),
                  ),
                ),
                _LinkRow(
                  icon: Icons.favorite_border,
                  iconColor: scheme.tertiary,
                  title: 'Support WakeGuard',
                  subtitle: 'Optional tip for independent development',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SupportScreen(),
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

  Future<void> _update(BuildContext context, AppSettings next) async {
    try {
      await viewModel.update(next);
    } catch (error) {
      if (!context.mounted) return;
      showAppToast(
        context,
        kind: ToastKind.error,
        message: 'Settings not saved',
        detail: '$error',
      );
    }
  }
}

class _StatusStrip extends StatelessWidget {
  const _StatusStrip();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = WakeTokens.of(context);
    final light = theme.brightness == Brightness.light;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(32),
      ),
      child: Row(
        children: [
          StatusDot(color: tokens.cyan, size: 10),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'OFFLINE READY',
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                // Design 'secondary' (#dcfdff).
                color: light ? scheme.secondary : const Color(0xffdcfdff),
                letterSpacing: 0.275,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '100% On-Device',
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.child,
    this.subtitle,
    this.icon,
    this.iconColor,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final IconData? icon;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SurfaceCard(
      radius: 32,
      padding: const EdgeInsets.all(24),
      margin: const EdgeInsets.only(bottom: 16),
      color: theme.colorScheme.surfaceContainerLow,
      borderColor: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 20, color: iconColor),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(title, style: theme.textTheme.titleMedium),
              ),
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

/// Three equal pills on a rounded track; the selected one is sunrise coral
/// with a check.
class _AppearanceToggle extends StatelessWidget {
  const _AppearanceToggle({required this.selected, required this.onChanged});

  final ThemeModeSetting selected;
  final ValueChanged<ThemeModeSetting> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = WakeTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: ShapeDecoration(
        color: scheme.surfaceContainer,
        shape: const StadiumBorder(),
      ),
      child: Row(
        children: [
          for (final (index, mode) in ThemeModeSetting.values.indexed) ...[
            if (index > 0) const SizedBox(width: 4),
            Expanded(
              child: Semantics(
                button: true,
                selected: mode == selected,
                child: Material(
                  color: mode == selected ? tokens.cta : Colors.transparent,
                  shape: const StadiumBorder(),
                  clipBehavior: Clip.antiAlias,
                  elevation: mode == selected ? 1 : 0,
                  child: InkWell(
                    onTap: mode == selected ? null : () => onChanged(mode),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 12,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (mode == selected) ...[
                            Icon(Icons.check, size: 18, color: tokens.onCta),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              mode.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: mode == selected
                                    ? tokens.onCta
                                    : scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SnoozeChip extends StatelessWidget {
  const _SnoozeChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = WakeTokens.of(context);
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
      shape: const StadiumBorder(),
      side: BorderSide.none,
      backgroundColor: scheme.surfaceContainer,
      selectedColor: tokens.cta,
      showCheckmark: true,
      checkmarkColor: tokens.onCta,
      elevation: 0,
      pressElevation: 0,
      selectedShadowColor: Colors.transparent,
      shadowColor: Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      labelPadding: const EdgeInsets.symmetric(horizontal: 6),
      labelStyle: theme.textTheme.labelMedium?.copyWith(
        color: selected ? tokens.onCta : scheme.onSurfaceVariant,
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.surfaceContainer,
              ),
              child: Icon(icon, size: 22, color: iconColor),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.labelLarge),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, color: scheme.outlineVariant),
          ],
        ),
      ),
    );
  }
}
