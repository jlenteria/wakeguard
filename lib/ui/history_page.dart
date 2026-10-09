import 'package:flutter/material.dart';

import '../core/alarm_controller.dart';

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key, required this.controller});
  final AlarmController controller;

  @override
  Widget build(BuildContext context) {
    final entries = controller.history;
    final stats = controller.wakeUpStats;
    final cutoff = DateTime.now().subtract(const Duration(days: 7)).millisecondsSinceEpoch;
    final week = entries.where((e) => ((e['at'] as num?)?.toInt() ?? 0) >= cutoff).toList();
    final completed = week.where((e) => e['event'] == 'dismissed' || e['event'] == null).map((e) => e['sessionId'] ?? e['at']).toSet().length;
    final missed = week.where((e) => e['event'] == 'missed').length;
    return Scaffold(
      appBar: AppBar(title: const Text('Wake-up history'), actions: [
        if (entries.isNotEmpty) IconButton(tooltip: 'Delete history', icon: const Icon(Icons.delete_outline),
            onPressed: () => _clear(context)),
      ]),
      body: RefreshIndicator(
        onRefresh: controller.refreshHealth,
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          itemCount: entries.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${stats.streak} scheduled-day streak', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text('Last 7 days: $completed dismissed · $missed missed'),
                const SizedBox(height: 8),
                const Text('Dismissals and check-ins show interaction with your alarm, not proof of sleep quality. Unscheduled days do not break the streak.'),
              ]))),
              if (entries.isEmpty) const Padding(padding: EdgeInsets.all(24),
                child: Text('Your first morning starts the story. Completed challenges, snoozes, missed alarms and check-ins will appear here.')),
            ]);
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
                'missed' || 'checkin_failed' || 'checkin_expired' || 'next_schedule_failed' => Icons.error_outline,
                'confirmed' => Icons.verified_outlined,
                'snoozed' => Icons.snooze,
                'dismissed' => Icons.check_circle_outline,
                _ => Icons.alarm,
              }),
              title: Text('${entry['label'] ?? 'Alarm'} · ${_eventLabel(event)}'),
              subtitle: Text([
                if (at != null) '${MaterialLocalizations.of(context).formatMediumDate(at)} · ${TimeOfDay.fromDateTime(at).format(context)}',
                if (event == 'dismissed') '${duration ~/ 60}m ${duration % 60}s${method.isEmpty ? '' : ' · $method'} · $snoozes snooze${snoozes == 1 ? '' : 's'}',
                if (entry['followUp'] == true) 'Follow-up alarm',
              ].join('\n')),
            );
          },
        ),
      ),
    );
  }

  static String _eventLabel(String event) => switch (event) {
    'started' => 'Rang', 'snoozed' => 'Snoozed', 'dismissed' => 'Dismissed',
    'missed' => 'Missed', 'confirmed' => 'Check-in confirmed',
    'unanswered' => 'Check-in unanswered', 'checkin_expired' => 'Check-in expired',
    'checkin_failed' => 'Check-in could not be scheduled',
    'next_schedule_failed' => 'Next alarm could not be scheduled', _ => event,
  };

  Future<void> _clear(BuildContext context) async {
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Delete wake-up history?'),
      content: const Text('This clears your local history and streak. Your alarms and pending check-ins are kept.'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete history'))],
    ));
    if (confirmed != true) return;
    try { await controller.clearHistory(); } catch (error) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not delete history: $error')));
    }
  }
}
