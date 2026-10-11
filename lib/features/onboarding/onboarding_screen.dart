import 'package:flutter/material.dart';

import '../../shared/toast.dart';
import 'onboarding_screen_view_model.dart';

/// First-run screen for the three settings that decide whether an alarm rings,
/// asked before the first alarm is saved because an empty list prompts nothing.
class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key, required this.viewModel});

  final OnboardingScreenViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          children: [
            Text('WakeGuard', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text(
              'Wake up, complete a challenge, and check you’re still up. '
              'Private, offline and free. Let’s get your first alarm ready.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            _Step(
              icon: Icons.notifications_outlined,
              title: 'Allow notifications',
              body:
                  'Allow WakeGuard to show alarm notifications. '
                  'Sound and lock-screen behavior depend on your phone settings.',
              button: FilledButton.tonal(
                onPressed: viewModel.requestingNotifications
                    ? null
                    : () => _requestNotifications(context),
                child: Text(
                  viewModel.requestingNotifications ? 'Opening…' : 'Allow',
                ),
              ),
            ),
            if (viewModel.hasChecks)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  viewModel.ready
                      ? 'Alarm settings are ready.'
                      : viewModel.pendingSummary,
                ),
              ),
            if (viewModel.lastError != null) Text(viewModel.lastError!),
            _Step(
              icon: Icons.volume_up_outlined,
              title: 'Check the alarm volume',
              body:
                  'A muted alarm stream is silent no matter how '
                  'reliable the scheduling is. This plays the real '
                  'tone for ten seconds.',
              button: FilledButton.tonal(
                onPressed: viewModel.playing
                    ? viewModel.stopTest
                    : viewModel.runPreflight,
                child: Text(viewModel.playing ? 'Stop test' : 'Test the sound'),
              ),
            ),
            if (viewModel.hasExactAlarmCheck)
              _Step(
                icon: Icons.health_and_safety_outlined,
                title: 'Exact alarms',
                body:
                    'Android may delay an alarm by minutes unless it '
                    'is allowed to fire exactly. The Health tab shows '
                    'this and the rest.',
                button: FilledButton.tonal(
                  onPressed: () => _allowExactAlarms(context),
                  child: const Text('Allow exact alarms'),
                ),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: viewModel.finishing ? null : () => _finish(context),
              child: Text(viewModel.finishing ? 'Opening…' : 'Get started'),
            ),
            TextButton(
              onPressed: viewModel.finishing ? null : () => _finish(context),
              child: const Text('Skip for now'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _requestNotifications(BuildContext context) async {
    final failure = await viewModel.requestNotifications();
    if (failure == null || !context.mounted) return;
    showAppToast(
      context,
      kind: ToastKind.error,
      message: 'Could not request notifications',
      detail: failure,
    );
  }

  Future<void> _allowExactAlarms(BuildContext context) async {
    final failure = await viewModel.allowExactAlarms();
    if (failure != null && context.mounted) {
      showAppToast(
        context,
        kind: ToastKind.error,
        message: 'Could not open alarm settings',
        detail: failure,
      );
    }
  }

  Future<void> _finish(BuildContext context) async {
    final failure = await viewModel.finish();
    if (failure != null && context.mounted) {
      showAppToast(
        context,
        kind: ToastKind.error,
        message: 'Could not complete setup',
        detail: failure,
      );
    }
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.icon,
    required this.title,
    required this.body,
    this.button,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? button;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 28),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(body, style: theme.textTheme.bodySmall),
                if (button != null) ...[const SizedBox(height: 8), button!],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
