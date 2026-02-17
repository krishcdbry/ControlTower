import Foundation
import Testing
@testable import ControlTowerCore

@Suite("Notification Model Tests")
struct NotificationModelTests {

    // MARK: - NotificationType Tests

    @Test("NotificationType has all expected cases")
    func notificationTypeHasAllCases() {
        let types = NotificationType.allCases
        #expect(types.contains(.quotaWarning))
        #expect(types.contains(.quotaDepleted))
        #expect(types.contains(.quotaRestored))
        #expect(types.contains(.resetReminder))
        #expect(types.contains(.usageSpike))
        #expect(types.contains(.weeklySummary))
        #expect(types.contains(.costAlert))
    }

    @Test("NotificationType display names are set")
    func notificationTypeDisplayNames() {
        #expect(NotificationType.quotaWarning.displayName == "Quota Warning")
        #expect(NotificationType.quotaDepleted.displayName == "Quota Depleted")
        #expect(NotificationType.quotaRestored.displayName == "Quota Restored")
        #expect(!NotificationType.costAlert.displayName.isEmpty)
    }

    @Test("NotificationType icons are set")
    func notificationTypeIcons() {
        for type in NotificationType.allCases {
            #expect(!type.icon.isEmpty)
        }
    }

    @Test("NotificationType default enabled states")
    func notificationTypeDefaultEnabled() {
        // Core notifications should be enabled by default
        #expect(NotificationType.quotaWarning.defaultEnabled == true)
        #expect(NotificationType.quotaDepleted.defaultEnabled == true)
        #expect(NotificationType.quotaRestored.defaultEnabled == true)

        // Optional notifications should be disabled by default
        #expect(NotificationType.resetReminder.defaultEnabled == false)
        #expect(NotificationType.weeklySummary.defaultEnabled == false)
        #expect(NotificationType.costAlert.defaultEnabled == false)
    }

    // MARK: - NotificationThreshold Tests

    @Test("NotificationThreshold creates with defaults")
    func thresholdCreatesWithDefaults() {
        let threshold = NotificationThreshold(type: .quotaWarning, value: 80)

        #expect(threshold.type == .quotaWarning)
        #expect(threshold.value == 80)
        #expect(threshold.isEnabled == true)
        #expect(threshold.provider == nil)
        #expect(threshold.cooldownMinutes == 60)
    }

    @Test("NotificationThreshold for specific provider")
    func thresholdForSpecificProvider() {
        let threshold = NotificationThreshold(
            type: .quotaDepleted,
            provider: .claude,
            value: 100,
            cooldownMinutes: 5
        )

        #expect(threshold.provider == .claude)
        #expect(threshold.value == 100)
    }

    @Test("Default thresholds are valid")
    func defaultThresholdsAreValid() {
        let defaults = NotificationThreshold.defaults

        #expect(!defaults.isEmpty)
        #expect(defaults.count >= 5)

        // Check for quota warning thresholds
        let warnings = defaults.filter { $0.type == .quotaWarning }
        #expect(warnings.count >= 3)

        // Check common thresholds exist
        #expect(defaults.contains { $0.value == 80 && $0.type == .quotaWarning })
        #expect(defaults.contains { $0.value == 90 && $0.type == .quotaWarning })
        #expect(defaults.contains { $0.value == 100 && $0.type == .quotaDepleted })
    }

    @Test("Threshold IDs are unique")
    func thresholdIDsAreUnique() {
        let defaults = NotificationThreshold.defaults
        let ids = defaults.map(\.id)
        let uniqueIDs = Set(ids)
        #expect(ids.count == uniqueIDs.count, "Threshold IDs must be unique")
    }

    // MARK: - NotificationConfig Tests

    @Test("NotificationConfig default values")
    func configDefaultValues() {
        let config = NotificationConfig.default

        #expect(!config.thresholds.isEmpty)
        #expect(config.quietHoursStart == nil)
        #expect(config.quietHoursEnd == nil)
        #expect(config.respectSystemDND == true)
        #expect(config.showBadges == true)
        #expect(config.playSounds == true)
    }

    @Test("NotificationConfig quiet hours detection - normal hours")
    func configQuietHoursNormal() {
        let config = NotificationConfig(
            quietHoursStart: 22,
            quietHoursEnd: 8
        )

        // Create dates for testing
        let calendar = Calendar.current
        var components = calendar.dateComponents(in: .current, from: Date())
        components.second = 0
        components.nanosecond = 0

        // 23:00 should be in quiet hours (22-8)
        components.hour = 23
        let lateNight = calendar.date(from: components)!
        #expect(config.isInQuietHours(now: lateNight) == true)

        // 10:00 should NOT be in quiet hours
        components.hour = 10
        let morning = calendar.date(from: components)!
        #expect(config.isInQuietHours(now: morning) == false)

        // 3:00 should be in quiet hours (overnight)
        components.hour = 3
        let earlyMorning = calendar.date(from: components)!
        #expect(config.isInQuietHours(now: earlyMorning) == true)
    }

    @Test("NotificationConfig no quiet hours returns false")
    func configNoQuietHours() {
        let config = NotificationConfig()
        #expect(config.isInQuietHours() == false)
    }

    // MARK: - PendingNotification Tests

    @Test("PendingNotification creates correctly")
    func pendingNotificationCreates() {
        let notification = PendingNotification(
            type: .quotaWarning,
            provider: .claude,
            title: "Test Title",
            body: "Test Body"
        )

        #expect(notification.type == .quotaWarning)
        #expect(notification.provider == .claude)
        #expect(notification.title == "Test Title")
        #expect(notification.body == "Test Body")
        #expect(notification.metadata.isEmpty)
    }

    @Test("PendingNotification with metadata")
    func pendingNotificationWithMetadata() {
        let notification = PendingNotification(
            type: .costAlert,
            provider: .gemini,
            title: "Cost Alert",
            body: "You've spent $10",
            metadata: ["amount": "10", "currency": "USD"]
        )

        #expect(notification.metadata["amount"] == "10")
        #expect(notification.metadata["currency"] == "USD")
    }

    // MARK: - NotificationRecord Tests

    @Test("NotificationRecord creates and encodes")
    func notificationRecordCreatesAndEncodes() throws {
        let record = NotificationRecord(
            type: .quotaDepleted,
            provider: .codex,
            title: "Quota Depleted",
            body: "Your Codex quota is depleted"
        )

        #expect(record.wasDelivered == true)

        // Test encoding/decoding
        let encoder = JSONEncoder()
        let data = try encoder.encode(record)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(NotificationRecord.self, from: data)

        #expect(decoded.type == record.type)
        #expect(decoded.provider == record.provider)
        #expect(decoded.title == record.title)
    }
}
