import Foundation

/// Claude token/cost summary used by the dashboard.
///
/// This is now a thin adapter over `TokenLedger`, which ingests transcripts
/// incrementally (per-file byte cursors + global dedup + SQLite aggregates)
/// instead of re-reading every JSONL file on each scan. The public snapshot
/// shape is preserved for existing UI; richer data (sources, projects,
/// 5h blocks) is available from `TokenLedger.shared.snapshot()` directly.
public actor ClaudeCostScanner {
    public static let shared = ClaudeCostScanner()

    /// Daily cost summary
    public struct DailyCost: Sendable, Equatable {
        public let date: String // YYYY-MM-DD
        public let inputTokens: Int
        public let outputTokens: Int
        public let cacheReadTokens: Int
        public let cacheWriteTokens: Int
        public let costUSD: Double
        public let modelBreakdown: [String: ModelUsage]

        public var totalTokens: Int {
            inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
        }

        public init(
            date: String,
            inputTokens: Int,
            outputTokens: Int,
            cacheReadTokens: Int,
            cacheWriteTokens: Int,
            costUSD: Double,
            modelBreakdown: [String: ModelUsage]
        ) {
            self.date = date
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.costUSD = costUSD
            self.modelBreakdown = modelBreakdown
        }

        public struct ModelUsage: Sendable, Equatable {
            public let inputTokens: Int
            public let outputTokens: Int
            public let cacheReadTokens: Int
            public let cacheWriteTokens: Int
            public let costUSD: Double

            public var totalTokens: Int {
                inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
            }

            public init(
                inputTokens: Int,
                outputTokens: Int,
                cacheReadTokens: Int,
                cacheWriteTokens: Int,
                costUSD: Double
            ) {
                self.inputTokens = inputTokens
                self.outputTokens = outputTokens
                self.cacheReadTokens = cacheReadTokens
                self.cacheWriteTokens = cacheWriteTokens
                self.costUSD = costUSD
            }
        }
    }

    /// Cost snapshot with aggregated data
    public struct CostSnapshot: Sendable {
        public let todayCostUSD: Double
        public let todayTokens: Int
        public let last7DaysCostUSD: Double
        public let last7DaysTokens: Int
        public let last30DaysCostUSD: Double
        public let last30DaysTokens: Int
        public let dailyCosts: [DailyCost]
        public let updatedAt: Date

        public init(
            todayCostUSD: Double = 0,
            todayTokens: Int = 0,
            last7DaysCostUSD: Double = 0,
            last7DaysTokens: Int = 0,
            last30DaysCostUSD: Double = 0,
            last30DaysTokens: Int = 0,
            dailyCosts: [DailyCost] = [],
            updatedAt: Date = Date()
        ) {
            self.todayCostUSD = todayCostUSD
            self.todayTokens = todayTokens
            self.last7DaysCostUSD = last7DaysCostUSD
            self.last7DaysTokens = last7DaysTokens
            self.last30DaysCostUSD = last30DaysCostUSD
            self.last30DaysTokens = last30DaysTokens
            self.dailyCosts = dailyCosts
            self.updatedAt = updatedAt
        }
    }

    public init() {}

    /// Scan logs (incrementally) and return a cost snapshot.
    public func scan(forceRefresh: Bool = false) async -> CostSnapshot {
        let ledger = await TokenLedger.shared.snapshot(forceScan: forceRefresh)
        return Self.adapt(ledger)
    }

    /// No-op retained for API compatibility; the ledger persists its own state.
    public func clearCache() {}

    static func adapt(_ ledger: LedgerSnapshot) -> CostSnapshot {
        let dailyCosts = ledger.days.map { day in
            DailyCost(
                date: day.date,
                inputTokens: day.totals.inputTokens,
                outputTokens: day.totals.outputTokens,
                cacheReadTokens: day.totals.cacheReadTokens,
                cacheWriteTokens: day.totals.cacheWriteTokens,
                costUSD: day.totals.costUSD,
                modelBreakdown: day.byModel.mapValues { totals in
                    DailyCost.ModelUsage(
                        inputTokens: totals.inputTokens,
                        outputTokens: totals.outputTokens,
                        cacheReadTokens: totals.cacheReadTokens,
                        cacheWriteTokens: totals.cacheWriteTokens,
                        costUSD: totals.costUSD
                    )
                }
            )
        }

        return CostSnapshot(
            todayCostUSD: ledger.today.costUSD,
            todayTokens: ledger.today.totalTokens,
            last7DaysCostUSD: ledger.last7Days.costUSD,
            last7DaysTokens: ledger.last7Days.totalTokens,
            last30DaysCostUSD: ledger.last30Days.costUSD,
            last30DaysTokens: ledger.last30Days.totalTokens,
            dailyCosts: dailyCosts,
            updatedAt: ledger.generatedAt
        )
    }
}
