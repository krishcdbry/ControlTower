import Foundation
import GRDB

/// Stores historical usage data for analytics.
public final class AnalyticsStore: Sendable {
    private let database: UsageDatabase

    public init(database: UsageDatabase) {
        self.database = database
    }

    /// Record a usage snapshot for analytics.
    public func record(snapshot: UsageSnapshot) async throws {
        try await database.recordUsage(snapshot)
    }

    /// Get usage history for a provider.
    public func history(
        for provider: ProviderID,
        days: Int = 7
    ) async throws -> [UsageDataPoint] {
        try await database.fetchUsageHistory(provider: provider, days: days)
    }

    /// Get daily aggregated usage.
    public func dailyUsage(
        for provider: ProviderID,
        days: Int = 7
    ) async throws -> [DailyUsageSummary] {
        try await database.fetchDailyUsage(provider: provider, days: days)
    }

    /// Get all providers' current usage percentages.
    public func currentUsageMap() async throws -> [ProviderID: Double] {
        var result: [ProviderID: Double] = [:]
        for provider in ProviderID.allCases {
            if let latest = try await database.fetchLatestUsage(provider: provider) {
                result[provider] = latest.primaryUsedPercent ?? 0
            }
        }
        return result
    }

    /// Get total tokens used across all providers for a time period.
    public func totalTokens(days: Int = 7) async throws -> Int {
        try await database.fetchTotalTokens(days: days)
    }

    /// Get cost summary for a time period.
    public func costSummary(days: Int = 30) async throws -> CostSummary {
        try await database.fetchCostSummary(days: days)
    }

    /// Export data to JSON.
    public func exportToJSON(days: Int = 30) async throws -> Data {
        let history = try await database.fetchAllUsageHistory(days: days)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(history)
    }

    /// Export data to CSV.
    public func exportToCSV(days: Int = 30) async throws -> String {
        let history = try await database.fetchAllUsageHistory(days: days)

        var csv = "timestamp,provider,primary_used_percent,secondary_used_percent,tokens_used,cost_usd\n"

        for point in history {
            let timestamp = ISO8601DateFormatter().string(from: point.timestamp)
            let costStr = point.costUSD.map { String(format: "%.4f", $0) } ?? ""
            let tokensStr = point.tokensUsed.map { "\($0)" } ?? ""
            let primaryStr = point.primaryUsedPercent.map { String(format: "%.2f", $0) } ?? ""
            let secondaryStr = point.secondaryUsedPercent.map { String(format: "%.2f", $0) } ?? ""

            csv += "\(timestamp),\(point.provider.rawValue),\(primaryStr),\(secondaryStr),\(tokensStr),\(costStr)\n"
        }

        return csv
    }
}

// Note: UsageDataPoint, DailyUsageSummary, CostSummary are defined in AnalyticsModels.swift
