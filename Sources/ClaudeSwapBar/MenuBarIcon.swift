import AppKit

/// App imagery.
///
/// `statusIcon` is a gauge glyph rendered as a template alpha mask — macOS
/// tints it to match the menu bar (dark/light/reduced transparency), which is
/// what makes it look native instead of a colored box.
///
/// `appLogo` is the full-color app icon, used in the popover header and the
/// About pane.
enum MenuBarIcon {

    static let statusIcon: NSImage = {
        guard let url = Bundle.module.url(forResource: "StatusIcon", withExtension: "svg"),
              let img = NSImage(contentsOf: url), img.isValid else {
            let fallback = NSImage(
                systemSymbolName: "gauge.with.needle",
                accessibilityDescription: "Claude Swap Bar"
            ) ?? NSImage()
            fallback.isTemplate = true
            return fallback
        }
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = true
        return img
    }()

    static let appLogo: NSImage = {
        guard let url = Bundle.module.url(forResource: "AppLogo", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return NSImage() }
        return img
    }()
}
