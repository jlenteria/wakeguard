import Foundation

/// Runs the actual iOS selector without an iOS simulator or app build.
@main
struct MotivationalQuotesChecks {
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let quotes = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
        precondition(quotes.count == 100 && Set(quotes).count == 100, "Expected 100 unique quotes")
        precondition(quotes.allSatisfy { !$0.isEmpty && $0.count <= 90 }, "Quotes should be brief")
        let suite = "wakeguard.quoteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let formatter = ISO8601DateFormatter()
        let beforeMidnight = formatter.date(from: "2026-10-13T15:59:00Z")!
        let afterMidnight = beforeMidnight.addingTimeInterval(60)
        let zone = TimeZone(secondsFromGMT: 8 * 3600)!
        var seen = Set<String>()
        for _ in 0..<100 {
            // Recreate both the selector and preference handle, as after an app restart.
            let selector = MotivationalQuotes(quotes: Array(quotes.reversed()), defaults: UserDefaults(suiteName: suite)!)
            guard let quote = selector.next(now: beforeMidnight, timeZone: zone) else {
                fatalError("Pool exhausted before all 100 quotes were shown")
            }
            precondition(seen.insert(quote).inserted, "Repeated a quote on the same day")
        }
        let selector = MotivationalQuotes(quotes: quotes, defaults: defaults)
        precondition(selector.next(now: beforeMidnight, timeZone: zone) == nil, "Exhaustion must not repeat a quote")
        precondition(selector.next(now: afterMidnight, timeZone: zone) != nil, "Pool must reset at local midnight")
        precondition(selector.next(now: afterMidnight, timeZone: zone) != nil, "Next-day pool should have more quotes")
        defaults.removePersistentDomain(forName: suite)
        let small = MotivationalQuotes(quotes: ["", "  ", "A", "A", "B"], defaults: defaults)
        let pair = [small.next(now: beforeMidnight, timeZone: zone), small.next(now: beforeMidnight, timeZone: zone)]
        precondition(Set(pair.compactMap { $0 }) == Set(["A", "B"]), "Skip blank and duplicate entries")
        precondition(small.next(now: beforeMidnight, timeZone: zone) == nil)
        precondition(MotivationalQuotes(quotes: [], defaults: defaults).next() == nil)
        print("Quote checks passed: 100 unique draws, persistence, exhaustion, local midnight, and malformed entries.")
    }
}
