import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'alarm.dart';

/// User preferences that are not part of any single alarm.
///
/// Kept out of [Alarm] because they are defaults for *new* alarms and app-wide
/// presentation, neither of which should rewrite alarms that already exist.
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeModeSetting.system,
    this.defaultSnoozeMinutes = Alarm.defaultSnoozeMinutes,
    this.onboardingDone = false,
  });

  final ThemeModeSetting themeMode;

  /// Snooze length given to newly created alarms.
  final int defaultSnoozeMinutes;

  /// Whether the first-run screen has been completed.
  ///
  /// Starts false, so a fresh install always gets it. It is a setting rather
  /// than a repository key because the whole point of the screen is that it
  /// appears before the user has touched anything else.
  final bool onboardingDone;

  AppSettings copyWith({
    ThemeModeSetting? themeMode,
    int? defaultSnoozeMinutes,
    bool? onboardingDone,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        defaultSnoozeMinutes: defaultSnoozeMinutes ?? this.defaultSnoozeMinutes,
        onboardingDone: onboardingDone ?? this.onboardingDone,
      );
}

enum ThemeModeSetting {
  system,
  light,
  dark;

  String get label => switch (this) {
        system => 'System',
        light => 'Light',
        dark => 'Dark',
      };
}

/// Loads and persists [AppSettings].
class SettingsRepository {
  static const _themeKey = 'wakeguard.themeMode';
  static const _snoozeKey = 'wakeguard.defaultSnoozeMinutes';
  static const _onboardingKey = 'wakeguard.onboardingDone';

  Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final theme = ThemeModeSetting.values.firstWhere(
      (mode) => mode.name == prefs.getString(_themeKey),
      orElse: () => ThemeModeSetting.system,
    );
    return AppSettings(
      themeMode: theme,
      defaultSnoozeMinutes: (prefs.getInt(_snoozeKey) ??
              Alarm.defaultSnoozeMinutes)
          .clamp(0, 60),
      onboardingDone: prefs.getBool(_onboardingKey) ?? false,
    );
  }

  Future<void> save(AppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, settings.themeMode.name);
    await prefs.setInt(_snoozeKey, settings.defaultSnoozeMinutes);
    await prefs.setBool(_onboardingKey, settings.onboardingDone);
  }
}

/// Observable settings, so a theme change repaints immediately.
class SettingsController extends ChangeNotifier {
  SettingsController({SettingsRepository? repository})
      : _repository = repository ?? SettingsRepository();

  final SettingsRepository _repository;

  AppSettings _settings = const AppSettings();
  bool _loaded = false;
  bool _disposed = false;
  Future<void> _writes = Future<void>.value();

  AppSettings get settings => _settings;
  bool get loaded => _loaded;

  Future<void> load() async {
    try {
      _settings = await _repository.load();
    } catch (error) {
      // Defaults are always usable; a broken preferences store must not stop
      // the app from opening.
      debugPrint('WakeGuard settings load failed: $error');
    }
    _loaded = true;
    if (_disposed) return;
    notifyListeners();
  }

  Future<void> update(AppSettings Function(AppSettings) mutate) async {
    if (_disposed) return;
    _settings = mutate(_settings);
    final snapshot = _settings;
    notifyListeners();
    _writes = _writes.then((_) async {
      try { await _repository.save(snapshot); }
      catch (error) { debugPrint('WakeGuard settings save failed: $error'); }
    });
    await _writes;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
