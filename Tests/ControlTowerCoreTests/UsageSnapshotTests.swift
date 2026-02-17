import Foundation
import Testing
@testable import ControlTowerCore

@Suite("UsageSnapshot Tests")
struct UsageSnapshotTests {
    @Test("RateWindow calculates used percent correctly")
    func rateWindowUsedPercent() {
        let window = RateWindow(usedPercent: 75.5, windowMinutes: 60, label: "Hourly")
        #expect(window.usedPercent == 75.5)
        #expect(window.windowMinutes == 60)
        #expect(window.label == "Hourly")
    }

    @Test("RateWindow handles reset time")
    func rateWindowResetTime() {
        let resetTime = Date().addingTimeInterval(3600)
        let window = RateWindow(usedPercent: 50, windowMinutes: 60, resetsAt: resetTime, label: "Test")
        #expect(window.resetsAt == resetTime)
    }

    @Test("UsageSnapshot creates with primary window")
    func usageSnapshotWithPrimary() {
        let primary = RateWindow(usedPercent: 25, label: "Session")
        let snapshot = UsageSnapshot(
            providerID: .claude,
            primary: primary,
            updatedAt: Date()
        )

        #expect(snapshot.providerID == .claude)
        #expect(snapshot.primary?.usedPercent == 25)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.tertiary == nil)
    }

    @Test("UsageSnapshot creates with all windows")
    func usageSnapshotWithAllWindows() {
        let primary = RateWindow(usedPercent: 10, label: "Session")
        let secondary = RateWindow(usedPercent: 30, label: "Weekly")
        let tertiary = RateWindow(usedPercent: 5, label: "Opus")

        let snapshot = UsageSnapshot(
            providerID: .claude,
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            updatedAt: Date()
        )

        #expect(snapshot.primary?.usedPercent == 10)
        #expect(snapshot.secondary?.usedPercent == 30)
        #expect(snapshot.tertiary?.usedPercent == 5)
    }

    @Test("UsageSnapshot with identity")
    func usageSnapshotWithIdentity() {
        let identity = ProviderIdentity(email: "test@example.com", plan: "Pro", authMethod: "oauth")
        let snapshot = UsageSnapshot(
            providerID: .gemini,
            primary: RateWindow(usedPercent: 0, label: "Pro"),
            updatedAt: Date(),
            identity: identity
        )

        #expect(snapshot.identity?.email == "test@example.com")
        #expect(snapshot.identity?.plan == "Pro")
    }

    @Test("ProviderCostInfo calculates correctly")
    func providerCostInfo() {
        let cost = ProviderCostInfo(dailyCostUSD: 1.5, monthlyCostUSD: 45.0)
        #expect(cost.dailyCostUSD == 1.5)
        #expect(cost.monthlyCostUSD == 45.0)
    }
}
