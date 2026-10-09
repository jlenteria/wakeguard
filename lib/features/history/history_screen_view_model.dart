import '../alarms/alarm_controller.dart';
import '../../models/wake_up_stats.dart';
import '../../shared/view_model.dart';

/// The dismissal record, its streak and the last-seven-days summary.
class HistoryScreenViewModel extends ViewModel {
  HistoryScreenViewModel(this.controller) {
    controller.addListener(safeNotify);
  }

  final AlarmController controller;

  List<Map<String, Object?>> get entries => controller.history;
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

  Future<void> refresh() => controller.refreshHealth();
  Future<void> clearHistory() => controller.clearHistory();

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
