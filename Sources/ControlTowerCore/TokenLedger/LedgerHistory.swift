import Foundation

public enum LedgerHistory {
    /// Calendar days, including zero-usage days. Taking the last N active
    /// records instead would silently turn a week into a much longer period.
    public static func dailySeries(
        _ activity: [LedgerActivityDay], days: Int, endingAt now: Date,
        calendar: Calendar = .current
    ) -> [LedgerActivityDay] {
        var byDay: [String: (tokens: Int, cost: Double)] = [:]
        for day in activity {
            byDay[day.date, default: (0, 0)].tokens += day.totalTokens
            byDay[day.date]?.cost += day.costUSD
        }
        return (0..<max(0, days)).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
            let key = TokenLedger.dayKey(for: date, calendar: calendar)
            let value = byDay[key]
            return LedgerActivityDay(date: key, totalTokens: value?.tokens ?? 0, costUSD: value?.cost ?? 0)
        }
    }
}
