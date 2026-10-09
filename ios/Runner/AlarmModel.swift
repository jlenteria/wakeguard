import Foundation
import UserNotifications

/// Native alarm record. Mirrors `StoredAlarm` on Android and `Alarm` in Dart.
struct StoredAlarm: Codable {
    let id: String
    let hour: Int
    let minute: Int
    let label: String
    let enabled: Bool
    let repeatDaily: Bool
    let weekdays: Set<Int>
    let qrValue: String
    let stepCount: Int
    /// Generated tone family: pulse | siren | radar | gong.
    ///
    /// Optional with a default so alarms written by an older build still decode
    /// instead of failing the whole store.
    let soundPack: String?

    var resolvedSoundPack: String { soundPack ?? AlarmSounds.defaultPack }

    /// Notification identifier prefix; the escalation ladder appends an index.
    var ladderIdPrefix: String { "wakeguard.\(id).rung" }

    func ladderId(rung: Int) -> String { "\(ladderIdPrefix).\(rung)" }
}

/// Mirrors `EscalationPolicy.standard` in Dart.
///
/// Keep the two files in step: the Dart planner decides which alarms fit in the
/// pending-notification budget, and this decides the exact offsets those alarms
/// are scheduled at.
enum EscalationTier: String {
    case gentle, firm, urgent, critical

    /// Bundled notification sound for the default family.
    ///
    /// iOS caps custom notification sounds at 30 seconds and never loops them,
    /// so every tier is a distinct asset.
    var soundName: String { AlarmSounds.fileName(pack: AlarmSounds.defaultPack, tier: rawValue) }
}

/// Maps a stored sound family to bundled `.caf` assets.
///
/// Mirrors `AlarmSounds` on Android and `AlarmSoundPack` in Dart. All three read
/// from the same naming scheme emitted by `tool/generate_alarms.py`:
/// `tone_<pack>_<tier>.caf`.
enum AlarmSounds {
    static let defaultPack = "pulse"
    static let packs = ["pulse", "siren", "radar", "gong"]

    /// iOS uses every tier, because each rung of the ladder is its own
    /// notification and none of them loop.
    static let tiers = ["gentle", "firm", "urgent", "critical"]

    static func normalize(_ pack: String?) -> String {
        guard let pack, packs.contains(pack) else { return defaultPack }
        return pack
    }

    static func fileName(pack: String?, tier: String) -> String {
        "tone_\(normalize(pack))_\(tier)"
    }

    /// The one generated tier used as "the" tone for every pack, so the alarm,
    /// every rung of the ladder and the preview all play the same file.
    static let tone = "critical"

    /// Preference order for a pack: its tone first, then its other files, then
    /// every other pack. Never empty.
    private static func candidates(pack: String?) -> [String] {
        let safePack = normalize(pack)
        let ordered = [tone] + tiers.filter { $0 != tone }
        return ordered.map { fileName(pack: safePack, tier: $0) }
            + packs.flatMap { other in ordered.map { fileName(pack: other, tier: $0) } }
    }

    /// Resolves a notification sound. The ladder tier is ignored on purpose:
    /// one pack is one tone. A missing asset must never leave an alarm silent,
    /// so this ends on a compile-time-known default rather than returning nil.
    static func sound(pack: String?, tier: EscalationTier) -> UNNotificationSound {
        let candidates = candidates(pack: pack)
        for name in candidates {
            let file = "\(name).caf"
            if Bundle.main.url(forResource: name, withExtension: "caf") != nil {
                return UNNotificationSound(named: UNNotificationSoundName(file))
            }
        }
        return .default
    }

    /// Bundled file URL for the in-app audibility probe.
    static func previewURL(pack: String?) -> URL? {
        for name in candidates(pack: pack) {
            if let url = Bundle.main.url(forResource: name, withExtension: "caf") {
                return url
            }
        }
        return nil
    }
}

struct EscalationStep {
    let offset: TimeInterval
    let tier: EscalationTier
    let interrupt: Bool
}

enum EscalationPolicy {
    static let steps: [EscalationStep] = [
        EscalationStep(offset: 0, tier: .gentle, interrupt: true),
        EscalationStep(offset: 45, tier: .firm, interrupt: true),
        EscalationStep(offset: 120, tier: .urgent, interrupt: true),
        EscalationStep(offset: 300, tier: .critical, interrupt: true),
        EscalationStep(offset: 600, tier: .critical, interrupt: true),
    ]

    /// iOS keeps only the soonest 64 pending notifications per app and silently
    /// discards the rest, so the budget must be enforced before scheduling or
    /// future alarms quietly stop firing.
    static let pendingNotificationCap = 64
    static let reservedSlots = 4
    static var usableSlots: Int { pendingNotificationCap - reservedSlots }

    static func fits(alarmCount: Int) -> Bool {
        alarmCount * steps.count <= usableSlots
    }
}
