import 'package:flutter/material.dart';

import '../../models/app_settings.dart';
import '../../shared/toast.dart';
import '../challenges/qr_sheet.dart';
import '../support/support_screen.dart';
import 'settings_screen_view_model.dart';

/// App-wide preferences, wake-up QR, package information and optional support.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.viewModel});

  final SettingsScreenViewModel viewModel;

  static const _snoozeChoices = [0, 5, 9, 15];

  @override
  Widget build(BuildContext context) {
    final settings = viewModel.value;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
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
            title: 'Alarm defaults',
            subtitle:
                'Applied to alarms you create from now on. Each alarm '
                'can override it, including switching snooze off entirely.',
            child: Wrap(
              spacing: 8,
              children: [
                for (final minutes in _snoozeChoices)
                  ChoiceChip(
                    label: Text(SettingsScreenViewModel.snoozeLabel(minutes)),
                    selected: settings.defaultSnoozeMinutes == minutes,
                    onSelected: (_) => viewModel.update(
                      settings.copyWith(defaultSnoozeMinutes: minutes),
                    ),
                  ),
              ],
            ),
          ),
          _Section(
            title: 'Wake-up QR',
            subtitle:
                'Print once and place it away from bed. New QR alarms reuse '
                'this code. Existing custom codes stay unchanged.',
            child: FilledButton.tonalIcon(
              icon: viewModel.loadingQr
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
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
          _Section(
            title: 'About',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('WakeGuard', style: text.titleMedium),
                const SizedBox(height: 4),
                Text('Version ${viewModel.version}', style: text.bodySmall),
                const SizedBox(height: 12),
                Text(
                  'Start your morning with purpose. WakeGuard combines offline '
                  'alarms, wake-up challenges and optional Stay Awake check-ins.\n\n'
                  'Free. No ads, accounts or tracking. Your alarms and history '
                  'stay on your device. Camera challenges run on-device; '
                  'images are never saved or uploaded.',
                  style: text.bodySmall,
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.favorite_border),
            title: const Text('Support WakeGuard'),
            subtitle: const Text(
              'Optional support for independent development',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SupportScreen()),
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
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
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
      ),
    );
  }
}
