import Foundation

/// Adapts Codex's counters into the shared dashboard models. Reasoning is
/// already part of output, so it must not become an extra cache-write charge.
enum CodexAnalytics {
    private struct DayBucket {
        var totals = TokenTotals.zero
        var reasoning = 0
        var byModel: [String: TokenTotals] = [:]
        var bySource: [UsageSource: TokenTotals] = [:]
    }

    static func totals(for row: LedgerHourRow) -> TokenTotals {
        TokenTotals(
            inputTokens: row.inputTokens,
            outputTokens: row.outputTokens,
            cacheReadTokens: row.cacheReadTokens,
            entryCount: row.entryCount,
            costUSD: CodexPricing.estimatedCost(
                model: row.model,
                inputTokens: row.inputTokens,
                cachedInputTokens: row.cacheReadTokens,
                outputTokens: row.outputTokens
            )
        )
    }

    static func build(
        rows: [LedgerHourRow], stats: LedgerScanStats, now: Date,
        calendar: Calendar = .current
    ) -> CodexLedgerSnapshot {
        func key(daysAgo: Int) -> String {
            TokenLedger.dayKey(for: calendar.date(byAdding: .day, value: -daysAgo, to: now)!, calendar: calendar)
        }
        let todayKey = key(daysAgo: 0)
        let weekStart = key(daysAgo: 6)
        let monthStart = key(daysAgo: 29)
        let activityStart = key(daysAgo: 179)
        let recentStart = now.addingTimeInterval(-5 * 3600)
        var buckets: [String: DayBucket] = [:]
        var bySource: [UsageSource: TokenTotals] = [:]
        var byModel: [String: TokenTotals] = [:]
        var byProject: [String: TokenTotals] = [:]
        var last5Hours = TokenTotals.zero
        var fallbackModels: Set<String> = []
        var fallbackTokens = 0
        var fallbackCost = 0.0

        for row in rows {
            let date = Date(timeIntervalSince1970: TimeInterval(row.hourStart))
            let day = TokenLedger.dayKey(for: date, calendar: calendar)
            guard day >= activityStart, day <= todayKey, date <= now else { continue }
            let totals = Self.totals(for: row)
            let source = UsageSource(rawValue: row.source) ?? .codexOther
            buckets[day, default: DayBucket()].totals.add(totals)
            buckets[day]?.reasoning += row.cacheWrite5mTokens
            buckets[day]?.byModel[row.model, default: .zero].add(totals)
            buckets[day]?.bySource[source, default: .zero].add(totals)
            if date >= recentStart { last5Hours.add(totals) }
            guard day >= monthStart else { continue }
            byModel[row.model, default: .zero].add(totals)
            bySource[source, default: .zero].add(totals)
            if !row.project.isEmpty { byProject[row.project, default: .zero].add(totals) }
            if CodexPricing.price(for: row.model) == nil {
                fallbackModels.insert(row.model)
                fallbackTokens += totals.totalTokens
                fallbackCost += totals.costUSD
            }
        }

        var today = TokenTotals.zero
        var week = TokenTotals.zero
        var month = TokenTotals.zero
        var days: [LedgerDay] = []
        var codexDays: [CodexLedgerDay] = []
        var activity: [LedgerActivityDay] = []
        for day in buckets.keys.sorted() {
            guard let bucket = buckets[day] else { continue }
            let totals = bucket.totals
            activity.append(LedgerActivityDay(date: day, totalTokens: totals.totalTokens, costUSD: totals.costUSD))
            guard day >= monthStart else { continue }
            days.append(LedgerDay(date: day, totals: totals, byModel: bucket.byModel, bySource: bucket.bySource))
            codexDays.append(CodexLedgerDay(
                date: day, inputTokens: totals.inputTokens, cachedInputTokens: totals.cacheReadTokens,
                outputTokens: totals.outputTokens, reasoningTokens: bucket.reasoning, costUSD: totals.costUSD
            ))
            month.add(totals)
            if day >= weekStart { week.add(totals) }
            if day == todayKey { today.add(totals) }
        }
        let projects = byProject.map { LedgerProjectUsage(path: $0.key, totals: $0.value) }
            .sorted { $0.totals.totalTokens > $1.totals.totalTokens }
        let analytics = LedgerSnapshot(
            generatedAt: now, today: today, last7Days: week, last30Days: month,
            days: days, bySource: bySource, byModel: byModel, byProject: Array(projects.prefix(8)),
            dailyActivity: activity, stats: stats
        )
        return CodexLedgerSnapshot(
            generatedAt: now, days: codexDays, stats: stats, analytics: analytics,
            last5Hours: last5Hours, fallbackModels: fallbackModels,
            fallbackTokens: fallbackTokens, fallbackCostUSD: fallbackCost
        )
    }

    static func dayDetail(rows: [LedgerHourRow], date: String, calendar: Calendar = .current) -> LedgerDayDetail? {
        var totals = TokenTotals.zero
        var byModel: [String: TokenTotals] = [:]
        var bySource: [UsageSource: TokenTotals] = [:]
        var byProject: [String: TokenTotals] = [:]
        var byHour: [Int: TokenTotals] = [:]
        for row in rows {
            let rowDate = Date(timeIntervalSince1970: TimeInterval(row.hourStart))
            guard TokenLedger.dayKey(for: rowDate, calendar: calendar) == date else { continue }
            let usage = Self.totals(for: row)
            totals.add(usage)
            byModel[row.model, default: .zero].add(usage)
            bySource[UsageSource(rawValue: row.source) ?? .codexOther, default: .zero].add(usage)
            if !row.project.isEmpty { byProject[row.project, default: .zero].add(usage) }
            byHour[calendar.component(.hour, from: rowDate), default: .zero].add(usage)
        }
        guard totals.entryCount > 0 else { return nil }
        return LedgerDayDetail(
            date: date, totals: totals, byModel: byModel, bySource: bySource,
            byProject: byProject.map { LedgerProjectUsage(path: $0.key, totals: $0.value) }
                .sorted { $0.totals.totalTokens > $1.totals.totalTokens },
            byHour: byHour
        )
    }
}
