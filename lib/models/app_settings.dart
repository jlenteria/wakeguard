import 'alarm.dart';

/// App-wide preferences kept out of [Alarm]; defaults must not rewrite alarms.
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeModeSetting.system,
    this.defaultSnoozeMinutes = Alarm.defaultSnoozeMinutes,
    this.onboardingDone = false,
  });

  final ThemeModeSetting themeMode;

  /// Snooze length given to newly created alarms.
  final int defaultSnoozeMinutes;

  /// Whether the first-run screen is done; starts false so a fresh install sees it.
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
