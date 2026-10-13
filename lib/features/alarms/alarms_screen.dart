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
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _refresh(context),
              child: viewModel.isEmpty
                  ? CustomScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        if (viewModel.lastError != null)
                          SliverToBoxAdapter(
                            child: _ErrorBar(
                              message: viewModel.lastError!,
                              onDismiss: viewModel.clearError,
                            ),
                          ),
                        SliverToBoxAdapter(
                          child: _ReadinessCard(
                            viewModel: viewModel,
                            onOpenHealth: onOpenHealth,
                          ),
                        ),
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: _EmptyState(),
                        ),
                      ],
                    )
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: viewModel.alarms.length + 2,
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return Column(
                            children: [
                              if (viewModel.lastError != null)
                                _ErrorBar(
                                  message: viewModel.lastError!,
                                  onDismiss: viewModel.clearError,
                                ),
                              _ReadinessCard(
                                viewModel: viewModel,
                                onOpenHealth: onOpenHealth,
                              ),
                              if (dropped.isNotEmpty)
                                _SlotWarning(count: dropped.length),
                              if (soonest != null)
                                _NextAlarmBanner(
                                  triggerAt: soonest,
                                  alarm: viewModel.nextAlarm,
                                ),
                              if (soonest == null)
                                Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text(
                                    viewModel.hasEnabledAlarms
                                        ? 'No upcoming alarm scheduled. Check Health for details.'
                                        : 'No alarms enabled. Switch one on to schedule your next wake-up.',
                                  ),
                                ),
                            ],
                          );
                        }
                        if (index == viewModel.alarms.length + 1) {
                          return const SizedBox(height: 96);
                        }
                        final alarm = viewModel.alarms[index - 1];
                        return _AlarmTile(
                          alarm: alarm,
                          busy: viewModel.isBusy(alarm.id),
                          plannedAt: viewModel.fireTime(alarm.id),
                          onOpen: onOpen,
                          onToggle: (value) async {
                            try {
                              final cameraMissing = await viewModel.toggle(
                                alarm,
                                value,
                              );
                              if (cameraMissing) onOpenHealth?.call();
                            } catch (error) {
                              if (context.mounted) {
                                showAppToast(
                                  context,
                                  kind: ToastKind.error,
                                  message: 'Could not update alarm',
                                  detail: '$error',
                                );
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
          ),
        ],
      ),
    );
  }

  Future<void> _refresh(BuildContext context) async {
    try {
      await viewModel.refresh();
    } catch (error) {
      if (context.mounted) {
        showAppToast(
          context,
          kind: ToastKind.error,
          message: 'Could not refresh alarms',
          detail: '$error',
        );
      }
    }
  }
}

class _ReadinessCard extends StatelessWidget {
  const _ReadinessCard({required this.viewModel, this.onOpenHealth});

  final AlarmsScreenViewModel viewModel;
  final VoidCallback? onOpenHealth;

  @override
  Widget build(BuildContext context) {
    final blocking = viewModel.unresolvedChecks;
    final warnings = viewModel.warnings;
    final ready =
        blocking.isEmpty && warnings.isEmpty && viewModel.readinessKnown;
    // The all-clear card is noise on every visit; only surface trouble here.
    if (ready) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: ListTile(
        leading: Icon(
          Icons.error_outline,
          color: blocking.isNotEmpty ? scheme.error : scheme.primary,
        ),
        trailing: const Icon(Icons.chevron_right),
        title: Text(
          !viewModel.readinessKnown
              ? 'Readiness unavailable'
              : 'Your alarm needs attention',
        ),
        subtitle: Text(
          !viewModel.readinessKnown
              ? 'Open Health to check your settings.'
              : [...blocking, ...warnings].map((c) => c.label).join(', '),
        ),
        onTap: onOpenHealth,
      ),
    );
  }
}

class _NextAlarmBanner extends StatelessWidget {
  const _NextAlarmBanner({required this.triggerAt, this.alarm});

  final DateTime triggerAt;
  final Alarm? alarm;

  @override
  Widget build(BuildContext context) {
    final delta = triggerAt.difference(DateTime.now());
    final label = delta.isNegative || delta.inMinutes < 1
        ? 'rings now'
        : delta.inHours >= 24
        ? 'rings in ${delta.inDays}d ${delta.inHours % 24}h'
        : 'rings in ${delta.inHours}h ${delta.inMinutes % 60}m';
    final localizations = MaterialLocalizations.of(context);
    return SizedBox(
      width: double.infinity,
      child: Card(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Next alarm', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Text(
                TimeOfDay.fromDateTime(triggerAt).format(context),
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              Text(
                '${alarm?.label.isNotEmpty == true ? alarm!.label : 'Alarm'} · '
                '${localizations.formatFullDate(triggerAt)}',
              ),
              const SizedBox(height: 8),
              Text(label, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
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
        trailing: IconButton(
          icon: const Icon(Icons.close),
          onPressed: onDismiss,
        ),
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
                '$count ${count == 1 ? 'alarm cannot' : 'alarms cannot'} be scheduled '
                'because your device’s reminder limit has been reached. '
                'Turn off or delete some alarms to make room.',
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
    required this.busy,
  });

  final Alarm alarm;
  final Future<void> Function(Alarm alarm) onOpen;
  final Future<void> Function(bool) onToggle;
  final Future<bool> Function() onDelete;
  final Future<void> Function() onRestore;
  final Future<void> Function() onDuplicate;
  final Future<void> Function() onSkip;
  final DateTime? plannedAt;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final time = TimeOfDay(hour: alarm.hour, minute: alarm.minute);
    final timeLabel = time.format(context);
    final messenger = ScaffoldMessenger.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Dismissible(
      key: ValueKey(alarm.id),
      direction: busy ? DismissDirection.none : DismissDirection.endToStart,
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
          duration: const Duration(seconds: 10),
          actionLabel: 'Undo',
          onAction: () => unawaited(
            onRestore().catchError((Object error) {
              showToastTo(
                messenger,
                scheme,
                kind: ToastKind.error,
                message: 'Could not restore alarm',
                detail: '$error',
              );
            }),
          ),
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
          onTap: busy ? null : () => onOpen(alarm),
          title: Text(
            time.format(context),
            style: const TextStyle(fontSize: 32),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${alarm.label.isEmpty ? 'Alarm' : alarm.label} · ${_repeatSummary(alarm)}',
              ),
              Text(
                alarm.needsSetup
                    ? 'Setup required · open to choose and practice the new challenge'
                    : !alarm.enabled
                    ? 'Off'
                    : plannedAt != null
                    ? 'Rings ${_relative(plannedAt!)}'
                    : 'Not scheduled',
              ),
              const SizedBox(height: 4),
              Text(
                '${alarm.difficulty.label} · ${_escapeSummary(alarm)}'
                '${alarm.snoozeMinutes == 0 ? ' · no snooze' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (alarm.checkInMinutes > 0)
                Text(
                  'Stay Awake · ${alarm.checkInMinutes} min',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (alarm.skipUntilMillis > DateTime.now().millisecondsSinceEpoch)
                Text(
                  'Next alarm skipped',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              Switch(
                value: alarm.enabled,
                onChanged: busy || alarm.needsSetup
                    ? null
                    : (value) => onToggle(value),
              ),
              PopupMenuButton<String>(
                tooltip: 'Alarm actions',
                enabled: !busy,
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
                      detail: action == 'duplicate'
                          ? 'Edit it to choose a time.'
                          : null,
                    );
                  } catch (error) {
                    if (context.mounted) {
                      showAppToast(
                        context,
                        kind: ToastKind.error,
                        message: 'Could not update alarm',
                        detail: '$error',
                      );
                    }
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'duplicate',
                    child: Text('Duplicate'),
                  ),
                  if (alarm.enabled && alarm.isRepeating)
                    PopupMenuItem(
                      value: 'skip',
                      child: Text(
                        alarm.skipUntilMillis >
                                DateTime.now().millisecondsSinceEpoch
                            ? 'Undo skip'
                            : 'Skip next alarm',
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Selected challenges only; legacy labels remain in History, not this list.
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
    if (delta.inHours < 24) {
      return 'in ${delta.inHours}h ${delta.inMinutes % 60}m';
    }
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
              'and practice your challenge.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
