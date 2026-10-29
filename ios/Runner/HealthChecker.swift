import Foundation
import AVFoundation
import UserNotifications
import UIKit

/// iOS health checks. Focus and Low Power modes are not introspectable, so only
/// permissions and real entitlements are surfaced as actual state.
enum HealthChecker {

    static var hasCriticalAlertsEntitlement: Bool {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: "CriticalAlertsEntitlementGranted"
        ) as? Bool else { return false }
        return value
    }

    static func capabilities() -> [String: Any] {
        [
            // Cannot loop audio while backgrounded despite requesting the audio mode.
            "canLoopWhileBackgrounded": false,
            // No public API exists to present UI over the lock screen.
            "canLockScreenTakeover": false,
            // Camera access requires the foreground.
            "canUseCameraInBackground": false,
            "canBypassSilentSwitch": hasCriticalAlertsEntitlement,
            // Hard limit; the ladder planner enforces this.
            "pendingSlotCap": EscalationPolicy.pendingNotificationCap,
            "contractVersion": 2,
            "canPractice": false,
            "canCheckIn": false,
        ]
    }

    static func check() async -> [[String: Any]] {
        var results: [[String: Any]] = []

        let settings = await notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .ephemeral:
            results.append(
                health(
                    id: "notification_authorization",
                    label: NSLocalizedString("health.notifications", comment: ""),
                    passing: true,
                    ok: NSLocalizedString("health.notifications.ok", comment: ""),
                    bad: "",
                    action: nil
                )
            )
        case .provisional:
            // Provisional delivery lands silently in Notification Center: the
            // alarm exists but cannot wake anyone, so passing it would be a lie.
            results.append(
                health(
                    id: "notification_authorization",
                    label: NSLocalizedString("health.notifications", comment: ""),
                    passing: false,
                    ok: "",
                    bad: NSLocalizedString("health.notifications.provisional", comment: ""),
                    action: "notifications",
                    failSeverity: "warning"
                )
            )
        default:
            results.append(
                health(
                    id: "notification_authorization",
                    label: NSLocalizedString("health.notifications", comment: ""),
                    passing: false,
                    ok: "",
                    bad: NSLocalizedString("health.notifications.bad", comment: ""),
                    action: "notifications"
                )
            )
        }

        results.append(
            health(
                id: "time_sensitive",
                label: NSLocalizedString("health.time_sensitive", comment: ""),
                passing: settings.timeSensitiveSetting == .enabled,
                ok: NSLocalizedString("health.time_sensitive.ok", comment: ""),
                bad: NSLocalizedString("health.time_sensitive.bad", comment: ""),
                action: "settings"
            )
        )

        // Focus modes are not introspectable. This is guidance, not state.
        results.append(
            health(
                id: "focus_modes",
                label: NSLocalizedString("health.focus", comment: ""),
                passing: true,
                ok: NSLocalizedString("health.focus.ok", comment: ""),
                bad: "",
                action: nil
            )
        )

        results.append(
            health(
                id: "critical_alerts",
                label: NSLocalizedString("health.critical", comment: ""),
                passing: hasCriticalAlertsEntitlement,
                ok: NSLocalizedString("health.critical.ok", comment: ""),
                bad: NSLocalizedString("health.critical.bad", comment: ""),
                action: nil
            )
        )

        let pendingCount = await pendingCount()
        results.append(
            health(
                id: "notification_budget",
                label: NSLocalizedString("health.budget", comment: ""),
                passing: pendingCount <= EscalationPolicy.usableSlots,
                ok: String(
                    format: NSLocalizedString("health.budget.ok", comment: ""),
                    pendingCount,
                    EscalationPolicy.pendingNotificationCap
                ),
                bad: String(
                    format: NSLocalizedString("health.budget.bad", comment: ""),
                    pendingCount,
                    EscalationPolicy.usableSlots
                ),
                action: "settings"
            )
        )

        // The ringer switch mutes every non-critical notification, time-sensitive
        // included; claiming this passes without the entitlement hides the most
        // common way an alarm fails to wake anyone.
        results.append(
            health(
                id: "silent_switch",
                label: NSLocalizedString("health.silent", comment: ""),
                passing: hasCriticalAlertsEntitlement,
                ok: NSLocalizedString("health.silent.ok", comment: ""),
                bad: NSLocalizedString("health.silent.bad", comment: ""),
                action: nil,
                failSeverity: "warning"
            )
        )

        return results
    }

    private static func notificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private static func pendingCount() async -> Int {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                continuation.resume(returning: requests.count)
            }
        }
    }

    private static func health(
        id: String,
        label: String,
        passing: Bool,
        ok: String,
        bad: String,
        action: String?,
        failSeverity: String = "blocking"
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "id": id,
            "label": label,
            "detail": passing ? ok : bad,
            "severity": passing ? "ok" : failSeverity,
        ]
        // A Swift `nil` boxed into [String: Any] is not bridgable by the channel
        // codec (it crashes the whole health reply), so failing checks without a
        // fix action send NSNull, which Dart reads as a null action.
        if !passing, let action {
            entry["action"] = action
        } else {
            entry["action"] = NSNull()
        }
        return entry
    }

    static func openFix(_ action: String) {
        switch action {
        case "notifications":
            UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge, .timeSensitive, .criticalAlert]
            ) { _, _ in }
        case "settings":
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        default:
            break
        }
    }

    /// `.criticalAlert` is only requested when granted; asking without it is harmless.
    static func requestAuthorization(completion: @escaping (Bool) -> Void) {
        var options: UNAuthorizationOptions = [.alert, .sound, .badge, .timeSensitive]
        if hasCriticalAlertsEntitlement {
            options.insert(.criticalAlert)
        }
        UNUserNotificationCenter.current().requestAuthorization(options: options) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}

/// Plays the ladder through the app's audio session so the user can confirm
/// audibility in the foreground, since a muted or Focus-swallowed alarm looks fine until it matters.
enum AudibilityProbe {
    private static var player: AVAudioPlayer?

    /// - Parameter pack: the family to preview, matching what the edited alarm will ring.
    static func play(pack: String? = nil, completion: @escaping () -> Void) {
        stop()
        let url = AlarmSounds.previewURL(pack: pack)
        guard let url else {
            completion()
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.duckOthers])
            try session.setActive(true)

            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = 1.0
            player.delegate = ProbeDelegate(completion: completion)
            player.prepareToPlay()
            player.play()
            Self.player = player
        } catch {
            completion()
        }
    }

    static func stop() {
        player?.stop()
        player = nil
        // The probe activated a .playback session that would otherwise keep the
        // app as the audio owner; deactivating lets other apps (music, calls)
        // resume with their volume restored.
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }

    private final class ProbeDelegate: NSObject, AVAudioPlayerDelegate {
        private let completion: () -> Void

        init(completion: @escaping () -> Void) {
            self.completion = completion
        }

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            AudibilityProbe.stop()
            completion()
        }
    }
}
