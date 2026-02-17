# Changelog

All notable changes to Control Tower will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0-beta.1] - 2026-02-17

### Added
- Initial beta release
- Support for 6 AI coding assistant providers:
  - **Claude**: OAuth and CLI authentication, session/weekly/opus limits
  - **Codex**: OAuth authentication via auth.json
  - **Cursor**: Browser cookie import from multiple browsers
  - **Gemini**: OAuth and API key authentication, Pro/Flash model quotas
  - **Copilot**: GitHub CLI authentication
  - **Antigravity**: Local process detection, multi-model quotas
- Menu bar application with quick status overview
- CLI tool (`ct`) for terminal usage
- Notification system with configurable thresholds (80%, 90%, 95%, 100%)
- Quiet hours support
- Multi-account support for Claude, Codex, Gemini, Copilot
- Usage analytics and history tracking
- Cost estimation for token-based providers
- Auto-refresh with configurable intervals
- Sparkle for auto-updates

### Technical
- Built with Swift 6, SwiftUI, and Swift Charts
- GRDB for local analytics storage
- Cross-platform core library (ControlTowerCore)
- Comprehensive test suite (44 tests)

### Known Issues
- CLI `ct status` may hang on some network configurations
- Token refresh for Gemini requires re-running `gemini` CLI

## [Unreleased]

### Planned
- Linux support (CLI only)
- Windows support
- Additional providers
- Webhook integrations
- Team/organization dashboards
