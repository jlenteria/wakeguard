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

  int get _weekCutoff =>
      DateTime.now().subtract(const Duration(days: 7)).millisecondsSinceEpoch;

  List<Map<String, Object?>> get _week => entries
      .where((e) => ((e['at'] as num?)?.toInt() ?? 0) >= _weekCutoff)
      .toList();

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
    'tap' => 'Tap to stop',
    'checkin' => 'Check-in confirmed',
    'qr' => 'QR challenge',
    'pattern' => 'Pattern challenge',
    'hold' => 'Hold to stop',
    'settings' => 'Stopped from settings',
    _ => 'Dismissal',
  };

  static String eventLabel(String event) => switch (event) {
    'started' => 'Rang',
    'snoozed' => 'Snoozed',
    'dismissed' => 'Dismissed',
    'missed' => 'Missed',
    'confirmed' => 'Check-in confirmed',
    'unanswered' => 'Check-in unanswered',
    'checkin_expired' => 'Check-in expired',
    'checkin_failed' => 'Check-in could not be scheduled',
    'next_schedule_failed' => 'Next alarm could not be scheduled',
    _ => event,
  };

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
