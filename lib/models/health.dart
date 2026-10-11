/// Platform health signals the UI surfaces before an alarm silently fails.
enum HealthSeverity { ok, warning, blocking }

class HealthCheck {
  const HealthCheck({
    required this.id,
    required this.label,
    required this.detail,
    required this.severity,
    this.action,
  });

  final String id;
  final String label;
  final String detail;
  final HealthSeverity severity;

  /// Platform-side identifier for a fix action, e.g. `exact_alarm`.
  final String? action;
}

/// Platform capabilities as data, so the UI never offers controls it cannot honour.
class EngineCapabilities {
  const EngineCapabilities({
    required this.canLoopWhileBackgrounded,
    required this.canLockScreenTakeover,
    required this.canUseCameraInBackground,
    required this.canBypassSilentSwitch,
    required this.pendingSlotCap,
    this.contractVersion = 1,
    this.canPractice = false,
    this.canCheckIn = false,
  });

  /// Android: foreground service. iOS: false.
  final bool canLoopWhileBackgrounded;

  /// Android: setFullScreenIntent. iOS: false, no public API.
  final bool canLockScreenTakeover;

  /// Android: true. iOS: false, camera needs the foreground.
  final bool canUseCameraInBackground;

  /// Android alarm audio is independent of silent/vibrate mode. On iOS this
  /// requires the Critical Alerts entitlement. Does not imply DND/Focus bypass.
  final bool canBypassSilentSwitch;

  /// Android: effectively unlimited. iOS: 64 pending notifications.
  final int? pendingSlotCap;
  final int contractVersion;
  final bool canPractice;
  final bool canCheckIn;

  bool get hasPendingSlotCap => pendingSlotCap != null;
}
