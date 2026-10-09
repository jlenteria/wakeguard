import 'package:flutter/material.dart';

import '../../models/health.dart';
import '../../shared/toast.dart';
import 'health_screen_view_model.dart';

/// The screen addressing the core problem: alarms silently failing due to OS settings.
class HealthScreen extends StatelessWidget {
  const HealthScreen({super.key, required this.viewModel, this.onReturnToAlarm});

  final HealthScreenViewModel viewModel;
  final VoidCallback? onReturnToAlarm;

  @override
  Widget build(BuildContext context) {
    final capabilities = viewModel.capabilities;
    final blocking = viewModel.blocking;

    return Scaffold(
      appBar: AppBar(title: const Text('Alarm health')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (onReturnToAlarm != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.icon(
                onPressed: onReturnToAlarm,
                icon: const Icon(Icons.alarm),
                label: const Text('Return to alarm'),
              ),
            ),
          if (blocking.isNotEmpty) _BlockingBanner(count: blocking.length),
          for (final check in viewModel.checks)
            _HealthTile(check: check, onFix: viewModel.openFix),
          const Divider(height: 32),
          if (capabilities != null) _CapabilityCard(capabilities: capabilities),
          const Divider(height: 32),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.icon(
              icon: const Icon(Icons.volume_up),
              label: const Text('Play audibility test'),
              onPressed: viewModel.runPreflight,
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: Text(
              'Plays the real alarm ladder through the alarm volume. If you '
              'cannot hear this, your alarm will not wake you either.',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _BlockingBanner extends StatelessWidget {
  const _BlockingBanner({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Icon(Icons.error),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '$count setting(s) will stop this alarm from ringing. '
              'Fix these before you rely on it.',
            ),
          ),
        ],
      ),
    );
  }
}

class _HealthTile extends StatelessWidget {
  const _HealthTile({required this.check, required this.onFix});

  final HealthCheck check;
  final Future<String?> Function(String action) onFix;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (check.severity) {
      HealthSeverity.ok => (Icons.check_circle, Theme.of(context).colorScheme.primary),
      HealthSeverity.warning => (
          Icons.error_outline,
          Theme.of(context).brightness == Brightness.dark
              ? Colors.amber.shade300
              : Colors.orange.shade800
        ),
      HealthSeverity.blocking => (Icons.dangerous, Theme.of(context).colorScheme.error),
    };
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(check.label),
      subtitle: Text(check.detail),
      trailing: check.action == null
          ? null
          : TextButton(
              onPressed: () async {
                // Show why the settings screen did not open; otherwise Fix looks inert/broken.
                final failure = await onFix(check.action!);
                if (!context.mounted) return;
                showAppToast(
                  context,
                  kind: failure == null ? ToastKind.success : ToastKind.error,
                  message: failure == null ? 'Opened settings' : 'Could not open settings',
                  detail: failure ?? 'Grant access, then re-check.',
                  duration: const Duration(seconds: 5),
                );
              },
              child: const Text('Fix'),
            ),
    );
  }
}

class _CapabilityCard extends StatelessWidget {
  const _CapabilityCard({required this.capabilities});

  final EngineCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final entries = <(String, bool)>[
      ('Loop until dismissed', capabilities.canLoopWhileBackgrounded),
      ('Take over the lock screen', capabilities.canLockScreenTakeover),
      ('Camera challenge in background', capabilities.canUseCameraInBackground),
      ('Sound through silent mode', capabilities.canBypassSilentSwitch),
      ('Pending notification limit', !capabilities.hasPendingSlotCap),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('This platform can', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 12),
              for (final (label, supported) in entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Icon(
                        supported ? Icons.check : Icons.remove,
                        size: 18,
                        color: supported ? Colors.greenAccent : Colors.grey,
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
                    ],
                  ),
                ),
              if (capabilities.pendingSlotCap != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'iOS keeps only the soonest '
                    '${capabilities.pendingSlotCap} scheduled notifications and '
                    'discards the rest silently.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
