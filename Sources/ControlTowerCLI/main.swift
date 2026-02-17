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

    static func listProviders() {
        print("Supported Providers:")
        print()

        for provider in ProviderID.allCases {
            let descriptor = ProviderRegistry.descriptor(for: provider)
            print("  \(provider.cliName.padding(toLength: 10, withPad: " ", startingAt: 0)) - \(descriptor.metadata.displayName)")
        }
    }

    static func printVersion() {
        print("Control Tower CLI v1.0.0")
    }

    static func printUsage() {
        print("""
        Control Tower CLI - AI Usage Monitor

        USAGE:
            ct <command> [options]

        COMMANDS:
            status, s       Show usage status for all providers
            list, l         List supported providers
            version, -v     Print version information
            help, -h        Show this help message

        EXAMPLES:
            ct status
            ct list

        """)
    }
}
