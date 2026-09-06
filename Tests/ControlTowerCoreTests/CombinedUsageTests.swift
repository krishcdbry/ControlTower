import Foundation
import Testing
@testable import ControlTowerCore

@Suite("Combined usage analytics")
struct CombinedUsageTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }
    // September 7 locally, still September 6 in UTC.
    private var now: Date { ISO8601DateFormatter().date(from: "2026-09-06T18:45:00Z")! }

    private func day(_ daysAgo: Int, tokens: Int, source: UsageSource, model: String) -> LedgerDay {
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        let totals = TokenTotals(inputTokens: tokens, entryCount: 1, costUSD: Double(tokens) / 100)
        return LedgerDay(date: TokenLedger.dayKey(for: date, calendar: calendar), totals: totals, byModel: [model: totals], bySource: [source: totals])
    }

    private func ledger(_ days: [LedgerDay]) -> LedgerSnapshot {
        LedgerSnapshot(generatedAt: now, days: days, dailyActivity: days.map {
            LedgerActivityDay(date: $0.date, totalTokens: $0.totals.totalTokens, costUSD: $0.totals.costUSD)
        })
    }

    @Test("Combined periods reconcile across providers, apps, models, and calendar days")
    func reportingWindows() {
        let claude = ledger([
            day(0, tokens: 100, source: .claudeDesktop, model: "claude-sonnet-4-6"),
            day(6, tokens: 200, source: .claudeDesktop, model: "claude-sonnet-4-6"),
            day(29, tokens: 300, source: .claudeCode, model: "claude-opus-4-6"),
            day(30, tokens: 9000, source: .claudeCode, model: "older-model"),
            day(-1, tokens: 10000, source: .claudeCode, model: "future-model")
        ])
        let codex = ledger([
            day(0, tokens: 400, source: .codexDesktop, model: "gpt-6-astra"),
            day(7, tokens: 500, source: .codexCLI, model: "gpt-5.6-sol"),
            day(29, tokens: 600, source: .codexDesktop, model: "gpt-6-astra")
        ])
        let combined = CombinedUsageSnapshot.build(snapshots: [.claude: claude, .codex: codex], now: now, calendar: calendar)
        #expect(combined.window(.today).totals.totalTokens == 500)
        #expect(combined.window(.week).totals.totalTokens == 700)
        #expect(combined.window(.month).totals.totalTokens == 2100)
        #expect(combined.window(.week).byModel["gpt-5.6-sol"] == nil)
        #expect(combined.window(.month).byModel["gpt-5.6-sol"]?.totalTokens == 500)
        #expect(combined.window(.month).bySource[.claudeCode]?.totalTokens == 300)
        #expect(combined.window(.month).byProvider[.claude]?.totalTokens == 600)
        #expect(combined.window(.month).byProvider[.codex]?.totalTokens == 1500)
        #expect(combined.window(.today).days.first?.date == "2026-09-07")
        #expect(combined.window(.week).days.first?.date == "2026-09-01")
        #expect(combined.window(.week).days.filter { $0.totalTokens == 0 }.count == 5)
        for period in UsageHistoryPeriod.allCases {
            let window = combined.window(period)
            #expect(window.days.count == period.rawValue)
            #expect(window.byProvider.values.reduce(0) { $0 + $1.totalTokens } == window.totals.totalTokens)
            #expect(window.byModel.values.reduce(0) { $0 + $1.totalTokens } == window.totals.totalTokens)
            #expect(window.bySource.values.reduce(0) { $0 + $1.totalTokens } == window.totals.totalTokens)
            #expect(window.days.reduce(0) { $0 + $1.totalTokens } == window.totals.totalTokens)
            #expect(window.days.reduce(0) { $0 + $1.costUSD } == window.totals.costUSD)
            #expect(window.byProvider.values.reduce(0) { $0 + $1.costUSD } == window.totals.costUSD)
            #expect(window.byModel.values.reduce(0) { $0 + $1.costUSD } == window.totals.costUSD)
            #expect(window.bySource.values.reduce(0) { $0 + $1.costUSD } == window.totals.costUSD)
        }
    }

    @Test("Empty histories and a single available provider remain usable")
    func emptyAndPartial() {
        let empty = CombinedUsageSnapshot.build(snapshots: [:], now: now, calendar: calendar)
        #expect(empty.providers.isEmpty)
        #expect(empty.window(.month).totals == .zero)
        #expect(empty.window(.month).days.count == 30)
        let onlyCodex = CombinedUsageSnapshot.build(snapshots: [.codex: ledger([
            day(0, tokens: 100, source: .codexAgent, model: "codex-auto-review")
        ])], now: now, calendar: calendar)
        #expect(onlyCodex.providers == [.codex])
        #expect(onlyCodex.window(.today).byProvider[.claude] == nil)
        #expect(onlyCodex.window(.today).totals.totalTokens == 100)
    }

    @Test("Combined day details preserve cache categories and provider-specific costs")
    func dayDetails() throws {
        let date = "2026-09-07"
        let claude = TokenTotals(inputTokens: 10, outputTokens: 20, cacheReadTokens: 30, cacheWrite5mTokens: 40, cacheWrite1hTokens: 50, entryCount: 1, costUSD: 6)
        let codex = TokenTotals(inputTokens: 60, outputTokens: 70, cacheReadTokens: 80, entryCount: 2, costUSD: 7)
        let details = [
            LedgerDayDetail(date: date, totals: claude, byModel: ["shared-model": claude], bySource: [.claudeCode: claude], byProject: [.init(path: "/projects/shared", totals: claude)], byHour: [0: claude]),
            LedgerDayDetail(date: date, totals: codex, byModel: ["shared-model": codex], bySource: [.codexCLI: codex], byProject: [.init(path: "/projects/shared", totals: codex)], byHour: [0: codex]),
            LedgerDayDetail(date: "2026-09-06", totals: codex, byModel: ["wrong-date": codex], bySource: [:], byProject: [], byHour: [:])
        ]
        let combined = try #require(CombinedUsageSnapshot.mergeDayDetails(details, date: date))
        #expect(combined.totals.totalTokens == 360)
        #expect(combined.totals.costUSD == 13)
        #expect(combined.totals.entryCount == 3)
        #expect(combined.totals.cacheWriteTokens == 90)
        #expect(combined.byModel.count == 1)
        #expect(combined.byModel["shared-model"] == combined.totals)
        #expect(combined.byHour[0] == combined.totals)
        #expect(combined.byProject.count == 1)
        #expect(combined.byProject.first?.totals == combined.totals)
        #expect(combined.bySource[.codexCLI] == codex)
        #expect(CombinedUsageSnapshot.mergeDayDetails([], date: date) == nil)
    }

    @Test("Calendar reporting handles a daylight-saving transition")
    func daylightSaving() {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = ISO8601DateFormatter().date(from: "2026-03-09T07:15:00Z")!
        let combined = CombinedUsageSnapshot.build(snapshots: [:], now: date, calendar: pacific)
        #expect(combined.window(.week).days.map(\.date) == ["2026-03-03", "2026-03-04", "2026-03-05", "2026-03-06", "2026-03-07", "2026-03-08", "2026-03-09"])
    }
}
