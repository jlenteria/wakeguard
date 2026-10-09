import 'package:flutter/material.dart';

import '../../shared/toast.dart';
import 'history_screen_view_model.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key, required this.viewModel});

  final HistoryScreenViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final entries = viewModel.entries;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wake-up history'),
        actions: [
          if (entries.isNotEmpty)
            IconButton(
              tooltip: 'Delete history',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _clear(context),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: viewModel.refresh,
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          itemCount: entries.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${viewModel.stats.streak} scheduled-day streak',
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 8),
                      Text('Last 7 days: ${viewModel.completed} dismissed · ${viewModel.missed} missed'),
                      const SizedBox(height: 8),
                      const Text(
                          'Dismissals and check-ins show interaction with your alarm, not proof of sleep quality. Unscheduled days do not break the streak.'),
                    ]),
                  ),
                ),
                if (entries.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                        'Your first morning starts the story. Completed challenges, snoozes, missed alarms and check-ins will appear here.'),
                  ),
              ]);
            }
            final entry = entries[index - 1];
            final raw = entry['at'];
            final at = raw is num ? DateTime.fromMillisecondsSinceEpoch(raw.toInt()) : null;
            final event = entry['event'] as String? ?? 'dismissed';
            final duration = ((entry['durationMs'] as num?)?.toInt() ?? 0) ~/ 1000;
            final snoozes = (entry['snoozes'] as num?)?.toInt() ?? 0;
            final method = entry['method'] as String? ?? '';
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              leading: Icon(switch (event) {
                'missed' || 'checkin_failed' || 'checkin_expired' || 'next_schedule_failed' =>
                  Icons.error_outline,
                'confirmed' => Icons.verified_outlined,
                'snoozed' => Icons.snooze,
                'dismissed' => Icons.check_circle_outline,
                _ => Icons.alarm,
              }),
              title: Text('${entry['label'] ?? 'Alarm'} · ${HistoryScreenViewModel.eventLabel(event)}'),
              subtitle: Text([
                if (at != null)
                  '${MaterialLocalizations.of(context).formatMediumDate(at)} · ${TimeOfDay.fromDateTime(at).format(context)}',
                if (event == 'dismissed')
                  '${duration ~/ 60}m ${duration % 60}s${method.isEmpty ? '' : ' · $method'} · $snoozes snooze${snoozes == 1 ? '' : 's'}',
                if (entry['followUp'] == true) 'Follow-up alarm',
              ].join('\n')),
            );
          },
        ),
      ),
    );
  }

  Future<void> _clear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete wake-up history?'),
        content: const Text(
            'This clears your local history and streak. Your alarms and pending check-ins are kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete history')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await viewModel.clearHistory();
    } catch (error) {
      if (context.mounted) {
        showAppToast(context,
            kind: ToastKind.error, message: 'Could not delete history', detail: '$error');
      }
    }
  }
}
