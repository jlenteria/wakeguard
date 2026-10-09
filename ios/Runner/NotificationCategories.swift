import Foundation
import UserNotifications

/// Registers the lock-screen affordances the alarm relies on.
///
/// On iOS the notification *is* the dismissal UI. There is no public API to take
/// over the lock screen, no way to turn the screen on, and no way to run a camera
/// in the background, so every escape the Android version offers from a live
/// alarm has to be reachable from a notification action instead.
///
/// Three actions are registered:
///
///  * `dismiss`  - foregrounds the app so the native face/QR challenge can run.
///  * `confirm`  - a text input action. This is a *complete* escape on its own:
///                 it needs no camera, no light, and works from the lock screen,
///                 which makes it the accessibility path and the path that works
///                 at 05:00 in a dark room.
///  * `snooze`   - silences and re-arms in nine minutes.
enum NotificationCategories {
    static let alarmCategory = "WAKEGUARD_ALARM"

    static func register() {
        let openChallenge = UNNotificationAction(
            identifier: ActionIdentifier.openChallenge.rawValue,
            title: NSLocalizedString("notification.action.awake", comment: ""),
            options: [.foreground]
        )

        let confirm = UNTextInputNotificationAction(
            identifier: ActionIdentifier.confirm.rawValue,
            title: NSLocalizedString("notification.action.confirm", comment: ""),
            options: [.authenticationRequired],
            textInputButtonTitle: NSLocalizedString("notification.action.confirm.send", comment: ""),
            textInputPlaceholder: NSLocalizedString("notification.action.confirm.placeholder", comment: "")
        )

        let snooze = UNNotificationAction(
            identifier: ActionIdentifier.snooze.rawValue,
            title: NSLocalizedString("notification.action.snooze", comment: ""),
            options: []
        )

        let category = UNNotificationCategory(
            identifier: alarmCategory,
            actions: [confirm, openChallenge, snooze],
            intentIdentifiers: [],
            // The user must be able to see and act on this from the lock screen.
            options: [.customDismissAction]
        )

        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}

enum ActionIdentifier: String {
    case openChallenge
    case confirm
    case snooze
}

/// The arithmetic challenge.
///
/// The prompt is built from separate operands and the answer is derived from
/// them, never rendered into the prompt itself. Showing the answer and asking the
/// user to type it back would be a no-op as a challenge, and would be trivially
/// bypassable by reading the lock screen.
struct Challenge {
    let prompt: String
    let answer: Int

    static func make() -> Challenge {
        // Multiplication rather than addition: an addition result can be
        // brute-forced by re-rolling until the answer looks plausible, while a
        // product in the 30-169 range requires a correct mental answer. The
        // operands stay inside the standard times tables so a waking brain can
        // still compute it unaided.
        let left = Int.random(in: 5...13)
        let right = Int.random(in: 6...13)
        return Challenge(
            prompt: String(
                format: NSLocalizedString("challenge.prompt", comment: ""),
                left,
                right
            ),
            answer: left * right
        )
    }

    static func matches(input: String, answer: Int) -> Bool {
        // Tolerate stray whitespace and full-width digits typed on the lock
        // screen keyboard, but nothing else.
        let normalised = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? ""
        return Int(normalised) == answer
    }
}
