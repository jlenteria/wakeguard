import 'package:flutter/material.dart';

import '../core/alarm_controller.dart';
import '../core/settings.dart';

/// App-wide preferences plus the wake-up record.
///
/// Deliberately its own tab rather than a gear in the app bar: theme and
/// snooze defaults are things a user looks for, and the streak is the one
/// piece of feedback the app gives outside of the moment the alarm rings.
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.controller,
    required this.settings,
    required this.onSettingsChanged,
  });

  final AlarmController controller;
  final AppSettings settings;
  final ValueChanged<AppSettings> onSettingsChanged;

  static const _snoozeChoices = [0, 5, 9, 15];

  @override
  Widget build(BuildContext context) {
    final stats = controller.wakeUpStats;
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
              onSelectionChanged: (value) => onSettingsChanged(
                settings.copyWith(themeMode: value.first),
              ),
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
                    label: Text(_snoozeLabel(minutes)),
                    selected: settings.defaultSnoozeMinutes == minutes,
                    onSelected: (_) => onSettingsChanged(
                      settings.copyWith(defaultSnoozeMinutes: minutes),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 32),
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
                      : 'Last: ${_methodLabel(stats.lastMethod)} '
                          '· ${_ago(stats.lastAt!)}',
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

  static String _snoozeLabel(int minutes) =>
      minutes == 0 ? 'No snooze' : '$minutes min';

  static String _methodLabel(String? method) => switch (method) {
        null => 'Dismissal',
        'face' => 'Face challenge',
        'tap' => 'Tap to stop',
        'checkin' => 'Check-in confirmed',
        'qr' => 'QR code',
        'pattern' => 'Pattern',
        'hold' => 'Hold to stop',
        'settings' => 'From settings',
        _ => 'Dismissal',
      };

  static String _ago(DateTime when) {
    final delta = DateTime.now().difference(when);
    if (delta.inMinutes < 1) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
    if (delta.inHours < 24) {
      return '${delta.inHours}h ${delta.inMinutes % 60}m ago';
    }
    return '${delta.inDays}d ago';
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
