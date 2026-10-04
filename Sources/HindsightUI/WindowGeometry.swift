import Foundation

/// The window geometry macOS remembers between launches, and when to ignore it.
///
/// AppKit restores a split view's subview frames and SwiftUI sizes the window
/// to fit them, so a window that was once taller than the screen opens that way
/// again — and each launch saves the oversized value back. Anything that no
/// longer fits is dropped; a size that fits is the person's and is left alone.
///
/// The parsing lives here, away from AppKit, so the formats can be tested: both
/// are undocumented strings written by the system.
public enum WindowGeometryParsing {
    public static let splitViewKey = "NSSplitView Subview Frames main, SidebarNavigationSplitView"
    public static let windowKey = "NSWindow Frame main"

    public static func discardIfLargerThanScreen(
        defaults: UserDefaults,
        screenHeight: CGFloat
    ) {
        if let frames = defaults.array(forKey: splitViewKey) as? [String],
           frames.contains(where: { (heightOfSplitViewFrame($0) ?? 0) > screenHeight }) {
            defaults.removeObject(forKey: splitViewKey)
        }

        if let frame = defaults.string(forKey: windowKey),
           let height = heightOfWindowFrame(frame), height > screenHeight {
            defaults.removeObject(forKey: windowKey)
        }
    }

    /// `"x, y, width, height, NO, NO"`.
    public static func heightOfSplitViewFrame(_ text: String) -> CGFloat? {
        let fields = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 4, let height = Double(fields[3]) else { return nil }
        return CGFloat(height)
    }

    /// `"x y width height screenX screenY screenWidth screenHeight "`.
    public static func heightOfWindowFrame(_ text: String) -> CGFloat? {
        let fields = text.split(separator: " ").map(String.init)
        guard fields.count >= 4, let height = Double(fields[3]) else { return nil }
        return CGFloat(height)
    }
}
