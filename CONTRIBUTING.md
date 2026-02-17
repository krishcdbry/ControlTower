# Contributing to Control Tower

Thank you for your interest in contributing to Control Tower! This document provides guidelines and information for contributors.

## Development Setup

### Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 16+ or Swift 6.0+
- Git

### Getting Started

1. Fork the repository
2. Clone your fork:
   ```bash
   git clone git@github.com:YOUR_USERNAME/control-tower.git
   cd control-tower
   ```
3. Build the project:
   ```bash
   swift build
   ```
4. Run tests:
   ```bash
   swift test
   ```

## Project Structure

```
control-tower/
├── Sources/
│   ├── ControlTowerCore/     # Core library (cross-platform)
│   │   ├── Models/           # Data models
│   │   ├── Providers/        # Provider implementations
│   │   ├── Persistence/      # Database and storage
│   │   └── Utilities/        # Helper utilities
│   ├── ControlTower/         # macOS app
│   │   ├── App/              # App entry and delegate
│   │   ├── StatusBar/        # Menu bar controller
│   │   ├── Popover/          # Dashboard views
│   │   ├── Preferences/      # Settings UI
│   │   └── Stores/           # Observable state
│   └── ControlTowerCLI/      # CLI tool
├── Tests/                    # Test suite
├── Scripts/                  # Build scripts
└── Formula/                  # Homebrew formula
```

## Pull Request Guidelines

### Before Submitting

1. **Create an issue first** for significant changes
2. **Fork and branch** from `main`
3. **Follow the code style** of the project
4. **Write tests** for new functionality
5. **Update documentation** if needed

### Branch Naming

Use descriptive branch names:
- `feat/provider-name` - New provider
- `fix/issue-description` - Bug fix
- `refactor/component-name` - Code refactoring
- `docs/topic` - Documentation updates

### Commit Messages

Use conventional commits:

```
type: brief description

Optional longer description explaining the change.
```

Types:
- `feat:` New feature
- `fix:` Bug fix
- `refactor:` Code refactoring
- `docs:` Documentation
- `test:` Tests
- `chore:` Build/tooling
- `perf:` Performance

Examples:
```
feat: add Ollama provider support

fix: resolve cookie parsing for Firefox

refactor: simplify CLIExecutor pipe handling
```

### PR Checklist

- [ ] Code builds without warnings (`swift build -c release`)
- [ ] All tests pass (`swift test`)
- [ ] New code has appropriate tests
- [ ] Documentation updated if needed
- [ ] Commit messages follow conventions
- [ ] PR description explains the changes

### PR Description Template

```markdown
## Summary
Brief description of what this PR does.

## Changes
- Change 1
- Change 2

## Testing
How was this tested?

## Related Issues
Fixes #123
```

## Adding a New Provider

1. Create provider directory:
   ```
   Sources/ControlTowerCore/Providers/NewProvider/
   ```

2. Implement required files:
   - `NewProviderDescriptor.swift` - Provider metadata
   - `NewProviderStrategy.swift` - Fetch strategy

3. Register in `ProviderRegistry.swift`

4. Add to `ProviderService.swift` strategies

5. Write tests in `Tests/ControlTowerCoreTests/`

6. Update README.md with setup instructions

## Code Style

- Use Swift 6 concurrency features
- Follow existing patterns in the codebase
- Use `@MainActor` for UI-related code
- Prefer `async/await` over callbacks
- Use meaningful variable names
- Keep functions focused and small

## Testing

```bash
# Run all tests
swift test

# Run specific test
swift test --filter "ProviderIDTests"

# Build and test
swift build && swift test
```

## Release Process

Releases follow semantic versioning (MAJOR.MINOR.PATCH):

1. Update version in `Info.plist`
2. Update `CHANGELOG.md`
3. Create PR for release
4. After merge, tag the release:
   ```bash
   git tag -a v1.0.0 -m "Release v1.0.0"
   git push origin v1.0.0
   ```
5. Create GitHub release with changelog

## Getting Help

- Open an issue for bugs or feature requests
- Use discussions for questions
- Check existing issues before creating new ones

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
