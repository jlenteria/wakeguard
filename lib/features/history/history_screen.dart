import 'package:flutter/material.dart';

import '../../shared/toast.dart';
import 'history_screen_view_model.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key, required this.viewModel});

  final HistoryScreenViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final entries = viewModel.entries;
    final rows = <(DateTime?, Map<String, Object?>?)>[
      for (final day in viewModel.days) ...[
        (day.date, null),
        for (final entry in day.entries) (day.date, entry),
      ],
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wake-up history'),
        actions: [
          IconButton(
            tooltip: 'Refresh history',
            onPressed: viewModel.refreshing ? null : () => _refresh(context),
            icon: viewModel.refreshing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
          if (entries.isNotEmpty)
            IconButton(
              tooltip: 'Delete history',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _clear(context),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _refresh(context),
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          itemCount: rows.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 24,
                            runSpacing: 16,
                            children: [
                              _HistoryStat(
                                value: viewModel.stats.streak,
                                label: 'Scheduled-day streak',
                              ),
                              _HistoryStat(
                                value: viewModel.completed,
                                label: 'Dismissed · last 7 days',
                              ),
                              _HistoryStat(
                                value: viewModel.missed,
                                label: 'Missed · last 7 days',
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '${viewModel.stats.totalDays} days completed overall',
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Dismissals and check-ins show interaction with your alarm, not proof of sleep quality. Unscheduled days do not break the streak.',
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (entries.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Your first morning starts the story. Completed challenges, snoozes, missed alarms and check-ins will appear here.',
                      ),
                    ),
                ],
              );
            }
            final (day, entry) = rows[index - 1];
            if (entry == null) {
              final now = DateTime.now();
              final today = DateTime(now.year, now.month, now.day);
              final yesterday = DateTime(now.year, now.month, now.day - 1);
              final heading = day == null
                  ? 'Date unavailable'
                  : day == today
                  ? 'Today'
                  : day == yesterday
                  ? 'Yesterday'
                  : MaterialLocalizations.of(context).formatFullDate(day);
              return Padding(
                padding: const EdgeInsets.fromLTRB(8, 20, 8, 8),
                child: Text(
                  heading,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              );
            }
            final raw = entry['at'];
            final at = raw is num
                ? DateTime.fromMillisecondsSinceEpoch(raw.toInt())
                : null;
            final event = entry['event'] as String? ?? 'dismissed';
            final duration =
                ((entry['durationMs'] as num?)?.toInt() ?? 0) ~/ 1000;
            final snoozes = (entry['snoozes'] as num?)?.toInt() ?? 0;
            final method = entry['method'] as String? ?? '';
            final scheme = Theme.of(context).colorScheme;
            final color = switch (event) {
              'missed' ||
              'checkin_failed' ||
              'checkin_expired' ||
              'next_schedule_failed' => scheme.error,
              'dismissed' || 'confirmed' => scheme.primary,
              'snoozed' || 'unanswered' => scheme.tertiary,
              _ => scheme.onSurfaceVariant,
            };
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 4,
              ),
              leading: Icon(switch (event) {
                'missed' ||
                'checkin_failed' ||
                'checkin_expired' ||
                'next_schedule_failed' => Icons.error_outline,
                'confirmed' => Icons.verified_outlined,
                'snoozed' => Icons.snooze,
                'dismissed' => Icons.check_circle_outline,
                _ => Icons.alarm,
              }, color: color),
              title: Text(
                '${entry['label'] ?? 'Alarm'} · ${HistoryScreenViewModel.eventLabel(event)}',
              ),
              subtitle: Text(
                [
                  if (at != null)
                    '${MaterialLocalizations.of(context).formatMediumDate(at)} · ${TimeOfDay.fromDateTime(at).format(context)}',
                  if (event == 'dismissed')
                    '${duration ~/ 60}m ${duration % 60}s${method.isEmpty ? '' : ' · ${HistoryScreenViewModel.methodLabel(method)}'} · $snoozes snooze${snoozes == 1 ? '' : 's'}',
                  if (entry['followUp'] == true) 'Follow-up alarm',
                ].join('\n'),
              ),
            );
          },
        ),
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
          message: 'Could not refresh history',
          detail: '$error',
        );
      }
    }
  }

  Future<void> _clear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete wake-up history?'),
        content: const Text(
          'This clears your local history and streak. Your alarms and pending check-ins are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete history'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await viewModel.clearHistory();
      if (context.mounted) {
        showAppToast(
          context,
          kind: ToastKind.success,
          message: 'History cleared',
        );
      }
    } catch (error) {
      if (context.mounted) {
        showAppToast(
          context,
          kind: ToastKind.error,
          message: 'Could not delete history',
          detail: '$error',
        );
      }
    }
  }
}

class _HistoryStat extends StatelessWidget {
  const _HistoryStat({required this.value, required this.label});
  final int value;
  final String label;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('$value', style: Theme.of(context).textTheme.headlineMedium),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}
