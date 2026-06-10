import AppKit
import ControlTowerCore
import SwiftUI

/// Controller for the menu bar status item.
@MainActor
final class StatusItemController: NSObject {
    // MARK: - Properties

    private let statusItem: NSStatusItem
    private let settingsStore: SettingsStore
    private let usageStore: UsageStore
    private let accountStore: AccountStore
    private let ledgerStore: TokenLedgerStore

    private var popover: NSPopover?
    private var tooltipTimer: Timer?
    private var cachedCustomIcon: NSImage?
    private var didLoadCustomIcon = false

    // MARK: - Initialization

    init(
        settingsStore: SettingsStore,
        usageStore: UsageStore,
        accountStore: AccountStore,
        ledgerStore: TokenLedgerStore
    ) {
        self.settingsStore = settingsStore
        self.usageStore = usageStore
        self.accountStore = accountStore
        self.ledgerStore = ledgerStore

        // Create status item
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        self.setupStatusItem()
        self.setupObservation()
    }

    isolated deinit {
        self.tooltipTimer?.invalidate()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }

        // Set initial icon
        self.updateIcon()

        // Setup click action
        button.action = #selector(self.statusItemClicked)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupObservation() {
        // Update the icon when usage data changes (re-arming observation each time).
        self.observeUsageChanges()

        // Low-frequency tick keeps the relative "Updated Xm ago" tooltip fresh.
        self.tooltipTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateIcon()
            }
        }
    }

    private func observeUsageChanges() {
        withObservationTracking {
            _ = self.usageStore.snapshots
            _ = self.usageStore.errors
            _ = self.settingsStore.enabledProviders
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateIcon()
                self.observeUsageChanges()
            }
        }
    }

    // MARK: - Icon

    private func updateIcon() {
        guard let button = statusItem.button else { return }

        // Get highest usage across enabled providers
        var highestUsage: Double = 0
        for provider in settingsStore.enabledProviders {
            if let snapshot = usageStore.snapshots[provider] {
                highestUsage = max(highestUsage, snapshot.highestUsagePercent)
            }
        }

        // Try to use custom menu bar icon first, fall back to SF Symbols
        if let customIcon = self.loadMenuBarIcon() {
            // Apply tint based on usage level
            if highestUsage >= 90 {
                button.image = self.tintedImage(customIcon, color: .systemRed)
            } else if highestUsage >= 80 {
                button.image = self.tintedImage(customIcon, color: .systemOrange)
            } else {
                button.image = customIcon
                button.image?.isTemplate = true
            }
        } else {
            // Fallback to SF Symbols - use lighthouse/tower-like icons
            let symbolName: String
            if highestUsage >= 90 {
                symbolName = "building.2.fill"
            } else if highestUsage >= 70 {
                symbolName = "building.2.crop.circle.fill"
            } else {
                symbolName = "building.2"
            }

            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Control Tower")?
                .withSymbolConfiguration(config)
            button.image?.isTemplate = true
        }

        // Update tooltip
        let tooltip = self.buildTooltip()
        button.toolTip = tooltip
    }

    private func loadMenuBarIcon() -> NSImage? {
        // Load the custom icon once; updateIcon runs frequently and must not hit disk.
        if self.didLoadCustomIcon {
            return self.cachedCustomIcon
        }
        self.didLoadCustomIcon = true

        if let url = Bundle.moduleResources.url(forResource: "menubar-icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            self.cachedCustomIcon = image
        } else if let url = Bundle.main.url(forResource: "menubar-icon", withExtension: "png"),
                  let image = NSImage(contentsOf: url) {
            self.cachedCustomIcon = image
        }
        return self.cachedCustomIcon
    }

    private func tintedImage(_ image: NSImage, color: NSColor) -> NSImage {
        let tinted = image.copy() as! NSImage
        tinted.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: tinted.size)
        rect.fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }

    private func buildTooltip() -> String {
        var lines: [String] = ["Control Tower"]

        for provider in settingsStore.enabledProviders.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let snapshot = usageStore.snapshots[provider] {
                let usage = Int(snapshot.highestUsagePercent)
                lines.append("\(provider.displayName): \(usage)%")
            } else if usageStore.errors[provider] != nil {
                lines.append("\(provider.displayName): Error")
            }
        }

        if let lastRefresh = usageStore.lastRefresh {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            let relative = formatter.localizedString(for: lastRefresh, relativeTo: Date())
            lines.append("Updated \(relative)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Actions

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!

        if event.type == .rightMouseUp {
            // Right click - show context menu
            self.showContextMenu()
        } else {
            // Left click - toggle popover
            self.togglePopover()
        }
    }

    func showMenu() {
        self.togglePopover()
    }

    private func togglePopover() {
        if let popover, popover.isShown {
            popover.close()
        } else {
            self.showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }

        // Reuse the popover; data flows from the observable stores, so the
        // content stays current without rebuilding the view hierarchy.
        let popover: NSPopover
        if let existing = self.popover {
            popover = existing
        } else {
            popover = NSPopover()
            // Stay open while the user explores (heatmap, day drill-downs);
            // dismissed by clicking the status item again, pressing Esc, or
            // the explicit close paths below — never by clicking elsewhere.
            popover.behavior = .applicationDefined
            popover.animates = true
            popover.delegate = self

            let contentView = PremiumDashboardView(
                usageStore: self.usageStore,
                settingsStore: self.settingsStore,
                ledgerStore: self.ledgerStore,
                onRefresh: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.ledgerStore.refresh(force: true)
                        await self.usageStore.refresh()
                    }
                },
                onSettings: { [weak self] in
                    self?.popover?.close()
                    self?.openSettings()
                },
                onQuit: { [weak self] in
                    self?.popover?.close()
                    NSApp.terminate(nil)
                },
                onClose: { [weak self] in
                    self?.popover?.close()
                }
            )

            let hostingController = NSHostingController(rootView: contentView)
            // Let SwiftUI determine the size
            hostingController.sizingOptions = [.preferredContentSize]
            popover.contentViewController = hostingController
            self.popover = popover
        }

        // Refresh token data when opening (incremental; typically a few ms).
        self.ledgerStore.refresh()

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showContextMenu() {
        let menu = NSMenu()

        // Refresh
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(self.refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        // Provider status
        for provider in settingsStore.enabledProviders.sorted(by: { $0.rawValue < $1.rawValue }) {
            let item = NSMenuItem()
            if let snapshot = usageStore.snapshots[provider] {
                let usage = Int(snapshot.highestUsagePercent)
                item.title = "\(provider.displayName): \(usage)%"
            } else {
                item.title = "\(provider.displayName): --"
            }
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(self.openSettingsAction), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit Control Tower", action: #selector(self.quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // Show menu
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Menu Actions

    @objc private func refreshNow() {
        Task {
            await self.usageStore.refresh()
        }
    }

    @objc private func openSettingsAction() {
        self.openSettings()
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - NSPopoverDelegate

extension StatusItemController: NSPopoverDelegate {}

// MARK: - Dashboard Popover View

struct DashboardPopoverView: View {
    @Bindable var settingsStore: SettingsStore
    @Bindable var usageStore: UsageStore
    @Bindable var accountStore: AccountStore

    let onClose: () -> Void
    let onSettings: () -> Void
    let onRefresh: () -> Void

    @State private var selectedProvider: ProviderID?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            self.headerView

            Divider()

            // Provider list
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(Array(self.settingsStore.enabledProviders).sorted { $0.rawValue < $1.rawValue }, id: \.self) { provider in
                        ProviderCardView(
                            provider: provider,
                            snapshot: self.usageStore.snapshots[provider],
                            error: self.usageStore.errors[provider],
                            isSelected: self.selectedProvider == provider,
                            onTap: { self.selectedProvider = provider }
                        )
                    }
                }
                .padding()
            }

            Divider()

            // Footer
            self.footerView
        }
        .frame(width: 380, height: 480)
    }

    private var headerView: some View {
        HStack {
            Text("Control Tower")
                .font(.headline)

            Spacer()

            if self.usageStore.isRefreshing {
                ProgressView()
                    .scaleEffect(0.6)
            }

            Button(action: self.onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(self.usageStore.isRefreshing)
        }
        .padding()
    }

    private var footerView: some View {
        HStack {
            if let lastRefresh = usageStore.lastRefresh {
                Text("Updated \(lastRefresh, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Settings", action: self.onSettings)
                .buttonStyle(.borderless)
        }
        .padding()
    }
}

// MARK: - Provider Card View

struct ProviderCardView: View {
    let provider: ProviderID
    let snapshot: UsageSnapshot?
    let error: String?
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: self.onTap) {
            VStack(alignment: .leading, spacing: 8) {
                // Header
                HStack {
                    Circle()
                        .fill(self.providerColor)
                        .frame(width: 8, height: 8)

                    Text(self.provider.displayName)
                        .font(.headline)

                    Spacer()

                    if let snapshot {
                        Text("\(Int(snapshot.highestUsagePercent))%")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundStyle(self.usageColor(snapshot.highestUsagePercent))
                    } else if error != nil {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    } else {
                        Text("--")
                            .foregroundStyle(.secondary)
                    }
                }

                // Usage bars
                if let snapshot {
                    if let primary = snapshot.primary {
                        UsageBarView(
                            label: primary.label ?? "Session",
                            percent: primary.usedPercent,
                            resetTime: primary.timeUntilReset()
                        )
                    }

                    if let secondary = snapshot.secondary {
                        UsageBarView(
                            label: secondary.label ?? "Weekly",
                            percent: secondary.usedPercent,
                            resetTime: secondary.timeUntilReset()
                        )
                    }
                } else if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(self.isSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(self.isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private var providerColor: Color {
        let color = ProviderRegistry.descriptor(for: provider).branding.color
        return Color(red: color.red, green: color.green, blue: color.blue)
    }

    private func usageColor(_ percent: Double) -> Color {
        if percent >= 95 {
            return .red
        } else if percent >= 80 {
            return .orange
        } else {
            return .primary
        }
    }
}

// MARK: - Usage Bar View

struct UsageBarView: View {
    let label: String
    let percent: Double
    let resetTime: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(self.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if let reset = resetTime {
                    Text("Resets in \(reset)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(self.barColor)
                        .frame(width: geometry.size.width * min(1, self.percent / 100), height: 4)
                }
            }
            .frame(height: 4)
        }
    }

    private var barColor: Color {
        if self.percent >= 95 {
            return .red
        } else if self.percent >= 80 {
            return .orange
        } else {
            return .accentColor
        }
    }
}
