import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/alarm.dart';
import '../../shared/toast.dart';
import 'alarms_screen_view_model.dart';

/// The home tab: readiness, the next armed trigger, and every saved alarm.
class AlarmsScreen extends StatelessWidget {
  const AlarmsScreen({
    super.key,
    required this.viewModel,
    required this.onOpen,
    this.onOpenHealth,
  });

  final AlarmsScreenViewModel viewModel;

  /// Opens the editor for an existing alarm; row taps previously only toggled the switch.
  final Future<void> Function(Alarm alarm) onOpen;
  final VoidCallback? onOpenHealth;

  @override
  Widget build(BuildContext context) {
    if (viewModel.loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final dropped = viewModel.dropped;
    final soonest = viewModel.nextTrigger;
    return Scaffold(
      appBar: AppBar(title: const Text('WakeGuard')),
      body: Column(
        children: [
          if (viewModel.lastError != null)
            _ErrorBar(
              message: viewModel.lastError!,
              onDismiss: viewModel.clearError,
            ),
          Expanded(
            child: viewModel.isEmpty
                ? Column(children: [
                    _ReadinessCard(viewModel: viewModel, onOpenHealth: onOpenHealth),
                    const Expanded(child: _EmptyState()),
                  ])
                : ListView.builder(
                    itemCount: viewModel.alarms.length + 2,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return Column(children: [
                          _ReadinessCard(viewModel: viewModel, onOpenHealth: onOpenHealth),
                          if (dropped.isNotEmpty) _SlotWarning(count: dropped.length),
                          if (soonest != null) _NextAlarmBanner(triggerAt: soonest),
                        ]);
                      }
                      if (index == viewModel.alarms.length + 1) {
                        return const SizedBox(height: 96);
                      }
                      final alarm = viewModel.alarms[index - 1];
                      return _AlarmTile(
                        alarm: alarm,
                        plannedAt: viewModel.fireTime(alarm.id),
                        onOpen: onOpen,
                        onToggle: (value) async {
                          try {
                            final cameraMissing = await viewModel.toggle(alarm, value);
                            if (cameraMissing) onOpenHealth?.call();
                          } catch (error) {
                            if (context.mounted) {
                              showAppToast(context,
                                  kind: ToastKind.error,
                                  message: 'Could not update alarm',
                                  detail: '$error');
                            }
                          }
                        },
                        onDelete: () => viewModel.delete(alarm),
                        onRestore: () => viewModel.restore(alarm),
                        onDuplicate: () => viewModel.duplicate(alarm),
                        onSkip: () => viewModel.toggleSkip(alarm),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ReadinessCard extends StatelessWidget {
  const _ReadinessCard({required this.viewModel, this.onOpenHealth});

  final AlarmsScreenViewModel viewModel;
  final VoidCallback? onOpenHealth;

  @override
  Widget build(BuildContext context) {
    final blocking = viewModel.unresolvedChecks;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: ListTile(
        leading: Icon(blocking.isEmpty ? Icons.check_circle_outline : Icons.error_outline),
        title: Text(viewModel.checks.isEmpty
            ? 'Checking readiness…'
            : blocking.isEmpty
                ? 'Alarm settings ready'
                : 'Your alarm needs attention'),
        subtitle: Text(blocking.isEmpty
            ? 'Practise your challenge and test the sound before your first morning.'
            : blocking.map((c) => c.label).join(', ')),
        onTap: onOpenHealth,
      ),
    );
  }
}

class _NextAlarmBanner extends StatelessWidget {
  const _NextAlarmBanner({required this.triggerAt});

  final DateTime triggerAt;

  @override
  Widget build(BuildContext context) {
    final delta = triggerAt.difference(DateTime.now());
    final label = delta.isNegative || delta.inMinutes < 1
        ? 'rings now'
        : delta.inHours >= 24
            ? 'rings in ${delta.inDays}d ${delta.inHours % 24}h'
            : 'rings in ${delta.inHours}h ${delta.inMinutes % 60}m';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          const Icon(Icons.schedule, size: 16),
          const SizedBox(width: 8),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _ErrorBar extends StatelessWidget {
  const _ErrorBar({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.errorContainer,
      child: ListTile(
        leading: const Icon(Icons.error_outline),
        title: Text(message, style: const TextStyle(fontSize: 13)),
        trailing: IconButton(icon: const Icon(Icons.close), onPressed: onDismiss),
      ),
    );
  }
}

class _SlotWarning extends StatelessWidget {
  const _SlotWarning({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.warning_amber),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '$count alarm(s) exceed this platform\'s pending notification '
                'budget and will NOT ring. Disable or delete some alarms '
                '(swipe left to delete).',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AlarmTile extends StatelessWidget {
  const _AlarmTile({
    required this.alarm,
    required this.onOpen,
    required this.onToggle,
    required this.onDelete,
    required this.onRestore,
    required this.onDuplicate,
    required this.onSkip,
    this.plannedAt,
  });

  final Alarm alarm;
  final Future<void> Function(Alarm alarm) onOpen;
  final Future<void> Function(bool) onToggle;
  final Future<bool> Function() onDelete;
  final Future<void> Function() onRestore;
  final Future<void> Function() onDuplicate;
  final Future<void> Function() onSkip;
  final DateTime? plannedAt;

  @override
  Widget build(BuildContext context) {
    final time = TimeOfDay(hour: alarm.hour, minute: alarm.minute);
    final timeLabel = time.format(context);
    final messenger = ScaffoldMessenger.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Dismissible(
      key: ValueKey(alarm.id),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        final deleted = await onDelete();
        if (!deleted) return false;
        // Captured before the await: the tile unmounts, so a later lookup would throw.
        messenger.clearSnackBars();
        showToastTo(
          messenger,
          scheme,
          kind: ToastKind.success,
          message: 'Deleted the $timeLabel alarm',
          duration: const Duration(seconds: 5),
          actionLabel: 'Undo',
          onAction: () => unawaited(onRestore().catchError((Object error) {
            showToastTo(messenger, scheme,
                kind: ToastKind.error, message: 'Could not restore alarm', detail: '$error');
          })),
        );
        return true;
      },
      background: Container(
        color: Theme.of(context).colorScheme.error,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.delete_outline),
      ),
      // Plain ListTile: SwitchListTile wires row taps to the switch, blocking edits.
      child: Opacity(
        opacity: alarm.enabled ? 1 : 0.55,
        child: ListTile(
          onTap: () => onOpen(alarm),
          title: Text(time.format(context), style: const TextStyle(fontSize: 32)),
          subtitle: Text([
            '${alarm.label} · ${_repeatSummary(alarm)}',
            if (plannedAt != null) 'rings ${_relative(plannedAt!)}',
            '${alarm.difficulty.label} challenge · ${_escapeSummary(alarm)}'
                '${alarm.snoozeMinutes == 0 ? ' · no snooze' : ''}',
            if (alarm.checkInMinutes > 0) 'Stay Awake check-in · ${alarm.checkInMinutes} min',
            if (alarm.skipUntilMillis > DateTime.now().millisecondsSinceEpoch) 'Next occurrence skipped',
          ].join('\n')),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Switch(value: alarm.enabled, onChanged: (value) => onToggle(value)),
            PopupMenuButton<String>(
              tooltip: 'Alarm actions',
              onSelected: (action) async {
                try {
                  if (action == 'duplicate') await onDuplicate();
                  if (action == 'skip') await onSkip();
                  if (!context.mounted) return;
                  showAppToast(
                      context,
                      kind: ToastKind.success,
                      message: action == 'duplicate'
                          ? 'Alarm duplicated, switched off.'
                          : 'Schedule updated.',
                      detail: action == 'duplicate' ? 'Edit it to choose a time.' : null);
                } catch (error) {
                  if (context.mounted) {
                    showAppToast(context,
                        kind: ToastKind.error, message: 'Could not update alarm', detail: '$error');
                  }
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
                if (alarm.enabled && alarm.isRepeating)
                  PopupMenuItem(
                    value: 'skip',
                    child: Text(alarm.skipUntilMillis > DateTime.now().millisecondsSinceEpoch
                        ? 'Restore skipped occurrence'
                        : 'Skip next occurrence'),
                  ),
              ],
            ),
          ]),
        ),
      ),
    );
  }

  /// "Face, Pattern" — what the alarm asks for, so a restricted set is visible.
  static String _escapeSummary(Alarm alarm) => EscapeKind.values
      .where(alarm.escapes.contains)
      .map((escape) => escape.label)
      .join(', ');

  /// "Every day", "Mon, Wed, Fri" or "Once" — the alarm's shape at a glance.
  static String _repeatSummary(Alarm alarm) {
    if (!alarm.isRepeating) return 'Once';
    if (alarm.weekdays.isEmpty) return 'Every day';
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final ordered = alarm.weekdays.toList()..sort();
    return ordered.map((day) => names[day - 1]).join(', ');
  }

  static String _relative(DateTime when) {
    final delta = when.difference(DateTime.now());
    if (delta.isNegative || delta.inMinutes < 1) return 'now';
    if (delta.inMinutes < 60) return 'in ${delta.inMinutes}m';
    if (delta.inHours < 24) return 'in ${delta.inHours}h ${delta.inMinutes % 60}m';
    return 'in ${delta.inDays}d';
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.alarm_off_outlined, size: 56),
            SizedBox(height: 16),
            Text(
              'Make tomorrow morning easier.\nAdd an alarm, choose a preset, '
              'and practise your challenge.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
