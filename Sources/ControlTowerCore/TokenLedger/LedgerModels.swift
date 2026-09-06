import Foundation

/// Which application generated a transcript.
public enum UsageSource: String, Sendable, Codable, CaseIterable, Hashable {
    /// Claude Code CLI / IDE extensions (anything writing to ~/.claude/projects not claimed by another source).
    case claudeCode = "code"
    /// Claude Desktop app sessions, including Cowork (identified via the Desktop session catalog).
    case claudeDesktop = "desktop"
    case codexDesktop = "codex-desktop"
    case codexCLI = "codex-cli"
    case codexIDE = "codex-ide"
    case codexAgent = "codex-agent"
    case codexOther = "codex"
    /// Control Tower's own CLI probe sessions (excluded from cost totals).
    case probe = "probe"

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Desktop / Cowork"
        case .codexDesktop: "Desktop / Work"
        case .codexCLI: "Codex CLI"
        case .codexIDE: "Codex IDE"
        case .codexAgent: "Background agents"
        case .codexOther: "Other Codex"
        case .probe: "Probe"
        }
    }
}

/// Addable token + cost totals.
public struct TokenTotals: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    /// Cache writes with 5-minute TTL (1.25x input price).
    public var cacheWrite5mTokens: Int
    /// Cache writes with 1-hour TTL (2x input price).
    public var cacheWrite1hTokens: Int
    public var entryCount: Int
    public var costUSD: Double

    public var cacheWriteTokens: Int { self.cacheWrite5mTokens + self.cacheWrite1hTokens }

    public var totalTokens: Int {
        self.inputTokens + self.outputTokens + self.cacheReadTokens + self.cacheWriteTokens
    }

    public static let zero = TokenTotals()

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWrite5mTokens: Int = 0,
        cacheWrite1hTokens: Int = 0,
        entryCount: Int = 0,
        costUSD: Double = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWrite5mTokens = cacheWrite5mTokens
        self.cacheWrite1hTokens = cacheWrite1hTokens
        self.entryCount = entryCount
        self.costUSD = costUSD
    }

    public mutating func add(_ other: TokenTotals) {
        self.inputTokens += other.inputTokens
        self.outputTokens += other.outputTokens
        self.cacheReadTokens += other.cacheReadTokens
        self.cacheWrite5mTokens += other.cacheWrite5mTokens
        self.cacheWrite1hTokens += other.cacheWrite1hTokens
        self.entryCount += other.entryCount
        self.costUSD += other.costUSD
    }
}

/// One local-timezone day of usage.
public struct LedgerDay: Sendable, Equatable {
    /// Local day key, "yyyy-MM-dd".
    public let date: String
    public let totals: TokenTotals
    public let byModel: [String: TokenTotals]
    public let bySource: [UsageSource: TokenTotals]

    public init(date: String, totals: TokenTotals, byModel: [String: TokenTotals], bySource: [UsageSource: TokenTotals]) {
        self.date = date
        self.totals = totals
        self.byModel = byModel
        self.bySource = bySource
    }
}

/// A 5-hour rate-limit block, mirroring Anthropic's session windows
/// (hour resolution; a new block starts after a 5h+ gap in activity).
public struct LedgerBlock: Sendable, Equatable {
    /// Block start (UTC hour floor of first activity).
    public let start: Date
    /// Block end (start + 5h).
    public let end: Date
    /// Start of the last hour with activity inside this block.
    public let lastActivityHour: Date
    public let totals: TokenTotals
    public let byModel: [String: TokenTotals]

    public init(start: Date, end: Date, lastActivityHour: Date, totals: TokenTotals, byModel: [String: TokenTotals]) {
        self.start = start
        self.end = end
        self.lastActivityHour = lastActivityHour
        self.totals = totals
        self.byModel = byModel
    }

    public func isActive(at now: Date = Date()) -> Bool {
        now >= self.start && now < self.end
    }

    /// Tokens per minute since the block started.
    public func burnRate(at now: Date = Date()) -> Double {
        let minutes = max(1, now.timeIntervalSince(self.start) / 60)
        return Double(self.totals.totalTokens) / minutes
    }

    /// Cost per hour since the block started.
    public func costPerHour(at now: Date = Date()) -> Double {
        let hours = max(1.0 / 60, now.timeIntervalSince(self.start) / 3600)
        return self.totals.costUSD / hours
    }

    /// Projected total tokens if the current burn rate continues until the block ends.
    public func projectedTotalTokens(at now: Date = Date()) -> Int {
        guard self.isActive(at: now) else { return self.totals.totalTokens }
        let remainingMinutes = self.end.timeIntervalSince(now) / 60
        return self.totals.totalTokens + Int(self.burnRate(at: now) * remainingMinutes)
    }

    public func remainingDescription(at now: Date = Date()) -> String {
        let interval = max(0, self.end.timeIntervalSince(now))
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

/// Per-project usage rollup.
public struct LedgerProjectUsage: Sendable, Equatable {
    /// Full working-directory path of the project (from transcript `cwd`).
    public let path: String
    public let totals: TokenTotals

    public init(path: String, totals: TokenTotals) {
        self.path = path
        self.totals = totals
    }

    /// Short display name, e.g. "acme/website" for "/Users/dev/acme/website".
    public var displayName: String {
        let components = self.path.split(separator: "/")
        if components.count >= 2 {
            return components.suffix(2).joined(separator: "/")
        }
        return components.last.map(String.init) ?? self.path
    }
}

/// One day of activity for the heatmap (lightweight, long window).
public struct LedgerActivityDay: Sendable, Equatable {
    /// Local day key, "yyyy-MM-dd".
    public let date: String
    public let totalTokens: Int
    public let costUSD: Double

    public init(date: String, totalTokens: Int, costUSD: Double) {
        self.date = date
        self.totalTokens = totalTokens
        self.costUSD = costUSD
    }
}

/// Full drill-down for a single day (heatmap selection).
public struct LedgerDayDetail: Sendable, Equatable {
    public let date: String
    public let totals: TokenTotals
    public let byModel: [String: TokenTotals]
    public let bySource: [UsageSource: TokenTotals]
    public let byProject: [LedgerProjectUsage]
    /// Local hour of day (0–23) -> totals.
    public let byHour: [Int: TokenTotals]

    public init(
        date: String,
        totals: TokenTotals,
        byModel: [String: TokenTotals],
        bySource: [UsageSource: TokenTotals],
        byProject: [LedgerProjectUsage],
        byHour: [Int: TokenTotals]
    ) {
        self.date = date
        self.totals = totals
        self.byModel = byModel
        self.bySource = bySource
        self.byProject = byProject
        self.byHour = byHour
    }
}

/// Statistics about the most recent scan.
public struct LedgerScanStats: Sendable, Equatable {
    public let filesSeen: Int
    public let filesParsed: Int
    public let bytesParsed: Int64
    public let entriesAdded: Int
    public let duration: TimeInterval
    /// True while the first full ingest of historical transcripts is still running.
    public let isInitialScan: Bool

    public init(
        filesSeen: Int = 0,
        filesParsed: Int = 0,
        bytesParsed: Int64 = 0,
        entriesAdded: Int = 0,
        duration: TimeInterval = 0,
        isInitialScan: Bool = false
    ) {
        self.filesSeen = filesSeen
        self.filesParsed = filesParsed
        self.bytesParsed = bytesParsed
        self.entriesAdded = entriesAdded
        self.duration = duration
        self.isInitialScan = isInitialScan
    }
}

/// Full ledger snapshot for UI / CLI consumption.
/// All aggregates exclude `.probe` usage (Control Tower's own probing).
public struct LedgerSnapshot: Sendable {
    public let generatedAt: Date
    public let today: TokenTotals
    public let last7Days: TokenTotals
    public let last30Days: TokenTotals
    /// Last 30 local days, ascending by date.
    public let days: [LedgerDay]
    /// 30-day rollup by source app.
    public let bySource: [UsageSource: TokenTotals]
    /// 30-day rollup by model (normalized id).
    public let byModel: [String: TokenTotals]
    /// 30-day rollup by project, sorted by cost descending.
    public let byProject: [LedgerProjectUsage]
    /// The currently active 5h block, if any activity is in flight.
    public let currentBlock: LedgerBlock?
    /// Most recent blocks (including the active one), newest last. Capped.
    public let recentBlocks: [LedgerBlock]
    /// Daily activity for the heatmap (~6 months), ascending by date.
    public let dailyActivity: [LedgerActivityDay]
    public let stats: LedgerScanStats

    public init(
        generatedAt: Date = Date(),
        today: TokenTotals = .zero,
        last7Days: TokenTotals = .zero,
        last30Days: TokenTotals = .zero,
        days: [LedgerDay] = [],
        bySource: [UsageSource: TokenTotals] = [:],
        byModel: [String: TokenTotals] = [:],
        byProject: [LedgerProjectUsage] = [],
        currentBlock: LedgerBlock? = nil,
        recentBlocks: [LedgerBlock] = [],
        dailyActivity: [LedgerActivityDay] = [],
        stats: LedgerScanStats = LedgerScanStats()
    ) {
        self.generatedAt = generatedAt
        self.today = today
        self.last7Days = last7Days
        self.last30Days = last30Days
        self.days = days
        self.bySource = bySource
        self.byModel = byModel
        self.byProject = byProject
        self.currentBlock = currentBlock
        self.recentBlocks = recentBlocks
        self.dailyActivity = dailyActivity
        self.stats = stats
    }
}
