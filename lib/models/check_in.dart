/// Native-owned Stay Awake response window; the UI cannot extend its deadline.
class PendingCheckIn {
  const PendingCheckIn({
    required this.alarmId,
    required this.sessionId,
    required this.label,
    required this.dueAt,
    required this.expiresAt,
  });

  factory PendingCheckIn.fromJson(Map<Object?, Object?> json) => PendingCheckIn(
    alarmId: json['id'] as String,
    sessionId: json['sessionId'] as String,
    label: json['label'] as String,
    dueAt: DateTime.fromMillisecondsSinceEpoch((json['dueAt'] as num).toInt()),
    expiresAt: DateTime.fromMillisecondsSinceEpoch(
      (json['expiresAt'] as num).toInt(),
    ),
  );

  final String alarmId;
  final String sessionId;
  final String label;
  final DateTime dueAt;
  final DateTime expiresAt;

  bool isAnswerable(DateTime now) =>
      !now.isBefore(dueAt) && now.isBefore(expiresAt);

  int remainingSeconds(DateTime now) =>
      ((expiresAt.difference(now).inMilliseconds + 999) ~/ 1000).clamp(0, 60);
}
