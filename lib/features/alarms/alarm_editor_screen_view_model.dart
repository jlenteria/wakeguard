import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/alarm.dart';
import '../challenges/wake_up_qr.dart';
import '../../platform/alarm_engine.dart';
import '../../shared/view_model.dart';
import 'tone_names.dart';

/// All state for creating or editing one alarm, from the preset chips down to
/// the text controllers and the QR secret.
class AlarmEditorScreenViewModel extends ViewModel with WidgetsBindingObserver {
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
    customSoundId = existing?.customSoundId ?? '';
    customSoundName = existing?.customSoundName ?? '';
    vibrate = existing?.vibrate ?? true;
    snoozeMinutes =
        existing?.snoozeMinutes ??
        defaultSnoozeMinutes ??
        Alarm.defaultSnoozeMinutes;
    checkInMinutes = existing?.checkInMinutes ?? 0;
    objectTarget = existing?.objectTarget ?? WakeObject.sink;
    objectVerified = existing?.objectVerified ?? false;
    escapes = {...?existing?.escapes};
    if (escapes.isEmpty) escapes = {...Alarm.defaultEscapes};
    // A QR escape with no code (legacy/partial backup) must not block Save; drop it.
    if (escapes.contains(EscapeKind.qr) && qrController.text.trim().isEmpty) {
      escapes.remove(EscapeKind.qr);
      if (escapes.isEmpty) escapes = {...Alarm.defaultEscapes};
    }
    qrController.addListener(safeNotify);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshObjectVerification());
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
  late String customSoundId;
  late String customSoundName;
  late bool vibrate;
  late int snoozeMinutes;
  late int checkInMinutes;
  late WakeObject objectTarget;
  late bool objectVerified;
  late Set<EscapeKind> escapes;

  int? preset;
  bool saving = false;
  String? validationError;
  int? previewing;
  bool practicing = false;
  bool pickingSound = false;

  /// The device's own alarm tones, loaded once when the picker is shown.
  List<PickedSound> systemSounds = const [];
  bool systemSoundsLoading = false;
  String? systemSoundsError;

  /// The uri being imported (copied into storage), so that row shows a spinner.
  String importingUri = '';

  /// [previewing] value while the uploaded tone plays; bundled packs use their index.
  static const customPreviewIndex = -1;

  String get trimmedQr => qrController.text.trim();
  bool get hasQrValue => trimmedQr.isNotEmpty;
  bool get showQrField => escapes.contains(EscapeKind.qr);
  bool get usesSharedQr => sharedQrValue != null && trimmedQr == sharedQrValue;
  bool get isExisting => existing != null;
  bool get previewingAny => previewing != null;
  bool get previewingCustom => previewing == customPreviewIndex;
  bool get hasCustomSound => customSoundId.isNotEmpty;

  CustomSoundEngine? get _customEngine {
    final engine = this.engine;
    return engine is CustomSoundEngine ? engine as CustomSoundEngine : null;
  }

  /// Uploading is offered only where the platform can store and play the file.
  bool get canUseCustomSound => _customEngine?.supportsCustomSounds ?? false;

  /// Whether a device sound with [name] is the one currently chosen.
  bool isSoundSelected(String name) =>
      hasCustomSound && customSoundName == name;

  void setVibrate(bool value) {
    vibrate = value;
    safeNotify();
  }

  /// Loads the device's own alarm tones once; safe to call on every build.
  Future<void> loadSystemSounds() async {
    final custom = _customEngine;
    if (custom == null || systemSoundsLoading || systemSounds.isNotEmpty) {
      return;
    }
    systemSoundsLoading = true;
    systemSoundsError = null;
    safeNotify();
    try {
      final sounds = await custom.listSystemSounds();
      if (disposed) return;
      // Titles like "光阴;Time" become "Time"; a title with no English at all
      // gets a neutral numbered name so the list stays English-only.
      systemSounds = [
        for (var i = 0; i < sounds.length; i++)
          PickedSound(
            id: sounds[i].id,
            name: englishToneName(sounds[i].name) ?? 'Alarm tone ${i + 1}',
          ),
      ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } on EngineException catch (error) {
      if (disposed) return;
      systemSoundsError = error.message;
    } catch (error) {
      if (disposed) return;
      systemSoundsError = '$error';
    } finally {
      systemSoundsLoading = false;
      safeNotify();
    }
  }

  /// Copies the device sound into app storage so it rings reliably; null on success.
  Future<String?> selectSystemSound(PickedSound sound) async {
    final custom = _customEngine;
    if (custom == null || importingUri.isNotEmpty || saving) return null;
    // Already the chosen sound: selecting again is a no-op.
    if (isSoundSelected(sound.name)) return null;
    importingUri = sound.id;
    safeNotify();
    try {
      await engine?.stopAudibilitySample();
      final stored = await custom.importSystemSound(sound.id);
      if (disposed) return null;
      customSoundId = stored.id;
      // Keep the name shown in the list (not the file's), so the same row stays
      // checked now and after the alarm is reopened.
      customSoundName = sound.name;
      return null;
    } on EngineException catch (error) {
      return error.message;
    } catch (error) {
      return '$error';
    } finally {
      importingUri = '';
      safeNotify();
    }
  }

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
      if (escape == EscapeKind.qr) _ensureQrSecret();
    } else {
      escapes.remove(escape);
    }
    validationError = null;
    safeNotify();
  }

  /// Every QR escape needs a code, so presets and toggles fill it in immediately.
  void _ensureQrSecret() {
    if (qrController.text.trim().isNotEmpty) return;
    final shared = sharedQrValue?.trim() ?? '';
    qrController.text = shared.isNotEmpty ? shared : generateQrSecret();
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
    validationError = null;
    repeatDaily = false;
    weekdays.clear();
    safeNotify();
  }

  void selectEveryDay() {
    validationError = null;
    repeatDaily = true;
    weekdays.clear();
    safeNotify();
  }

  void selectSelectedDays() {
    validationError = null;
    repeatDaily = true;
    if (weekdays.isEmpty) weekdays = {1, 2, 3, 4, 5};
    safeNotify();
  }

  void toggleWeekday(int day, bool selected) {
    if (selected) {
      weekdays.add(day);
    } else {
      if (weekdays.length == 1 && weekdays.contains(day)) {
        validationError =
            'Keep at least one weekday, or choose Once or Every day.';
        safeNotify();
        return;
      }
      weekdays.remove(day);
    }
    validationError = null;
    safeNotify();
  }

  void setDifficulty(ChallengeDifficulty value) {
    difficulty = value;
    safeNotify();
  }

  /// Choosing a bundled tone replaces an uploaded one; the file is cleaned up natively.
  void setSoundPack(AlarmSoundPack value) {
    soundPack = value;
    customSoundId = '';
    customSoundName = '';
    safeNotify();
  }

  /// Returns an error message, or null when a file was chosen or the picker was cancelled.
  Future<String?> pickCustomSound() async {
    final custom = _customEngine;
    if (custom == null || pickingSound || saving) return null;
    pickingSound = true;
    safeNotify();
    try {
      await engine?.stopAudibilitySample();
      final picked = await custom.pickCustomSound();
      if (disposed || picked == null) return null;
      customSoundId = picked.id;
      customSoundName = picked.name;
      return null;
    } on EngineException catch (error) {
      return error.message;
    } catch (error) {
      return '$error';
    } finally {
      pickingSound = false;
      safeNotify();
    }
  }

  void removeCustomSound() {
    if (!hasCustomSound) return;
    customSoundId = '';
    customSoundName = '';
    safeNotify();
  }

  /// Returns an error message, or null when the uploaded tone started playing.
  Future<String?> previewCustom() async {
    final custom = _customEngine;
    if (custom == null || !hasCustomSound) return null;
    if (previewingAny || saving) return null;
    previewing = customPreviewIndex;
    safeNotify();
    try {
      // Vibrate only when this alarm is set to, so the preview matches the ring.
      await custom.previewCustomSound(customSoundId, vibrate: vibrate);
      return null;
    } on EngineException catch (error) {
      return error.message;
    } catch (error) {
      return '$error';
    } finally {
      previewing = null;
      safeNotify();
    }
  }

  void setSnoozeMinutes(int value) {
    snoozeMinutes = value;
    safeNotify();
  }

  void setCheckInMinutes(int value) {
    checkInMinutes = value;
    safeNotify();
  }

  void setObjectTarget(WakeObject value) {
    objectTarget = value;
    objectVerified = false;
    safeNotify();
    unawaited(_refreshObjectVerification());
  }

  Future<void> _refreshObjectVerification() async {
    final target = objectTarget;
    try {
      final verified = await engine?.objectTargetVerified(target.name) ?? false;
      if (disposed || objectTarget != target) return;
      objectVerified = verified;
      safeNotify();
    } catch (_) {
      /* Native saving also checks the persisted verification. */
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshObjectVerification());
    }
  }

  void applyPreset(int index) {
    preset = index;
    difficulty = index == 2
        ? ChallengeDifficulty.strict
        : ChallengeDifficulty.gentle;
    escapes = switch (index) {
      0 => {EscapeKind.tap},
      // Getting out of bed means leaving the room: object or a scan away from bed.
      2 => {EscapeKind.object, EscapeKind.qr},
      _ => {EscapeKind.face},
    };
    snoozeMinutes = index == 0 ? 9 : 0;
    checkInMinutes = index == 2 && canCheckIn ? 5 : 0;
    // "Get out of bed" turns on QR, so it must come with a scannable code.
    if (escapes.contains(EscapeKind.qr)) _ensureQrSecret();
    validationError = null;
    safeNotify();
  }

  Future<String?> preview(AlarmSoundPack pack) async {
    if (previewingAny || saving) return null;
    previewing = pack.index;
    safeNotify();
    try {
      // Audible regardless of notification volume on both platforms: the point of the check.
      await engine?.playAudibilitySample(soundPack: pack, vibrate: vibrate);
      return null;
    } catch (error) {
      return '$error';
    } finally {
      previewing = null;
      safeNotify();
    }
  }

  /// Returns an error message, or null when practice started.
  Future<String?> practice() async {
    if (practicing || saving) return null;
    final problem = _problem(forPractice: true);
    if (problem != null) {
      validationError = problem;
      safeNotify();
      return null;
    }
    practicing = true;
    safeNotify();
    try {
      await engine?.stopAudibilitySample();
      final draft = _build();
      // Practice must offer the same selected alternatives as the real alarm.
      await engine?.practice(draft);
      return null;
    } catch (error) {
      return '$error';
    } finally {
      practicing = false;
      safeNotify();
    }
  }

  /// Validates, stops any preview and returns the alarm to save; null when invalid.
  Future<Alarm?> save() async {
    if (saving || practicing) return null;
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
  String? _problem({bool forPractice = false}) {
    if (escapes.isEmpty) return 'Choose at least one way to stop the alarm.';
    if (!forPractice &&
        enabled &&
        escapes.contains(EscapeKind.object) &&
        !objectVerified) {
      return 'Practice scanning your ${objectTarget.label.toLowerCase()} successfully before enabling this alarm.';
    }
    if (escapes.contains(EscapeKind.qr) && qrController.text.trim().isEmpty) {
      return 'The QR challenge needs a code. Create one, or turn QR off.';
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
      customSoundId: customSoundId,
      customSoundName: customSoundName,
      vibrate: vibrate,
      snoozeMinutes: snoozeMinutes,
      escapes: {...escapes},
      checkInMinutes: checkInMinutes,
      objectTarget: objectTarget,
      objectVerified: objectVerified,
      needsSetup: false,
      skipUntilMillis: 0,
      createdAt: existing?.createdAt ?? DateTime.now(),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Covers dismissing the sheet without saving (drag down, back gesture).
    unawaited(
      (engine?.stopAudibilitySample() ?? Future<void>.value()).catchError(
        (Object _) {},
      ),
    );
    qrController.removeListener(safeNotify);
    labelController.dispose();
    qrController.dispose();
    super.dispose();
  }
}
