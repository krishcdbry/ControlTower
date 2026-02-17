import Foundation

// Override SwiftPM's auto-generated Bundle.module to look in correct location
// SwiftPM looks in Bundle.main.bundleURL but macOS apps need Contents/Resources
extension Foundation.Bundle {
    static let moduleResources: Bundle = {
        // For macOS app bundle: look in Contents/Resources
        let resourcesPath = Bundle.main.bundlePath + "/Contents/Resources/ControlTower_ControlTower.bundle"

        if let bundle = Bundle(path: resourcesPath) {
            return bundle
        }

        // Fallback for SwiftPM development builds
        let buildPath = Bundle.main.bundleURL.appendingPathComponent("ControlTower_ControlTower.bundle").path
        if let bundle = Bundle(path: buildPath) {
            return bundle
        }

        // Last resort: check relative to executable
        let executablePath = Bundle.main.executablePath ?? ""
        let execDir = (executablePath as NSString).deletingLastPathComponent
        let relativeResourcesPath = (execDir as NSString).appendingPathComponent("../Resources/ControlTower_ControlTower.bundle")
        if let bundle = Bundle(path: relativeResourcesPath) {
            return bundle
        }

        fatalError("Could not load resource bundle")
    }()
}
