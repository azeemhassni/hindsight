import AppKit
import HindsightUI

/// Decides how big the window may be, and how big it opens.
///
/// All of this is `NSWindow` work rather than SwiftUI `frame` modifiers,
/// because a frame on the `NavigationSplitView` breaks its layout: the window
/// resizes and the content does not, leaving a toolbar above an empty
/// rectangle. AppKit constrains the window without touching anything inside
/// it.
@MainActor
enum WindowFloor {
    /// Where macOS keeps this window's frame between launches. Checked so that
    /// a size the person chose is never overridden.
    static let autosaveKey = WindowGeometryParsing.windowKey

    /// Applied more than once on purpose.
    ///
    /// SwiftUI sizes the window from its content after the first layout pass,
    /// which lands after this code runs — so a size set once is overwritten a
    /// moment later. Setting it again after that pass is what makes it stick,
    /// and a window the person has already sized is never touched.
    static func applyWhenSettled(
        minWidth: CGFloat,
        minHeight: CGFloat,
        openingSize: NSSize,
        defaults: UserDefaults = .standard
    ) {
        apply(
            minWidth: minWidth,
            minHeight: minHeight,
            openingSize: openingSize,
            defaults: defaults
        )
        for delay in [0.15, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                apply(
                    minWidth: minWidth,
                    minHeight: minHeight,
                    openingSize: openingSize,
                    defaults: defaults
                )
            }
        }
    }

    static func apply(
        minWidth: CGFloat,
        minHeight: CGFloat,
        openingSize: NSSize,
        defaults: UserDefaults = .standard
    ) {
        let remembered = defaults.string(forKey: autosaveKey) != nil
        for window in NSApp.windows where window.contentView != nil {
            guard window.styleMask.contains(.titled), !window.isSheet else { continue }
            window.contentMinSize = NSSize(width: minWidth, height: minHeight)
            // Explicitly unbounded: a window the screen can hold should be
            // allowed to fill it.
            window.contentMaxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            window.styleMask.insert(.resizable)

            if !remembered {
                // First run: the content's own ideal height is most of a
                // scroll view, which would open the window taller than the
                // screen. Opening size is the app's decision.
                resize(window, to: openingSize)
            }
            clampToScreen(window)
        }
    }

    private static func resize(_ window: NSWindow, to size: NSSize) {
        var frame = window.frame
        let delta = frame.height - window.contentRect(forFrameRect: frame).height
        frame.size = NSSize(width: size.width, height: size.height + delta)
        window.setFrame(frame, display: true)
        window.center()
    }

    /// Brings a window back inside the screen it is on.
    ///
    /// macOS restores the frame a window had last time, and a window saved on
    /// a larger display would otherwise open with most of it past the edge.
    static func clampToScreen(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true)
    }
}
