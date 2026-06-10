# Changelog

All notable changes to Control Tower will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-06-10

First stable release.

### Added
- Activity heatmap: six months of daily usage at a glance, GitHub-style
- Day drill-down: click any day for totals, hour-of-day distribution, and
  per-model / per-app / per-project breakdowns
- Codex incremental token ledger with model-aware pricing and a
  `ct tokens codex` CLI command

### Changed
- The dashboard stays open while you explore; dismiss it from the menu bar
  icon, with Esc, or via explicit actions — it no longer closes when you
  click elsewhere
- Token history window widened to six months (one-time re-index on first
  launch)

### Fixed
- Codex usage was severely overcounted (cumulative session totals were
  summed per update, and cached/reasoning tokens were double-added);
  counts now derive from per-turn deltas

## [1.0.0-beta.3] - 2026-06-10

### Added
- Token ledger: precise Claude token and cost tracking across every app that
  writes transcripts — Claude Code CLI/IDE, Claude Desktop, and Cowork
- Per-app usage attribution (Claude Code vs Desktop/Cowork) and per-project
  rollups in the dashboard
- Live 5-hour rate-limit block card with burn rate, cost pace, and reset
  countdown; token counts update in real time while sessions run
- `ct tokens` CLI command for token/cost summaries in the terminal
- Tiered prompt-cache pricing (5-minute vs 1-hour TTL cache writes)

### Changed
- Transcript scanning is now incremental (per-file cursors with global
  message deduplication in SQLite); steady-state refreshes take milliseconds
  instead of re-reading every session file
- Updated model pricing (Opus 4.5+, Haiku 4.5) and added current-generation
  models; costs are computed at query time so corrections apply to history

### Fixed
- Menu bar icon no longer re-reads its image from disk every second; updates
  are driven by data changes
- Popover is reused across opens and global event monitors are cleaned up
- Refresh timer now rebuilds when the interval setting changes
- Builds restored on Swift 6.2 toolchains (swift-log 1.13.2)

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
