import 'package:flutter/material.dart';

import '../../models/app_settings.dart';
import '../../shared/toast.dart';
import '../challenges/qr_sheet.dart';
import 'settings_screen_view_model.dart';

/// App-wide preferences plus the wake-up record.
/// Its own tab: theme, snooze defaults and the streak are things users seek out.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.viewModel});

  final SettingsScreenViewModel viewModel;

  static const _snoozeChoices = [0, 5, 9, 15];

  @override
  Widget build(BuildContext context) {
    final settings = viewModel.value;
    final stats = viewModel.stats;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _Section(
            title: 'Appearance',
            child: SegmentedButton<ThemeModeSetting>(
              segments: [
                for (final mode in ThemeModeSetting.values)
                  ButtonSegment(value: mode, label: Text(mode.label)),
              ],
              selected: {settings.themeMode},
              onSelectionChanged: (value) =>
                  viewModel.update(settings.copyWith(themeMode: value.first)),
            ),
          ),
          _Section(
            title: 'Default snooze',
            subtitle: 'Applied to alarms you create from now on. Each alarm '
                'can override it, including switching snooze off entirely.',
            child: Wrap(
              spacing: 8,
              children: [
                for (final minutes in _snoozeChoices)
                  ChoiceChip(
                    label: Text(SettingsScreenViewModel.snoozeLabel(minutes)),
                    selected: settings.defaultSnoozeMinutes == minutes,
                    onSelected: (_) =>
                        viewModel.update(settings.copyWith(defaultSnoozeMinutes: minutes)),
                  ),
              ],
            ),
          ),
          const Divider(height: 32),
          _Section(
            title: 'Wake-up QR',
            subtitle: 'Print once and place it away from bed. New QR alarms reuse '
                'this code. Existing custom codes stay unchanged.',
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.qr_code_2),
              label: const Text('Show wake-up QR'),
              onPressed: () async {
                try {
                  final value = await viewModel.wakeUpQrValue();
                  if (!context.mounted) return;
                  await showModalBottomSheet<void>(
                    context: context,
                    showDragHandle: true,
                    isScrollControlled: true,
                    builder: (_) => QrSheet(value: value),
                  );
                } catch (error) {
                  if (context.mounted) {
                    showAppToast(context,
                        kind: ToastKind.error, message: 'Could not load wake-up QR', detail: '$error');
                  }
                }
              },
            ),
          ),
          _Section(
            title: 'Wake-ups',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 24,
                  runSpacing: 16,
                  children: [
                    _Stat(value: '${stats.streak}', label: 'scheduled-day streak'),
                    _Stat(value: '${stats.totalDays}', label: 'days completed'),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  stats.lastAt == null
                      ? 'No wake-ups recorded yet. They appear here after you '
                          'dismiss an alarm.'
                      : 'Last: ${SettingsScreenViewModel.methodLabel(stats.lastMethod)} '
                          '· ${SettingsScreenViewModel.ago(stats.lastAt!)}',
                  style: text.bodySmall,
                ),
              ],
            ),
          ),
          const Divider(height: 32),
          _Section(
            title: 'About',
            child: Text(
              'WakeGuard is free, with no ads, no accounts and no tracking. '
              'Everything it stores stays on this phone. The camera is used '
              'only while a challenge is on screen, and frames are never saved '
              'or sent anywhere.',
              style: text.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.subtitle});

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: Theme.of(context).textTheme.headlineMedium),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
