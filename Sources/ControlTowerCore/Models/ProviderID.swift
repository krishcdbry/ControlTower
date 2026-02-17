import Foundation

/// Unique identifier for each supported AI provider.
public enum ProviderID: String, CaseIterable, Sendable, Codable, Hashable {
    case claude
    case codex
    case cursor
    case gemini
    case copilot
    case antigravity

    /// Human-readable display name for the provider.
    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .gemini: "Gemini"
        case .copilot: "Copilot"
        case .antigravity: "Antigravity"
        }
    }

    /// CLI command name for the provider.
    public var cliName: String {
        self.rawValue
    }
}

/// Visual style for provider icons.
public enum IconStyle: String, Sendable, CaseIterable, Codable {
    case claude
    case codex
    case cursor
    case gemini
    case copilot
    case antigravity

    public init(from provider: ProviderID) {
        switch provider {
        case .claude: self = .claude
        case .codex: self = .codex
        case .cursor: self = .cursor
        case .gemini: self = .gemini
        case .copilot: self = .copilot
        case .antigravity: self = .antigravity
        }
    }
}
