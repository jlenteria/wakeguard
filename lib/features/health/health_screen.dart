import 'package:flutter/material.dart';

import '../../models/health.dart';
import '../../shared/toast.dart';
import 'health_screen_view_model.dart';

/// The screen addressing the core problem: alarms silently failing due to OS settings.
class HealthScreen extends StatelessWidget {
  const HealthScreen({
    super.key,
    required this.viewModel,
    this.onReturnToAlarm,
  });

  final HealthScreenViewModel viewModel;
  final VoidCallback? onReturnToAlarm;

  @override
  Widget build(BuildContext context) {
    final capabilities = viewModel.capabilities;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Alarm health'),
        actions: [
          IconButton(
            tooltip: 'Refresh checks',
            onPressed: viewModel.refreshing ? null : () => _refresh(context),
            icon: viewModel.refreshing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _refresh(context),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            _ReadinessSummary(viewModel: viewModel),
            if (onReturnToAlarm != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: onReturnToAlarm,
                  icon: const Icon(Icons.alarm),
                  label: const Text('Return to alarm'),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Check the sound',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Listen for the alarm tone at your current volume. '
                        'The test stops after 10 seconds. On iOS, a foreground '
                        'test does not verify locked-screen or silent-mode delivery.',
                      ),
                      const SizedBox(height: 12),
                      if (viewModel.playing) ...[
                        const Row(
                          children: [
                            Icon(Icons.graphic_eq, size: 18),
                            SizedBox(width: 8),
                            Text('Sound test running…'),
                          ],
                        ),
                        const SizedBox(height: 8),
                      ],
                      FilledButton.icon(
                        icon: Icon(
                          viewModel.playing ? Icons.stop : Icons.volume_up,
                        ),
                        label: Text(
                          viewModel.playing
                              ? 'Stop test'
                              : 'Play audibility test',
                        ),
                        onPressed: () => _soundTest(context),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            for (final check in [...viewModel.blocking, ...viewModel.warnings])
              _HealthTile(check: check, viewModel: viewModel),
            if (viewModel.passed.isNotEmpty)
              ExpansionTile(
                title: Text('Passed checks (${viewModel.passed.length})'),
                children: [
                  for (final check in viewModel.passed)
                    _HealthTile(check: check, viewModel: viewModel),
                ],
              ),
            const SizedBox(height: 16),
            if (capabilities != null)
              _CapabilityCard(capabilities: capabilities),
          ],
        ),
      ),
    );
  }

  Future<void> _refresh(BuildContext context) async {
    final error = await viewModel.refresh();
    if (error != null && context.mounted) {
      showAppToast(
        context,
        kind: ToastKind.error,
        message: 'Could not refresh checks',
        detail: error,
      );
    }
  }

  Future<void> _soundTest(BuildContext context) async {
    if (viewModel.playing) {
      await viewModel.stopTest();
      return;
    }
    final error = await viewModel.runPreflight();
    if (error != null && context.mounted) {
      showAppToast(
        context,
        kind: ToastKind.error,
        message: 'Could not play sound test',
        detail: error,
      );
    }
  }
}

class _ReadinessSummary extends StatelessWidget {
  const _ReadinessSummary({required this.viewModel});
  final HealthScreenViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final count = viewModel.blocking.length + viewModel.warnings.length;
    final unavailable =
        viewModel.capabilities == null ||
        viewModel.controller.fatalError != null;
    final title = unavailable
        ? 'Readiness unavailable'
        : count == 0
        ? 'Required checks passed'
        : '$count ${count == 1 ? 'setting needs' : 'settings need'} attention';
    final detail = unavailable
        ? 'Refresh to check your alarm settings.'
        : viewModel.blocking.isNotEmpty
        ? 'Fix the required settings below before relying on your alarm.'
        : count > 0
        ? 'Review the warnings below, then test the sound.'
        : 'Your reported settings are clear. Test the sound before relying on an alarm.';
    final color = viewModel.blocking.isNotEmpty
        ? scheme.errorContainer
        : scheme.secondaryContainer;
    final foreground = viewModel.blocking.isNotEmpty
        ? scheme.onErrorContainer
        : scheme.onSecondaryContainer;
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(
            unavailable
                ? Icons.help_outline
                : count == 0
                ? Icons.check_circle_outline
                : Icons.error_outline,
            color: foreground,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(color: foreground),
                ),
                const SizedBox(height: 4),
                Text(detail, style: TextStyle(color: foreground)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HealthTile extends StatelessWidget {
  const _HealthTile({required this.check, required this.viewModel});

  final HealthCheck check;
  final HealthScreenViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (check.severity) {
      HealthSeverity.ok => (
        Icons.check_circle,
        Theme.of(context).colorScheme.primary,
      ),
      HealthSeverity.warning => (
        Icons.error_outline,
        Theme.of(context).brightness == Brightness.dark
            ? Colors.amber.shade300
            : Colors.orange.shade800,
      ),
      HealthSeverity.blocking => (
        Icons.dangerous,
        Theme.of(context).colorScheme.error,
      ),
    };
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(check.label),
      subtitle: Text(check.detail),
      trailing: check.action == null || check.severity == HealthSeverity.ok
          ? null
          : TextButton(
              onPressed: viewModel.fixingAction != null
                  ? null
                  : () async {
                      final failure = await viewModel.openFix(check.action!);
                      if (!context.mounted) return;
                      final resolved = viewModel.checks.any(
                        (c) =>
                            c.id == check.id && c.severity == HealthSeverity.ok,
                      );
                      showAppToast(
                        context,
                        kind: failure != null
                            ? ToastKind.error
                            : resolved
                            ? ToastKind.success
                            : ToastKind.info,
                        message: failure != null
                            ? 'Could not resolve setting'
                            : resolved
                            ? 'Resolved'
                            : 'Action requested',
                        detail:
                            failure ??
                            (resolved
                                ? check.label
                                : 'Complete the permission or settings change, then refresh.'),
                        duration: const Duration(seconds: 5),
                      );
                    },
              child: Text(
                viewModel.fixingAction == check.action ? 'Opening…' : 'Fix',
              ),
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
      ('No pending notification limit', !capabilities.hasPendingSlotCap),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This platform can',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 12),
              for (final (label, supported) in entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Icon(
                        supported ? Icons.check : Icons.remove,
                        size: 18,
                        color: supported
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          label,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
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
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'Silent-mode support does not guarantee sound through '
                  'Do Not Disturb or Focus. Check those settings and your alarm volume. '
                  'If alarms are delayed, review battery or background activity restrictions '
                  'in your phone settings. Available options vary by device.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
