import Foundation
import UserNotifications

/// Registers the lock-screen actions, since on iOS the notification *is* the
/// dismissal UI. The confirm text-input action is a complete, camera-free escape.
enum NotificationCategories {
    static let alarmCategory = "WAKEGUARD_ALARM"
    /// Alarms with `snoozeMinutes == 0` must not be offered a snooze action.
    static let alarmCategoryNoSnooze = "WAKEGUARD_ALARM_NO_SNOOZE"

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

        let actions = [snooze, openChallenge, confirm]
        let noSnoozeActions = [openChallenge, confirm]
        UNUserNotificationCenter.current().setNotificationCategories([
            // Put Snooze first so compact action presentations can expose it.
            category(actions: actions, identifier: alarmCategory),
            category(actions: noSnoozeActions, identifier: alarmCategoryNoSnooze),
        ])
    }

    /// The user must be able to see and act on this from the lock screen.
    private static func category(actions: [UNNotificationAction], identifier: String) -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: identifier,
            actions: actions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }
}

enum ActionIdentifier: String {
    case openChallenge
    case confirm
    case snooze
}

/// Arithmetic challenge; the answer is derived from the operands, never shown in
/// the prompt, which would make it trivially bypassable from the lock screen.
struct Challenge {
    let prompt: String
    let answer: Int

    static func make() -> Challenge {
        // Multiplication, not addition: products can't be brute-forced and stay in the times tables.
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
        // Tolerate stray whitespace and full-width digits only.
        let normalised = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? ""
        return Int(normalised) == answer
    }
}
