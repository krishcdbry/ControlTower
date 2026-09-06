import Foundation
import Testing
@testable import ControlTowerCore

@Suite("Codex dashboard analytics")
struct CodexAnalyticsTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return value
    }
    private var now: Date { ISO8601DateFormatter().date(from: "2026-09-06T12:00:00Z")! }

    private func row(daysAgo: Int = 0, source: UsageSource = .codexDesktop, model: String = "gpt-6-astra", project: String = "/projects/app") -> LedgerHourRow {
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: now)!.addingTimeInterval(-3600)
        return LedgerHourRow(
            hourStart: Int64(date.timeIntervalSince1970), model: model, source: source.rawValue, project: project,
            inputTokens: 20, outputTokens: 10, cacheReadTokens: 80,
            cacheWrite5mTokens: 5, cacheWrite1hTokens: 0, entryCount: 1
        )
    }

    @Test("Today, weekly, monthly, and six-month windows are independent")
    func reportingWindows() {
        let rows = [row(), row(daysAgo: 6), row(daysAgo: 29), row(daysAgo: 30), row(daysAgo: 179), row(daysAgo: 180)]
        let result = CodexAnalytics.build(rows: rows, stats: LedgerScanStats(), now: now, calendar: calendar)
        #expect(result.analytics.today.totalTokens == 110)
        #expect(result.analytics.last7Days.totalTokens == 220)
        #expect(result.analytics.last30Days.totalTokens == 330)
        #expect(result.last5Hours.totalTokens == 110)
        #expect(result.analytics.dailyActivity.count == 5)
        #expect(result.analytics.days.count == 3)
        #expect(result.days.count == 3)
        #expect(result.analytics.currentBlock == nil)
        #expect(abs(result.analytics.today.costUSD - 0.00078) < 0.00000001)
        #expect(result.days.last?.reasoningTokens == 5)
        #expect(result.analytics.today.cacheWriteTokens == 0)
    }

    @Test("Model, app, project, and day drill-down totals reconcile")
    func breakdowns() throws {
        let rows = [row(), row(source: .codexAgent, model: "internal-review", project: "/projects/other")]
        let result = CodexAnalytics.build(rows: rows, stats: LedgerScanStats(), now: now, calendar: calendar)
        #expect(result.analytics.today.totalTokens == 220)
        #expect(result.analytics.bySource[.codexDesktop]?.totalTokens == 110)
        #expect(result.analytics.bySource[.codexAgent]?.totalTokens == 110)
        #expect(result.analytics.byProject.count == 2)
        #expect(result.fallbackModels == ["internal-review"])
        #expect(result.fallbackTokens == 110)
        #expect(abs(result.fallbackCostUSD - 0.000312) < 0.00000001)
        #expect(CodexPricing.price(for: "internal-review") == nil)

        let detail = try #require(CodexAnalytics.dayDetail(rows: rows, date: "2026-09-06", calendar: calendar))
        #expect(detail.totals == result.analytics.today)
        #expect(detail.byModel == result.analytics.byModel)
        #expect(detail.bySource == result.analytics.bySource)
        #expect(detail.byHour[16]?.totalTokens == 220)
        #expect(detail.byProject.reduce(0) { $0 + $1.totals.totalTokens } == 220)
        #expect(CodexAnalytics.dayDetail(rows: rows, date: "2026-09-05", calendar: calendar) == nil)
    }

    @Test("Fallback rates are estimates, while published model rates remain authoritative")
    func pricingBasis() throws {
        let known = try #require(CodexPricing.cost(model: "gpt-6-astra", inputTokens: 1_000_000, cachedInputTokens: 1_000_000, outputTokens: 1_000_000))
        #expect(known == 61)
        #expect(CodexPricing.estimatedCost(model: "gpt-6-astra", inputTokens: 1_000_000, cachedInputTokens: 1_000_000, outputTokens: 1_000_000) == known)
        #expect(CodexPricing.estimatedCost(model: "internal-unlisted", inputTokens: 1_000_000, cachedInputTokens: 1_000_000, outputTokens: 1_000_000) == 24.4)
        #expect(CodexPricing.cost(model: "codex-auto-review", inputTokens: 1_000_000, cachedInputTokens: 1_000_000, outputTokens: 1_000_000) == 17.75)
    }

    @Test("History charts show calendar days with zeros instead of the last seven active dates")
    func sparseHistory() {
        let activity = [
            LedgerActivityDay(date: "2026-08-15", totalTokens: 9000, costUSD: 9),
            LedgerActivityDay(date: "2026-09-01", totalTokens: 100, costUSD: 1),
            LedgerActivityDay(date: "2026-09-06", totalTokens: 200, costUSD: 2),
            LedgerActivityDay(date: "2026-09-07", totalTokens: 8000, costUSD: 8)
        ]
        let week = LedgerHistory.dailySeries(activity, days: 7, endingAt: now, calendar: calendar)
        #expect(week.count == 7)
        #expect(week.first?.date == "2026-08-31")
        #expect(week.last?.date == "2026-09-06")
        #expect(week.filter { $0.totalTokens == 0 }.count == 5)
        #expect(week.reduce(0) { $0 + $1.totalTokens } == 300)
        let month = LedgerHistory.dailySeries(activity, days: 30, endingAt: now, calendar: calendar)
        #expect(month.count == 30)
        #expect(month.reduce(0) { $0 + $1.totalTokens } == 9300)
    }

    @Test("Session metadata distinguishes desktop, Work, IDE, CLI, and agents")
    func sourceAttribution() {
        #expect(CodexSessionIngestor.usageSource(metadata: ["source": "vscode", "originator": "Codex Desktop"]) == .codexDesktop)
        #expect(CodexSessionIngestor.usageSource(metadata: ["source": "vscode", "originator": "codex_work_desktop"]) == .codexDesktop)
        #expect(CodexSessionIngestor.usageSource(metadata: ["source": "vscode"]) == .codexIDE)
        #expect(CodexSessionIngestor.usageSource(metadata: ["source": "cli"]) == .codexCLI)
        #expect(CodexSessionIngestor.usageSource(metadata: ["source": ["subagent": "review"], "originator": "Codex Desktop"]) == .codexAgent)
        #expect(CodexSessionIngestor.usageSource(metadata: [:]) == .codexOther)
    }
}
