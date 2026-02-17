# Control Tower

A unified macOS menu bar app for monitoring AI coding assistant usage across multiple providers.

<p align="center">
  <img src="https://krishcdbry.com/images/control-tower.png" alt="Control Tower" width="800">
</p>

## Supported Providers

| Provider | Auth Method | Features |
|----------|-------------|----------|
| **Claude** | OAuth/CLI | Session, Weekly, Opus limits |
| **Codex** | OAuth | Session, Weekly limits |
| **Cursor** | Browser cookies | Credits tracking |
| **Gemini** | OAuth/API Key | Pro, Flash model quotas |
| **Copilot** | GitHub CLI | Subscription status |
| **Antigravity** | Local process | Claude, Gemini Pro/Flash quotas |

## Installation

### Homebrew (Recommended)

```bash
brew tap krishcdbry/tap
brew install control-tower
```

### Manual Installation

1. Download the latest release from [Releases](https://github.com/krishcdbry/ControlTower/releases)
2. Move `Control Tower.app` to `/Applications`
3. Launch from Applications or Spotlight

### Build from Source

Requirements:
- macOS 14.0+
- Xcode 16+ or Swift 6.0+

```bash
git clone https://github.com/krishcdbry/ControlTower.git
cd ControlTower
swift build -c release
```

## Usage

### Menu Bar

Control Tower lives in your menu bar. Click the icon to see:
- Usage overview for all enabled providers
- Quick access to provider dashboards
- Refresh button to update all providers

### CLI Tool

Control Tower includes a CLI tool `ct` for terminal usage:

```bash
# Show status of all providers
ct status

# List available providers
ct list

# Get help
ct --help
```

### Provider Setup

#### Claude
Requires Claude CLI to be installed and logged in:
```bash
# Install Claude CLI (if not already installed)
npm install -g @anthropic-ai/claude-code

# Authenticate
claude
```

#### Codex
Requires Codex CLI to be installed and logged in:
```bash
# Authenticate with Codex
codex
```

#### Cursor
Automatically imports cookies from supported browsers:
- Safari, Chrome, Edge, Brave, Arc, Firefox, Vivaldi, Zen

Just sign in to cursor.com in any supported browser.

#### Gemini
**Option 1: OAuth (Recommended)**
```bash
# Install Gemini CLI
npm install -g @google/gemini-cli

# Authenticate
gemini
```

**Option 2: API Key**
```bash
export GEMINI_API_KEY="your-api-key"
```

#### Copilot
Requires GitHub CLI to be installed:
```bash
# Install GitHub CLI
brew install gh

# Authenticate
gh auth login
```

#### Antigravity
Launch the Antigravity app and sign in with your Google account. Control Tower will automatically detect the running process.

## Features

- **Real-time Usage Monitoring**: Track usage limits across all AI coding assistants
- **Smart Notifications**: Get alerts when approaching quota limits
- **Multi-Account Support**: Manage multiple accounts per provider
- **Cost Tracking**: Monitor estimated costs for token-based providers
- **Analytics**: View usage trends over time
- **Quiet Hours**: Configure Do Not Disturb periods
- **Auto-refresh**: Automatic periodic usage updates

## Configuration

Preferences can be accessed from the menu bar:
- **General**: Refresh interval, launch at login
- **Providers**: Enable/disable providers, configure auth
- **Notifications**: Threshold alerts, quiet hours
- **Analytics**: Usage history, cost reports

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel Mac

## Privacy

Control Tower:
- Does not collect or transmit any user data
- All credentials are stored locally in system keychain
- Only communicates with official provider APIs

## License

MIT License - see [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.

## Support

- [Issues](https://github.com/krishcdbry/ControlTower/issues)
- [Discussions](https://github.com/krishcdbry/ControlTower/discussions)
