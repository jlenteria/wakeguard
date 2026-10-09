import Foundation
import UserNotifications
import UIKit

/// Handles the notification actions that stand in for Android's lock-screen
/// takeover.
///
/// `userNotificationCenter(_:didReceive:)` runs in the background even when the
/// device is locked, which is the only mechanism iOS gives us to make progress
/// on a live alarm without the user opening the app. The typed-confirm path is
/// deliberately complete on its own: it validates the answer here, stops the
/// ladder, and reschedules, with no UI and no camera involved. That matters
/// because the camera cannot run from the lock screen at all on iOS.
final class AlarmActionHandler {

    static let shared = AlarmActionHandler()

    private let scheduler = LadderScheduler.shared
    private let store = AlarmStore()

    private init() {}

    func handle(
        response: UNNotificationResponse,
        completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        guard let alarmId = userInfo["alarmId"] as? String else {
            completionHandler()
            return
        }

        switch response.actionIdentifier {
        case ActionIdentifier.snooze.rawValue:
            Task { await snooze(alarmId: alarmId) }
            completionHandler()

        case ActionIdentifier.confirm.rawValue:
            guard let textResponse = response as? UNTextInputNotificationResponse else {
                completionHandler()
                return
            }
            let answer = (userInfo["answer"] as? Int) ?? 0
            if Challenge.matches(input: textResponse.userText, answer: answer) {
                Task { await dismiss(alarmId: alarmId, method: "typed") }
            }
            // A wrong answer is a no-op: the next rung fires with a fresh
            // question, which is the intended escalation behaviour.
            completionHandler()

        case ActionIdentifier.openChallenge.rawValue:
            presentChallenge(alarmId: alarmId)
            completionHandler()

        default:
            completionHandler()
        }
    }

    /// Called from the native challenge once it is satisfied.
    func dismissFromChallenge(alarmId: String, method: String) {
        Task { await dismiss(alarmId: alarmId, method: method) }
    }

    /// Called from the settings UI, where the user is already in the app.
    func dismissFromSettings(alarmId: String, method: String) {
        Task { await dismiss(alarmId: alarmId, method: method) }
    }

    private func snooze(alarmId: String) async {
        scheduler.cancel(alarmId)
        guard let alarm = store.get(alarmId) else { return }
        await scheduler.schedule(alarm, triggerAt: Date().addingTimeInterval(9 * 60))
    }

    @discardableResult
    private func dismiss(alarmId: String, method: String) async -> Bool {
        UserDefaults.standard.set(method, forKey: "wakeguard.lastDismissalMethod")
        UserDefaults.standard.set(Date(), forKey: "wakeguard.lastDismissalAt")

        scheduler.cancel(alarmId)
        guard let alarm = store.get(alarmId) else { return false }

        // A one-shot alarm is retired rather than rolled forward.
        guard alarm.repeatDaily || !alarm.weekdays.isEmpty else {
            store.put(alarm.disabled())
            return true
        }

        store.put(alarm)
        await scheduler.schedule(alarm, triggerAt: scheduler.nextTrigger(alarm, from: Date()))
        return true
    }

    /// Foregrounds the native challenge.
    private func presentChallenge(alarmId: String) {
        guard let alarm = store.get(alarmId) else { return }
        DispatchQueue.main.async {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            let root = scene?.windows.first { $0.isKeyWindow }?.rootViewController
            root?.present(WakeChallengeViewController(alarm: alarm), animated: true)
        }
    }
}

private extension StoredAlarm {
    func disabled() -> StoredAlarm {
        StoredAlarm(
            id: id,
            hour: hour,
            minute: minute,
            label: label,
            enabled: false,
            repeatDaily: repeatDaily,
            weekdays: weekdays,
            qrValue: qrValue,
            stepCount: stepCount,
            // Every field has to be copied. Dropping one here silently resets
            // that setting when an alarm is disabled after ringing.
            soundPack: soundPack
        )
    }
}
