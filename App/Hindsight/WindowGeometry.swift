import AppKit
import HindsightUI

/// Applies `WindowGeometryParsing` to this machine's screen.
@MainActor
enum WindowGeometry {
    static func discardIfLargerThanScreen() {
        guard let height = NSScreen.main?.visibleFrame.height else { return }
        WindowGeometryParsing.discardIfLargerThanScreen(
            defaults: .standard,
            screenHeight: height
        )
    }
}
