// Checks that every button in the running app says what it does on hover.
//
// A tooltip is the only explanation a toolbar icon ever gets, and the ones
// worth having are on disabled buttons — they are what tell someone why they
// cannot continue. This walks the accessibility tree of whatever Hindsight is
// showing right now, so run it with each tab and sheet open.
//
//     swift scripts/tooltip-audit.swift
//
// Needs Accessibility permission for the terminal running it. The window's own
// close, minimise and zoom buttons are skipped: they are the system's.
import ApplicationServices
import Cocoa

func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var out: CFTypeRef?
    AXUIElementCopyAttributeValue(element, name as CFString, &out)
    return out
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (value(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func role(_ element: AXUIElement) -> String {
    value(element, kAXRoleAttribute as String) as? String ?? "?"
}

func text(_ element: AXUIElement, _ key: String) -> String? {
    guard let raw = value(element, key) else { return nil }
    let string = "\(raw)".split(separator: "\n").first.map(String.init) ?? "\(raw)"
    return string.isEmpty ? nil : string
}

func name(_ element: AXUIElement) -> String {
    text(element, "AXDescription")
        ?? text(element, "AXTitle")
        ?? text(element, "AXAttributedDescription")
        ?? "(unnamed)"
}

var missing = 0
var total = 0

func walk(_ element: AXUIElement) {
    let r = role(element)
    if r == "AXButton" || r == "AXMenuButton" || r == "AXPopUpButton" {
        total += 1
        let help = text(element, "AXHelp")
        let subrole = text(element, "AXSubrole") ?? ""
        if subrole.hasPrefix("AXClose") || subrole.hasPrefix("AXMinimize")
            || subrole.hasPrefix("AXZoom") || subrole.hasPrefix("AXFullScreen") {
            total -= 1  // the window's own controls, not ours
        } else if help == nil {
            missing += 1
            print("NO TOOLTIP: \(name(element).prefix(60)) subrole=\(subrole)")
        } else {
            print("ok: \(name(element).prefix(34)) → \(help!.prefix(70))")
        }
    }
    for child in children(element) { walk(child) }
}

let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "app.hindsight").first!
    .processIdentifier
let app = AXUIElementCreateApplication(pid)
for window in children(app) {
    walk(window)
}
print("--- \(total) buttons, \(missing) without a tooltip")
