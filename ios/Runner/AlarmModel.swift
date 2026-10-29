import Foundation
import UserNotifications

/// Native alarm record. Mirrors `StoredAlarm` on Android and `Alarm` in Dart.
struct StoredAlarm: Codable {
    let id: String
    let hour: Int
    let minute: Int
    let label: String
    /// Stored so `disabled()` can flip one field without a field-dropping init.
    var enabled: Bool
    let repeatDaily: Bool
    let weekdays: Set<Int>
    let qrValue: String
    let stepCount: Int
    /// Generated tone family: pulse | siren | radar | gong. Optional so old alarms decode.
    let soundPack: String?
    /// Seconds the hold-to-stop escape takes; optional so old alarms decode to the default.
    let holdSeconds: Int?
    /// Escape names (`tap|face|object|qr`) as sent by Dart; echoed back verbatim so a
    /// round-trip through the native store never invalidates the alarm.
    let escapes: [String]?
    /// Snooze length in minutes; 0 disables snoozing. Optional so old alarms default to 9.
    let snoozeMinutes: Int?
    /// Epoch millis before which the alarm must not fire (user skipped an occurrence).
    let skipUntilMillis: Int?
    /// Object label for the object challenge (`sink|cup`); echoed back to Dart.
    let objectTarget: String?
    /// Result of an actual native practice scan; never fabricated.
    let objectVerified: Bool?
    /// Draft alarms from Dart carry the flag; echo it instead of dropping it.
    let needsSetup: Bool?
    /// Whether the alarm vibrates alongside the tone; echoes the Dart field.
    let vibrate: Bool?

    var resolvedSoundPack: String { soundPack ?? AlarmSounds.defaultPack }

    /// Names Dart's `EscapeKind` accepts; anything else would force needsSetup in Dart.
    static let validEscapeNames = ["tap", "face", "object", "qr"]

    /// Valid escape names only; an empty/invalid set falls back to the Dart default.
    var effectiveEscapes: [String] {
        let valid = (escapes ?? []).filter { Self.validEscapeNames.contains($0) }
        return valid.isEmpty ? ["face"] : valid
    }

    /// Lifetime value for an alarm that predates per-alarm holds; also the strictest preset.
    static let defaultHoldSeconds = 60

    /// Seconds the hold-to-stop escape takes, clamped to the range the UI offers.
    var effectiveHoldSeconds: Int { min(90, max(15, holdSeconds ?? Self.defaultHoldSeconds)) }

    /// Mirrors Dart `Alarm.defaultSnoozeMinutes`; 0 means no snooze.
    var effectiveSnoozeMinutes: Int { min(60, max(0, snoozeMinutes ?? 9)) }

    var effectiveSkipUntilMillis: Int { skipUntilMillis ?? 0 }

    var effectiveObjectTarget: String {
        objectTarget == "cup" ? "cup" : "sink"
    }

    /// Notification identifier prefix; the escalation ladder appends an index.
    var ladderIdPrefix: String { "wakeguard.\(id).rung" }

    func ladderId(rung: Int) -> String { "\(ladderIdPrefix).\(rung)" }
}

/// Mirrors `EscalationPolicy.standard` in Dart; keep both in step.
enum EscalationTier: String {
    case gentle, firm, urgent, critical

    /// Bundled sound per tier; iOS caps notification sounds at 30s and never loops.
    var soundName: String { AlarmSounds.fileName(pack: AlarmSounds.defaultPack, tier: rawValue) }
}

/// Maps a sound family to bundled `.caf` assets (`tone_<pack>_<tier>.caf`),
/// mirroring the Android and Dart naming scheme.
enum AlarmSounds {
    static let defaultPack = "pulse"
    static let packs = ["pulse", "siren", "radar", "gong"]

    /// All tiers are used, since each rung is its own non-looping notification.
    static let tiers = ["gentle", "firm", "urgent", "critical"]

    static func normalize(_ pack: String?) -> String {
        guard let pack, packs.contains(pack) else { return defaultPack }
        return pack
    }

    static func fileName(pack: String?, tier: String) -> String {
        "tone_\(normalize(pack))_\(tier)"
    }

    /// The single tone used by the alarm, every rung and the preview.
    static let tone = "critical"

    /// Preference order: pack tone, then its other files, then every other pack.
    private static func candidates(pack: String?) -> [String] {
        let safePack = normalize(pack)
        let ordered = [tone] + tiers.filter { $0 != tone }
        return ordered.map { fileName(pack: safePack, tier: $0) }
            + packs.flatMap { other in ordered.map { fileName(pack: other, tier: $0) } }
    }

    /// Resolves a sound; one pack is one tone, and a missing asset falls back to
    /// a default rather than leaving the alarm silent.
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

    /// iOS keeps only the soonest 64 pending notifications, so enforce before scheduling.
    static let pendingNotificationCap = 64
    static let reservedSlots = 4
    static var usableSlots: Int { pendingNotificationCap - reservedSlots }

    static func fits(alarmCount: Int) -> Bool {
        alarmCount * steps.count <= usableSlots
    }
}
