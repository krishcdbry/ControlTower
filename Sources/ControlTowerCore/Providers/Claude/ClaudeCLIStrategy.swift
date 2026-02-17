import Foundation

/// Fetch Claude usage via PTY-based CLI scraping.
/// Runs `claude` in a PTY, sends `/usage`, and parses the TUI output.
public struct ClaudeCLIStrategy: ProviderFetchStrategy, Sendable {
    public let id = "claude-cli"
    public let kind = ProviderFetchKind.cli

    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 20.0) {
        self.timeout = timeout
    }

    public func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        return Self.resolvedBinaryPath() != nil
    }

    public func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let binaryPath = Self.resolvedBinaryPath() else {
            throw ProviderFetchError.commandFailed("Claude CLI not found")
        }

        // Capture /usage output via PTY
        var usageText = try await Self.capture(subcommand: "/usage", binary: binaryPath, timeout: timeout)

        // Check if output looks relevant, retry once if not
        if !Self.usageOutputLooksRelevant(usageText) {
            usageText = try await Self.capture(subcommand: "/usage", binary: binaryPath, timeout: max(timeout, 14))
        }

        // Optionally capture /status for account info
        let statusText = try? await Self.capture(subcommand: "/status", binary: binaryPath, timeout: min(timeout, 12))

        // Reset session after capturing
        await ClaudeCLISession.shared.reset()

        // Parse the captured output
        let snapshot = try Self.parseUsageOutput(usageText: usageText, statusText: statusText)
        return makeResult(usage: snapshot, sourceLabel: "cli")
    }

    public func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        return true
    }

    // MARK: - PTY Capture

    private static func capture(subcommand: String, binary: String, timeout: TimeInterval) async throws -> String {
        let stopOnSubstrings = subcommand == "/usage"
            ? [
                "Current week (all models)",
                "Current week (Opus)",
                "Current week (Sonnet only)",
                "Current week (Sonnet)",
                "Current session",
                "Failed to load usage data",
            ]
            : []
        let idleTimeout: TimeInterval? = subcommand == "/usage" ? nil : 3.0
        let sendEnterEvery: TimeInterval? = subcommand == "/usage" ? 0.8 : nil

        do {
            return try await ClaudeCLISession.shared.capture(
                subcommand: subcommand,
                binary: binary,
                timeout: timeout,
                idleTimeout: idleTimeout,
                stopOnSubstrings: stopOnSubstrings,
                settleAfterStop: subcommand == "/usage" ? 2.0 : 0.25,
                sendEnterEvery: sendEnterEvery
            )
        } catch ClaudeCLISession.SessionError.processExited {
            await ClaudeCLISession.shared.reset()
            throw ProviderFetchError.commandFailed("Claude CLI session exited unexpectedly")
        } catch ClaudeCLISession.SessionError.timedOut {
            throw ProviderFetchError.commandFailed("Claude CLI timed out")
        } catch ClaudeCLISession.SessionError.launchFailed(let msg) {
            throw ProviderFetchError.commandFailed("Failed to launch Claude CLI: \(msg)")
        } catch {
            await ClaudeCLISession.shared.reset()
            throw error
        }
    }

    private static func usageOutputLooksRelevant(_ text: String) -> Bool {
        let normalized = TextParsing.stripANSICodes(text).lowercased().filter { !$0.isWhitespace }
        return normalized.contains("currentsession")
            || normalized.contains("currentweek")
            || normalized.contains("loadingusage")
            || normalized.contains("failedtoloadusagedata")
    }

    // MARK: - Binary Resolution

    private static func resolvedBinaryPath() -> String? {
        let paths = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin/claude",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.claude/local/claude",
        ]

        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Try which command
        if let url = CLIExecutor.findExecutable("claude") {
            return url.path
        }

        return nil
    }

    // MARK: - Output Parsing

    private static func parseUsageOutput(usageText: String, statusText: String?) throws -> UsageSnapshot {
        let clean = TextParsing.stripANSICodes(usageText)
        let statusClean = statusText.map { TextParsing.stripANSICodes($0) }

        guard !clean.isEmpty else {
            throw ProviderFetchError.parseError("Empty usage output")
        }

        // Check for usage errors
        if let usageError = extractUsageError(text: clean) {
            throw ProviderFetchError.apiError(usageError)
        }

        // Trim to the latest usage panel
        let usagePanelText = trimToLatestUsagePanel(clean) ?? clean
        let lines = usagePanelText.components(separatedBy: .newlines)
        let normalizedLines = lines.map { TextParsing.normalizedForSearch($0) }

        // Extract session percentage (inverted - CLI shows "X% left")
        var sessionPct = extractPercent(labelSubstring: "current session", lines: lines, normalizedLines: normalizedLines)
        var weeklyPct = extractPercent(labelSubstring: "current week (all models)", lines: lines, normalizedLines: normalizedLines)
        var opusPct = extractPercent(
            labelSubstrings: ["current week (opus)", "current week (sonnet only)", "current week (sonnet)"],
            lines: lines,
            normalizedLines: normalizedLines
        )

        // Fallback: ordered percent scraping
        let compactContext = usagePanelText.lowercased().filter { !$0.isWhitespace }
        let hasWeeklyLabel = compactContext.contains("currentweek")
        let hasOpusLabel = compactContext.contains("opus") || compactContext.contains("sonnet")

        if sessionPct == nil || (hasWeeklyLabel && weeklyPct == nil) || (hasOpusLabel && opusPct == nil) {
            let ordered = allPercents(usagePanelText)
            if sessionPct == nil, ordered.indices.contains(0) { sessionPct = ordered[0] }
            if hasWeeklyLabel, weeklyPct == nil, ordered.indices.contains(1) { weeklyPct = ordered[1] }
            if hasOpusLabel, opusPct == nil, ordered.indices.contains(2) { opusPct = ordered[2] }
        }

        guard let sessionPercentLeft = sessionPct else {
            throw ProviderFetchError.parseError("Missing Current session in usage output")
        }

        // Extract reset descriptions
        let sessionReset = extractReset(labelSubstring: "current session", lines: lines, normalizedLines: normalizedLines)
        let weeklyReset = hasWeeklyLabel
            ? extractReset(labelSubstring: "current week (all models)", lines: lines, normalizedLines: normalizedLines)
            : nil
        let opusReset = hasOpusLabel
            ? extractReset(
                labelSubstrings: ["current week (opus)", "current week (sonnet only)", "current week (sonnet)"],
                lines: lines,
                normalizedLines: normalizedLines
            )
            : nil

        // Extract identity
        let identity = extractIdentity(usageText: clean, statusText: statusClean)

        // Convert "percent left" to "percent used" for our model
        // The CLI shows "X% left", we store "X% used"
        let sessionUsedPercent = 100.0 - Double(sessionPercentLeft)
        let weeklyUsedPercent = weeklyPct.map { 100.0 - Double($0) }
        let opusUsedPercent = opusPct.map { 100.0 - Double($0) }

        // Build rate windows
        let primary = RateWindow(
            usedPercent: sessionUsedPercent,
            windowMinutes: 5 * 60,
            resetsAt: parseResetDate(from: sessionReset),
            resetDescription: sessionReset,
            label: "Session"
        )

        let secondary = weeklyUsedPercent.map { pct in
            RateWindow(
                usedPercent: pct,
                windowMinutes: 7 * 24 * 60,
                resetsAt: parseResetDate(from: weeklyReset),
                resetDescription: weeklyReset,
                label: "Weekly"
            )
        }

        let tertiary = opusUsedPercent.map { pct in
            RateWindow(
                usedPercent: pct,
                windowMinutes: 7 * 24 * 60,
                resetsAt: parseResetDate(from: opusReset),
                resetDescription: opusReset,
                label: opusPct != nil && compactContext.contains("opus") ? "Opus" : "Sonnet"
            )
        }

        return UsageSnapshot(
            providerID: .claude,
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            cost: nil,
            updatedAt: Date(),
            identity: identity
        )
    }

    // MARK: - Parsing Helpers

    private static func extractPercent(labelSubstring: String, lines: [String], normalizedLines: [String]) -> Int? {
        let label = TextParsing.normalizedForSearch(labelSubstring)
        for (idx, normalizedLine) in normalizedLines.enumerated() where normalizedLine.contains(label) {
            let window = lines.dropFirst(idx).prefix(12)
            for candidate in window {
                if let pct = percentFromLine(candidate) { return pct }
            }
        }
        return nil
    }

    private static func extractPercent(labelSubstrings: [String], lines: [String], normalizedLines: [String]) -> Int? {
        for label in labelSubstrings {
            if let value = extractPercent(labelSubstring: label, lines: lines, normalizedLines: normalizedLines) {
                return value
            }
        }
        return nil
    }

    private static func percentFromLine(_ line: String, assumeRemainingWhenUnclear: Bool = false) -> Int? {
        // Skip status context lines (model selection bars)
        if isLikelyStatusContextLine(line) { return nil }

        let pattern = #"([0-9]{1,3}(?:\.[0-9]+)?)\s*%"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges >= 2,
              let valRange = Range(match.range(at: 1), in: line) else { return nil }

        let rawVal = Double(line[valRange]) ?? 0
        let clamped = max(0, min(100, rawVal))
        let lower = line.lowercased()

        // Determine if this is "used" or "remaining" percentage
        let usedKeywords = ["used", "spent", "consumed"]
        let remainingKeywords = ["left", "remaining", "available"]

        if usedKeywords.contains(where: lower.contains) {
            // If it says "used", invert to get "remaining"
            return Int(max(0, min(100, 100 - clamped)).rounded())
        }
        if remainingKeywords.contains(where: lower.contains) {
            return Int(clamped.rounded())
        }
        return assumeRemainingWhenUnclear ? Int(clamped.rounded()) : nil
    }

    private static func isLikelyStatusContextLine(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        let lower = line.lowercased()
        let modelTokens = ["opus", "sonnet", "haiku", "default"]
        return modelTokens.contains(where: lower.contains)
    }

    private static func allPercents(_ text: String) -> [Int] {
        let lines = text.components(separatedBy: .newlines)
        let normalized = text.lowercased().filter { !$0.isWhitespace }
        let hasUsageWindows = normalized.contains("currentsession") || normalized.contains("currentweek")
        let hasLoading = normalized.contains("loadingusage")
        let hasUsagePercentKeywords = normalized.contains("used") || normalized.contains("left")
            || normalized.contains("remaining") || normalized.contains("available")

        guard hasUsageWindows || hasLoading else { return [] }
        if hasLoading && !hasUsageWindows { return [] }
        guard hasUsagePercentKeywords else { return [] }

        return lines.compactMap { percentFromLine($0, assumeRemainingWhenUnclear: false) }
    }

    private static func trimToLatestUsagePanel(_ text: String) -> String? {
        guard let settingsRange = text.range(of: "Settings:", options: [.caseInsensitive, .backwards]) else {
            return nil
        }
        let tail = text[settingsRange.lowerBound...]
        guard tail.range(of: "Usage", options: .caseInsensitive) != nil else { return nil }

        let lower = tail.lowercased()
        let hasPercent = lower.contains("%")
        let hasUsageWords = lower.contains("used") || lower.contains("left") || lower.contains("remaining")
            || lower.contains("available")
        let hasLoading = lower.contains("loading usage")

        guard (hasPercent && hasUsageWords) || hasLoading else { return nil }
        return String(tail)
    }

    private static func extractReset(labelSubstring: String, lines: [String], normalizedLines: [String]) -> String? {
        let label = TextParsing.normalizedForSearch(labelSubstring)
        for (idx, normalizedLine) in normalizedLines.enumerated() where normalizedLine.contains(label) {
            let window = lines.dropFirst(idx).prefix(14)
            for candidate in window {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = TextParsing.normalizedForSearch(trimmed)
                if normalized.hasPrefix("current "), !normalized.contains(label) { break }
                if let reset = resetFromLine(candidate) { return reset }
            }
        }
        return nil
    }

    private static func extractReset(labelSubstrings: [String], lines: [String], normalizedLines: [String]) -> String? {
        for label in labelSubstrings {
            if let value = extractReset(labelSubstring: label, lines: lines, normalizedLines: normalizedLines) {
                return value
            }
        }
        return nil
    }

    private static func resetFromLine(_ line: String) -> String? {
        guard let range = line.range(of: "Resets", options: [.caseInsensitive]) else { return nil }
        let raw = String(line[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanResetLine(raw)
    }

    private static func cleanResetLine(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " )"))
        let openCount = cleaned.count(where: { $0 == "(" })
        let closeCount = cleaned.count(where: { $0 == ")" })
        if openCount > closeCount { cleaned.append(")") }
        return cleaned
    }

    private static func extractUsageError(text: String) -> String? {
        let lower = text.lowercased()

        if lower.contains("do you trust the files in this folder?"), !lower.contains("current session") {
            return "Claude CLI is waiting for a folder trust prompt. Run `claude` once and choose 'Yes, proceed', then retry."
        }
        if lower.contains("token_expired") || lower.contains("token has expired") {
            return "Claude CLI token expired. Run `claude login` to refresh."
        }
        if lower.contains("authentication_error") {
            return "Claude CLI authentication error. Run `claude login`."
        }
        if lower.contains("failed to load usage data") {
            return "Claude CLI could not load usage data. Open the CLI and retry `/usage`."
        }
        return nil
    }

    private static func extractIdentity(usageText: String, statusText: String?) -> ProviderIdentity? {
        let emailPatterns = [
            #"(?i)Account:\s+([^\s@]+@[^\s@]+)"#,
            #"(?i)Email:\s+([^\s@]+@[^\s@]+)"#,
            #"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
        ]

        var email: String?
        for pattern in emailPatterns {
            if let found = TextParsing.extractFirst(pattern: pattern, text: usageText) {
                email = found
                break
            }
            if let status = statusText, let found = TextParsing.extractFirst(pattern: pattern, text: status) {
                email = found
                break
            }
        }

        let orgPatterns = [
            #"(?i)Org:\s*(.+)"#,
            #"(?i)Organization:\s*(.+)"#,
        ]
        var org: String?
        for pattern in orgPatterns {
            if let found = TextParsing.extractFirst(pattern: pattern, text: usageText) {
                org = found
                break
            }
            if let status = statusText, let found = TextParsing.extractFirst(pattern: pattern, text: status) {
                org = found
                break
            }
        }

        // Suppress org if it's just the email prefix
        if let email, let organization = org?.trimmingCharacters(in: .whitespacesAndNewlines),
           organization.lowercased().hasPrefix(email.lowercased()) {
            org = nil
        }

        let login = extractLoginMethod(text: statusText ?? "") ?? extractLoginMethod(text: usageText)

        guard email != nil || org != nil || login != nil else { return nil }

        return ProviderIdentity(
            email: email,
            organization: org,
            plan: login,
            authMethod: "cli"
        )
    }

    private static func extractLoginMethod(text: String) -> String? {
        guard !text.isEmpty else { return nil }

        if let explicit = TextParsing.extractFirst(pattern: #"(?i)login\s+method:\s*(.+)"#, text: text) {
            return cleanPlan(explicit)
        }

        // Capture "Claude <...>" phrases (Max/Pro/Ultra/Team)
        let planPattern = #"(?i)(claude\s+[a-z0-9][a-z0-9\s._-]{0,24})"#
        var candidates: [String] = []
        if let regex = try? NSRegularExpression(pattern: planPattern, options: []) {
            let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
            regex.enumerateMatches(in: text, options: [], range: nsrange) { match, _, _ in
                guard let match,
                      match.numberOfRanges >= 2,
                      let r = Range(match.range(at: 1), in: text) else { return }
                let raw = String(text[r])
                candidates.append(cleanPlan(raw))
            }
        }

        // Filter out "Claude Code" version strings
        if let plan = candidates.first(where: { cand in
            let lower = cand.lowercased()
            return !lower.contains("code v") && !lower.contains("code version") && !lower.contains("code")
        }) {
            return plan
        }
        return nil
    }

    private static func cleanPlan(_ text: String) -> String {
        var cleaned = TextParsing.stripANSICodes(text)
        // Remove stray bracketed codes
        let pattern = #"\[\d+m"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: ""
            )
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Date Parsing

    private static func parseResetDate(from text: String?) -> Date? {
        guard let raw = normalizeResetInput(text) else { return nil }
        let (cleanText, timeZone) = raw

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone ?? TimeZone.current
        formatter.defaultDate = Date()

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone

        // Try datetime formats
        let dateTimeFormats = [
            "MMM d, h:mma", "MMM d, h:mm a", "MMM d h:mma", "MMM d h:mm a",
            "MMM d, HH:mm", "MMM d HH:mm", "MMM d, ha", "MMM d, h a", "MMM d ha", "MMM d h a"
        ]
        for format in dateTimeFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleanText) {
                var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                comps.second = 0
                return calendar.date(from: comps)
            }
        }

        // Try time-only formats
        let timeFormats = ["h:mma", "h:mm a", "HH:mm", "H:mm", "ha", "h a"]
        for format in timeFormats {
            formatter.dateFormat = format
            if let time = formatter.date(from: cleanText) {
                let comps = calendar.dateComponents([.hour, .minute], from: time)
                guard let anchored = calendar.date(
                    bySettingHour: comps.hour ?? 0,
                    minute: comps.minute ?? 0,
                    second: 0,
                    of: Date()
                ) else { continue }
                if anchored >= Date() { return anchored }
                return calendar.date(byAdding: .day, value: 1, to: anchored)
            }
        }

        return nil
    }

    private static func normalizeResetInput(_ text: String?) -> (String, TimeZone?)? {
        guard var raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        raw = raw.replacingOccurrences(of: #"(?i)^resets?:?\s*"#, with: "", options: .regularExpression)
        raw = raw.replacingOccurrences(of: " at ", with: " ", options: .caseInsensitive)
        raw = raw.replacingOccurrences(of: #"(?<=\d)\.(\d{2})\b"#, with: ":$1", options: .regularExpression)

        var timeZone: TimeZone?
        if let tzRange = raw.range(of: #"\(([^)]+)\)"#, options: .regularExpression) {
            let tzID = String(raw[tzRange]).trimmingCharacters(in: CharacterSet(charactersIn: "() "))
            raw.removeSubrange(tzRange)
            raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            timeZone = TimeZone(identifier: tzID)
        }

        raw = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : (raw, timeZone)
    }
}
