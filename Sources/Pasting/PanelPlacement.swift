import AppKit
import ApplicationServices

enum PanelPlacement {
    static let chromeHeight: CGFloat = 64          // search bar + tabs + paddings
    static func height(forCard card: CGFloat) -> CGFloat { card + chromeHeight }

    /// Caret rect of the focused text element in the frontmost app, in Cocoa (bottom-left) coordinates.
    /// nil if Accessibility isn't granted or the app doesn't expose it.
    static func caretRect() -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        let element = el as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.15)
        var rangeVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeVal) == .success,
              let rv = rangeVal else { return nil }
        var boundsVal: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rv, &boundsVal) == .success,
              let bv = boundsVal, CFGetTypeID(bv) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(bv as! AXValue, .cgRect, &r), r.origin.x.isFinite, r.origin.y.isFinite,
              !(r.origin == .zero && r.size == .zero) else { return nil }
        return axToCocoa(r)
    }

    /// AX uses top-left origin relative to the primary screen.
    static func axToCocoa(_ r: CGRect) -> NSRect {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: r.origin.x, y: primaryMaxY - r.origin.y - max(r.height, 1), width: max(r.width, 1), height: max(r.height, 1))
    }

    /// Pure placement logic (unit-testable): above caret (8pt gap), centered, clamped; below if no room.
    static func frame(size: NSSize, caret: NSRect?, screens: [(frame: NSRect, visible: NSRect)], fallbackVisible: NSRect) -> (NSRect, String) {
        if let caret, let scr = screens.first(where: { $0.frame.intersects(caret) || $0.frame.contains(caret.origin) }) {
            let v = scr.visible
            var x = caret.midX - size.width / 2
            x = min(max(x, v.minX + 8), v.maxX - size.width - 8)
            var y = caret.maxY + 8
            var mode = "caret-above"
            if y + size.height > v.maxY - 4 {
                y = caret.minY - 8 - size.height
                mode = "caret-below"
            }
            y = min(max(y, v.minY + 4), v.maxY - size.height - 4)
            return (NSRect(x: x, y: y, width: size.width, height: size.height), mode)
        }
        let v = fallbackVisible
        return (NSRect(x: v.midX - size.width / 2, y: v.minY + 16, width: size.width, height: size.height), "fallback-bottom-center")
    }

    static func selfTest() {
        let screen = (frame: NSRect(x: 0, y: 0, width: 1440, height: 900), visible: NSRect(x: 0, y: 0, width: 1440, height: 875))
        let size = NSSize(width: 560, height: 182)
        let cases: [(String, NSRect?)] = [
            ("mid", NSRect(x: 700, y: 400, width: 2, height: 16)),
            ("top", NSRect(x: 700, y: 820, width: 2, height: 16)),
            ("left-edge", NSRect(x: 10, y: 300, width: 2, height: 16)),
            ("none", nil),
        ]
        var out: [String] = []
        for (name, c) in cases {
            let (f, mode) = frame(size: size, caret: c, screens: [screen], fallbackVisible: screen.visible)
            out.append("\(name): \(mode) x=\(Int(f.minX)) y=\(Int(f.minY)) w=\(Int(f.width)) h=\(Int(f.height))")
        }
        AppLog.info("Placement self-test: " + out.joined(separator: " | "))
    }
}
