import Foundation

/// A single data point for usage analytics.
public struct UsageDataPoint: Sendable, Codable, Identifiable {
    public var id: Int64?

    /// When this data point was recorded.
    public let timestamp: Date

    /// The provider this data belongs to.
    public let provider: ProviderID

    /// Optional account ID for multi-account tracking.
    public let accountID: UUID?

    /// Primary window usage percentage.
    public let primaryUsedPercent: Double?

    /// Secondary window usage percentage.
    public let secondaryUsedPercent: Double?

    /// Cost in USD for this period.
    public let costUSD: Double?

    /// Number of tokens used, if available.
    public let tokensUsed: Int?

    /// Models used during this period (JSON-encoded array).
    public let modelsUsed: [String]?

    public init(
        id: Int64? = nil,
        timestamp: Date = Date(),
        provider: ProviderID,
        accountID: UUID? = nil,
        primaryUsedPercent: Double? = nil,
        secondaryUsedPercent: Double? = nil,
        costUSD: Double? = nil,
        tokensUsed: Int? = nil,
        modelsUsed: [String]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.provider = provider
        self.accountID = accountID
        self.primaryUsedPercent = primaryUsedPercent
        self.secondaryUsedPercent = secondaryUsedPercent
        self.costUSD = costUSD
        self.tokensUsed = tokensUsed
        self.modelsUsed = modelsUsed
    }

    /// Creates a data point from a usage snapshot.
    public static func from(_ snapshot: UsageSnapshot) -> UsageDataPoint {
        UsageDataPoint(
            timestamp: snapshot.updatedAt,
            provider: snapshot.providerID,
            accountID: snapshot.accountID,
            primaryUsedPercent: snapshot.primary?.usedPercent,
            secondaryUsedPercent: snapshot.secondary?.usedPercent,
            costUSD: snapshot.cost?.dailyCostUSD,
            tokensUsed: nil,
            modelsUsed: nil
        )
    }
}

/// Time period for aggregating usage data.
public enum AggregationPeriod: String, CaseIterable, Sendable, Codable {
    case hourly
    case daily
    case weekly
    case monthly

    public var displayName: String {
        switch self {
        case .hourly: "Hourly"
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        }
    }

    /// Number of seconds in this period.
    public var seconds: TimeInterval {
        switch self {
        case .hourly: 3600
        case .daily: 86400
        case .weekly: 604800
        case .monthly: 2592000  // 30 days
        }
    }
}

/// Aggregated usage statistics for a time period.
public struct AggregatedUsage: Sendable, Identifiable {
    public var id: String { "\(provider.rawValue)-\(startDate.timeIntervalSince1970)" }

    /// Aggregation period type.
    public let period: AggregationPeriod

    /// Provider this data belongs to.
    public let provider: ProviderID

    /// Optional account ID.
    public let accountID: UUID?

    /// Start of the aggregation period.
    public let startDate: Date

    /// End of the aggregation period.
    public let endDate: Date

    /// Number of data points in this aggregation.
    public let dataPointCount: Int

    /// Total cost in USD.
    public let totalCostUSD: Double

    /// Average cost per day in USD.
    public var averageDailyCostUSD: Double {
        let days = max(1, endDate.timeIntervalSince(startDate) / 86400)
        return totalCostUSD / days
    }

    /// Peak usage percentage during the period.
    public let peakUsagePercent: Double

    /// Average usage percentage.
    public let averageUsagePercent: Double

    /// Minimum usage percentage.
    public let minUsagePercent: Double

    /// Total tokens used.
    public let totalTokens: Int

    /// Number of times usage hit 100% (depleted).
    public let depletionCount: Int

    /// Breakdown by model.
    public let modelBreakdown: [ModelUsage]

    public init(
        period: AggregationPeriod,
        provider: ProviderID,
        accountID: UUID? = nil,
        startDate: Date,
        endDate: Date,
        dataPointCount: Int = 0,
        totalCostUSD: Double = 0,
        peakUsagePercent: Double = 0,
        averageUsagePercent: Double = 0,
        minUsagePercent: Double = 0,
        totalTokens: Int = 0,
        depletionCount: Int = 0,
        modelBreakdown: [ModelUsage] = []
    ) {
        self.period = period
        self.provider = provider
        self.accountID = accountID
        self.startDate = startDate
        self.endDate = endDate
        self.dataPointCount = dataPointCount
        self.totalCostUSD = totalCostUSD
        self.peakUsagePercent = peakUsagePercent
        self.averageUsagePercent = averageUsagePercent
        self.minUsagePercent = minUsagePercent
        self.totalTokens = totalTokens
        self.depletionCount = depletionCount
        self.modelBreakdown = modelBreakdown
    }
}

/// Usage breakdown for a specific model.
public struct ModelUsage: Sendable, Codable, Identifiable {
    public var id: String { self.modelName }

    /// Model name (e.g., "claude-3-opus", "gpt-4").
    public let modelName: String

    /// Tokens used with this model.
    public let tokensUsed: Int

    /// Cost attributed to this model.
    public let costUSD: Double

    /// Percentage of total usage.
    public let usagePercent: Double

    public init(
        modelName: String,
        tokensUsed: Int,
        costUSD: Double,
        usagePercent: Double
    ) {
        self.modelName = modelName
        self.tokensUsed = tokensUsed
        self.costUSD = costUSD
        self.usagePercent = usagePercent
    }
}

/// Usage trend comparing two periods.
public struct UsageTrend: Sendable {
    /// Provider this trend is for.
    public let provider: ProviderID

    /// Current period aggregation.
    public let current: AggregatedUsage

    /// Previous period for comparison.
    public let previous: AggregatedUsage

    /// Percentage change in average usage.
    public var usageChangePercent: Double {
        guard previous.averageUsagePercent > 0 else { return 0 }
        return ((current.averageUsagePercent - previous.averageUsagePercent) / previous.averageUsagePercent) * 100
    }

    /// Percentage change in cost.
    public var costChangePercent: Double {
        guard previous.totalCostUSD > 0 else { return 0 }
        return ((current.totalCostUSD - previous.totalCostUSD) / previous.totalCostUSD) * 100
    }

    /// Whether usage is trending up.
    public var isTrendingUp: Bool {
        self.usageChangePercent > 5
    }

    /// Whether usage is trending down.
    public var isTrendingDown: Bool {
        self.usageChangePercent < -5
    }

    public init(provider: ProviderID, current: AggregatedUsage, previous: AggregatedUsage) {
        self.provider = provider
        self.current = current
        self.previous = previous
    }
}

/// Projected cost based on historical data.
public struct CostProjection: Sendable {
    /// Provider this projection is for.
    public let provider: ProviderID

    /// Number of days used for projection.
    public let basedOnDays: Int

    /// Projected daily cost.
    public let projectedDailyCostUSD: Double

    /// Projected weekly cost.
    public var projectedWeeklyCostUSD: Double {
        self.projectedDailyCostUSD * 7
    }

    /// Projected monthly cost.
    public var projectedMonthlyCostUSD: Double {
        self.projectedDailyCostUSD * 30
    }

    /// Confidence level (0-1) based on data quality.
    public let confidence: Double

    public init(
        provider: ProviderID,
        basedOnDays: Int,
        projectedDailyCostUSD: Double,
        confidence: Double
    ) {
        self.provider = provider
        self.basedOnDays = basedOnDays
        self.projectedDailyCostUSD = projectedDailyCostUSD
        self.confidence = confidence
    }
}

/// Daily usage summary.
public struct DailyUsageSummary: Codable, Sendable {
    public let date: Date
    public let provider: ProviderID
    public let avgUsedPercent: Double
    public let maxUsedPercent: Double
    public let totalTokens: Int
    public let totalCostUSD: Double

    public init(
        date: Date,
        provider: ProviderID,
        avgUsedPercent: Double,
        maxUsedPercent: Double,
        totalTokens: Int,
        totalCostUSD: Double
    ) {
        self.date = date
        self.provider = provider
        self.avgUsedPercent = avgUsedPercent
        self.maxUsedPercent = maxUsedPercent
        self.totalTokens = totalTokens
        self.totalCostUSD = totalCostUSD
    }
}

/// Cost summary across providers.
public struct CostSummary: Codable, Sendable {
    public let totalCostUSD: Double
    public let costByProvider: [ProviderID: Double]
    public let dailyCosts: [Date: Double]
    public let periodDays: Int

    public init(
        totalCostUSD: Double,
        costByProvider: [ProviderID: Double],
        dailyCosts: [Date: Double],
        periodDays: Int
    ) {
        self.totalCostUSD = totalCostUSD
        self.costByProvider = costByProvider
        self.dailyCosts = dailyCosts
        self.periodDays = periodDays
    }

    public var averageDailyCost: Double {
        periodDays > 0 ? totalCostUSD / Double(periodDays) : 0
    }
}

/// Export format for analytics data.
public enum ExportFormat: String, CaseIterable, Sendable {
    case csv
    case json

    public var displayName: String {
        switch self {
        case .csv: "CSV"
        case .json: "JSON"
        }
    }

    public var fileExtension: String {
        self.rawValue
    }

    public var mimeType: String {
        switch self {
        case .csv: "text/csv"
        case .json: "application/json"
        }
    }
}

/// Options for exporting analytics data.
public struct ExportOptions: Sendable {
    /// Output format.
    public let format: ExportFormat

    /// Providers to include, nil for all.
    public let providers: [ProviderID]?

    /// Date range to export.
    public let dateRange: ClosedRange<Date>

    /// Whether to include detailed breakdowns.
    public let includeBreakdowns: Bool

    /// Whether to include notification history.
    public let includeNotifications: Bool

    public init(
        format: ExportFormat,
        providers: [ProviderID]? = nil,
        dateRange: ClosedRange<Date>,
        includeBreakdowns: Bool = true,
        includeNotifications: Bool = false
    ) {
        self.format = format
        self.providers = providers
        self.dateRange = dateRange
        self.includeBreakdowns = includeBreakdowns
        self.includeNotifications = includeNotifications
    }
}
