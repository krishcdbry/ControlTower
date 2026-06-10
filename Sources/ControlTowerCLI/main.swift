import ControlTowerCore
import Foundation

/// Control Tower CLI entry point.
@main
struct ControlTowerCLI {
    static func main() async {
        let arguments = CommandLine.arguments.dropFirst()

        guard let command = arguments.first else {
            Self.printUsage()
            return
        }

        switch command {
        case "status", "s":
            await Self.showStatus()
        case "tokens", "t":
            await Self.showTokens(arguments: Array(arguments.dropFirst()))
        case "list", "l":
            Self.listProviders()
        case "version", "-v", "--version":
            Self.printVersion()
        case "help", "-h", "--help":
            Self.printUsage()
        default:
            print("Unknown command: \(command)")
            Self.printUsage()
        }
    }

    // MARK: - Commands

    static func showStatus() async {
        print("Control Tower Status")
        print("====================")
        print()

        let context = ProviderService.defaultCLIContext()
        let results = await ProviderService.shared.fetchAll(context: context)

        for provider in ProviderID.allCases {
            let descriptor = ProviderRegistry.descriptor(for: provider)
            print("\(descriptor.metadata.displayName):")

            if let outcome = results[provider] {
                switch outcome.result {
                case .success(let result):
                    if let primary = result.usage.primary {
                        print("  \(descriptor.metadata.sessionLabel): \(String(format: "%.1f%%", primary.usedPercent)) used")
                    }
                    if let secondary = result.usage.secondary {
                        print("  \(descriptor.metadata.quotaLabel): \(String(format: "%.1f%%", secondary.usedPercent)) used")
                    }
                    if let tertiary = result.usage.tertiary, descriptor.metadata.supportsTertiary {
                        print("  \(descriptor.metadata.tertiaryLabel ?? "Tertiary"): \(String(format: "%.1f%%", tertiary.usedPercent)) used")
                    }
                    if let identity = result.usage.identity {
                        if let email = identity.email {
                            print("  Account: \(email)")
                        }
                        if let plan = identity.plan {
                            print("  Plan: \(plan)")
                        }
                    }
                case .failure(let error):
                    print("  Error: \(error.localizedDescription)")
                    for attempt in outcome.attempts {
                        if let err = attempt.error {
                            print("    - \(attempt.strategyID): \(err.localizedDescription)")
                        } else if !attempt.wasAvailable {
                            print("    - \(attempt.strategyID): not available")
                        }
                    }
                }
            } else {
                print("  Status: No result")
            }
            print()
        }
    }

    static func showTokens(arguments: [String]) async {
        if arguments.first == "codex" {
            await Self.showCodexTokens()
            return
        }
        let started = Date()
        let snapshot = await TokenLedger.shared.snapshot(forceScan: true)
        let elapsed = Date().timeIntervalSince(started)

        func fmt(_ tokens: Int) -> String {
            if tokens >= 1_000_000_000 { return String(format: "%.2fB", Double(tokens) / 1_000_000_000) }
            if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
            if tokens >= 1_000 { return String(format: "%.1fK", Double(tokens) / 1_000) }
            return "\(tokens)"
        }
        func money(_ value: Double) -> String { String(format: "$%.2f", value) }
        func row(_ label: String, _ totals: TokenTotals) {
            let padded = label.padding(toLength: 14, withPad: " ", startingAt: 0)
            print("  \(padded) \(fmt(totals.totalTokens).padding(toLength: 10, withPad: " ", startingAt: 0)) \(money(totals.costUSD).padding(toLength: 10, withPad: " ", startingAt: 0)) (in \(fmt(totals.inputTokens)) / out \(fmt(totals.outputTokens)) / cache r \(fmt(totals.cacheReadTokens)) w \(fmt(totals.cacheWriteTokens)))")
        }

        print("Claude Token Ledger")
        print("===================")
        print()
        print("  Period         Tokens     Cost       Breakdown")
        row("Today", snapshot.today)
        row("Last 7 days", snapshot.last7Days)
        row("Last 30 days", snapshot.last30Days)

        if !snapshot.bySource.isEmpty {
            print()
            print("By app (30d):")
            for (source, totals) in snapshot.bySource.sorted(by: { $0.value.costUSD > $1.value.costUSD }) {
                row(source.displayName, totals)
            }
        }

        if !snapshot.byModel.isEmpty {
            print()
            print("By model (30d):")
            for (model, totals) in snapshot.byModel.sorted(by: { $0.value.costUSD > $1.value.costUSD }) {
                row(model, totals)
            }
        }

        if !snapshot.byProject.isEmpty {
            print()
            print("Top projects (30d):")
            for project in snapshot.byProject.prefix(5) {
                row(project.displayName, project.totals)
            }
        }

        if let block = snapshot.currentBlock {
            print()
            print("Current 5h block (started \(Self.timeFormatter.string(from: block.start))):")
            print("  Tokens: \(fmt(block.totals.totalTokens))  Cost: \(money(block.totals.costUSD))  Burn: \(fmt(Int(block.burnRate())))/min  Resets in: \(block.remainingDescription())")
        } else {
            print()
            print("No active 5h block.")
        }

        if let first = snapshot.dailyActivity.first {
            let active = snapshot.dailyActivity.filter { $0.totalTokens > 0 }.count
            print()
            print("Activity: \(active) active days since \(first.date)")
        }

        let stats = snapshot.stats
        print()
        print(String(format: "Scan: %d files seen, %d parsed, %.1f MB read, %d entries added in %.2fs (total %.2fs)%@",
                     stats.filesSeen, stats.filesParsed,
                     Double(stats.bytesParsed) / 1_048_576,
                     stats.entriesAdded, stats.duration, elapsed,
                     stats.isInitialScan ? " [initial index]" : ""))
    }

    static func showCodexTokens() async {
        let started = Date()
        let cost = await CodexCostScanner.shared.scan(forceRefresh: true)
        let snapshot = await CodexLedger.shared.snapshot()
        let elapsed = Date().timeIntervalSince(started)

        func fmt(_ tokens: Int) -> String {
            if tokens >= 1_000_000_000 { return String(format: "%.2fB", Double(tokens) / 1_000_000_000) }
            if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
            if tokens >= 1_000 { return String(format: "%.1fK", Double(tokens) / 1_000) }
            return "\(tokens)"
        }

        print("Codex Token Ledger")
        print("==================")
        print()
        print("  Period         Tokens     Cost")
        print("  Today          \(fmt(cost.todayTokens).padding(toLength: 10, withPad: " ", startingAt: 0)) $\(String(format: "%.2f", cost.todayCostUSD))")
        print("  Last 7 days    \(fmt(cost.last7DaysTokens).padding(toLength: 10, withPad: " ", startingAt: 0)) $\(String(format: "%.2f", cost.last7DaysCostUSD))")
        print("  Last 30 days   \(fmt(cost.last30DaysTokens).padding(toLength: 10, withPad: " ", startingAt: 0)) $\(String(format: "%.2f", cost.last30DaysCostUSD))")

        if !cost.dailyCosts.isEmpty {
            print()
            print("Days with activity (30d): \(cost.dailyCosts.count)")
        }

        let stats = snapshot.stats
        print()
        print(String(format: "Scan: %d files seen, %d parsed, %.1f MB read, %d entries added in %.2fs (total %.2fs)%@",
                     stats.filesSeen, stats.filesParsed,
                     Double(stats.bytesParsed) / 1_048_576,
                     stats.entriesAdded, stats.duration, elapsed,
                     stats.isInitialScan ? " [initial index]" : ""))
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func listProviders() {
        print("Supported Providers:")
        print()

        for provider in ProviderID.allCases {
            let descriptor = ProviderRegistry.descriptor(for: provider)
            print("  \(provider.cliName.padding(toLength: 10, withPad: " ", startingAt: 0)) - \(descriptor.metadata.displayName)")
        }
    }

    static func printVersion() {
        print("Control Tower CLI v1.0.0-beta.3")
    }

    static func printUsage() {
        print("""
        Control Tower CLI - AI Usage Monitor

        USAGE:
            ct <command> [options]

        COMMANDS:
            status, s       Show usage status for all providers
            tokens, t       Show Claude token usage and costs (all apps)
            tokens codex    Show Codex token usage and costs
            list, l         List supported providers
            version, -v     Print version information
            help, -h        Show this help message

        EXAMPLES:
            ct status
            ct tokens
            ct list

        """)
    }
}
