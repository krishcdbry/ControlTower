import Foundation

public enum UsageHistoryPeriod: Int, CaseIterable, Sendable {
    case today = 1
    case week = 7
    case month = 30

    public var title: String {
        switch self {
        case .today: "Today"
        case .week: "7 Days"
        case .month: "30 Days"
        }
    }
}

public struct CombinedUsageWindow: Sendable {
    public var totals: TokenTotals = .zero
    public var byProvider: [ProviderID: TokenTotals] = [:]
    public var byModel: [String: TokenTotals] = [:]
    public var bySource: [UsageSource: TokenTotals] = [:]
    public var days: [LedgerActivityDay] = []
}

public struct CombinedUsageSnapshot: Sendable {
    public let generatedAt: Date
    public let providers: [ProviderID]
    private let windows: [UsageHistoryPeriod: CombinedUsageWindow]

    public func window(_ period: UsageHistoryPeriod) -> CombinedUsageWindow {
        self.windows[period] ?? CombinedUsageWindow()
    }

    /// Combines already-deduplicated token histories. Quota percentages and
    /// subscription allowances are intentionally not additive inputs.
    public static func build(
        snapshots: [ProviderID: LedgerSnapshot], now: Date = Date(),
        calendar: Calendar = .current
    ) -> Self {
        let todayKey = TokenLedger.dayKey(for: now, calendar: calendar)
        let providers = snapshots.keys.sorted { $0.rawValue < $1.rawValue }
        var windows: [UsageHistoryPeriod: CombinedUsageWindow] = [:]
        for period in UsageHistoryPeriod.allCases {
            let start = calendar.date(byAdding: .day, value: -(period.rawValue - 1), to: now)!
            let startKey = TokenLedger.dayKey(for: start, calendar: calendar)
            var window = CombinedUsageWindow()
            var days: [String: TokenTotals] = [:]
            for provider in providers {
                guard let snapshot = snapshots[provider] else { continue }
                var providerTotal = TokenTotals.zero
                for day in snapshot.days where day.date >= startKey && day.date <= todayKey {
                    window.totals.add(day.totals)
                    providerTotal.add(day.totals)
                    days[day.date, default: .zero].add(day.totals)
                    for (model, totals) in day.byModel {
                        window.byModel[model, default: .zero].add(totals)
                    }
                    for (source, totals) in day.bySource {
                        window.bySource[source, default: .zero].add(totals)
                    }
                }
                window.byProvider[provider] = providerTotal
            }
            window.days = LedgerHistory.dailySeries(
                days.map { LedgerActivityDay(date: $0.key, totalTokens: $0.value.totalTokens, costUSD: $0.value.costUSD) },
                days: period.rawValue, endingAt: now, calendar: calendar
            )
            windows[period] = window
        }
        return Self(
            generatedAt: now, providers: providers,
            windows: windows
        )
    }

    public static func mergeDayDetails(_ details: [LedgerDayDetail], date: String) -> LedgerDayDetail? {
        var totals = TokenTotals.zero
        var byModel: [String: TokenTotals] = [:]
        var bySource: [UsageSource: TokenTotals] = [:]
        var byProject: [String: TokenTotals] = [:]
        var byHour: [Int: TokenTotals] = [:]
        for detail in details where detail.date == date {
            totals.add(detail.totals)
            for (model, value) in detail.byModel { byModel[model, default: .zero].add(value) }
            for (source, value) in detail.bySource { bySource[source, default: .zero].add(value) }
            for project in detail.byProject { byProject[project.path, default: .zero].add(project.totals) }
            for (hour, value) in detail.byHour { byHour[hour, default: .zero].add(value) }
        }
        guard totals.totalTokens > 0 else { return nil }
        return LedgerDayDetail(
            date: date, totals: totals, byModel: byModel, bySource: bySource,
            byProject: byProject.map { LedgerProjectUsage(path: $0.key, totals: $0.value) }
                .sorted { $0.totals.costUSD > $1.totals.costUSD },
            byHour: byHour
        )
    }
}
