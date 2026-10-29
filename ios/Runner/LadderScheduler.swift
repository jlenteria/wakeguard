import Foundation
import UserNotifications

/// Schedules an alarm as a ladder of time-sensitive notifications. iOS has no
/// background service, so the ladder is committed up front within the 64-slot cap.
final class LadderScheduler {

    static let shared = LadderScheduler()

    /// A ladder is only "scheduled" when every rung is accepted by the center;
    /// a swallowed `add` failure or a missing authorization must reach the caller.
    enum ScheduleError: Error {
        case notAuthorized
        case rungRejected(String)
    }

    private let center = UNUserNotificationCenter.current()

    private init() {}

    // MARK: - Scheduling

    func schedule(_ alarm: StoredAlarm, triggerAt: Date) async throws {
        // Without full authorization, notifications deliver silently or not at
        // all; reporting success anyway would be a silently-dead alarm.
        let settings = await notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .ephemeral else {
            throw ScheduleError.notAuthorized
        }
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
            // Snooze is offered only when the alarm allows it; a stale action on a
            // snooze-disabled alarm would otherwise re-arm one silently.
            content.categoryIdentifier = alarm.effectiveSnoozeMinutes > 0
                ? NotificationCategories.alarmCategory
                : NotificationCategories.alarmCategoryNoSnooze
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
            do {
                try await center.add(request)
            } catch {
                // Keep no half-built ladder: drop the rungs already added.
                cancel(alarm.id)
                NSLog("WakeGuard: rung %d of alarm %@ rejected: %@", index, alarm.id, String(describing: error))
                throw ScheduleError.rungRejected(alarm.ladderId(rung: index))
            }
        }
    }

    func rescheduleAll() async {
        let now = Date()
        // Rescheduling begins with cancel(), which wipes pending *and* delivered
        // rungs, so it must never touch a ladder that is live (ringing, or tapped
        // mid-ring with later rungs still pending) or one already armed at a time
        // at least as soon as the next occurrence (a pending snooze).
        let delivered = Set(await deliveredIdentifiers())
        let pending = await pendingRequests()
        for alarm in AlarmStore.shared.all() where alarm.enabled {
            let live = isLadderLive(alarm, now: now, delivered: delivered, pending: pending)
            if live { continue }
            let expected = nextTrigger(alarm, from: now)
            if let scheduled = pendingRung0Time(alarm, pending: pending), scheduled <= expected {
                continue
            }
            do {
                try await schedule(alarm, triggerAt: expected)
            } catch {
                NSLog("WakeGuard: reschedule of alarm %@ failed: %@", alarm.id, String(describing: error))
            }
        }
    }

    /// Live from the moment rung 0 should have fired until the last rung plus a
    /// dismissal grace, or while any rung is still on screen. A body tap on a
    /// ringing notification removes the delivered rung, so relying on delivered
    /// state alone would let rescheduleAll kill the pending escalation rungs.
    private func isLadderLive(
        _ alarm: StoredAlarm,
        now: Date,
        delivered: Set<String>,
        pending: [PendingRequest]
    ) -> Bool {
        let prefix = "\(alarm.ladderIdPrefix)."
        if delivered.contains(where: { $0.hasPrefix(prefix) }) { return true }
        guard let rung0 = pendingRung0Time(alarm, pending: pending) else { return false }
        let lastOffset = EscalationPolicy.steps.last?.offset ?? 0
        // 120s grace: dismissal handling can lag the final rung by a minute.
        return now >= rung0 && now <= rung0.addingTimeInterval(lastOffset + 120)
    }

    /// Fire time of rung 0 derived from any still-pending rung of this ladder.
    private func pendingRung0Time(_ alarm: StoredAlarm, pending: [PendingRequest]) -> Date? {
        let prefix = "\(alarm.ladderIdPrefix)."
        for request in pending where request.identifier.hasPrefix(prefix) {
            guard
                let rungText = request.identifier.split(separator: ".").last,
                let rung = Int(rungText),
                rung >= 0, rung < EscalationPolicy.steps.count
            else { continue }
            return request.nextTriggerDate
                .addingTimeInterval(-EscalationPolicy.steps[rung].offset)
        }
        return nil
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
        AlarmStore.shared.remove(alarmId)
    }

    // MARK: - Center queries

    private func notificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private func deliveredIdentifiers() async -> [String] {
        await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { notifications in
                continuation.resume(returning: notifications.map(\.request.identifier))
            }
        }
    }

    /// Soonest committed trigger per alarm, from the pending ladder's first rung;
    /// the Dart mirror shows this instead of a UI-side estimate.
    func scheduledTriggers() async -> [String: Date] {
        let pending = await pendingRequests()
        var triggers: [String: Date] = [:]
        for alarm in AlarmStore.shared.all() {
            // A rung already past returns .distantFuture; treat that as not scheduled.
            if let rung = pending.first(where: { $0.identifier == alarm.ladderId(rung: 0) }),
               rung.nextTriggerDate < Date.distantFuture {
                triggers[alarm.id] = rung.nextTriggerDate
            }
        }
        return triggers
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
        // Eviction silently un-arms another alarm, so it must at least be visible.
        NSLog("WakeGuard: 64-slot cap hit; evicted %d rung(s): %@", victims.count, Array(victims))
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

    /// Next local wall-clock occurrence honouring the weekday set and skip-until.
    func nextTrigger(_ alarm: StoredAlarm, from date: Date) -> Date {
        let calendar = Calendar.current
        // A skipped occurrence pushes the search past the skip window, mirroring
        // Dart `Alarm.nextOccurrence`.
        let skipUntil = Date(
            timeIntervalSince1970: Double(alarm.effectiveSkipUntilMillis) / 1000
        )
        let start = max(date, skipUntil)
        guard let base = calendar.nextDate(
            after: start,
            matching: DateComponents(hour: alarm.hour, minute: alarm.minute),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) else {
            return start.addingTimeInterval(86400)
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
/// Mutations are read-modify-write, so one shared instance plus a serial queue
/// keeps main-thread and background-Task access from clobbering each other.
final class AlarmStore {

    static let shared = AlarmStore()

    private let key = "wakeguard.alarms.v2"
    private let queue = DispatchQueue(label: "app.wakeguard.alarmstore")

    private init() {}

    func all() -> [StoredAlarm] {
        queue.sync {
            decoded().sorted { $0.hour * 60 + $0.minute < $1.hour * 60 + $1.minute }
        }
    }

    func put(_ alarm: StoredAlarm) {
        queue.sync {
            var alarms = decoded().filter { $0.id != alarm.id }
            alarms.append(alarm)
            save(alarms)
        }
    }

    func remove(_ alarmId: String) {
        queue.sync {
            let alarms = decoded().filter { $0.id != alarmId }
            save(alarms)
        }
    }

    func get(_ alarmId: String) -> StoredAlarm? {
        all().first { $0.id == alarmId }
    }

    private func decoded() -> [StoredAlarm] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let alarms = try? JSONDecoder().decode([StoredAlarm].self, from: data)
        else { return [] }
        return alarms
    }

    /// Called only while the serial queue is held by `put`/`remove`.
    private func save(_ alarms: [StoredAlarm]) {
        guard let data = try? JSONEncoder().encode(alarms) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
