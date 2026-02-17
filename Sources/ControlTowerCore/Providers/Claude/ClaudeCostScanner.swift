import Foundation

/// Scans Claude CLI JSONL logs to calculate token usage and costs.
public actor ClaudeCostScanner {
    public static let shared = ClaudeCostScanner()

    /// Daily cost summary
    public struct DailyCost: Sendable, Equatable {
        public let date: String // YYYY-MM-DD
        public let inputTokens: Int
        public let outputTokens: Int
        public let cacheReadTokens: Int
        public let cacheWriteTokens: Int
        public let costUSD: Double
        public let modelBreakdown: [String: ModelUsage]

        public var totalTokens: Int {
            inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
        }

        public init(
            date: String,
            inputTokens: Int,
            outputTokens: Int,
            cacheReadTokens: Int,
            cacheWriteTokens: Int,
            costUSD: Double,
            modelBreakdown: [String: ModelUsage]
        ) {
            self.date = date
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.costUSD = costUSD
            self.modelBreakdown = modelBreakdown
        }

        public struct ModelUsage: Sendable, Equatable {
            public let inputTokens: Int
            public let outputTokens: Int
            public let cacheReadTokens: Int
            public let cacheWriteTokens: Int
            public let costUSD: Double

            public var totalTokens: Int {
                inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
            }

            public init(
                inputTokens: Int,
                outputTokens: Int,
                cacheReadTokens: Int,
                cacheWriteTokens: Int,
                costUSD: Double
            ) {
                self.inputTokens = inputTokens
                self.outputTokens = outputTokens
                self.cacheReadTokens = cacheReadTokens
                self.cacheWriteTokens = cacheWriteTokens
                self.costUSD = costUSD
            }
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
    private let minScanInterval: TimeInterval = 60 // Don't rescan more than once per minute

    public init() {}

    /// Scan logs and return cost snapshot
    public func scan(forceRefresh: Bool = false) async -> CostSnapshot {
        let now = Date()

        // Return cached if recent
        if !forceRefresh,
           let cached = cachedSnapshot,
           let lastScan = lastScanAt,
           now.timeIntervalSince(lastScan) < minScanInterval
        {
            return cached
        }

        // Scan the logs
        let snapshot = await Self.scanLogs(now: now)
        self.cachedSnapshot = snapshot
        self.lastScanAt = now
        return snapshot
    }

    /// Clear cache
    public func clearCache() {
        self.cachedSnapshot = nil
        self.lastScanAt = nil
    }

    // MARK: - Log Scanning

    private static func scanLogs(now: Date) async -> CostSnapshot {
        let projectsRoots = Self.claudeProjectsRoots()

        guard !projectsRoots.isEmpty else {
            return CostSnapshot(updatedAt: now)
        }

        // Calculate date range
        let calendar = Calendar.current
        let todayKey = Self.dayKey(from: now)
        let last7Start = calendar.date(byAdding: .day, value: -6, to: now)!
        let last30Start = calendar.date(byAdding: .day, value: -29, to: now)!
        let last7StartKey = Self.dayKey(from: last7Start)
        let last30StartKey = Self.dayKey(from: last30Start)

        // Collect all JSONL files
        var allFiles: [URL] = []
        for root in projectsRoots {
            allFiles.append(contentsOf: Self.findJSONLFiles(in: root))
        }

        // Parse files and aggregate by day
        var dailyData: [String: DailyAggregator] = [:]

        for fileURL in allFiles {
            Self.parseJSONLFile(fileURL: fileURL, sinceKey: last30StartKey) { entry in
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

    private static func claudeProjectsRoots() -> [URL] {
        var roots: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser

        // Check environment variable
        if let envPath = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !envPath.isEmpty
        {
            for part in envPath.split(separator: ",") {
                let path = String(part).trimmingCharacters(in: .whitespaces)
                let url = URL(fileURLWithPath: path)
                if url.lastPathComponent == "projects" {
                    roots.append(url)
                } else {
                    roots.append(url.appendingPathComponent("projects", isDirectory: true))
                }
            }
        } else {
            // Default locations
            roots.append(home.appendingPathComponent(".claude/projects", isDirectory: true))
            roots.append(home.appendingPathComponent(".config/claude/projects", isDirectory: true))
        }

        return roots.filter { FileManager.default.fileExists(atPath: $0.path) }
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
        let model: String
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheWriteTokens: Int
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

        // Track seen message+request IDs to deduplicate streaming chunks within a JSONL file.
        // Claude emits multiple lines per message with cumulative usage, so we only count once.
        var seenKeys: Set<String> = []

        for line in content.components(separatedBy: .newlines) {
            guard !line.isEmpty,
                  line.contains("\"type\":\"assistant\""),
                  line.contains("\"usage\"") else {
                continue
            }

            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = obj["type"] as? String,
                  type == "assistant" else {
                continue
            }

            guard let timestamp = obj["timestamp"] as? String,
                  let dayKey = Self.dayKeyFromTimestamp(timestamp),
                  dayKey >= sinceKey else {
                continue
            }

            guard let message = obj["message"] as? [String: Any],
                  let model = message["model"] as? String,
                  let usage = message["usage"] as? [String: Any] else {
                continue
            }

            // Deduplicate by message.id + requestId (streaming chunks have same usage)
            let messageId = message["id"] as? String
            let requestId = obj["requestId"] as? String
            if let messageId, let requestId {
                let key = "\(messageId):\(requestId)"
                if seenKeys.contains(key) { continue }
                seenKeys.insert(key)
            }
            // Older logs omit IDs; treat each line as distinct to avoid dropping usage.

            let inputTokens = (usage["input_tokens"] as? Int) ?? 0
            let outputTokens = (usage["output_tokens"] as? Int) ?? 0
            let cacheReadTokens = (usage["cache_read_input_tokens"] as? Int) ?? 0
            let cacheWriteTokens = (usage["cache_creation_input_tokens"] as? Int) ?? 0

            guard inputTokens > 0 || outputTokens > 0 else { continue }

            onEntry(UsageEntry(
                dayKey: dayKey,
                model: model,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens
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

    /// Convert ISO8601 timestamp to local day key
    /// Properly handles UTC timestamps like "2026-02-16T19:23:05.712Z" -> local date
    private static func dayKeyFromTimestamp(_ timestamp: String) -> String? {
        // Parse ISO8601 timestamp and convert to local timezone
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var date = formatter.date(from: timestamp)
        if date == nil {
            // Try without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: timestamp)
        }

        guard let parsedDate = date else { return nil }

        // Convert to local day key
        return dayKey(from: parsedDate)
    }

    // MARK: - Aggregation

    private class DailyAggregator {
        let date: String
        var models: [String: ModelAggregator] = [:]

        init(date: String) {
            self.date = date
        }

        func add(_ entry: UsageEntry) {
            if models[entry.model] == nil {
                models[entry.model] = ModelAggregator()
            }
            models[entry.model]?.add(entry)
        }

        func build() -> DailyCost {
            var totalInput = 0
            var totalOutput = 0
            var totalCacheRead = 0
            var totalCacheWrite = 0
            var totalCost: Double = 0
            var breakdown: [String: DailyCost.ModelUsage] = [:]

            for (model, agg) in models {
                let cost = ClaudePricing.cost(
                    model: model,
                    inputTokens: agg.inputTokens,
                    outputTokens: agg.outputTokens,
                    cacheReadTokens: agg.cacheReadTokens,
                    cacheWriteTokens: agg.cacheWriteTokens
                )

                breakdown[model] = DailyCost.ModelUsage(
                    inputTokens: agg.inputTokens,
                    outputTokens: agg.outputTokens,
                    cacheReadTokens: agg.cacheReadTokens,
                    cacheWriteTokens: agg.cacheWriteTokens,
                    costUSD: cost
                )

                totalInput += agg.inputTokens
                totalOutput += agg.outputTokens
                totalCacheRead += agg.cacheReadTokens
                totalCacheWrite += agg.cacheWriteTokens
                totalCost += cost
            }

            return DailyCost(
                date: date,
                inputTokens: totalInput,
                outputTokens: totalOutput,
                cacheReadTokens: totalCacheRead,
                cacheWriteTokens: totalCacheWrite,
                costUSD: totalCost,
                modelBreakdown: breakdown
            )
        }
    }

    private class ModelAggregator {
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cacheWriteTokens = 0

        func add(_ entry: UsageEntry) {
            inputTokens += entry.inputTokens
            outputTokens += entry.outputTokens
            cacheReadTokens += entry.cacheReadTokens
            cacheWriteTokens += entry.cacheWriteTokens
        }
    }
}
