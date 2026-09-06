import Foundation

/// Codex token/cost summary used by the dashboard.
///
/// This is now a thin adapter over `CodexLedger`, which ingests Codex rollout
/// files incrementally (per-file byte cursors + monotonic-total dedup + SQLite
/// aggregates) instead of re-reading every session file on each scan.
/// Costs are nil when a period includes models without known pricing.
///
/// Counting semantics (verified against real rollouts): per-turn deltas from
/// `last_token_usage` are summed; `cached_input_tokens` is a subset of input
/// and `reasoning_output_tokens` a subset of output, so neither is added on
/// top when totaling.
public actor CodexCostScanner {
    public static let shared = CodexCostScanner()

    /// Daily cost summary
    public struct DailyCost: Sendable, Equatable {
        public let date: String // YYYY-MM-DD
        /// Non-cached input tokens.
        public let inputTokens: Int
        public let cachedInputTokens: Int
        /// Output tokens (reasoning included).
        public let outputTokens: Int
        /// Reasoning tokens, an informational subset of `outputTokens`.
        public let reasoningTokens: Int
        public let costUSD: Double?

        public var totalTokens: Int {
            // Reasoning is inside outputTokens; adding it would double-count.
            inputTokens + cachedInputTokens + outputTokens
        }

        public init(
            date: String,
            inputTokens: Int,
            cachedInputTokens: Int,
            outputTokens: Int,
            reasoningTokens: Int,
            costUSD: Double?
        ) {
            self.date = date
            self.inputTokens = inputTokens
            self.cachedInputTokens = cachedInputTokens
            self.outputTokens = outputTokens
            self.reasoningTokens = reasoningTokens
            self.costUSD = costUSD
        }
    }

    /// Cost snapshot with aggregated data
    public struct CostSnapshot: Sendable {
        public let todayCostUSD: Double?
        public let todayTokens: Int
        public let last7DaysCostUSD: Double?
        public let last7DaysTokens: Int
        public let last30DaysCostUSD: Double?
        public let last30DaysTokens: Int
        public let dailyCosts: [DailyCost]
        public let updatedAt: Date

        public init(
            todayCostUSD: Double? = 0,
            todayTokens: Int = 0,
            last7DaysCostUSD: Double? = 0,
            last7DaysTokens: Int = 0,
            last30DaysCostUSD: Double? = 0,
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
        let ledger = await CodexLedger.shared.snapshot(forceScan: forceRefresh)
        return Self.adapt(ledger)
    }

    /// No-op retained for API compatibility; the ledger persists its own state.
    public func clearCache() {}

    private static func addCost(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs, let rhs else { return nil }
        return lhs + rhs
    }

    static func adapt(_ ledger: CodexLedgerSnapshot, now: Date = Date()) -> CostSnapshot {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let todayKey = TokenLedger.dayKey(for: now, calendar: calendar)
        let last7Start = TokenLedger.dayKey(for: now.addingTimeInterval(-6 * 86400), calendar: calendar)

        var todayCost: Double? = 0
        var last7Cost: Double? = 0
        var last30Cost: Double? = 0
        var todayTokens = 0, last7Tokens = 0, last30Tokens = 0

        let dailyCosts = ledger.days.map { day -> DailyCost in
            last30Cost = Self.addCost(last30Cost, day.costUSD)
            last30Tokens += day.totalTokens
            if day.date >= last7Start {
                last7Cost = Self.addCost(last7Cost, day.costUSD)
                last7Tokens += day.totalTokens
            }
            if day.date == todayKey {
                todayCost = day.costUSD
                todayTokens = day.totalTokens
            }
            return DailyCost(
                date: day.date,
                inputTokens: day.inputTokens,
                cachedInputTokens: day.cachedInputTokens,
                outputTokens: day.outputTokens,
                reasoningTokens: day.reasoningTokens,
                costUSD: day.costUSD
            )
        }

        return CostSnapshot(
            todayCostUSD: todayCost,
            todayTokens: todayTokens,
            last7DaysCostUSD: last7Cost,
            last7DaysTokens: last7Tokens,
            last30DaysCostUSD: last30Cost,
            last30DaysTokens: last30Tokens,
            dailyCosts: dailyCosts,
            updatedAt: ledger.generatedAt
        )
    }
}

// MARK: - Codex Pricing

/// Pricing for OpenAI models used by Codex (per million tokens, USD).
/// Standard API estimates, verified 2026-09-06 against:
/// https://developers.openai.com/api/docs/models/gpt-6-astra
/// https://developers.openai.com/api/docs/models/gpt-5.6-sol
/// https://developers.openai.com/api/docs/models/gpt-5.6-terra
/// https://developers.openai.com/api/docs/models/gpt-5.6-luna
/// https://developers.openai.com/api/docs/models/gpt-5.4-mini
/// https://developers.openai.com/api/docs/models/gpt-5.2
/// These base rates exclude service-tier, long-context, and cache-write
/// surcharges. They are not the cost of a ChatGPT subscription.
public enum CodexPricing {
    public struct ModelPrice: Sendable {
        public let inputPerMillion: Double
        public let cachedInputPerMillion: Double
        public let outputPerMillion: Double

        public init(input: Double, output: Double, cachedInput: Double? = nil) {
            self.inputPerMillion = input
            self.outputPerMillion = output
            self.cachedInputPerMillion = cachedInput ?? (input * 0.1)
        }
    }

    private static let gpt55 = ModelPrice(input: 5.0, output: 30.0)
    private static let gpt54 = ModelPrice(input: 2.5, output: 15.0)
    private static let codex53 = ModelPrice(input: 1.75, output: 14.0)
    private static let gpt51Family = ModelPrice(input: 1.25, output: 10.0)
    private static let o3 = ModelPrice(input: 2.0, output: 8.0)
    private static let o4Mini = ModelPrice(input: 1.10, output: 4.40, cachedInput: 0.275)
    private static let codexMini = ModelPrice(input: 1.50, output: 6.0)

    public static let pricing: [String: ModelPrice] = [
        "gpt-6-astra": ModelPrice(input: 10.0, output: 50.0),
        "gpt-5.6": ModelPrice(input: 4.0, output: 20.0),
        "gpt-5.6-sol": ModelPrice(input: 4.0, output: 20.0),
        "gpt-5.6-terra": ModelPrice(input: 2.0, output: 12.0),
        "gpt-5.6-luna": ModelPrice(input: 0.20, output: 1.20),
        "gpt-5.5": gpt55,
        "gpt-5.4-mini": ModelPrice(input: 0.75, output: 4.5),
        "gpt-5.4": gpt54,
        "gpt-5.3-codex": codex53,
        "gpt-5.2-codex": codex53,
        "gpt-5.2": codex53,
        "gpt-5.1-codex-max": gpt51Family,
        "gpt-5.1-codex": gpt51Family,
        "gpt-5.1": gpt51Family,
        "gpt-5-codex": gpt51Family,
        "gpt-5": gpt51Family,
        "codex-mini-latest": codexMini,
        "o3": o3,
        "o4-mini": o4Mini,
    ]

    /// Only published model IDs and their dated snapshots have known prices.
    /// An unknown model must not silently inherit another model's rate.
    public static func price(for model: String) -> ModelPrice? {
        let normalized = model.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = pricing[normalized] { return exact }
        if let suffix = normalized.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            return pricing[String(normalized[..<suffix.lowerBound])]
        }
        return nil
    }

    /// Cost for usage where `inputTokens` excludes cached tokens and
    /// `outputTokens` already includes reasoning.
    public static func cost(
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int
    ) -> Double? {
        guard let price = Self.price(for: model) else { return nil }
        return Double(inputTokens) / 1_000_000 * price.inputPerMillion
            + Double(cachedInputTokens) / 1_000_000 * price.cachedInputPerMillion
            + Double(outputTokens) / 1_000_000 * price.outputPerMillion
    }
}
