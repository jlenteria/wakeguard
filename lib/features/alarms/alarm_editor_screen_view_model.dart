import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/alarm.dart';
import '../challenges/wake_up_qr.dart';
import '../../platform/alarm_engine.dart';
import '../../shared/view_model.dart';

/// All state for creating or editing one alarm, from the preset chips down to
/// the text controllers and the QR secret.
class AlarmEditorScreenViewModel extends ViewModel {
  AlarmEditorScreenViewModel({
    this.engine,
    this.existing,
    this.defaultSnoozeMinutes,
    this.canCheckIn = true,
    this.canPractice = true,
    this.sharedQrValue,
  }) {
    final existing = this.existing;
    time = existing == null
        ? const TimeOfDay(hour: 7, minute: 0)
        : TimeOfDay(hour: existing.hour, minute: existing.minute);
    labelController = TextEditingController(text: existing?.label ?? 'Wake up');
    qrController = TextEditingController(text: existing?.qrValue ?? '');
    enabled = existing?.enabled ?? true;
    repeatDaily = existing?.repeatDaily ?? true;
    weekdays = {...?existing?.weekdays};
    difficulty = existing?.difficulty ?? ChallengeDifficulty.moderate;
    soundPack = existing?.soundPack ?? AlarmSoundPack.pulse;
    snoozeMinutes =
        existing?.snoozeMinutes ?? defaultSnoozeMinutes ?? Alarm.defaultSnoozeMinutes;
    checkInMinutes = existing?.checkInMinutes ?? 0;
    escapes = {...?existing?.escapes};
    if (escapes.isEmpty) escapes = {...Alarm.defaultEscapes};
    // A QR escape with no code (legacy/partial backup) must not block Save; drop it.
    if (escapes.contains(EscapeKind.qr) && qrController.text.trim().isEmpty) {
      escapes.remove(EscapeKind.qr);
      if (escapes.isEmpty) escapes = {...Alarm.defaultEscapes};
    }
    qrController.addListener(safeNotify);
  }

  /// Enables tone preview only; null disables it, keeping the editor usable in tests.
  final AlarmEngine? engine;
  final Alarm? existing;

  /// Snooze length for a brand-new alarm, taken from settings.
  final int? defaultSnoozeMinutes;
  final bool canCheckIn;
  final bool canPractice;
  final String? sharedQrValue;

  late TimeOfDay time;
  late final TextEditingController labelController;
  late final TextEditingController qrController;
  late bool enabled;
  late bool repeatDaily;
  late Set<int> weekdays;
  late ChallengeDifficulty difficulty;
  late AlarmSoundPack soundPack;
  late int snoozeMinutes;
  late int checkInMinutes;
  late Set<EscapeKind> escapes;

  int? preset;
  bool saving = false;
  String? validationError;
  int? previewing;

  String get trimmedQr => qrController.text.trim();
  bool get hasQrValue => trimmedQr.isNotEmpty;
  bool get showQrField => escapes.contains(EscapeKind.qr);
  bool get usesSharedQr => sharedQrValue != null && trimmedQr == sharedQrValue;
  bool get isExisting => existing != null;
  bool get previewingAny => previewing != null;

  void setTime(TimeOfDay value) {
    time = value;
    safeNotify();
  }

  void clearValidation() {
    if (validationError == null) return;
    validationError = null;
    safeNotify();
  }

  void toggleEscape(EscapeKind escape, bool selected) {
    if (selected) {
      escapes.add(escape);
      // A QR escape with no code points at nothing, so create the code first.
      if (escape == EscapeKind.qr && qrController.text.trim().isEmpty) {
        qrController.text = sharedQrValue ?? generateQrSecret();
      }
    } else {
      escapes.remove(escape);
    }
    validationError = null;
    safeNotify();
  }

  void generateCustomQrSecret() {
    qrController.text = generateQrSecret();
    validationError = null;
    safeNotify();
  }

  void useSharedQr() {
    final shared = sharedQrValue;
    if (shared == null) return;
    qrController.text = shared;
    validationError = null;
    safeNotify();
  }

  void selectOnce() {
    repeatDaily = false;
    weekdays.clear();
    safeNotify();
  }

  void selectEveryDay() {
    repeatDaily = true;
    weekdays.clear();
    safeNotify();
  }

  void selectSelectedDays() {
    repeatDaily = true;
    if (weekdays.isEmpty) weekdays = {1, 2, 3, 4, 5};
    safeNotify();
  }

  void toggleWeekday(int day, bool selected) {
    if (selected) {
      weekdays.add(day);
    } else {
      weekdays.remove(day);
    }
    safeNotify();
  }

  void setDifficulty(ChallengeDifficulty value) {
    difficulty = value;
    safeNotify();
  }

  void setSoundPack(AlarmSoundPack value) {
    soundPack = value;
    safeNotify();
  }

  void setSnoozeMinutes(int value) {
    snoozeMinutes = value;
    safeNotify();
  }

  void setCheckInMinutes(int value) {
    checkInMinutes = value;
    safeNotify();
  }

  void applyPreset(int index) {
    preset = index;
    difficulty = index == 2 ? ChallengeDifficulty.strict : ChallengeDifficulty.gentle;
    escapes = switch (index) {
      0 => {EscapeKind.tap},
      2 => {EscapeKind.qr},
      _ => {EscapeKind.pattern},
    };
    snoozeMinutes = index == 0 ? 9 : 0;
    checkInMinutes = index == 2 && canCheckIn ? 5 : 0;
    if (index == 2 && qrController.text.trim().isEmpty) {
      qrController.text = sharedQrValue ?? generateQrSecret();
    }
    validationError = null;
    safeNotify();
  }

  Future<void> preview(AlarmSoundPack pack) async {
    previewing = pack.index;
    safeNotify();
    try {
      // Audible regardless of notification volume on both platforms: the point of the check.
      await engine?.playAudibilitySample(soundPack: pack);
    } catch (_) {
      // Preview is a convenience; failing it must not block saving.
    } finally {
      previewing = null;
      safeNotify();
    }
  }

  /// Returns an error message, or null when practice started.
  Future<String?> practice() async {
    final problem = _problem();
    if (problem != null) {
      validationError = problem;
      safeNotify();
      return null;
    }
    try {
      await engine?.stopAudibilitySample();
      await engine?.practice(_build());
      return null;
    } catch (error) {
      return '$error';
    }
  }

  /// Validates, stops any preview and returns the alarm to save; null when invalid.
  Future<Alarm?> save() async {
    final problem = _problem();
    if (problem != null) {
      validationError = problem;
      safeNotify();
      return null;
    }
    final alarm = _build();
    saving = true;
    safeNotify();
    try {
      await engine?.stopAudibilitySample();
    } catch (_) {
      // Stopping the preview must never block saving.
    }
    return alarm;
  }

  /// Why this alarm cannot ring as configured, or null; failures surface at 05:00.
  String? _problem() {
    if (escapes.isEmpty) return 'Choose at least one wake escape.';
    if (escapes.contains(EscapeKind.qr) && qrController.text.trim().isEmpty) {
      return 'The QR escape needs a code. Generate one, or turn QR off.';
    }
    return null;
  }

  Alarm _build() {
    final existing = this.existing;
    final label = labelController.text.trim();
    return Alarm(
      id: existing?.id ?? Alarm.generateId(),
      hour: time.hour,
      minute: time.minute,
      label: label.isEmpty ? 'Wake up' : label,
      enabled: enabled,
      repeatDaily: repeatDaily,
      weekdays: repeatDaily ? weekdays : const {},
      qrValue: qrController.text.trim(),
      difficulty: difficulty,
      soundPack: soundPack,
      snoozeMinutes: snoozeMinutes,
      escapes: {...escapes},
      checkInMinutes: checkInMinutes,
      skipUntilMillis: 0,
      createdAt: existing?.createdAt ?? DateTime.now(),
    );
  }

  @override
  void dispose() {
    // Covers dismissing the sheet without saving (drag down, back gesture).
    unawaited(
      (engine?.stopAudibilitySample() ?? Future<void>.value()).catchError((Object _) {}),
    );
    qrController.removeListener(safeNotify);
    labelController.dispose();
    qrController.dispose();
    super.dispose();
  }
}
