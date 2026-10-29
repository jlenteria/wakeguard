import Flutter
import UIKit
import UserNotifications

/// Bridges the Dart settings UI to the native engine. Ringing never passes through
/// Flutter, so a Dart crash cannot stop or block dismissal of an alarm.
final class AlarmEngineChannel {

    static let channelName = "app.wakeguard/alarm"

    /// Retained for the process lifetime: a transient handler captures
    /// `[weak self]`, so everything would deallocate after launch and every
    /// Dart call would return NO_ENGINE.
    static let shared = AlarmEngineChannel()

    private let scheduler = LadderScheduler.shared
    private let store = AlarmStore.shared

    private init() {}

    func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: Self.channelName,
            binaryMessenger: registrar.messenger()
        )
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else {
                result(FlutterError(code: "NO_ENGINE", message: "Engine unavailable", details: nil))
                return
            }
            self.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]

        switch call.method {
        case "capabilities":
            result(HealthChecker.capabilities())

        case "health":
            Task {
                let checks = await HealthChecker.check()
                await MainActor.run { result(checks) }
            }

        case "schedule":
            let alarm = StoredAlarm(
                id: args["id"] as? String ?? UUID().uuidString,
                hour: args["hour"] as? Int ?? 7,
                minute: args["minute"] as? Int ?? 0,
                label: args["label"] as? String ?? "Wake up",
                enabled: args["enabled"] as? Bool ?? true,
                repeatDaily: args["repeatDaily"] as? Bool ?? true,
                weekdays: Set((args["weekdays"] as? [Int]) ?? []),
                qrValue: args["qrValue"] as? String ?? "",
                stepCount: Self.steps(forDifficulty: args["difficulty"] as? String),
                soundPack: args["soundPack"] as? String,
                holdSeconds: args["holdSeconds"] as? Int,
                escapes: (args["escapes"] as? [String])?.filter {
                    StoredAlarm.validEscapeNames.contains($0)
                },
                snoozeMinutes: args["snoozeMinutes"] as? Int,
                // Millis exceed Int32; `.intValue` would truncate the skip window.
                skipUntilMillis: (args["skipUntilMillis"] as? NSNumber).map { Int($0.int64Value) },
                objectTarget: args["objectTarget"] as? String,
                objectVerified: args["objectVerified"] as? Bool,
                needsSetup: args["needsSetup"] as? Bool,
                vibrate: args["vibrate"] as? Bool
            )
            let triggerAt = (args["triggerAtMillis"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
                ?? scheduler.nextTrigger(alarm, from: Date())
            if alarm.enabled {
                // Persist only after every rung is accepted; a failed schedule must
                // not leave an alarm that looks armed to the Dart mirror.
                Task {
                    do {
                        try await scheduler.schedule(alarm, triggerAt: triggerAt)
                        store.put(alarm)
                        await MainActor.run { result(nil) }
                    } catch {
                        scheduler.cancel(alarm.id)
                        store.remove(alarm.id)
                        let failure = Self.scheduleFlutterError(error)
                        await MainActor.run { result(failure) }
                    }
                }
            } else {
                scheduler.cancel(alarm.id)
                store.remove(alarm.id)
                result(nil)
            }

        case "cancel":
            if let id = args["id"] as? String {
                scheduler.delete(id)
            }
            result(nil)

        case "dismiss":
            if let id = args["id"] as? String {
                AlarmActionHandler.shared.dismissFromSettings(
                    alarmId: id,
                    method: args["method"] as? String ?? "settings"
                )
            }
            result(nil)

        case "openFixAction":
            HealthChecker.openFix(args["action"] as? String ?? "")
            result(nil)

        case "playAudibilitySample":
            AudibilityProbe.play(pack: args["soundPack"] as? String) { result(nil) }

        case "stopAudibilitySample":
            AudibilityProbe.stop()
            result(nil)

        case "notificationsReady":
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                var missing: [String] = []
                if settings.authorizationStatus != .authorized { missing.append("notifications") }
                if settings.timeSensitiveSetting != .enabled { missing.append("timeSensitive") }
                if !HealthChecker.hasCriticalAlertsEntitlement { missing.append("criticalAlerts") }
                DispatchQueue.main.async { result(missing) }
            }

        case "requestPermissions":
            HealthChecker.requestAuthorization { granted in result(granted) }

        case "launchDetails":
            result(["ringing": false, "id": NSNull(), "label": NSNull()])

        case "rescheduleAll":
            Task {
                await scheduler.rescheduleAll()
                await MainActor.run { result(nil) }
            }

        case "alarms":
            // Keys must match Dart `Alarm.fromJson`; escapes in particular must be
            // valid EscapeKind names or Dart force-disables every alarm it reads.
            Task {
                let triggers = await scheduler.scheduledTriggers()
                let alarms = store.all().map { alarm -> [String: Any] in
                    let difficulty: String = switch alarm.stepCount {
                    case 1: "gentle"
                    case 3: "strict"
                    default: "moderate"
                    }
                    var entry: [String: Any] = [
                        "id": alarm.id,
                        "hour": alarm.hour,
                        "minute": alarm.minute,
                        "label": alarm.label,
                        "enabled": alarm.enabled,
                        "repeatDaily": alarm.repeatDaily,
                        "weekdays": Array(alarm.weekdays),
                        "qrValue": alarm.qrValue,
                        "stepCount": alarm.stepCount,
                        "soundPack": alarm.resolvedSoundPack,
                        "holdSeconds": alarm.effectiveHoldSeconds,
                        "snoozeMinutes": alarm.effectiveSnoozeMinutes,
                        "escapes": alarm.effectiveEscapes,
                        "checkInMinutes": 0,
                        "objectTarget": alarm.effectiveObjectTarget,
                        "objectVerified": alarm.objectVerified ?? false,
                        "needsSetup": alarm.needsSetup ?? false,
                        "skipUntilMillis": alarm.effectiveSkipUntilMillis,
                        "customSoundId": "",
                        "customSoundName": "",
                        "vibrate": alarm.vibrate ?? true,
                        "difficulty": difficulty,
                    ]
                    // Dart reads `nextTriggerAt`; a past/absent rung is not scheduled.
                    if let trigger = triggers[alarm.id] {
                        entry["nextTriggerAt"] = Int64(trigger.timeIntervalSince1970 * 1000)
                    } else {
                        entry["nextTriggerAt"] = NSNull()
                    }
                    return entry
                }
                await MainActor.run { result(alarms) }
            }

        case "history":
            result([])

        case "objectTargetVerified":
            // Verification is an actual native practice scan, which iOS does not
            // offer (practice is Android-only); claiming verified would be a lie
            // that lets an untested camera challenge arm anyway.
            result(false)

        case "pendingCheckIns":
            result([])

        case "confirmCheckIn":
            result(false)

        case "listSystemSounds":
            result([])

        case "importSystemSound":
            result(FlutterError(code: "UNSUPPORTED", message: "Custom sounds are available on Android only.", details: nil))

        case "pickCustomSound":
            result(FlutterError(code: "UNSUPPORTED", message: "Custom sounds are available on Android only.", details: nil))

        case "previewCustomSound":
            result(nil)

        case "retainCustomSounds":
            result(nil)

        case "practice":
            result(FlutterError(code: "UNAVAILABLE", message: "Challenge practice is available on Android phones only.", details: nil))

        case "clearHistory":
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private static func steps(forDifficulty difficulty: String?) -> Int {
        switch difficulty {
        case "gentle": return 1
        case "strict": return 3
        default: return 2
        }
    }

    /// Turns a scheduler failure into a channel error the Dart client surfaces
    /// as a save failure instead of pretending the alarm is armed.
    private static func scheduleFlutterError(_ error: Error) -> FlutterError {
        switch error {
        case LadderScheduler.ScheduleError.notAuthorized:
            return FlutterError(
                code: "NOT_AUTHORIZED",
                message: "Notifications are not allowed, so this alarm could not be scheduled. Enable them in Settings > Notifications.",
                details: nil
            )
        case LadderScheduler.ScheduleError.rungRejected(let identifier):
            return FlutterError(
                code: "SCHEDULE_FAILED",
                message: "The alarm engine rejected notification \(identifier).",
                details: nil
            )
        default:
            return FlutterError(
                code: "SCHEDULE_FAILED",
                message: "Could not schedule the alarm: \(error).",
                details: nil
            )
        }
    }
}

