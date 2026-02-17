import Foundation

/// Types of notifications Control Tower can send.
public enum NotificationType: String, CaseIterable, Sendable, Codable {
    /// Approaching usage limit (configurable thresholds: 80%, 90%, 95%).
    case quotaWarning

    /// Hit 100% usage - depleted.
    case quotaDepleted

    /// Usage restored after being depleted.
    case quotaRestored

    /// Reminder before quota resets.
    case resetReminder

    /// Unusual usage increase detected.
    case usageSpike

    /// Weekly usage summary digest.
    case weeklySummary

    /// Cost threshold exceeded.
    case costAlert

    public var displayName: String {
        switch self {
        case .quotaWarning: "Quota Warning"
        case .quotaDepleted: "Quota Depleted"
        case .quotaRestored: "Quota Restored"
        case .resetReminder: "Reset Reminder"
        case .usageSpike: "Usage Spike"
        case .weeklySummary: "Weekly Summary"
        case .costAlert: "Cost Alert"
        }
    }

    public var icon: String {
        switch self {
        case .quotaWarning: "exclamationmark.triangle"
        case .quotaDepleted: "xmark.circle"
        case .quotaRestored: "checkmark.circle"
        case .resetReminder: "clock"
        case .usageSpike: "chart.line.uptrend.xyaxis"
        case .weeklySummary: "calendar"
        case .costAlert: "dollarsign.circle"
        }
    }

    /// Default enabled state for this notification type.
    public var defaultEnabled: Bool {
        switch self {
        case .quotaWarning, .quotaDepleted, .quotaRestored: true
        case .resetReminder, .usageSpike, .weeklySummary, .costAlert: false
        }
    }
}

/// A configurable notification threshold.
public struct NotificationThreshold: Sendable, Codable, Identifiable, Equatable {
    public var id: String { "\(type.rawValue)-\(provider?.rawValue ?? "all")-\(Int(value))" }

    /// Type of notification.
    public let type: NotificationType

    /// Specific provider, or nil for all providers.
    public let provider: ProviderID?

    /// Threshold value (percentage or USD amount).
    public let value: Double

    /// Whether this threshold is enabled.
    public var isEnabled: Bool

    /// Cooldown period to prevent notification spam (minutes).
    public let cooldownMinutes: Int

    public init(
        type: NotificationType,
        provider: ProviderID? = nil,
        value: Double,
        isEnabled: Bool = true,
        cooldownMinutes: Int = 60
    ) {
        self.type = type
        self.provider = provider
        self.value = value
        self.isEnabled = isEnabled
        self.cooldownMinutes = cooldownMinutes
    }

    /// Default thresholds for a new installation.
    public static var defaults: [NotificationThreshold] {
        [
            NotificationThreshold(type: .quotaWarning, value: 80, cooldownMinutes: 60),
            NotificationThreshold(type: .quotaWarning, value: 90, cooldownMinutes: 30),
            NotificationThreshold(type: .quotaWarning, value: 95, cooldownMinutes: 15),
            NotificationThreshold(type: .quotaDepleted, value: 100, cooldownMinutes: 5),
            NotificationThreshold(type: .quotaRestored, value: 0, cooldownMinutes: 0),
            NotificationThreshold(type: .costAlert, value: 10, isEnabled: false, cooldownMinutes: 1440),
            NotificationThreshold(type: .costAlert, value: 50, isEnabled: false, cooldownMinutes: 1440),
        ]
    }
}

/// Configuration for the notification system.
public struct NotificationConfig: Sendable, Codable {
    /// All configured thresholds.
    public var thresholds: [NotificationThreshold]

    /// Start of quiet hours (hour of day 0-23), nil if disabled.
    public var quietHoursStart: Int?

    /// End of quiet hours (hour of day 0-23).
    public var quietHoursEnd: Int?

    /// Whether to respect system Do Not Disturb.
    public var respectSystemDND: Bool

    /// Day of week for weekly summary (1=Sunday, 7=Saturday).
    public var weeklySummaryDay: Int

    /// Hour of day for weekly summary (0-23).
    public var weeklySummaryHour: Int

    /// Whether to show notification badges on the menu bar icon.
    public var showBadges: Bool

    /// Whether to play sounds with notifications.
    public var playSounds: Bool

    public init(
        thresholds: [NotificationThreshold] = NotificationThreshold.defaults,
        quietHoursStart: Int? = nil,
        quietHoursEnd: Int? = nil,
        respectSystemDND: Bool = true,
        weeklySummaryDay: Int = 1,
        weeklySummaryHour: Int = 9,
        showBadges: Bool = true,
        playSounds: Bool = true
    ) {
        self.thresholds = thresholds
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
        self.respectSystemDND = respectSystemDND
        self.weeklySummaryDay = weeklySummaryDay
        self.weeklySummaryHour = weeklySummaryHour
        self.showBadges = showBadges
        self.playSounds = playSounds
    }

    public static var `default`: NotificationConfig {
        NotificationConfig()
    }

    /// Returns true if currently in quiet hours.
    public func isInQuietHours(now: Date = Date()) -> Bool {
        guard let start = quietHoursStart, let end = quietHoursEnd else {
            return false
        }

        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)

        if start <= end {
            return hour >= start && hour < end
        } else {
            // Quiet hours span midnight
            return hour >= start || hour < end
        }
    }
}

/// A notification that is pending delivery.
public struct PendingNotification: Sendable, Identifiable {
    public let id: UUID
    public let type: NotificationType
    public let provider: ProviderID
    public let title: String
    public let body: String
    public let metadata: [String: String]
    public let scheduledAt: Date

    public init(
        id: UUID = UUID(),
        type: NotificationType,
        provider: ProviderID,
        title: String,
        body: String,
        metadata: [String: String] = [:],
        scheduledAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.provider = provider
        self.title = title
        self.body = body
        self.metadata = metadata
        self.scheduledAt = scheduledAt
    }
}

/// Record of a delivered notification.
public struct NotificationRecord: Sendable, Identifiable, Codable {
    public let id: UUID
    public let type: NotificationType
    public let provider: ProviderID
    public let title: String
    public let body: String
    public let timestamp: Date
    public let wasDelivered: Bool
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        type: NotificationType,
        provider: ProviderID,
        title: String,
        body: String,
        timestamp: Date = Date(),
        wasDelivered: Bool = true,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.type = type
        self.provider = provider
        self.title = title
        self.body = body
        self.timestamp = timestamp
        self.wasDelivered = wasDelivered
        self.metadata = metadata
    }
}
