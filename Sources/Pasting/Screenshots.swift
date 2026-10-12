import AppKit
import SwiftUI

/// Test-mode only: renders the app's own windows to PNG with a DEMO dataset (no Screen Recording needed,
/// never touches the real store). Usage: PASTING_DATA_DIR=/tmp/demo Pasting --test screenshots <dir>
enum Screenshots {
    static func demoItems() -> ([ClipItem], [Pinboard]) {
        let work = Pinboard(name: "Work"), travel = Pinboard(name: "Travel")
        let now = Date()
        func ago(_ m: Double) -> Date { now.addingTimeInterval(-m * 60) }
        let rtf: Data? = {
            let a = NSAttributedString(html: Data("<b>Quarterly review</b> — <i>agenda</i> and action items".utf8), documentAttributes: nil)
            return a.flatMap { $0.rtf(from: NSRange(location: 0, length: $0.length), documentAttributes: [:]) }
        }()
        // Demo image
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 420, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(colors: [.systemOrange, .systemPink, .systemPurple])!.draw(in: NSRect(x: 0, y: 0, width: 640, height: 420), angle: 35)
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: 420, y: 250, width: 120, height: 120)).fill()
        NSColor.black.withAlphaComponent(0.25).setFill()
        let mount = NSBezierPath(); mount.move(to: .zero); mount.line(to: NSPoint(x: 220, y: 230)); mount.line(to: NSPoint(x: 380, y: 90))
        mount.line(to: NSPoint(x: 480, y: 180)); mount.line(to: NSPoint(x: 640, y: 0)); mount.close(); mount.fill()
        NSGraphicsContext.restoreGraphicsState()
        let img = Store.shared.saveImageData(rep.representation(using: .png, properties: [:])!)
        let items: [ClipItem] = [
            ClipItem(kind: .text, createdAt: ago(1), text: "Meeting moved to Thursday 3pm — room 4B. Bring the Q4 roadmap draft.",
                     sourceAppName: "Notes", sourceAppBundleID: "com.apple.Notes"),
            ClipItem(kind: .url, createdAt: ago(3), text: "https://github.com/jiaqili3/Pasting", urlString: "https://github.com/jiaqili3/Pasting",
                     sourceAppName: "Safari", sourceAppBundleID: "com.apple.Safari"),
            ClipItem(kind: .image, createdAt: ago(6), imageFilename: img, sourceAppName: "Preview", sourceAppBundleID: "com.apple.Preview"),
            ClipItem(kind: .text, createdAt: ago(9), text: "Quarterly review — agenda and action items", rtfData: rtf,
                     sourceAppName: "TextEdit", sourceAppBundleID: "com.apple.TextEdit"),
            ClipItem(kind: .color, createdAt: ago(14), text: "#0A84FF", colorHex: "#0A84FF", sourceAppName: "Safari", sourceAppBundleID: "com.apple.Safari"),
            ClipItem(kind: .text, createdAt: ago(20), text: "git log --oneline --graph --decorate -20", customTitle: "Pretty git log",
                     sourceAppName: "Terminal", sourceAppBundleID: "com.apple.Terminal", isFavorite: true),
            ClipItem(kind: .file, createdAt: ago(31), fileURLs: ["/System/Applications/Calculator.app"], sourceAppName: "Finder", sourceAppBundleID: "com.apple.finder"),
            ClipItem(kind: .text, createdAt: ago(45), text: "Flight CA1234 · PEK → SZX · Seat 32A · Boarding 08:40", customTitle: "Flight to Shenzhen",
                     sourceAppName: "Notes", sourceAppBundleID: "com.apple.Notes", pinboardIDs: [travel.id], isFavorite: true),
            ClipItem(kind: .url, createdAt: ago(60), text: "https://developer.apple.com/documentation/appkit/nspanel",
                     urlString: "https://developer.apple.com/documentation/appkit/nspanel", sourceAppName: "Safari", sourceAppBundleID: "com.apple.Safari"),
            ClipItem(kind: .text, createdAt: ago(90), text: "会议纪要：下周一前提交模型评测结果，并整理 optimizer 对比表格。",
                     sourceAppName: "Notes", sourceAppBundleID: "com.apple.Notes"),
            ClipItem(kind: .color, createdAt: ago(120), text: "#FF9F0A", colorHex: "#FF9F0A", sourceAppName: "Safari", sourceAppBundleID: "com.apple.Safari"),
        ]
        return (items, [work, travel])
    }

    static func run(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (items, boards) = demoItems()
        Store.shared.replaceAllForTest(items, pinboards: boards)
        Store.shared.setPanelSize(width: 760, card: 130)
        var made: [String] = []
        for lang in [L10n.Choice.en, .zh] {
            Store.shared.setLanguage(lang)
            let sfx = lang == .en ? "en" : "zh"
            let c = ClipboardPanelController.shared
            c.show()
            c.shotRefresh()
            c.shotSetTab(.history); c.shotSetSearch("")
            c.moveSelection(1); c.moveSelection(1); c.moveSelection(1)  // select the rich-text card
            settle(); made.append(panel(c, dir, "panel-\(sfx).png"))
            c.trashClicked(); settle(); made.append(panel(c, dir, "panel-clear-confirm-\(sfx).png"))
            c.trashClicked(); for _ in 0..<12 { settle() }; made.append(panel(c, dir, "panel-cleared-\(sfx).png"))
            c.undoClear(); settle()
            c.shotSetSearch("meeting"); settle(); made.append(panel(c, dir, "panel-search-\(sfx).png"))
            c.shotSetSearch(""); c.shotSetTab(.app("com.apple.Safari")); settle(); made.append(panel(c, dir, "panel-app-filter-\(sfx).png"))
            c.shotSetTab(.favorites); settle(); made.append(panel(c, dir, "panel-favorites-\(sfx).png"))
            if let fav = Store.shared.items.first(where: { $0.isFavorite && $0.kind == .text }) {
                c.editItem(fav); settle()
                if let v = FavoriteEditor.shared.testContentView {
                    v.layoutSubtreeIfNeeded()
                    if let snap = snapshot(v) {
                        let out = NSImage(size: v.bounds.size); out.lockFocus()
                        NSColor.windowBackgroundColor.setFill(); NSRect(origin: .zero, size: v.bounds.size).fill()
                        snap.draw(in: NSRect(origin: .zero, size: v.bounds.size)); out.unlockFocus()
                        made.append(write(out, dir, "favorite-editor-\(sfx).png"))
                    }
                }
                FavoriteEditor.shared.testCancel()
            }
            c.shotSetTab(.pinboard(boards[1].id)); settle(); made.append(panel(c, dir, "panel-pinboard-\(sfx).png"))
            c.shotSetTab(.history)
            c.hide()
            // Guide pages
            for p in 0..<GuideModel.pageCount {
                let m = GuideModel(); m.page = p; m.pageStart = Date().addingTimeInterval(p == 1 ? -2.2 : p == 2 ? -2.6 : p == 3 ? -4.3 : -1.5)
                made.append(render(GuideView(model: m, finish: {}), size: NSSize(width: 640, height: 460), dir, "guide-\(p + 1)-\(sfx).png", vibrancy: true))
            }
            // Accessibility drag helper
            let hm = AXHelperModel(); hm.trusted = false
            made.append(render(AXHelperView(model: hm, close: {}), size: NSSize(width: 400, height: 112), dir, "ax-helper-\(sfx).png", vibrancy: false))
            // Settings tabs
            for (i, name) in ["general", "history", "shortcuts", "privacy", "about"].enumerated() {
                let nav = SettingsNav(); nav.tab = i
                made.append(render(SettingsView(nav: nav), size: NSSize(width: 560, height: 400), dir, "settings-\(name)-\(sfx).png", vibrancy: false))
            }
        }
        Store.shared.setLanguage(.system)
        AppLog.info("SCREENSHOTS wrote \(made.filter { !$0.isEmpty }.count) files to \(dir.path)")
    }

    static func settle() {
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    /// Renders the bottom panel's content over a soft desktop-like backdrop.
    static func panel(_ c: ClipboardPanelController, _ dir: URL, _ name: String) -> String {
        guard let v = c.shotContentView else { return "" }
        v.layoutSubtreeIfNeeded()
        guard let snap = snapshot(v) else { return "" }
        let pad: CGFloat = 36
        let size = NSSize(width: v.bounds.width + pad * 2, height: v.bounds.height + pad * 2)
        let out = NSImage(size: size)
        out.lockFocus()
        NSGradient(colors: [NSColor(calibratedRed: 0.36, green: 0.42, blue: 0.62, alpha: 1), NSColor(calibratedRed: 0.62, green: 0.45, blue: 0.58, alpha: 1)])!
            .draw(in: NSRect(origin: .zero, size: size), angle: 30)
        let r = NSRect(x: pad, y: pad, width: v.bounds.width, height: v.bounds.height)
        let path = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowBlurRadius = 18; sh.shadowColor = .black.withAlphaComponent(0.35); sh.shadowOffset = NSSize(width: 0, height: -6); sh.set()
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
        path.addClip()
        snap.draw(in: r)
        out.unlockFocus()
        return write(out, dir, name)
    }

    static func render<V: View>(_ view: V, size: NSSize, _ dir: URL, _ name: String, vibrancy: Bool) -> String {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        w.alphaValue = 0
        w.orderFrontRegardless()
        settle()
        host.layoutSubtreeIfNeeded()
        guard let snap = snapshot(host) else { w.orderOut(nil); return "" }
        w.orderOut(nil)
        let out = NSImage(size: size)
        out.lockFocus()
        (vibrancy ? NSColor.windowBackgroundColor : NSColor.windowBackgroundColor).setFill()
        NSRect(origin: .zero, size: size).fill()
        snap.draw(in: NSRect(origin: .zero, size: size))
        out.unlockFocus()
        return write(out, dir, name)
    }

    static func snapshot(_ v: NSView) -> NSImage? {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        let img = NSImage(size: v.bounds.size); img.addRepresentation(rep)
        return img
    }

    static func write(_ img: NSImage, _ dir: URL, _ name: String) -> String {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return "" }
        let url = dir.appendingPathComponent(name)
        try? png.write(to: url)
        return url.path
    }
}
