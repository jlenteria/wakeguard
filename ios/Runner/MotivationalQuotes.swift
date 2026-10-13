import Foundation

/// Device-local, offline selection without replacement for each local calendar day.
final class MotivationalQuotes {
    static let shared = MotivationalQuotes()
    private let quotes: [String]
    private let defaults: UserDefaults
    private let lock = NSLock()
    private let key = "wakeguard.motivationalQuotes.v1"

    init(quotes: [String]? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let quotes {
            self.quotes = quotes
        } else if let url = Bundle.main.url(forResource: "motivational_quotes", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let loaded = try? JSONDecoder().decode([String].self, from: data) {
            self.quotes = loaded
        } else {
            self.quotes = []
        }
    }

    func next(now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        lock.lock()
        defer { lock.unlock() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let day = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        let saved = defaults.dictionary(forKey: key)
        var used = saved?["day"] as? String == day
            ? Set(saved?["used"] as? [String] ?? []) : Set<String>()
        let remaining = Array(Set(quotes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { !$0.isEmpty && !used.contains($0) }
        guard let quote = remaining.randomElement() else { return nil }
        used.insert(quote)
        defaults.set(["day": day, "used": Array(used)], forKey: key)
        return quote
    }
}
