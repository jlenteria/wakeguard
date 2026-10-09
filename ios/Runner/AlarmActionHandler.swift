import Foundation
import UserNotifications
import UIKit

/// Handles notification actions in place of Android's lock-screen takeover; the
/// typed-confirm path validates and reschedules with no UI or camera.
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
            // A wrong answer is a no-op; the next rung fires with a fresh question.
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
            // Copy every field; dropping one silently resets it when disabled after ringing.
            soundPack: soundPack
        )
    }
}
