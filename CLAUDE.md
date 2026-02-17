# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run Commands

```bash
# Development cycle (build and launch)
./Scripts/compile_and_run.sh

# Build only
swift build                      # debug
swift build -c release          # release

# Run tests
swift test

# CLI tool
swift run controltower status
swift run controltower list
```

## Architecture

### Module Structure

- **ControlTowerCore**: Cross-platform fetch/parse logic, models, persistence, providers
- **ControlTower**: macOS app (SwiftUI + AppKit), stores, UI components
- **ControlTowerCLI**: Command-line interface for scripts/CI

### Key Components

```
Sources/
├── ControlTowerCore/
│   ├── Models/              # UsageSnapshot, ProviderMetadata, NotificationModels, AnalyticsModels
│   ├── Providers/           # ProviderDescriptor, FetchPlan, Registry
│   └── Persistence/         # UsageDatabase (GRDB/SQLite)
├── ControlTower/
│   ├── App/                 # ControlTowerApp, AppDelegate
│   ├── StatusBar/           # StatusItemController, IconRenderer
│   ├── Stores/              # (in AppDelegate) UsageStore, SettingsStore, AccountStore
│   └── Resources/           # Info.plist
└── ControlTowerCLI/         # CLI entry point
```

### Data Flow

```
Background Refresh Timer
         ↓
    UsageStore.refresh()
         ↓
    ProviderFetchPipeline (strategies: OAuth → CLI → Web → API)
         ↓
    UsageSnapshot → UI Update
         ↓
    AnalyticsEngine (record to SQLite)
         ↓
    NotificationScheduler (evaluate thresholds)
```

### Provider System

Providers are descriptor-driven with a strategy chain pattern:
- `ProviderDescriptor`: Metadata, branding, auth methods, fetch plan
- `ProviderFetchStrategy`: Protocol for fetch implementations (OAuth, CLI, cookies, API)
- `ProviderFetchPipeline`: Executes strategies in order with fallback

To add a new provider:
1. Add case to `ProviderID` enum
2. Add case to `IconStyle` enum
3. Create descriptor in `ProviderRegistry.makeDescriptor()`
4. Implement fetch strategies

## Coding Conventions

- Swift 6 strict concurrency (`@Sendable`, `@MainActor`)
- macOS 14+ minimum
- `@Observable` macro for state management (not ObservableObject)
- SwiftUI for preferences, AppKit for menu bar (hybrid pattern)

## Key Files

| File | Purpose |
|------|---------|
| `ControlTowerCore/Models/UsageSnapshot.swift` | Core usage data model |
| `ControlTowerCore/Providers/ProviderDescriptor.swift` | Provider blueprint |
| `ControlTowerCore/Providers/ProviderFetchPlan.swift` | Fetch strategy pipeline |
| `ControlTowerCore/Providers/ProviderRegistry.swift` | Provider factory |
| `ControlTowerCore/Persistence/UsageDatabase.swift` | SQLite via GRDB |
| `ControlTower/App/AppDelegate.swift` | App lifecycle, stores |
| `ControlTower/StatusBar/StatusItemController.swift` | Menu bar controller |

## Supported Providers

| Provider | Auth Methods | Status |
|----------|--------------|--------|
| Claude | OAuth, Cookies, CLI | Descriptor ready |
| Codex | OAuth, Cookies, CLI | Descriptor ready |
| Cursor | Cookies | Descriptor ready |
| Gemini | OAuth, CLI | Descriptor ready |
| Copilot | OAuth (Device Flow) | Descriptor ready |

## Dependencies

- **Sparkle**: Auto-updates
- **GRDB.swift**: SQLite database
- **swift-log**: Logging
- **KeyboardShortcuts**: Global hotkeys
- **SweetCookieKit**: Browser cookie import

## Future Work

- [ ] Implement actual provider fetch strategies
- [ ] Add provider-specific settings UI
- [ ] Implement analytics charts (Swift Charts)
- [ ] Add notification delivery
- [ ] Add multi-account management UI
- [ ] Add data export functionality
