import 'dart:math';

/// A single alarm configuration. [id] is an opaque string because Android uses
/// int IDs/keys while iOS uses strings, avoiding integer-overflow collisions.
/// Selectable alarm tone families; names must match `tool/generate_alarms.py`.
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

/// Ways out of a ring, deliberately per-alarm rather than a global setting.
enum EscapeKind {
  tap,
  face,

  /// Recognise a chosen object away from bed using the rear camera.
  object,

  qr;

  String get label => switch (this) {
    tap => 'Tap to stop',
    face => 'Face',
    object => 'Find an object',
    qr => 'QR code',
  };
}

/// Specific labels present in the bundled offline model; not broad categories.
enum WakeObject {
  sink(
    'Sink',
    'Use a bathroom or kitchen sink. Show the whole basin and faucet in good light, and hold your phone steady.',
  ),
  cup('Cup', 'Place a cup in the kitchen, away from your bed.');

  const WakeObject(this.label, this.description);
  final String label;
  final String description;
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
    this.objectTarget = WakeObject.sink,
    this.objectVerified = false,
    this.needsSetup = false,
    this.skipUntilMillis = 0,
    this.customSoundId = '',
    this.customSoundName = '',
    this.vibrate = true,
    this.scheduledAtMillis,
    this.createdAt,
  });

  /// Minutes the user may snooze this alarm; 0 disables snoozing.
  static const int defaultSnoozeMinutes = 9;

  /// Every escape, and the fallback for a record naming none, so reading such a
  /// record never silently removes a way out.
  static const Set<EscapeKind> allEscapes = {
    EscapeKind.face,
    EscapeKind.object,
    EscapeKind.qr,
  };

  /// Face needs no object enrollment or printed code. Tap is explicitly opt-in.
  static const Set<EscapeKind> defaultEscapes = {EscapeKind.face};

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

  /// The bundled tone, which also rings if [customSoundId] cannot be played.
  final AlarmSoundPack soundPack;

  /// Android-only uploaded tone: an opaque id for a file the app keeps in its own
  /// storage. Empty means the bundled [soundPack] rings.
  final String customSoundId;

  /// The uploaded file's display name, shown in the editor.
  final String customSoundName;

  bool get hasCustomSound => customSoundId.isNotEmpty;

  /// Whether the phone vibrates while this alarm rings, alongside the tone.
  final bool vibrate;

  /// Snooze window in minutes; 0 means this alarm cannot be snoozed.
  final int snoozeMinutes;

  /// Only these selected challenges may successfully dismiss the alarm.
  final Set<EscapeKind> escapes;

  /// Opt-in follow-up check after dismissal. Zero disables it.
  final int checkInMinutes;

  final WakeObject objectTarget;
  final bool objectVerified;

  /// Legacy Pattern-only alarms are disabled until their replacement is set up.
  final bool needsSetup;

  final int skipUntilMillis;

  /// Native-confirmed primary trigger, rather than a UI estimate.
  final int? scheduledAtMillis;

  final DateTime? createdAt;

  bool get isRepeating => repeatDaily || weekdays.isNotEmpty;

  bool get usesFace => escapes.contains(EscapeKind.face);

  int get minuteOfDay => hour * 60 + minute;

  bool isScheduledFor(DateTime day) =>
      weekdays.isEmpty || weekdays.contains(day.weekday);

  /// Next firing instant strictly after [from]; uses local time arithmetic so a
  /// time-of-day alarm survives DST (native rescheduling may differ, see docs).
  DateTime nextOccurrence([DateTime? from]) {
    final now = from ?? DateTime.now();
    final skipped = DateTime.fromMillisecondsSinceEpoch(skipUntilMillis);
    final start = skipped.isAfter(now) ? skipped : now;
    var candidate = DateTime(start.year, start.month, start.day, hour, minute);
    // 8 days covers any weekly pattern.
    for (var i = 0; i <= 8; i++) {
      final probe = i == 0
          ? candidate
          : DateTime(start.year, start.month, start.day + i, hour, minute);
      if (probe.isAfter(start) &&
          probe.millisecondsSinceEpoch > skipUntilMillis &&
          isScheduledFor(probe)) {
        return probe;
      }
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
    WakeObject? objectTarget,
    bool? objectVerified,
    bool? needsSetup,
    int? skipUntilMillis,
    String? customSoundId,
    String? customSoundName,
    bool? vibrate,
  }) => Alarm(
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
    objectTarget: objectTarget ?? this.objectTarget,
    objectVerified: objectVerified ?? this.objectVerified,
    needsSetup: needsSetup ?? this.needsSetup,
    skipUntilMillis: skipUntilMillis ?? this.skipUntilMillis,
    customSoundId: customSoundId ?? this.customSoundId,
    customSoundName: customSoundName ?? this.customSoundName,
    vibrate: vibrate ?? this.vibrate,
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
    'objectTarget': objectTarget.name,
    'objectVerified': objectVerified,
    'needsSetup': needsSetup,
    'skipUntilMillis': skipUntilMillis,
    'customSoundId': customSoundId,
    'customSoundName': customSoundName,
    'vibrate': vibrate,
    'createdAt': createdAt?.millisecondsSinceEpoch,
  };

  factory Alarm.fromJson(Map<String, Object?> json) {
    final rawWeekdays = json['weekdays'];
    final rawEscapes = json['escapes'];
    final validNames = EscapeKind.values.map((e) => e.name).toSet();
    final validObjectTarget = WakeObject.values.any(
      (target) => target.name == json['objectTarget'],
    );
    final requiresSetup =
        json['needsSetup'] == true ||
        (rawEscapes is List &&
            (!rawEscapes.any(validNames.contains) ||
                (rawEscapes.contains('object') && !validObjectTarget)));
    return Alarm(
      id: json['id'] as String? ?? generateId(),
      hour: (json['hour'] as int? ?? 7).clamp(0, 23),
      minute: (json['minute'] as int? ?? 0).clamp(0, 59),
      label: json['label'] as String? ?? 'Wake up',
      enabled: !requiresSetup && (json['enabled'] as bool? ?? true),
      repeatDaily: json['repeatDaily'] as bool? ?? true,
      weekdays: rawWeekdays is List
          ? rawWeekdays
                .whereType<num>()
                .map((n) => n.toInt())
                .where((n) => n >= 1 && n <= 7)
                .toSet()
          : const <int>{},
      qrValue: json['qrValue'] as String? ?? '',
      difficulty: ChallengeDifficulty.values.firstWhere(
        (d) => d.name == json['difficulty'],
        orElse: () => ChallengeDifficulty.moderate,
      ),
      // Unknown values fall back, so a downgrade still loads newer builds' alarms.
      soundPack: AlarmSoundPack.values.firstWhere(
        (s) => s.name == json['soundPack'],
        orElse: () => AlarmSoundPack.pulse,
      ),
      snoozeMinutes: ((json['snoozeMinutes'] as num?) ?? defaultSnoozeMinutes)
          .toInt()
          .clamp(0, 60),
      escapes: _parseEscapes(json['escapes']),
      checkInMinutes: const [0, 3, 5, 10].contains(json['checkInMinutes'])
          ? json['checkInMinutes'] as int
          : 0,
      objectTarget: WakeObject.values.firstWhere(
        (value) => value.name == json['objectTarget'],
        orElse: () => WakeObject.sink,
      ),
      objectVerified: validObjectTarget && json['objectVerified'] == true,
      needsSetup: requiresSetup,
      skipUntilMillis: (json['skipUntilMillis'] as num?)?.toInt() ?? 0,
      customSoundId: json['customSoundId'] as String? ?? '',
      customSoundName: json['customSoundName'] as String? ?? '',
      vibrate: json['vibrate'] as bool? ?? true,
      scheduledAtMillis: (json['nextTriggerAt'] as num?)?.toInt(),
      createdAt: json['createdAt'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(json['createdAt']! as int),
    );
  }

  /// Legacy Pattern-only alarms become Object drafts requiring setup, never Tap.
  static Set<EscapeKind> _parseEscapes(Object? raw) {
    if (raw is! List) return defaultEscapes;
    final parsed = <EscapeKind>{
      for (final name in raw.whereType<String>())
        ...EscapeKind.values.where((e) => e.name == name),
    };
    return parsed.isEmpty ? {EscapeKind.object} : parsed;
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
