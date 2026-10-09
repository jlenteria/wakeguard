import Flutter
import UIKit
import UserNotifications

/// Bridges the Dart settings UI to the native iOS alarm engine.
///
/// Everything here is settings-surface only. Ringing never passes through
/// Flutter: the notification ladder and the native challenge own that path, so a
/// Dart crash cannot prevent an alarm from being dismissed or stop it sounding.
final class AlarmEngineChannel {

    static let channelName = "app.wakeguard/alarm"

    private let scheduler = LadderScheduler.shared
    private let store = AlarmStore()

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
                soundPack: args["soundPack"] as? String
            )
            let triggerAt = (args["triggerAtMillis"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
                ?? scheduler.nextTrigger(alarm, from: Date())
            store.put(alarm)
            Task {
                await scheduler.schedule(alarm, triggerAt: triggerAt)
                await MainActor.run { result(nil) }
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
}

