import Foundation

/// Text parsing utilities for CLI output.
public enum TextParsing {
    /// Strip ANSI escape codes from text.
    public static func stripANSICodes(_ text: String) -> String {
        // Pattern matches:
        // - CSI sequences: \x1b[...m (colors, styles)
        // - OSC sequences: \x1b]...(\x07|\x1b\\) (window titles, etc.)
        // - Other escape sequences: \x1b[?...h/l (modes)
        var result = text

        // CSI sequences (most common for colors/styles)
        let csiPattern = #"\x1b\[[0-9;]*[A-Za-z]"#
        if let regex = try? NSRegularExpression(pattern: csiPattern, options: []) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // OSC sequences (less common but can appear)
        let oscPattern = #"\x1b\][^\x07]*(\x07|\x1b\\)"#
        if let regex = try? NSRegularExpression(pattern: oscPattern, options: []) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // Simple escape sequences
        let simplePattern = #"\x1b[()][AB012]"#
        if let regex = try? NSRegularExpression(pattern: simplePattern, options: []) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // Stray bracketed codes like "[22m" that survive after ANSI stripping
        let strayPattern = #"\[\d+m"#
        if let regex = try? NSRegularExpression(pattern: strayPattern, options: []) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        return result
    }

    /// Normalize text for label searching (lowercase, collapse whitespace).
    public static func normalizedForSearch(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Extract first match of a regex pattern from text.
    public static func extractFirst(pattern: String, text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let resultRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[resultRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
