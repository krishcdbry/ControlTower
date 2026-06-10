import Foundation

/// Pricing for Claude models (per million tokens, in USD).
///
/// Source: platform.claude.com pricing (cached 2026-05). Cache reads cost
/// 0.1x input; cache writes cost 1.25x input for 5-minute TTL and 2x input
/// for 1-hour TTL.
public enum ClaudePricing {
    /// Model pricing tiers.
    public struct ModelPrice: Sendable {
        public let inputPerMillion: Double
        public let outputPerMillion: Double
        public let cacheReadPerMillion: Double
        public let cacheWrite5mPerMillion: Double
        public let cacheWrite1hPerMillion: Double

        /// Backwards-compatible alias for the 5m cache-write rate.
        public var cacheWritePerMillion: Double { self.cacheWrite5mPerMillion }

        public init(
            input: Double,
            output: Double,
            cacheRead: Double? = nil,
            cacheWrite: Double? = nil,
            cacheWrite1h: Double? = nil
        ) {
            self.inputPerMillion = input
            self.outputPerMillion = output
            self.cacheReadPerMillion = cacheRead ?? (input * 0.1)
            self.cacheWrite5mPerMillion = cacheWrite ?? (input * 1.25)
            self.cacheWrite1hPerMillion = cacheWrite1h ?? (input * 2.0)
        }
    }

    // Family base rates.
    private static let fable5 = ModelPrice(input: 10, output: 50)
    private static let modernOpus = ModelPrice(input: 5, output: 25) // Opus 4.5 and later
    private static let legacyOpus = ModelPrice(input: 15, output: 75) // Opus 3 / 4.0 / 4.1
    private static let sonnet = ModelPrice(input: 3, output: 15)
    private static let modernHaiku = ModelPrice(input: 1, output: 5) // Haiku 4.5
    private static let haiku35 = ModelPrice(input: 0.80, output: 4)
    private static let haiku3 = ModelPrice(input: 0.25, output: 1.25)

    /// Known model pricing (aliases and dated ids).
    public static let pricing: [String: ModelPrice] = [
        // Fable 5
        "claude-fable-5": fable5,

        // Opus 4.5+ ($5/$25)
        "claude-opus-4-8": modernOpus,
        "claude-opus-4-7": modernOpus,
        "claude-opus-4-6": modernOpus,
        "claude-opus-4-5": modernOpus,
        "claude-opus-4-5-20251101": modernOpus,

        // Legacy Opus ($15/$75)
        "claude-opus-4-1": legacyOpus,
        "claude-opus-4-1-20250805": legacyOpus,
        "claude-opus-4-0": legacyOpus,
        "claude-opus-4-20250514": legacyOpus,
        "claude-3-opus": legacyOpus,
        "claude-3-opus-20240229": legacyOpus,

        // Sonnet ($3/$15)
        "claude-sonnet-4-6": sonnet,
        "claude-sonnet-4-5": sonnet,
        "claude-sonnet-4-5-20250929": sonnet,
        "claude-sonnet-4-0": sonnet,
        "claude-sonnet-4-20250514": sonnet,
        "claude-3-7-sonnet": sonnet,
        "claude-3-7-sonnet-20250219": sonnet,
        "claude-3-5-sonnet": sonnet,
        "claude-3-5-sonnet-20241022": sonnet,
        "claude-3-5-sonnet-20240620": sonnet,
        "claude-3-sonnet": sonnet,
        "claude-3-sonnet-20240229": sonnet,

        // Haiku 4.5 ($1/$5)
        "claude-haiku-4-5": modernHaiku,
        "claude-haiku-4-5-20251001": modernHaiku,

        // Haiku 3.5 ($0.80/$4)
        "claude-3-5-haiku": haiku35,
        "claude-3-5-haiku-20241022": haiku35,

        // Haiku 3 ($0.25/$1.25)
        "claude-3-haiku": haiku3,
        "claude-3-haiku-20240307": haiku3,
    ]

    /// Default pricing for unknown models (assume Sonnet-class).
    public static let defaultPricing = sonnet

    /// Get pricing for a model. Handles "[1m]" context suffixes, dated ids,
    /// and falls back to version-aware family matching for unknown ids.
    public static func price(for model: String) -> ModelPrice {
        let normalized = Self.normalize(model)

        if let price = pricing[normalized] {
            return price
        }

        // Dated id whose alias we know: strip a trailing -yyyymmdd component.
        if normalized.count > 9 {
            let suffix = normalized.suffix(9)
            if suffix.first == "-", suffix.dropFirst().allSatisfy(\.isNumber) {
                let alias = String(normalized.dropLast(9))
                if let price = pricing[alias] {
                    return price
                }
            }
        }

        // Family fallback.
        if normalized.contains("fable") {
            return fable5
        }
        if normalized.contains("opus") {
            // Opus 4.5 dropped the price to $5/$25; only 3.x/4.0/4.1 keep legacy rates.
            let isLegacy = normalized.contains("opus-4-0") || normalized.contains("opus-4-1")
                || normalized.contains("opus-4-2") || normalized.contains("opus-4-3")
                || normalized.contains("opus-4-4") || normalized.contains("3-opus")
                || normalized.contains("opus-3") || normalized.hasSuffix("opus-4")
                || normalized.contains("opus-4-2025")
            return isLegacy ? legacyOpus : modernOpus
        }
        if normalized.contains("haiku") {
            if normalized.contains("3-5-haiku") || normalized.contains("haiku-3-5") {
                return haiku35
            }
            if normalized.contains("3-haiku") || normalized.contains("haiku-3") {
                return haiku3
            }
            return modernHaiku
        }
        if normalized.contains("sonnet") {
            return sonnet
        }

        return defaultPricing
    }

    /// Lowercases and strips bracketed context suffixes like "claude-opus-4-7[1m]".
    static func normalize(_ model: String) -> String {
        var normalized = model.lowercased().trimmingCharacters(in: .whitespaces)
        if let bracket = normalized.firstIndex(of: "[") {
            normalized = String(normalized[..<bracket])
        }
        return normalized
    }

    /// Calculate cost for usage with separate 5m/1h cache-write tiers.
    public static func cost(
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheWrite5mTokens: Int = 0,
        cacheWrite1hTokens: Int = 0
    ) -> Double {
        let price = Self.price(for: model)
        let inputCost = Double(inputTokens) / 1_000_000 * price.inputPerMillion
        let outputCost = Double(outputTokens) / 1_000_000 * price.outputPerMillion
        let cacheReadCost = Double(cacheReadTokens) / 1_000_000 * price.cacheReadPerMillion
        let cacheWrite5mCost = Double(cacheWrite5mTokens) / 1_000_000 * price.cacheWrite5mPerMillion
        let cacheWrite1hCost = Double(cacheWrite1hTokens) / 1_000_000 * price.cacheWrite1hPerMillion
        return inputCost + outputCost + cacheReadCost + cacheWrite5mCost + cacheWrite1hCost
    }

    /// Backwards-compatible single-tier cost (cache writes priced at the 5m rate).
    public static func cost(
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int
    ) -> Double {
        Self.cost(
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWrite5mTokens: cacheWriteTokens,
            cacheWrite1hTokens: 0
        )
    }
}
