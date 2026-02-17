import Foundation

/// Pricing for Claude models (per million tokens, in USD).
public enum ClaudePricing {
    /// Model pricing tiers
    public struct ModelPrice: Sendable {
        public let inputPerMillion: Double
        public let outputPerMillion: Double
        public let cacheReadPerMillion: Double
        public let cacheWritePerMillion: Double

        public init(
            input: Double,
            output: Double,
            cacheRead: Double? = nil,
            cacheWrite: Double? = nil
        ) {
            self.inputPerMillion = input
            self.outputPerMillion = output
            self.cacheReadPerMillion = cacheRead ?? (input * 0.1) // 90% discount for cache read
            self.cacheWritePerMillion = cacheWrite ?? (input * 1.25) // 25% premium for cache write
        }
    }

    /// Known model pricing (as of Feb 2025)
    public static let pricing: [String: ModelPrice] = [
        // Opus 4.5
        "claude-opus-4-5": ModelPrice(input: 15, output: 75),
        "claude-opus-4-5-20251101": ModelPrice(input: 15, output: 75),

        // Sonnet 4.5
        "claude-sonnet-4-5": ModelPrice(input: 3, output: 15),
        "claude-sonnet-4-5-20250514": ModelPrice(input: 3, output: 15),
        "claude-sonnet-4-5-20250929": ModelPrice(input: 3, output: 15),

        // Sonnet 3.5
        "claude-3-5-sonnet": ModelPrice(input: 3, output: 15),
        "claude-3-5-sonnet-20241022": ModelPrice(input: 3, output: 15),

        // Haiku 4
        "claude-haiku-4-5": ModelPrice(input: 0.25, output: 1.25),
        "claude-haiku-4-5-20251001": ModelPrice(input: 0.25, output: 1.25),

        // Haiku 3.5
        "claude-3-5-haiku": ModelPrice(input: 0.80, output: 4),
        "claude-3-5-haiku-20241022": ModelPrice(input: 0.80, output: 4),

        // Opus 3
        "claude-3-opus": ModelPrice(input: 15, output: 75),
        "claude-3-opus-20240229": ModelPrice(input: 15, output: 75),

        // Sonnet 3
        "claude-3-sonnet": ModelPrice(input: 3, output: 15),
        "claude-3-sonnet-20240229": ModelPrice(input: 3, output: 15),

        // Haiku 3
        "claude-3-haiku": ModelPrice(input: 0.25, output: 1.25),
        "claude-3-haiku-20240307": ModelPrice(input: 0.25, output: 1.25),
    ]

    /// Default pricing for unknown models (assume Sonnet-class)
    public static let defaultPricing = ModelPrice(input: 3, output: 15)

    /// Get pricing for a model (with fuzzy matching)
    public static func price(for model: String) -> ModelPrice {
        // Exact match
        if let price = pricing[model] {
            return price
        }

        // Fuzzy match by prefix
        let normalized = model.lowercased()
        if normalized.contains("opus") {
            return ModelPrice(input: 15, output: 75)
        }
        if normalized.contains("haiku") {
            if normalized.contains("3-5") || normalized.contains("4") {
                return ModelPrice(input: 0.25, output: 1.25)
            }
            return ModelPrice(input: 0.80, output: 4)
        }
        if normalized.contains("sonnet") {
            return ModelPrice(input: 3, output: 15)
        }

        return defaultPricing
    }

    /// Calculate cost for a single API call
    public static func cost(
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0
    ) -> Double {
        let price = Self.price(for: model)
        let inputCost = Double(inputTokens) / 1_000_000 * price.inputPerMillion
        let outputCost = Double(outputTokens) / 1_000_000 * price.outputPerMillion
        let cacheReadCost = Double(cacheReadTokens) / 1_000_000 * price.cacheReadPerMillion
        let cacheWriteCost = Double(cacheWriteTokens) / 1_000_000 * price.cacheWritePerMillion
        return inputCost + outputCost + cacheReadCost + cacheWriteCost
    }
}
