import Foundation
import UserNotifications

/// Schedules an alarm as a ladder of independent time-sensitive notifications.
///
/// iOS has no equivalent of Android's foreground service: the app cannot run in
/// the background, cannot keep a sound looping, and cannot be woken to start a
/// timer. Every design decision here follows from that, so the escalation ladder
/// is committed to the notification scheduler at the moment the alarm is saved.
/// That is also why the 64-notification cap has to be budgeted for up front
/// instead of being discovered when a distant alarm quietly stops firing.
///
/// `interruptionLevel = .timeSensitive` is what gets these through Do Not
/// Disturb and most Focus modes without the Critical Alerts entitlement.
final class LadderScheduler {

    static let shared = LadderScheduler()

    private let center = UNUserNotificationCenter.current()

    private init() {}

    // MARK: - Scheduling

    func schedule(_ alarm: StoredAlarm, triggerAt: Date) async {
        cancel(alarm.id)
        await makeRoom(forLadderOf: alarm.id)

        // Each rung carries its own arithmetic problem, so a wrong answer to one
        // rung cannot be replayed against the next one.
        let challenges = Dictionary(
            uniqueKeysWithValues: EscalationPolicy.steps.indices.map {
                (EscalationPolicy.steps[$0].offset, Challenge.make())
            }
        )

        for (index, step) in EscalationPolicy.steps.enumerated() {
            let content = UNMutableNotificationContent()
            content.title = alarm.label
            let challenge = challenges[step.offset]
            content.body = index == 0
                ? challenge?.prompt ?? ""
                : NSLocalizedString("notification.ringing.still", comment: "")
            content.categoryIdentifier = NotificationCategories.alarmCategory
            content.sound = sound(for: step.tier, pack: alarm.soundPack)
            content.interruptionLevel = step.interrupt ? .timeSensitive : .passive
            content.userInfo = [
                "alarmId": alarm.id,
                "rung": index,
                "answer": challenge?.answer ?? 0,
                "qrValue": alarm.qrValue,
                "stepCount": alarm.stepCount,
            ]
            content.relevanceScore = Double(EscalationPolicy.steps.count - index)

            let fireDate = triggerAt.addingTimeInterval(step.offset)
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: fireDate
                ),
                repeats: false
            )

            let request = UNNotificationRequest(
                identifier: alarm.ladderId(rung: index),
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }

    func rescheduleAll() async {
        let now = Date()
        for alarm in AlarmStore().all() where alarm.enabled {
            await schedule(alarm, triggerAt: nextTrigger(alarm, from: now))
        }
    }

    /// Removes the pending ladder but keeps the alarm record. Scheduling a new
    /// occurrence goes through here, so this must never touch the store.
    func cancel(_ alarmId: String) {
        let identifiers = (0..<EscalationPolicy.steps.count)
            .map { "wakeguard.\(alarmId).rung.\($0)" }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// Full removal, used when the user deletes the alarm.
    func delete(_ alarmId: String) {
        cancel(alarmId)
        AlarmStore().remove(alarmId)
    }

    // MARK: - Notification budget

    /// iOS keeps only the 64 soonest pending notifications and silently drops the
    /// rest, which presents to the user as "my alarm didn't fire". Rather than
    /// refuse to save an alarm, the furthest-future rungs belonging to *other*
    /// alarms are evicted until this ladder fits. Evicting the latest rungs of a
    /// ladder degrades it into a shorter ladder, which is recoverable; evicting
    /// the earliest rung would silently delete that alarm.
    private func makeRoom(forLadderOf alarmId: String) async {
        let needed = EscalationPolicy.steps.count
        let pending = await pendingRequests()
        let slack = EscalationPolicy.pendingNotificationCap - EscalationPolicy.reservedSlots
        guard pending.count + needed > EscalationPolicy.pendingNotificationCap else { return }

        let victims = pending
            .filter { !$0.identifier.contains("wakeguard.\(alarmId).rung.") }
            .sorted { $0.nextTriggerDate > $1.nextTriggerDate }
            .map(\.identifier)
            .prefix(max(0, pending.count + needed - slack))

        guard !victims.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: Array(victims))
        UserDefaults.standard.set(Array(victims), forKey: "wakeguard.evictedSlots")
    }

    private struct PendingRequest {
        let identifier: String
        let nextTriggerDate: Date
    }

    private func pendingRequests() async -> [PendingRequest] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests.map {
                    PendingRequest(
                        identifier: $0.identifier,
                        nextTriggerDate: ($0.trigger as? UNCalendarNotificationTrigger)?
                            .nextTriggerDate() ?? .distantFuture
                    )
                })
            }
        }
    }

    // MARK: - Sound

    /// Notification sound for a tier.
    ///
    /// Apple's `criticalSoundNamed:withAudioVolume:` factory is not exposed in
    /// the current SDK's Swift interface, and Critical Alerts is only granted to
    /// health and safety apps in practice, so the ladder always uses the standard
    /// named sound and reports the missing entitlement in health checks rather
    /// than pretending it will cut through the silent switch. If the entitlement
    /// is ever approved, this needs a small Objective-C shim before the critical
    /// variant can be used.
    private func sound(
        for tier: EscalationTier,
        pack: String?
    ) -> UNNotificationSound? {
        AlarmSounds.sound(pack: pack, tier: tier)
    }

    // MARK: - Next occurrence

    /// Next local wall-clock occurrence honouring the weekday set.
    func nextTrigger(_ alarm: StoredAlarm, from date: Date) -> Date {
        let calendar = Calendar.current
        guard let base = calendar.nextDate(
            after: date,
            matching: DateComponents(hour: alarm.hour, minute: alarm.minute),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) else {
            return date.addingTimeInterval(86400)
        }

        guard !alarm.weekdays.isEmpty else { return base }
        // The shared encoding is 1=Monday..7=Sunday (Dart's DateTime.weekday),
        // while Calendar.weekday is 1=Sunday..7=Saturday. Comparing them directly
        // shifts every alarm by a day in both directions, which is why this
        // translation exists and why the Android scheduler does the same.
        let wanted = Set(alarm.weekdays.map(Self.calendarWeekday(fromPlatform:)))
        var probe = base
        for _ in 0..<7 {
            if wanted.contains(calendar.component(.weekday, from: probe)) {
                return probe
            }
            probe = calendar.date(byAdding: .day, value: 1, to: probe) ?? probe
        }
        return base
    }

    /// Shared weekday encoding (1=Monday..7=Sunday) to Calendar.weekday
    /// (1=Sunday..7=Saturday).
    private static func calendarWeekday(fromPlatform weekday: Int) -> Int {
        weekday == 7 ? 1 : weekday + 1
    }
}

/// UserDefaults-backed alarm set. The Dart layer mirrors this, but native is the
/// source of truth for anything that must survive a cold launch.
final class AlarmStore {
    private let key = "wakeguard.alarms.v2"

    func all() -> [StoredAlarm] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let alarms = try? JSONDecoder().decode([StoredAlarm].self, from: data)
        else { return [] }
        return alarms.sorted { $0.hour * 60 + $0.minute < $1.hour * 60 + $1.minute }
    }

    func put(_ alarm: StoredAlarm) {
        var alarms = all().filter { $0.id != alarm.id }
        alarms.append(alarm)
        save(alarms)
    }

    func remove(_ alarmId: String) {
        save(all().filter { $0.id != alarmId })
    }

    func get(_ alarmId: String) -> StoredAlarm? {
        all().first { $0.id == alarmId }
    }

    private func save(_ alarms: [StoredAlarm]) {
        guard let data = try? JSONEncoder().encode(alarms) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
