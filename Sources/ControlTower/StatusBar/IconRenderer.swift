import AppKit

/// Renders dynamic menu bar icons based on usage data.
enum IconRenderer {
    // MARK: - Constants

    static let baseSize = NSSize(width: 18, height: 18)
    static let outputScale: CGFloat = 2

    // MARK: - Cache

    @MainActor
    private static var iconCache: [String: NSImage] = [:]
    private static let cacheLimit = 64

    // MARK: - Public API

    /// Render an icon with a single usage percentage.
    @MainActor
    static func render(usagePercent: Double, size: NSSize = baseSize) -> NSImage {
        let key = "single-\(Int(usagePercent))"

        if let cached = iconCache[key] {
            return cached
        }

        let icon = Self.renderIcon(
            primaryPercent: usagePercent,
            secondaryPercent: nil,
            size: size
        )

        Self.cacheIcon(icon, key: key)
        return icon
    }

    /// Render an icon with primary and secondary usage percentages.
    @MainActor
    static func render(
        primaryPercent: Double,
        secondaryPercent: Double,
        size: NSSize = baseSize
    ) -> NSImage {
        let key = "dual-\(Int(primaryPercent))-\(Int(secondaryPercent))"

        if let cached = iconCache[key] {
            return cached
        }

        let icon = Self.renderIcon(
            primaryPercent: primaryPercent,
            secondaryPercent: secondaryPercent,
            size: size
        )

        Self.cacheIcon(icon, key: key)
        return icon
    }

    // MARK: - Private Rendering

    private static func renderIcon(
        primaryPercent: Double,
        secondaryPercent: Double?,
        size: NSSize
    ) -> NSImage {
        let scale = outputScale
        let pixelSize = NSSize(
            width: size.width * scale,
            height: size.height * scale
        )

        let image = NSImage(size: size)
        image.lockFocus()

        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        // Scale for retina
        context.scaleBy(x: 1 / scale, y: 1 / scale)

        // Clear background
        context.clear(CGRect(origin: .zero, size: pixelSize))

        // Draw icon
        Self.drawControlTowerIcon(
            context: context,
            size: pixelSize,
            primaryPercent: primaryPercent,
            secondaryPercent: secondaryPercent
        )

        image.unlockFocus()
        return image
    }

    private static func drawControlTowerIcon(
        context: CGContext,
        size: NSSize,
        primaryPercent: Double,
        secondaryPercent: Double?
    ) {
        let width = size.width
        let height = size.height

        // Icon design: Two vertical bars like a control tower meter
        let barWidth: CGFloat = 4
        let barSpacing: CGFloat = 4
        let barHeight: CGFloat = height - 4
        let cornerRadius: CGFloat = 2

        let totalWidth = barWidth * 2 + barSpacing
        let startX = (width - totalWidth) / 2
        let startY: CGFloat = 2

        // Calculate fill heights based on usage (inverted - higher usage = less fill)
        let primaryFill = (1 - min(1, max(0, primaryPercent / 100))) * barHeight
        let secondaryFillValue: Double
        if let secondary = secondaryPercent {
            secondaryFillValue = (1 - min(1, max(0, secondary / 100))) * barHeight
        } else {
            secondaryFillValue = primaryFill
        }

        // Colors
        let fillColor = Self.colorForUsage(primaryPercent)
        let emptyColor = NSColor.white.withAlphaComponent(0.3)

        // Left bar (primary usage)
        self.drawBar(
            context: context,
            x: startX,
            y: startY,
            width: barWidth,
            height: barHeight,
            fillHeight: barHeight - primaryFill,
            cornerRadius: cornerRadius,
            fillColor: fillColor,
            emptyColor: emptyColor
        )

        // Right bar (secondary usage)
        let secondaryColor = secondaryPercent.map { Self.colorForUsage($0) } ?? fillColor
        self.drawBar(
            context: context,
            x: startX + barWidth + barSpacing,
            y: startY,
            width: barWidth,
            height: barHeight,
            fillHeight: barHeight - secondaryFillValue,
            cornerRadius: cornerRadius,
            fillColor: secondaryColor,
            emptyColor: emptyColor
        )
    }

    private static func drawBar(
        context: CGContext,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        fillHeight: CGFloat,
        cornerRadius: CGFloat,
        fillColor: NSColor,
        emptyColor: NSColor
    ) {
        // Background (empty portion)
        let backgroundPath = CGPath(
            roundedRect: CGRect(x: x, y: y, width: width, height: height),
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        context.setFillColor(emptyColor.cgColor)
        context.addPath(backgroundPath)
        context.fillPath()

        // Filled portion (from bottom)
        if fillHeight > 0 {
            let fillRect = CGRect(
                x: x,
                y: y,
                width: width,
                height: min(height, fillHeight)
            )

            // Clip to rounded rect shape
            context.saveGState()
            context.addPath(backgroundPath)
            context.clip()

            context.setFillColor(fillColor.cgColor)
            context.fill(fillRect)
            context.restoreGState()
        }
    }

    private static func colorForUsage(_ percent: Double) -> NSColor {
        if percent >= 95 {
            return NSColor.systemRed
        } else if percent >= 80 {
            return NSColor.systemOrange
        } else if percent >= 50 {
            return NSColor.systemYellow
        } else {
            return NSColor.white
        }
    }

    // MARK: - Cache Management

    @MainActor
    private static func cacheIcon(_ icon: NSImage, key: String) {
        // Prune cache if needed
        if iconCache.count >= cacheLimit {
            // Remove oldest entries (simple FIFO approximation)
            let keysToRemove = Array(iconCache.keys.prefix(cacheLimit / 2))
            for key in keysToRemove {
                iconCache.removeValue(forKey: key)
            }
        }

        iconCache[key] = icon
    }

    /// Clear the icon cache.
    @MainActor
    static func clearCache() {
        iconCache.removeAll()
    }
}
