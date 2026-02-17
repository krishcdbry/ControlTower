import Foundation

/// Calculates usage pace - whether you're ahead or behind expected usage.
public struct UsagePace: Sendable, Equatable {
    /// How far ahead or behind the expected pace
    public enum Stage: String, Sendable, Equatable {
        case farAhead       // >20% in deficit
        case ahead          // 10-20% in deficit
        case slightlyAhead  // 5-10% in deficit
        case onTrack        // within 5%
        case slightlyBehind // 5-10% in reserve
        case behind         // 10-20% in reserve
        case farBehind      // >20% in reserve
    }

    /// Expected usage percentage based on time elapsed
    public let expectedUsedPercent: Double

    /// Actual usage percentage
    public let actualUsedPercent: Double

    /// Difference: positive = in deficit, negative = in reserve
    public let deltaPercent: Double

    /// Stage classification
    public let stage: Stage

    /// Whether current pace will last until reset
    public let willLastToReset: Bool

    /// Estimated seconds until quota runs out (nil if will last)
    public let etaSeconds: TimeInterval?

    /// Seconds until reset
    public let secondsToReset: TimeInterval

    /// Human-readable pace description
    public var paceDescription: String {
        let delta = Int(abs(deltaPercent).rounded())
        switch stage {
        case .onTrack:
            return "On pace"
        case .slightlyAhead, .ahead, .farAhead:
            return "\(delta)% in deficit"
        case .slightlyBehind, .behind, .farBehind:
            return "\(delta)% in reserve"
        }
    }

    /// Human-readable ETA description
    public var etaDescription: String? {
        if willLastToReset { return "Lasts until reset" }
        guard let eta = etaSeconds else { return nil }
        if eta <= 0 { return "Runs out now" }
        return "Runs out in \(Self.formatDuration(eta))"
    }

    // MARK: - Factory Methods

    /// Calculate pace for a weekly rate window
    public static func weekly(
        window: RateWindow,
        now: Date = Date(),
        defaultWindowMinutes: Int = 10080 // 7 days
    ) -> UsagePace? {
        guard let resetsAt = window.resetsAt else { return nil }
        let windowMinutes = window.windowMinutes ?? defaultWindowMinutes
        return Self.calculate(
            usedPercent: window.usedPercent,
            resetsAt: resetsAt,
            windowMinutes: windowMinutes,
            now: now
        )
    }

    /// Calculate pace for a session rate window
    public static func session(
        window: RateWindow,
        now: Date = Date(),
        defaultWindowMinutes: Int = 300 // 5 hours
    ) -> UsagePace? {
        guard let resetsAt = window.resetsAt else { return nil }
        let windowMinutes = window.windowMinutes ?? defaultWindowMinutes
        return Self.calculate(
            usedPercent: window.usedPercent,
            resetsAt: resetsAt,
            windowMinutes: windowMinutes,
            now: now
        )
    }

    /// Core pace calculation
    public static func calculate(
        usedPercent: Double,
        resetsAt: Date,
        windowMinutes: Int,
        now: Date = Date()
    ) -> UsagePace? {
        let secondsToReset = resetsAt.timeIntervalSince(now)
        guard secondsToReset > 0 else { return nil }

        let totalWindowSeconds = Double(windowMinutes * 60)
        let elapsedSeconds = totalWindowSeconds - secondsToReset
        guard elapsedSeconds > 0 else { return nil }

        // Expected usage based on time elapsed
        let fractionElapsed = elapsedSeconds / totalWindowSeconds
        let expectedUsedPercent = fractionElapsed * 100

        // Delta: positive means using more than expected (deficit)
        let deltaPercent = usedPercent - expectedUsedPercent

        // Classify stage
        let stage: Stage
        if abs(deltaPercent) < 5 {
            stage = .onTrack
        } else if deltaPercent >= 20 {
            stage = .farAhead
        } else if deltaPercent >= 10 {
            stage = .ahead
        } else if deltaPercent >= 5 {
            stage = .slightlyAhead
        } else if deltaPercent <= -20 {
            stage = .farBehind
        } else if deltaPercent <= -10 {
            stage = .behind
        } else {
            stage = .slightlyBehind
        }

        // Calculate ETA
        let remainingPercent = 100 - usedPercent
        let willLastToReset: Bool
        let etaSeconds: TimeInterval?

        if remainingPercent <= 0 {
            willLastToReset = false
            etaSeconds = 0
        } else if usedPercent <= 0 {
            willLastToReset = true
            etaSeconds = nil
        } else {
            // Rate of usage: usedPercent per elapsedSeconds
            let usageRate = usedPercent / elapsedSeconds
            if usageRate <= 0 {
                willLastToReset = true
                etaSeconds = nil
            } else {
                let secondsToDeplete = remainingPercent / usageRate
                willLastToReset = secondsToDeplete >= secondsToReset
                etaSeconds = willLastToReset ? nil : secondsToDeplete
            }
        }

        return UsagePace(
            expectedUsedPercent: expectedUsedPercent,
            actualUsedPercent: usedPercent,
            deltaPercent: deltaPercent,
            stage: stage,
            willLastToReset: willLastToReset,
            etaSeconds: etaSeconds,
            secondsToReset: secondsToReset
        )
    }

    // MARK: - Formatting

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let days = totalSeconds / 86400
        let hours = (totalSeconds % 86400) / 3600
        let minutes = (totalSeconds % 3600) / 60

        if days > 0 {
            return "\(days)d \(hours)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}
