import 'dart:math';

/// A single alarm configuration.
///
/// [id] is a string rather than an integer on purpose: Android notification IDs
/// and SharedPreferences keys are integers, while iOS notification identifiers
/// are strings, and a stable opaque string avoids integer-overflow collisions
/// that the previous integer-timestamp scheme was prone to.
/// Selectable alarm tone families.
///
/// These must stay in step with `tool/generate_alarms.py`, which generates the
/// assets: Android gets `tone_<pack>_gentle|critical.wav`, iOS gets all four
/// tiers as `.caf`. The names are the single source of truth for both.
enum AlarmSoundPack {
  pulse,
  siren,
  radar,
  gong;

  String get label => switch (this) {
        pulse => 'Pulse (gentle beeps)',
        siren => 'Siren (rising sweep)',
        radar => 'Radar (fast pips)',
        gong => 'Gong (metal strikes)',
      };

  String get description => switch (this) {
        pulse => 'Least abrasive. Best if other sounds irritate you.',
        siren => 'The classic. Most reliable at waking most people.',
        radar => 'Short high pips. Cuts through a noisy room.',
        gong => 'Harshest. Hardest to sleep through, easiest to resent.',
      };
}

/// Which ways out of the ring an alarm offers.
///
/// Deliberately a per-alarm set rather than a global setting: a strict alarm
/// and a lenient one are usually different alarms in the same list.
enum EscapeKind {
  /// A conventional alarm, for mornings that need no challenge.
  tap,
  /// Camera-based actions: blink, smile, turn your head.
  face,

  /// A memorised cell sequence. Works in the dark, no permissions.
  pattern,

  /// Scanning a code the user placed away from bed.
  qr;

  String get label => switch (this) {
        tap => 'Tap to stop',
        face => 'Face',
        pattern => 'Pattern',
        qr => 'QR code',
      };
}

class Alarm {
  const Alarm({
    required this.id,
    required this.hour,
    required this.minute,
    required this.label,
    this.enabled = true,
    this.repeatDaily = true,
    this.weekdays = const <int>{},
    this.qrValue = '',
    this.difficulty = ChallengeDifficulty.moderate,
    this.soundPack = AlarmSoundPack.pulse,
    this.snoozeMinutes = defaultSnoozeMinutes,
    this.escapes = defaultEscapes,
    this.checkInMinutes = 0,
    this.skipUntilMillis = 0,
    this.scheduledAtMillis,
    this.createdAt,
  });

  /// Minutes the user may surrender this alarm for. 0 disables snoozing,
  /// which is what a strict alarm is for.
  static const int defaultSnoozeMinutes = 9;

  /// Every escape, and the fallback for a record that names none.
  ///
  /// This is what an alarm written before escapes existed had available, so
  /// reading one back must not silently take a way out away.
  static const Set<EscapeKind> allEscapes = {
    EscapeKind.face,
    EscapeKind.pattern,
    EscapeKind.qr,
  };

  /// Escapes a brand-new alarm offers: the two that work with no setup.
  ///
  /// QR is deliberately left out of the default. It only helps once a code has
  /// been printed and placed away from bed, and an escape that cannot be used
  /// is a button on the ringing screen pointing at nothing.
  static const Set<EscapeKind> defaultEscapes = {
    EscapeKind.face,
    EscapeKind.pattern,
  };

  /// Matches [DateTime.weekday]: 1 = Monday ... 7 = Sunday.
  final Set<int> weekdays;
  final String id;
  final int hour;
  final int minute;
  final String label;
  final bool enabled;

  /// When false the alarm fires once and then disables itself.
  final bool repeatDaily;

  /// Secret payload the QR challenge compares against. Empty disables QR.
  final String qrValue;

  final ChallengeDifficulty difficulty;

  /// Which generated tone family this alarm rings with.
  final AlarmSoundPack soundPack;

  /// Snooze window in minutes; 0 means this alarm cannot be snoozed.
  final int snoozeMinutes;

  /// Ways out of the ring this alarm offers.
  ///
  /// The one-minute hold is always available regardless of this set: no
  /// configuration may leave a user with no way out of a live alarm.
  final Set<EscapeKind> escapes;

  /// Opt-in follow-up check after dismissal. Zero disables it.
  final int checkInMinutes;
  final int skipUntilMillis;
  /// Native-confirmed primary trigger, rather than a UI estimate.
  final int? scheduledAtMillis;

  final DateTime? createdAt;

  /// Whether this alarm rolls forward after it fires.
  bool get isRepeating => repeatDaily || weekdays.isNotEmpty;

  /// Whether this alarm needs a camera when it rings.
  bool get usesFace => escapes.contains(EscapeKind.face);

  /// The effective local time-of-day as minutes since midnight.
  int get minuteOfDay => hour * 60 + minute;

  bool isScheduledFor(DateTime day) =>
      weekdays.isEmpty || weekdays.contains(day.weekday);

  /// Next firing instant strictly after [from].
  ///
  /// Uses local time arithmetic so a time-of-day alarm keeps firing at the same
  /// wall-clock time across DST transitions. Note that when the platform
  /// reschedules after a reboot or time-zone change it recomputes natively with
  /// its own Calendar / Calendar-based equivalent; see docs/ARCHITECTURE.md for
  /// why that is acceptable and where the edge case lives.
  DateTime nextOccurrence([DateTime? from]) {
    final now = from ?? DateTime.now();
    final skipped = DateTime.fromMillisecondsSinceEpoch(skipUntilMillis);
    final start = skipped.isAfter(now) ? skipped : now;
    var candidate = DateTime(
      start.year,
      start.month,
      start.day,
      hour,
      minute,
    );
    // Search forward up to 8 days: enough to cover any weekly pattern.
    for (var i = 0; i <= 8; i++) {
      final probe = i == 0
          ? candidate
          : DateTime(start.year, start.month, start.day + i, hour, minute);
      if (probe.isAfter(start) && probe.millisecondsSinceEpoch > skipUntilMillis && isScheduledFor(probe)) return probe;
    }
    throw StateError('Alarm weekdays must contain at least one valid weekday');
  }

  Alarm copyWith({
    String? id,
    int? hour,
    int? minute,
    String? label,
    bool? enabled,
    bool? repeatDaily,
    Set<int>? weekdays,
    String? qrValue,
    ChallengeDifficulty? difficulty,
    AlarmSoundPack? soundPack,
    int? snoozeMinutes,
    Set<EscapeKind>? escapes,
    int? checkInMinutes,
    int? skipUntilMillis,
  }) =>
      Alarm(
        id: id ?? this.id,
        hour: hour ?? this.hour,
        minute: minute ?? this.minute,
        label: label ?? this.label,
        enabled: enabled ?? this.enabled,
        repeatDaily: repeatDaily ?? this.repeatDaily,
        weekdays: weekdays ?? this.weekdays,
        qrValue: qrValue ?? this.qrValue,
        difficulty: difficulty ?? this.difficulty,
        soundPack: soundPack ?? this.soundPack,
        snoozeMinutes: snoozeMinutes ?? this.snoozeMinutes,
        escapes: escapes ?? this.escapes,
        checkInMinutes: checkInMinutes ?? this.checkInMinutes,
        skipUntilMillis: skipUntilMillis ?? this.skipUntilMillis,
        createdAt: createdAt,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'hour': hour,
        'minute': minute,
        'label': label,
        'enabled': enabled,
        'repeatDaily': repeatDaily,
        'weekdays': weekdays.toList(),
        'qrValue': qrValue,
        'difficulty': difficulty.name,
        'soundPack': soundPack.name,
        'snoozeMinutes': snoozeMinutes,
        'escapes': escapes.map((e) => e.name).toList(),
        'checkInMinutes': checkInMinutes,
        'skipUntilMillis': skipUntilMillis,
        'createdAt': createdAt?.millisecondsSinceEpoch,
      };

  factory Alarm.fromJson(Map<String, Object?> json) {
    final rawWeekdays = json['weekdays'];
    return Alarm(
      id: json['id'] as String? ?? generateId(),
      hour: (json['hour'] as int? ?? 7).clamp(0, 23),
      minute: (json['minute'] as int? ?? 0).clamp(0, 59),
      label: json['label'] as String? ?? 'Wake up',
      enabled: json['enabled'] as bool? ?? true,
      repeatDaily: json['repeatDaily'] as bool? ?? true,
      weekdays: rawWeekdays is List
          ? rawWeekdays.whereType<num>().map((n) => n.toInt()).where((n) => n >= 1 && n <= 7).toSet()
          : const <int>{},
      qrValue: json['qrValue'] as String? ?? '',
      difficulty: ChallengeDifficulty.values.firstWhere(
        (d) => d.name == json['difficulty'],
        orElse: () => ChallengeDifficulty.moderate,
      ),
      // Unknown values fall back rather than throwing, so an alarm saved by a
      // newer build still loads after a downgrade.
      soundPack: AlarmSoundPack.values.firstWhere(
        (s) => s.name == json['soundPack'],
        orElse: () => AlarmSoundPack.pulse,
      ),
      snoozeMinutes: ((json['snoozeMinutes'] as num?) ??
              defaultSnoozeMinutes)
          .toInt()
          .clamp(0, 60),
      escapes: _parseEscapes(json['escapes']),
      checkInMinutes: const [0, 3, 5, 10].contains(json['checkInMinutes']) ? json['checkInMinutes'] as int : 0,
      skipUntilMillis: (json['skipUntilMillis'] as num?)?.toInt() ?? 0,
      scheduledAtMillis: (json['nextTriggerAt'] as num?)?.toInt(),
      createdAt: json['createdAt'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(json['createdAt']! as int),
    );
  }

  /// Unknown names are dropped, an empty or missing set means "all of them".
  ///
  /// Falling back to every escape rather than to the new-alarm default matters:
  /// a record written before escapes existed offered all three, and a record
  /// written by a newer build may name one this build does not know. Either
  /// way the alarm must still offer every way out it used to.
  static Set<EscapeKind> _parseEscapes(Object? raw) {
    if (raw is! List) return allEscapes;
    final parsed = <EscapeKind>{
      for (final name in raw.whereType<String>())
        ...EscapeKind.values.where((e) => e.name == name),
    };
    return parsed.isEmpty ? allEscapes : parsed;
  }

  static String generateId() {
    final random = Random.secure();
    final salt = DateTime.now().microsecondsSinceEpoch;
    return '$salt-${random.nextInt(1 << 32).toRadixString(16)}';
  }

  @override
  bool operator ==(Object other) => other is Alarm && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

enum ChallengeDifficulty {
  gentle(1),
  moderate(2),
  strict(3);

  const ChallengeDifficulty(this.stepCount);

  /// How many face actions must be completed to dismiss.
  final int stepCount;

  String get label => switch (this) {
        ChallengeDifficulty.gentle => 'Gentle',
        ChallengeDifficulty.moderate => 'Moderate',
        ChallengeDifficulty.strict => 'Strict',
      };
}
