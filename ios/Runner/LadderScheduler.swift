import Foundation
import UserNotifications

/// Schedules an alarm as a ladder of time-sensitive notifications. iOS has no
/// background service, so the ladder is committed up front within the 64-slot cap.
final class LadderScheduler {

    static let shared = LadderScheduler()

    private let center = UNUserNotificationCenter.current()

    private init() {}

    // MARK: - Scheduling

    func schedule(_ alarm: StoredAlarm, triggerAt: Date) async {
        cancel(alarm.id)
        await makeRoom(forLadderOf: alarm.id)

        // Each rung gets its own challenge, so answers cannot be replayed.
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
            // Passive delivery suppresses sound; every alarm rung should alert.
            content.interruptionLevel = step.interrupt ? .timeSensitive : .active
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

    /// Removes the pending ladder but never the alarm record; must not touch the store.
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

    /// iOS silently drops all but the 64 soonest notifications, so evict the
    /// furthest-future rungs of *other* alarms; evicting the earliest would delete an alarm.
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

    /// Always the standard named sound: `criticalSoundNamed` is not in the Swift
    /// interface and Critical Alerts needs an approved entitlement plus an Obj-C shim.
    private func sound(
        for tier: EscalationTier,
        pack: String?
    ) -> UNNotificationSound {
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
        // Shared weekdays are 1=Mon..7=Sun; Calendar.weekday is 1=Sun..7=Sat,
        // so comparing directly would shift alarms by a day.
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

    /// Converts shared weekday (Mon=1..Sun=7) to Calendar.weekday (Sun=1..Sat=7).
    private static func calendarWeekday(fromPlatform weekday: Int) -> Int {
        weekday == 7 ? 1 : weekday + 1
    }
}

/// UserDefaults-backed alarm set; native is the source of truth across cold launches.
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
