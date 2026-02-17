import Foundation

/// A snapshot of usage data for a provider at a point in time.
public struct UsageSnapshot: Sendable, Equatable {
    /// The provider this snapshot belongs to.
    public let providerID: ProviderID

    /// Optional account ID for multi-account support.
    public let accountID: UUID?

    /// Primary rate window (e.g., session/5-hour limit).
    public let primary: RateWindow?

    /// Secondary rate window (e.g., weekly limit).
    public let secondary: RateWindow?

    /// Tertiary rate window (e.g., model-specific like Opus).
    public let tertiary: RateWindow?

    /// Cost information if available.
    public let cost: ProviderCostInfo?

    /// When this snapshot was fetched.
    public let updatedAt: Date

    /// Identity information (email, org, plan).
    public let identity: ProviderIdentity?

    /// Additional metadata from the provider.
    public let metadata: [String: String]

    public init(
        providerID: ProviderID,
        accountID: UUID? = nil,
        primary: RateWindow? = nil,
        secondary: RateWindow? = nil,
        tertiary: RateWindow? = nil,
        cost: ProviderCostInfo? = nil,
        updatedAt: Date = Date(),
        identity: ProviderIdentity? = nil,
        metadata: [String: String] = [:]
    ) {
        self.providerID = providerID
        self.accountID = accountID
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.cost = cost
        self.updatedAt = updatedAt
        self.identity = identity
        self.metadata = metadata
    }

    /// Returns the highest usage percentage across all windows.
    public var highestUsagePercent: Double {
        [primary?.usedPercent, secondary?.usedPercent, tertiary?.usedPercent]
            .compactMap { $0 }
            .max() ?? 0
    }

    /// Returns true if any rate window is depleted (>= 99%).
    public var isDepleted: Bool {
        self.highestUsagePercent >= 99
    }

    /// Returns true if approaching limit (>= 80%).
    public var isApproachingLimit: Bool {
        self.highestUsagePercent >= 80
    }
}

/// A rate-limited usage window (session, weekly, etc.).
public struct RateWindow: Sendable, Equatable, Codable {
    /// Percentage of the limit that has been used (0-100).
    public let usedPercent: Double

    /// Percentage remaining (0-100).
    public var remainingPercent: Double {
        max(0, 100 - self.usedPercent)
    }

    /// Number of tokens used, if available.
    public let usedTokens: Int?

    /// Token limit for this window, if available.
    public let limitTokens: Int?

    /// Number of messages/requests used, if available.
    public let usedMessages: Int?

    /// Message/request limit, if available.
    public let limitMessages: Int?

    /// Duration of this window in minutes, if known.
    public let windowMinutes: Int?

    /// When this window resets.
    public let resetsAt: Date?

    /// Human-readable reset description (e.g., "in 2h 30m").
    public let resetDescription: String?

    /// Label for this window (e.g., "Session", "Weekly").
    public let label: String?

    public init(
        usedPercent: Double,
        usedTokens: Int? = nil,
        limitTokens: Int? = nil,
        usedMessages: Int? = nil,
        limitMessages: Int? = nil,
        windowMinutes: Int? = nil,
        resetsAt: Date? = nil,
        resetDescription: String? = nil,
        label: String? = nil
    ) {
        self.usedPercent = min(100, max(0, usedPercent))
        self.usedTokens = usedTokens
        self.limitTokens = limitTokens
        self.usedMessages = usedMessages
        self.limitMessages = limitMessages
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.label = label
    }

    /// Formatted token usage string (e.g., "45.2K / 100K").
    public var tokenUsageString: String? {
        guard let used = usedTokens else { return nil }
        let usedStr = Self.formatTokenCount(used)
        if let limit = limitTokens {
            return "\(usedStr) / \(Self.formatTokenCount(limit))"
        }
        return usedStr
    }

    /// Formatted message usage string.
    public var messageUsageString: String? {
        guard let used = usedMessages else { return nil }
        if let limit = limitMessages {
            return "\(used) / \(limit)"
        }
        return "\(used)"
    }

    private static func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    /// Returns a human-readable time until reset.
    public func timeUntilReset(from now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        let interval = resetsAt.timeIntervalSince(now)
        guard interval > 0 else { return "now" }

        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60

        if hours > 24 {
            let days = hours / 24
            return "\(days)d \(hours % 24)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

/// Cost and credit information for a provider.
public struct ProviderCostInfo: Sendable, Equatable, Codable {
    /// Daily cost in USD, if available.
    public let dailyCostUSD: Double?

    /// Monthly cost in USD, if available.
    public let monthlyCostUSD: Double?

    /// Remaining credits, if applicable.
    public let remainingCredits: Double?

    /// Total credits limit, if applicable.
    public let totalCredits: Double?

    /// Currency code (default: "USD").
    public let currencyCode: String

    /// Billing period description (e.g., "Monthly", "Daily").
    public let period: String?

    public init(
        dailyCostUSD: Double? = nil,
        monthlyCostUSD: Double? = nil,
        remainingCredits: Double? = nil,
        totalCredits: Double? = nil,
        currencyCode: String = "USD",
        period: String? = nil
    ) {
        self.dailyCostUSD = dailyCostUSD
        self.monthlyCostUSD = monthlyCostUSD
        self.remainingCredits = remainingCredits
        self.totalCredits = totalCredits
        self.currencyCode = currencyCode
        self.period = period
    }

    /// Credits usage percentage if both remaining and total are available.
    public var creditsUsedPercent: Double? {
        guard let remaining = remainingCredits, let total = totalCredits, total > 0 else {
            return nil
        }
        return ((total - remaining) / total) * 100
    }
}

/// Identity information for a provider account.
public struct ProviderIdentity: Sendable, Equatable, Codable {
    /// Email address associated with the account.
    public let email: String?

    /// Organization name, if applicable.
    public let organization: String?

    /// Plan tier (e.g., "Pro", "Team", "Enterprise").
    public let plan: String?

    /// How the user authenticated (OAuth, CLI, cookies, etc.).
    public let authMethod: String?

    public init(
        email: String? = nil,
        organization: String? = nil,
        plan: String? = nil,
        authMethod: String? = nil
    ) {
        self.email = email
        self.organization = organization
        self.plan = plan
        self.authMethod = authMethod
    }
}
