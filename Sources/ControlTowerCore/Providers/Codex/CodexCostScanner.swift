import Foundation

/// Scans Codex CLI JSONL logs to calculate token usage and costs.
public actor CodexCostScanner {
    public static let shared = CodexCostScanner()

    /// Daily cost summary
    public struct DailyCost: Sendable, Equatable {
        public let date: String // YYYY-MM-DD
        public let inputTokens: Int
        public let cachedInputTokens: Int
        public let outputTokens: Int
        public let reasoningTokens: Int
        public let costUSD: Double

        public var totalTokens: Int {
            inputTokens + cachedInputTokens + outputTokens + reasoningTokens
        }

        public init(
            date: String,
            inputTokens: Int,
            cachedInputTokens: Int,
            outputTokens: Int,
            reasoningTokens: Int,
            costUSD: Double
        ) {
            self.date = date
            self.inputTokens = inputTokens
            self.cachedInputTokens = cachedInputTokens
            self.outputTokens = outputTokens
            self.reasoningTokens = reasoningTokens
            self.costUSD = costUSD
        }
    }

    /// Cost snapshot with aggregated data
    public struct CostSnapshot: Sendable {
        public let todayCostUSD: Double
        public let todayTokens: Int
        public let last7DaysCostUSD: Double
        public let last7DaysTokens: Int
        public let last30DaysCostUSD: Double
        public let last30DaysTokens: Int
        public let dailyCosts: [DailyCost]
        public let updatedAt: Date

        public init(
            todayCostUSD: Double = 0,
            todayTokens: Int = 0,
            last7DaysCostUSD: Double = 0,
            last7DaysTokens: Int = 0,
            last30DaysCostUSD: Double = 0,
            last30DaysTokens: Int = 0,
            dailyCosts: [DailyCost] = [],
            updatedAt: Date = Date()
        ) {
            self.todayCostUSD = todayCostUSD
            self.todayTokens = todayTokens
            self.last7DaysCostUSD = last7DaysCostUSD
            self.last7DaysTokens = last7DaysTokens
            self.last30DaysCostUSD = last30DaysCostUSD
            self.last30DaysTokens = last30DaysTokens
            self.dailyCosts = dailyCosts
            self.updatedAt = updatedAt
        }
    }

    private var cachedSnapshot: CostSnapshot?
    private var lastScanAt: Date?
    private let minScanInterval: TimeInterval = 60

    public init() {}

    /// Scan logs and return cost snapshot
    public func scan(forceRefresh: Bool = false) async -> CostSnapshot {
        let now = Date()

        if !forceRefresh,
           let cached = cachedSnapshot,
           let lastScan = lastScanAt,
           now.timeIntervalSince(lastScan) < minScanInterval
        {
            return cached
        }

        let snapshot = await Self.scanLogs(now: now)
        self.cachedSnapshot = snapshot
        self.lastScanAt = now
        return snapshot
    }

    public func clearCache() {
        self.cachedSnapshot = nil
        self.lastScanAt = nil
    }

    // MARK: - Log Scanning

    private static func scanLogs(now: Date) async -> CostSnapshot {
        let sessionsRoot = codexSessionsRoot()

        guard FileManager.default.fileExists(atPath: sessionsRoot.path) else {
            return CostSnapshot(updatedAt: now)
        }

        let calendar = Calendar.current
        let todayKey = dayKey(from: now)
        let last7Start = calendar.date(byAdding: .day, value: -6, to: now)!
        let last30Start = calendar.date(byAdding: .day, value: -29, to: now)!
        let last7StartKey = dayKey(from: last7Start)
        let last30StartKey = dayKey(from: last30Start)

        // Find all JSONL files
        let allFiles = findJSONLFiles(in: sessionsRoot)

        // Parse and aggregate by day
        var dailyData: [String: DailyAggregator] = [:]

        for fileURL in allFiles {
            parseJSONLFile(fileURL: fileURL, sinceKey: last30StartKey) { entry in
                let dayKey = entry.dayKey
                if dailyData[dayKey] == nil {
                    dailyData[dayKey] = DailyAggregator(date: dayKey)
                }
                dailyData[dayKey]?.add(entry)
            }
        }

        // Build daily costs
        let sortedDays = dailyData.keys.sorted()
        var dailyCosts: [DailyCost] = []

        var todayCost: Double = 0
        var todayTokens: Int = 0
        var last7Cost: Double = 0
        var last7Tokens: Int = 0
        var last30Cost: Double = 0
        var last30Tokens: Int = 0

        for dayKey in sortedDays {
            guard dayKey >= last30StartKey else { continue }
            guard let agg = dailyData[dayKey] else { continue }

            let daily = agg.build()
            dailyCosts.append(daily)

            last30Cost += daily.costUSD
            last30Tokens += daily.totalTokens

            if dayKey >= last7StartKey {
                last7Cost += daily.costUSD
                last7Tokens += daily.totalTokens
            }

            if dayKey == todayKey {
                todayCost = daily.costUSD
                todayTokens = daily.totalTokens
            }
        }

        return CostSnapshot(
            todayCostUSD: todayCost,
            todayTokens: todayTokens,
            last7DaysCostUSD: last7Cost,
            last7DaysTokens: last7Tokens,
            last30DaysCostUSD: last30Cost,
            last30DaysTokens: last30Tokens,
            dailyCosts: dailyCosts,
            updatedAt: now
        )
    }

    // MARK: - File Discovery

    private static func codexSessionsRoot() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser

        if let envPath = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !envPath.isEmpty
        {
            return URL(fileURLWithPath: envPath).appendingPathComponent("sessions", isDirectory: true)
        }

        return home.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    private static func findJSONLFiles(in root: URL) -> [URL] {
        var files: [URL] = []

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return files }

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "jsonl" {
                files.append(fileURL)
            }
        }

        return files
    }

    // MARK: - JSONL Parsing

    private struct UsageEntry {
        let dayKey: String
        let inputTokens: Int
        let cachedInputTokens: Int
        let outputTokens: Int
        let reasoningTokens: Int
    }

    private static func parseJSONLFile(
        fileURL: URL,
        sinceKey: String,
        onEntry: (UsageEntry) -> Void
    ) {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            return
        }

        // Track seen timestamps to deduplicate (Codex can emit multiple token_count per turn)
        var lastSeenUsage: (inputTokens: Int, outputTokens: Int)?

        for line in content.components(separatedBy: .newlines) {
            guard !line.isEmpty,
                  line.contains("\"type\":\"token_count\""),
                  line.contains("\"total_token_usage\"") else {
                continue
            }

            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let timestamp = obj["timestamp"] as? String,
                  let dayKey = dayKeyFromTimestamp(timestamp),
                  dayKey >= sinceKey else {
                continue
            }

            guard let payload = obj["payload"] as? [String: Any],
                  let info = payload["info"] as? [String: Any],
                  let totalUsage = info["total_token_usage"] as? [String: Any] else {
                continue
            }

            let inputTokens = (totalUsage["input_tokens"] as? Int) ?? 0
            let cachedInputTokens = (totalUsage["cached_input_tokens"] as? Int) ?? 0
            let outputTokens = (totalUsage["output_tokens"] as? Int) ?? 0
            let reasoningTokens = (totalUsage["reasoning_output_tokens"] as? Int) ?? 0

            // Deduplicate: Codex emits cumulative usage, only count if changed
            let currentUsage = (inputTokens, outputTokens)
            if let last = lastSeenUsage, last == currentUsage {
                continue
            }
            lastSeenUsage = currentUsage

            guard inputTokens > 0 || outputTokens > 0 else { continue }

            onEntry(UsageEntry(
                dayKey: dayKey,
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: outputTokens,
                reasoningTokens: reasoningTokens
            ))
        }
    }

    // MARK: - Date Helpers

    private static func dayKey(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    private static func dayKeyFromTimestamp(_ timestamp: String) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var date = formatter.date(from: timestamp)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: timestamp)
        }

        guard let parsedDate = date else { return nil }
        return dayKey(from: parsedDate)
    }

    // MARK: - Aggregation

    private class DailyAggregator {
        let date: String
        var inputTokens = 0
        var cachedInputTokens = 0
        var outputTokens = 0
        var reasoningTokens = 0

        init(date: String) {
            self.date = date
        }

        func add(_ entry: UsageEntry) {
            // For Codex, each entry represents cumulative session usage
            // We take the max per session (since we deduplicate in parsing)
            inputTokens += entry.inputTokens
            cachedInputTokens += entry.cachedInputTokens
            outputTokens += entry.outputTokens
            reasoningTokens += entry.reasoningTokens
        }

        func build() -> DailyCost {
            let cost = CodexPricing.cost(
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: outputTokens,
                reasoningTokens: reasoningTokens
            )

            return DailyCost(
                date: date,
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: outputTokens,
                reasoningTokens: reasoningTokens,
                costUSD: cost
            )
        }
    }
}

// MARK: - Codex Pricing (OpenAI o3/o4-mini pricing estimates)

public enum CodexPricing {
    // OpenAI o4-mini pricing (per 1M tokens) - estimated
    private static let inputPricePerMillion: Double = 1.10
    private static let cachedInputPricePerMillion: Double = 0.275 // 75% discount
    private static let outputPricePerMillion: Double = 4.40
    private static let reasoningPricePerMillion: Double = 4.40

    public static func cost(
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int
    ) -> Double {
        let inputCost = Double(inputTokens) * inputPricePerMillion / 1_000_000
        let cachedCost = Double(cachedInputTokens) * cachedInputPricePerMillion / 1_000_000
        let outputCost = Double(outputTokens) * outputPricePerMillion / 1_000_000
        let reasoningCost = Double(reasoningTokens) * reasoningPricePerMillion / 1_000_000

        return inputCost + cachedCost + outputCost + reasoningCost
    }
}
