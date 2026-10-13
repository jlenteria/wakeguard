import '../alarms/alarm_controller.dart';
import '../../models/wake_up_stats.dart';
import '../../shared/view_model.dart';

/// The dismissal record, its streak and the last-seven-days summary.
class HistoryScreenViewModel extends ViewModel {
  HistoryScreenViewModel(this.controller) {
    controller.addListener(safeNotify);
  }

  final AlarmController controller;

  List<Map<String, Object?>> get entries => List.of(controller.history)
    ..sort(
      (a, b) => ((b['at'] as num?)?.toInt() ?? 0).compareTo(
        (a['at'] as num?)?.toInt() ?? 0,
      ),
    );
  WakeUpStats get stats => controller.wakeUpStats;

  List<Map<String, Object?>> get _week {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cutoff = now - const Duration(days: 7).inMilliseconds;
    return controller.history.where((entry) {
      final at = (entry['at'] as num?)?.toInt();
      return at != null && at >= cutoff && at <= now;
    }).toList();
  }

  List<HistoryWeekDay> get currentWeek {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final monday = DateTime(now.year, now.month, now.day - now.weekday + 1);
    final completed = <DateTime>{};
    final missed = <DateTime>{};
    for (final entry in controller.history) {
      final raw = entry['at'];
      if (raw is! num || raw <= 0 || raw > now.millisecondsSinceEpoch) continue;
      final at = DateTime.fromMillisecondsSinceEpoch(raw.toInt());
      final day = DateTime(at.year, at.month, at.day);
      if (day.isBefore(monday) || day.isAfter(today)) continue;
      if (isCompletedWakeUpEvent(entry)) completed.add(day);
      if (entry['event'] == 'missed') missed.add(day);
    }
    return List.generate(7, (index) {
      final date = DateTime(monday.year, monday.month, monday.day + index);
      return HistoryWeekDay(
        date: date,
        isToday: date == today,
        state: completed.contains(date)
            ? HistoryWeekState.completed
            : missed.contains(date)
            ? HistoryWeekState.missed
            : date.isAfter(today)
            ? HistoryWeekState.upcoming
            : HistoryWeekState.pending,
      );
    });
  }

  int get completed {
    return _week
        .where((e) => e['event'] == 'dismissed' || e['event'] == null)
        .map((e) => e['sessionId'] ?? e['at'])
        .toSet()
        .length;
  }

  int get missed => _week.where((e) => e['event'] == 'missed').length;

  bool _refreshing = false;
  bool get refreshing => _refreshing;
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    safeNotify();
    try {
      await controller.refreshHistory();
    } finally {
      _refreshing = false;
      safeNotify();
    }
  }

  Future<void> clearHistory() => controller.clearHistory();

  List<HistoryDay> get days {
    final groups = <DateTime?, List<Map<String, Object?>>>{};
    for (final entry in entries) {
      final at = entry['at'];
      final date = at is num
          ? DateTime.fromMillisecondsSinceEpoch(at.toInt())
          : null;
      final day = date == null
          ? null
          : DateTime(date.year, date.month, date.day);
      groups.putIfAbsent(day, () => []).add(entry);
    }
    return [
      for (final group in groups.entries) HistoryDay(group.key, group.value),
    ];
  }

  static String methodLabel(String method) => switch (method) {
    'face' => 'Face challenge',
    'object' => 'Object challenge',
    'tap' => 'Tap to stop',
    'checkin' => 'Check-in confirmed',
    'qr' => 'QR challenge',
    'pattern' => 'Pattern challenge',
    'hold' => 'Hold to stop',
    'settings' => 'Stopped from settings',
    _ => 'Alarm stopped',
  };

  static String eventLabel(String event) => switch (event) {
    'started' => 'Rang',
    'snoozed' => 'Snoozed',
    'dismissed' => 'Stopped',
    'missed' => 'Missed',
    'confirmed' => 'Check-in confirmed',
    'unanswered' => 'Check-in unanswered',
    'checkin_expired' => 'Check-in expired',
    'checkin_failed' => 'Check-in could not be scheduled',
    'checkin_scheduled' => 'Stay Awake check-in scheduled',
    'checkin_prompted' => 'Stay Awake reminder shown',
    'checkin_notification_blocked' => 'Stay Awake notifications blocked',
    'checkin_notification_failed' => 'Stay Awake reminder failed',
    'challenge_setup_required' => 'New challenge setup required',
    'next_schedule_failed' => 'Next alarm could not be scheduled',
    _ => event,
  };

  /// Describe recorded outcomes without inventing a routine or chime type.
  static String eventDetail(Map<String, Object?> entry) {
    if (entry['followUp'] == true) return 'Follow-up alarm';
    final minutes = (entry['checkInMinutes'] as num?)?.toInt();
    return switch (entry['event']) {
      'started' => 'Scheduled alarm',
      'confirmed' => 'Stay Awake check-in',
      'snoozed' => 'Alarm temporarily postponed',
      'missed' => 'The alarm stopped ringing before you completed a challenge',
      'unanswered' => 'No response within 1 minute',
      'checkin_scheduled' =>
        minutes != null && minutes > 0
            ? 'Reminder in $minutes min'
            : 'Stay Awake reminder scheduled',
      'checkin_prompted' => 'Stay Awake notification',
      'checkin_failed' => 'Could not set the reminder. Check Health.',
      'checkin_notification_blocked' =>
        'Allow Stay Awake notifications in your device’s settings',
      'checkin_notification_failed' => 'The reminder could not be displayed',
      'checkin_expired' => 'The time to respond has passed',
      'next_schedule_failed' => 'Could not set the next alarm. Check Health.',
      'challenge_setup_required' =>
        'Choose the replacement challenge in your alarm',
      _ => '',
    };
  }

  @override
  void dispose() {
    controller.removeListener(safeNotify);
    super.dispose();
  }
}

class HistoryDay {
  const HistoryDay(this.date, this.entries);
  final DateTime? date;
  final List<Map<String, Object?>> entries;
}

enum HistoryWeekState { completed, missed, pending, upcoming }

class HistoryWeekDay {
  const HistoryWeekDay({
    required this.date,
    required this.isToday,
    required this.state,
  });
  final DateTime date;
  final bool isToday;
  final HistoryWeekState state;
}
