import Foundation
import UserNotifications
import UIKit

/// Handles notification actions in place of Android's lock-screen takeover; the
/// typed-confirm path validates and reschedules with no UI or camera.
final class AlarmActionHandler {

    static let shared = AlarmActionHandler()

    private let scheduler = LadderScheduler.shared
    private let store = AlarmStore.shared

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
            // The process suspends the moment completion is called, so the
            // reschedule must finish inside a background task first.
            withBackgroundTask({ await self.snooze(alarmId: alarmId) }, then: completionHandler)

        case ActionIdentifier.confirm.rawValue:
            guard let textResponse = response as? UNTextInputNotificationResponse else {
                completionHandler()
                return
            }
            let answer = (userInfo["answer"] as? Int) ?? 0
            if Challenge.matches(input: textResponse.userText, answer: answer) {
                withBackgroundTask(
                    { await self.dismiss(alarmId: alarmId, method: "typed") },
                    then: completionHandler
                )
            } else {
                // A wrong answer is a no-op; the next rung fires with a fresh question.
                completionHandler()
            }

        case ActionIdentifier.openChallenge.rawValue:
            presentChallenge(alarmId: alarmId)
            completionHandler()

        default:
            completionHandler()
        }
    }

    /// Runs async alarm work before releasing the notification-response
    /// completion handler, with a background task so the process cannot be
    /// suspended mid-reschedule. `handle` is not main-actor isolated, so the
    /// UIApplication calls happen inside the MainActor task, not around it.
    private func withBackgroundTask(
        _ work: @escaping @MainActor () async -> Void,
        then completion: @escaping () -> Void
    ) {
        Task { @MainActor in
            let application = UIApplication.shared
            let task = application.beginBackgroundTask {
                // Expiry: let go of the assertion; the work itself is best-effort.
            }
            await work()
            completion()
            if task != .invalid { application.endBackgroundTask(task) }
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
        guard let alarm = store.get(alarmId) else { return }
        // Snooze is honoured only when the alarm allows it; the no-snooze
        // category should prevent the action, this guards stale delivered rungs.
        guard alarm.effectiveSnoozeMinutes > 0 else { return }
        scheduler.cancel(alarmId)
        do {
            try await scheduler.schedule(
                alarm,
                triggerAt: Date().addingTimeInterval(TimeInterval(alarm.effectiveSnoozeMinutes * 60))
            )
        } catch {
            NSLog("WakeGuard: snooze of alarm %@ failed: %@", alarmId, String(describing: error))
            // Never lose the next scheduled occurrence over a failed snooze.
            do {
                try await scheduler.schedule(alarm, triggerAt: scheduler.nextTrigger(alarm, from: Date()))
            } catch {
                NSLog("WakeGuard: snooze fallback reschedule failed too: %@", String(describing: error))
            }
        }
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
        do {
            // `nextTrigger` honours the stored skip-until window, so a skipped
            // alarm rolls to the next occurrence that is actually due.
            try await scheduler.schedule(alarm, triggerAt: scheduler.nextTrigger(alarm, from: Date()))
        } catch {
            NSLog("WakeGuard: roll-forward after dismiss of alarm %@ failed: %@", alarmId, String(describing: error))
        }
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
    /// Flips only `enabled` on a value copy. Rebuilding via the memberwise init
    /// would fail to compile against the added fields, and a field-dropping init
    /// would silently reset escape/snooze/skip settings when a one-shot retires.
    func disabled() -> StoredAlarm {
        var retired = self
        retired.enabled = false
        return retired
    }
}
