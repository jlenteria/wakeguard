import Foundation
import AVFoundation
import UserNotifications
import UIKit

/// iOS health checks.
///
/// The honest reality on iOS: several of the things that break Android alarms
/// cannot be probed at all. Focus modes are private API, so the app can only ask
/// the user to verify them. Low Power Mode is likewise invisible. What *can* be
/// checked is notification authorisation, whether time-sensitive delivery was
/// granted, and whether the critical-alerts entitlement actually landed, so
/// those are surfaced with real state rather than optimism.
enum HealthChecker {

    static var hasCriticalAlertsEntitlement: Bool {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: "CriticalAlertsEntitlementGranted"
        ) as? Bool else { return false }
        return value
    }

    static func capabilities() -> [String: Any] {
        [
            // iOS cannot loop audio while backgrounded, so this is false even
            // though the app requests the audio background mode.
            "canLoopWhileBackgrounded": false,
            // No public API exists to present UI over the lock screen.
            "canLockScreenTakeover": false,
            // Camera access requires the foreground.
            "canUseCameraInBackground": false,
            "canBypassSilentSwitch": hasCriticalAlertsEntitlement,
            // Hard limit; the ladder planner enforces this.
            "pendingSlotCap": EscalationPolicy.pendingNotificationCap,
        ]
    }

    static func check() async -> [[String: Any]] {
        var results: [[String: Any]] = []

        let settings = await notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
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

        results.append(
            health(
                id: "silent_switch",
                label: NSLocalizedString("health.silent", comment: ""),
                passing: true,
                ok: NSLocalizedString("health.silent.ok", comment: ""),
                bad: "",
                action: nil
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
        action: String?
    ) -> [String: Any] {
        [
            "id": id,
            "label": label,
            "detail": passing ? ok : bad,
            "severity": passing ? "ok" : "blocking",
            "action": passing ? NSNull() : (action as Any?),
        ]
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

    /// Requesting `.criticalAlert` without the granted entitlement is harmless:
    /// the system simply does not show a critical prompt. The option is included
    /// so that a future approved request needs no code change.
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

/// Plays the bundled ladder through the app's own audio session so the user can
/// confirm audibility while the app is in the foreground. This is the iOS
/// equivalent of the Android preflight probe: an alarm volume at zero or a Focus
/// mode swallowing sound looks identical to a working alarm until it matters.
enum AudibilityProbe {
    private static var player: AVAudioPlayer?

    /// - Parameter pack: the sound family to preview, so the user hears exactly
    ///   what the alarm they just edited will ring with.
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
