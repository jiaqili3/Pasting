import AppKit
import Darwin

/// Isolated test mode: `PASTING_DATA_DIR=/tmp/x Pasting.app/Contents/MacOS/Pasting --test <command>`
/// No status item, no hotkey, no guide, capture paused (the clipboard is never recorded), panel invisible.
enum TestMode {
    static let dataDir: URL? = ProcessInfo.processInfo.environment["PASTING_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    static var isOn: Bool { dataDir != nil && CommandLine.arguments.contains("--test") }

    static func arg(after flag: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func start() {
        Store.shared.settings.capturingPaused = true   // never record the real clipboard in tests
        ClipboardMonitor.shared.start()
        ClipboardPanelController.shared.testInvisible = true
        ClipboardPanelController.shared.prepare()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if CommandLine.arguments.contains("resources") { runResources() }
            if CommandLine.arguments.contains("axdrag") {
                let s = AccessibilityHelper.pasteboardItem().string(forType: .fileURL) ?? "nil"
                let ok = URL(string: s)?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL && s.hasSuffix("Pasting.app/")
                AppLog.info("AXDRAG pasteboard file-url=\(s) bundle=\(Bundle.main.bundleURL.path) \(ok ? "PASS" : "FAIL")")
            }
            if CommandLine.arguments.contains("scrolltest") { runScrollTest() }
            if CommandLine.arguments.contains("favtest") { runFavTest() }
            if CommandLine.arguments.contains("dragtest") { runDragTest() }
            if CommandLine.arguments.contains("cleartest") { runClearTest() }
            if CommandLine.arguments.contains("animtest") { runAnimTest() }
            if CommandLine.arguments.contains("qltest") { runQLTest() }
            if CommandLine.arguments.contains("ringtest") { runRingTest() }
            if CommandLine.arguments.contains("cornertest") {
                Store.shared.replaceAllForTest(makeSynthetic(count: 20, images: 0))
                let c = ClipboardPanelController.shared
                c.show(); RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                AppLog.info("CORNERTEST " + c.cornerAlphaReport())
                c.hide()
            }
            if let dir = arg(after: "screenshots") { Screenshots.run(into: URL(fileURLWithPath: dir)) }
        }
    }

    // MARK: - Synthetic data

    static func makeSynthetic(count: Int, images: Int) -> [ClipItem] {
        var out: [ClipItem] = []
        let apps = [("com.apple.Safari", "Safari"), ("com.apple.Notes", "Notes"), ("com.tinyspeck.slackmacgap", "Slack"),
                    ("com.microsoft.VSCode", "Code"), ("com.apple.Terminal", "Terminal")]
        let now = Date()
        for i in 0..<count { autoreleasepool {
            let (bid, name) = apps[i % apps.count]
            let date = now.addingTimeInterval(-Double(i) * 300)
            if i < images {
                let size = 1600 + (i % 5) * 200   // full-size-ish images to stress thumbnails
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size * 2 / 3, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSColor(hue: CGFloat(i % 12) / 12, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
                NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
                NSColor.white.withAlphaComponent(0.5).setFill()
                NSBezierPath(ovalIn: NSRect(x: 100, y: 100, width: 600, height: 400)).fill()
                NSGraphicsContext.restoreGraphicsState()
                let name2 = Store.shared.saveImageData(rep.representation(using: .png, properties: [:])!)
                out.append(ClipItem(kind: .image, createdAt: date, imageFilename: name2, sourceAppName: name, sourceAppBundleID: bid))
            } else {
                out.append(ClipItem(kind: .text, createdAt: date,
                                    text: "Synthetic clip #\(i) — meeting notes 模型 权重 optimizer " + String(repeating: "lorem ipsum ", count: 1 + i % 40),
                                    sourceAppName: name, sourceAppBundleID: bid))
            }
        } }
        return out
    }

    // MARK: - Resource test

    /// Synthetic wheel events at points over the chips row and the card row; checks each only scrolls its own row.
    static func runScrollTest() {
        let boards = ["Work", "Travel", "Recipes", "Code", "Links"].map { Pinboard(name: $0) }
        Store.shared.replaceAllForTest(makeSynthetic(count: 60, images: 0), pinboards: boards)
        Store.shared.setPanelSize(width: 420, card: 110)   // small panel so chips overflow
        let c = ClipboardPanelController.shared
        c.show(); c.shotRefresh()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let panel = c.benchPanel, let chips = c.chipsScrollView(), let cards = c.cardScrollView(), chips !== cards else {
            AppLog.error("SCROLLTEST FAIL: scroll views not found"); return
        }
        func off(_ s: NSScrollView) -> CGFloat { s.contentView.bounds.origin.x }
        func span(_ s: NSScrollView) -> CGFloat { (s.documentView?.frame.width ?? 0) - s.contentView.bounds.width }
        func wheel(over s: NSScrollView, lines: Int32) -> Bool {
            let r = s.convert(s.bounds, to: nil)
            let wp = NSPoint(x: r.midX, y: r.midY)
            let sp = panel.convertPoint(toScreen: wp)
            let primaryH = NSScreen.screens.first?.frame.height ?? 0
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { return false }
            cg.location = CGPoint(x: sp.x, y: primaryH - sp.y)
            guard let e = NSEvent(cgEvent: cg) else { return false }
            return c.handleScroll(e)
        }
        AppLog.info(String(format: "SCROLLTEST panel w=%.0f chips h=%.0f overflow=%.0f | cards h=%.0f overflow=%.0f",
                           panel.frame.width, chips.frame.height, span(chips), cards.frame.height, span(cards)))
        let c0 = off(chips), k0 = off(cards)
        let h1 = wheel(over: chips, lines: -3)
        let c1 = off(chips), k1 = off(cards)
        let h2 = wheel(over: cards, lines: -3)
        let c2 = off(chips), k2 = off(cards)
        let h3 = wheel(over: chips, lines: 3)
        let c3 = off(chips)
        let ok = span(chips) > 0 && h1 && c1 > c0 && k1 == k0 && h2 && k2 > k1 && c2 == c1 && h3 && c3 < c2
        AppLog.info(String(format: "SCROLLTEST over chips: chips %.0f->%.0f cards %.0f->%.0f | over cards: chips %.0f->%.0f cards %.0f->%.0f | back over chips: chips %.0f->%.0f | %@",
                           c0, c1, k0, k1, c1, c2, k1, k2, c2, c3, ok ? "PASS" : "FAIL"))
        c.hide()
    }

    /// Create + edit favorites through the editor UI path, then verify search and persistence (fresh decode).
    static func runFavTest() {
        let st = Store.shared
        let rtf = try? NSAttributedString(string: "Rich hello", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
            .data(from: NSRange(location: 0, length: 10), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        st.replaceAllForTest([
            ClipItem(kind: .text, text: "Rich hello", rtfData: rtf, sourceAppName: "TextEdit", sourceAppBundleID: "com.apple.TextEdit", isFavorite: true),
            ClipItem(kind: .url, text: "https://example.com", urlString: "https://example.com", isFavorite: true),
            ClipItem(kind: .image, imageFilename: "none.png", isFavorite: true),
        ])
        let c = ClipboardPanelController.shared
        c.show()
        var log: [String] = []
        // 1) New manual favorite via editor
        c.editItem(nil)
        FavoriteEditor.shared.testFill(title: "Home address", content: "1 Infinite Loop\nCupertino")
        FavoriteEditor.shared.testSave()
        let manual = st.items.first { $0.customTitle == "Home address" }
        log.append("create=\(manual != nil && manual!.isFavorite && manual!.appKey == Store.manualBundleID && !FavoriteEditor.shared.isOpen)")
        // 2) Edit rich text content -> plain
        let rich = st.items.first { $0.isRich }!
        c.editItem(rich)
        let warned = FavoriteEditor.shared.testHasWarning
        FavoriteEditor.shared.testFill(title: "Greeting", content: "Hello edited zebra")
        FavoriteEditor.shared.testSave()
        let r2 = st.items.first { $0.id == rich.id }!
        log.append("richEdit=\(r2.text == "Hello edited zebra" && !r2.isRich && r2.customTitle == "Greeting") warn=\(warned)")
        // 3) URL content edit, 4) image title only
        let url = st.items.first { $0.kind == .url }!
        c.editItem(url); FavoriteEditor.shared.testFill(title: "", content: "https://apple.com"); FavoriteEditor.shared.testSave()
        let img = st.items.first { $0.kind == .image }!
        c.editItem(img); FavoriteEditor.shared.testFill(title: "Logo", content: nil); FavoriteEditor.shared.testSave()
        log.append("url=\(st.items.first { $0.id == url.id }!.urlString == "https://apple.com") imgTitle=\(st.items.first { $0.id == img.id }!.customTitle == "Logo")")
        // Search on edited title/content
        let s1 = st.filteredItems(query: "zebra", pinboardID: nil).count, s2 = st.filteredItems(query: "greeting", pinboardID: nil).count
        let s3 = st.filteredItems(query: "home addr", pinboardID: nil).count, s4 = st.filteredItems(query: "rich hello", pinboardID: nil).count
        log.append("search zebra=\(s1) greeting=\(s2) home=\(s3) oldText=\(s4)")
        // Persist + fresh decode
        st.saveNow(sync: true)
        var persisted = false
        if let d = try? Data(contentsOf: st.storeURL), let p = try? JSONDecoder().decode(PersistedStore.self, from: d) {
            persisted = p.items.contains { $0.customTitle == "Home address" && $0.isFavorite && $0.text == "1 Infinite Loop\nCupertino" }
                && p.items.contains { $0.text == "Hello edited zebra" && $0.rtfData == nil && $0.customTitle == "Greeting" }
                && p.items.contains { $0.customTitle == "Logo" }
        }
        log.append("persisted=\(persisted)")
        let ok = !log.contains { $0.contains("false") } && s1 == 1 && s2 == 1 && s3 == 1 && s4 == 0
        AppLog.info("FAVTEST " + log.joined(separator: " | ") + " | " + (ok ? "PASS" : "FAIL"))
        c.hide()
    }

    /// Non-blocking frame sampling of the clear/confirm/undo animations (presentation layers + composited window).
    /// Samples the composited window: where is the blue selection ring (x) and how high (top y) over time.
    static func runRingTest() {
        Store.shared.replaceAllForTest(makeSynthetic(count: 20, images: 0))
        let c = ClipboardPanelController.shared
        c.show()
        guard let panel = c.benchPanel else { return }
        panel.setFrameOrigin(NSPoint(x: -20000, y: -20000)); panel.alphaValue = 1
        func ring() -> String {
            guard let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber), [.boundsIgnoreFraming]) else { return "-" }
            let rep = NSBitmapImageRep(cgImage: cg); let w = rep.pixelsWide, h = rep.pixelsHigh
            func blue(_ x: Int, _ y: Int) -> Bool {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return c.blueComponent > 0.75 && c.redComponent < 0.45 && c.greenComponent < 0.75 && c.alphaComponent > 0.5
            }
            let midY = h * 3 / 4                       // inside the card row
            var left = -1, right = -1
            for x in 0..<w where blue(x, midY) { if left < 0 { left = x }; right = x }
            var top = -1
            if left >= 0 { for y in (h / 2)..<h where blue(left + 30, y) { top = y; break } }
            return "x=\(left)..\(right) top=\(top)"
        }
        var rows: [String] = []
        let t0 = 0.6
        var steps: [(Double, () -> Void)] = [(t0, { rows.append("before " + ring()); let s = CFAbsoluteTimeGetCurrent(); c.moveSelection(1)
            rows.append(String(format: "moveSelection took %.2f ms", (CFAbsoluteTimeGetCurrent() - s) * 1000)) })]
        for ms in [16, 40, 70, 100, 140, 200, 300, 450] { steps.append((t0 + Double(ms) / 1000, { rows.append("+\(ms)ms " + ring()) })) }
        let t1 = t0 + 0.8
        steps.append((t1, { rows.append("hover-before " + ring()); c.model.hoveredID = c.model.selectedItem?.id }))
        for ms in [40, 100, 250] { steps.append((t1 + Double(ms) / 1000, { rows.append("hover+\(ms)ms " + ring()) })) }
        steps.append((t1 + 0.4, { AppLog.info("RINGTEST reduce=\(Motion.reduce)\n" + rows.joined(separator: "\n")); c.hide() }))
        for (t, f) in steps { Timer.scheduledTimer(withTimeInterval: t, repeats: false) { _ in f() } }
    }

    static func runQLTest() {
        let st = Store.shared
        // A big image so we can check the preview uses the full-size original, not the thumbnail.
        let big = NSImage(size: NSSize(width: 2400, height: 1600)); big.lockFocus()
        NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 2400, height: 1600).fill(); big.unlockFocus()
        let png = NSBitmapImageRep(data: big.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let imgName = st.saveImageData(png) ?? ""
        st.replaceAllForTest([
            ClipItem(kind: .image, createdAt: Date(), imageFilename: imgName),
            ClipItem(kind: .file, createdAt: Date().addingTimeInterval(-10), fileURLs: ["/System/Applications/Calculator.app"]),
            ClipItem(kind: .text, createdAt: Date().addingTimeInterval(-20), text: "Hello Quick Look"),
            ClipItem(kind: .color, createdAt: Date().addingTimeInterval(-30), text: "#FF0000", colorHex: "#FF0000"),
        ])
        let q = QuickLookController.shared; q.dryRun = true
        let c = ClipboardPanelController.shared
        c.show(); c.testSetSearch("")
        var log: [String] = []
        // URLs per kind
        let items = c.model.items
        let u0 = q.previewURL(for: items[0]), u1 = q.previewURL(for: items[1]), u2 = q.previewURL(for: items[2]), u3 = q.previewURL(for: items[3])
        let px = u0.flatMap { NSImageRep(contentsOf: $0) }.map { "\($0.pixelsWide)x\($0.pixelsHigh)" } ?? "nil"
        let txt = u2.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        log.append("image=\(px) file=\(u1?.lastPathComponent ?? "nil") text=\(txt == "Hello Quick Look") color=\(u3 == nil)")
        // Space with empty search → preview; Esc closes preview first, panel stays.
        c.model.selectedIndex = 0
        let spaceEmpty = c.testKey(49, chars: " ") && q.isOpen
        let n = q.numberOfPreviewItems(in: nil), item0 = (q.previewPanel(nil, previewItemAt: 0) as? NSURL)?.lastPathComponent
        // Arrow while open → selection + preview update
        q.handleKeyWhileOpen(124)
        let afterArrow = c.model.selectedIndex == 1 && (q.previewPanel(nil, previewItemAt: 0) as? NSURL)?.lastPathComponent == "Calculator.app"
        let frame = q.previewPanel(nil, sourceFrameOnScreenFor: nil)
        let esc1 = c.testKey(53, chars: "\u{1b}") && !q.isOpen && c.isVisible
        log.append("spaceEmpty=\(spaceEmpty) items=\(n) first=\(item0 ?? "nil") arrow=\(afterArrow) sourceFrame=\(Int(frame.width))x\(Int(frame.height))@\(Int(frame.minX)),\(Int(frame.minY)) esc1ClosesPreviewOnly=\(esc1)")
        // Space toggles closed
        _ = c.testKey(49, chars: " "); let reopened = q.isOpen; _ = c.testKey(49, chars: " ")
        log.append("spaceToggle=\(reopened && !q.isOpen)")
        // Search has text → Space is not consumed (types into search)
        c.testSetSearch("ab")
        let spaceTyped = !c.testKey(49, chars: " ") && !q.isOpen
        c.testSetSearch("")
        // Color card → not previewable
        c.model.selectedIndex = 3; _ = c.testKey(49, chars: " ")
        log.append("spaceWithText=\(spaceTyped) colorNoPreview=\(!q.isOpen && q.numberOfPreviewItems(in: nil) == 0)")
        let esc2 = c.testKey(53, chars: "\u{1b}") && !c.isVisible
        log.append("esc2ClosesPanel=\(esc2)")
        let ok = !log.joined().contains("false") && (u0.flatMap { NSImageRep(contentsOf: $0) }?.pixelsWide ?? 0) >= 2400 && frame.width > 0
        AppLog.info("QLTEST " + log.joined(separator: " | ") + " | " + (ok ? "PASS" : "FAIL"))
        q.cleanup()
    }

    static func runAnimTest() {
        let st = Store.shared
        var items = makeSynthetic(count: 14, images: 3)
        if let i = items.firstIndex(where: { $0.kind == .text }) { items[i].isFavorite = true }
        st.replaceAllForTest(items)
        let c = ClipboardPanelController.shared
        c.show()
        guard let panel = c.benchPanel, let b = c.trashButton else { AppLog.error("ANIMTEST no panel"); return }
        panel.setFrameOrigin(NSPoint(x: -20000, y: -20000)); panel.alphaValue = 1
        func lum() -> String {
            guard let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber), [.boundsIgnoreFraming]) else { return "-" }
            let rep = NSBitmapImageRep(cgImage: cg); let w = rep.pixelsWide, h = rep.pixelsHigh
            var sum = 0.0, n = 0.0
            for x in stride(from: 20, to: w - 20, by: 6) { for y in stride(from: h * 2 / 3, to: h - 12, by: 6) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) { sum += Double(c.brightnessComponent * c.alphaComponent); n += 1 } } }
            return String(format: "%.3f", n > 0 ? sum / n : 0)
        }
        var rows: [String] = []
        func sample(_ tag: String) {
            rows.append(String(format: "%@ w=%.1f red=%.2f label=%.2f bar=%.2f toastA=%.2f toastY=%.1f cards=%@",
                               tag, b.probeWidth, b.probeRed, b.probeLabelAlpha, b.probeBar,
                               c.testToast?.probeAlpha ?? 0, c.testToast?.probeOffsetY ?? 0, lum()))
        }
        var steps: [(Double, () -> Void)] = []
        let t0 = 0.5
        steps.append((t0, { sample("arm+0"); c.trashClicked() }))
        for ms in [40, 90, 150, 220, 320, 500, 1500, 2900] { steps.append((t0 + Double(ms) / 1000, { sample("arm+\(ms)") })) }
        for ms in [3060, 3120, 3200, 3350, 3600] { steps.append((t0 + Double(ms) / 1000, { sample("timeout+\(ms - 3000)") })) }
        let t1 = t0 + 4.0
        steps.append((t1, { c.trashClicked(); c.trashClicked(); sample("confirm+0") }))
        for ms in [40, 80, 140, 200, 280, 400, 700] { steps.append((t1 + Double(ms) / 1000, { sample("confirm+\(ms)") })) }
        let t2 = t1 + 1.2
        steps.append((t2, { c.undoClear(); sample("undo+0") }))
        for ms in [40, 100, 180, 300, 500] { steps.append((t2 + Double(ms) / 1000, { sample("undo+\(ms)") })) }
        steps.append((t2 + 0.8, {
            AppLog.info("ANIMTEST reduceMotion=\(Motion.reduce) glass=\(Motion.hasGlass)\n" + rows.joined(separator: "\n"))
            c.hide()
        }))
        for (t, f) in steps { Timer.scheduledTimer(withTimeInterval: t, repeats: false) { _ in f() } }
    }

    static func runClearTest() {
        let st = Store.shared
        var items = makeSynthetic(count: 12, images: 4)
        // two favorites, one with an image
        if let i = items.firstIndex(where: { $0.kind == .image }) { items[i].isFavorite = true }
        if let i = items.firstIndex(where: { $0.kind == .text }) { items[i].isFavorite = true }
        st.replaceAllForTest(items)
        let c = ClipboardPanelController.shared
        c.undoDelay = 1.0
        c.show(); RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        func files() -> Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath: st.imageURL(for: "x").deletingLastPathComponent().path)) ?? []) }
        let favIDs = Set(st.items.filter(\.isFavorite).map(\.id))
        let favImg = st.items.first { $0.isFavorite && $0.imageFilename != nil }!.imageFilename!
        let total = st.items.count, files0 = files()
        var log: [String] = ["total=\(total) favs=\(favIDs.count) imgFiles=\(files0.count)"]
        // Favorites tab: hidden/disabled
        c.shotSetTab(.favorites); c.trashClicked(); c.trashClicked()
        log.append("favTabNoop=\(st.items.count == total)")
        c.shotSetTab(.history)
        // Single click only arms; auto-disarms after confirm window
        c.confirmWindow = 0.3
        c.trashClicked(); let armed = c.testTrashArmed && st.items.count == total
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        log.append("armOnly=\(armed) disarmed=\(!c.testTrashArmed)")
        c.confirmWindow = 3
        // Clear + undo
        c.trashClicked(); c.trashClicked()
        let afterClear = Set(st.items.map(\.id)) == favIDs && c.model.clearedCount == total - favIDs.count && files() == files0
        c.undoClear()
        RunLoop.main.run(until: Date().addingTimeInterval(1.3))
        let undone = st.items.count == total && files() == files0 && c.model.clearedCount == nil
        log.append("clear=\(afterClear) undo=\(undone)")
        // Clear + timeout deletes files (except favorite's)
        c.trashClicked(); c.trashClicked()
        let midFiles = files() == files0
        RunLoop.main.run(until: Date().addingTimeInterval(1.4))
        let f2 = files()
        let deleted = midFiles && f2 == [favImg] && Set(st.items.map(\.id)) == favIDs && c.model.clearedCount == nil && c.testPendingCount == 0
        log.append("timeoutDelete=\(deleted) filesLeft=\(f2.count) favImgKept=\(f2.contains(favImg))")
        // Persisted
        st.saveNow(sync: true)
        let persisted = (try? JSONDecoder().decode(PersistedStore.self, from: Data(contentsOf: st.storeURL)))?.items.count == favIDs.count
        log.append("persisted=\(persisted)")
        c.hide()
        AppLog.info("CLEARTEST " + log.joined(separator: " ") + " | " + (!log.contains { $0.contains("false") } ? "PASS" : "FAIL"))
    }

    static func runDragTest() {
        let st = Store.shared
        st.replaceAllForTest(makeSynthetic(count: 2, images: 0))
        let c = ClipboardPanelController.shared
        var log: [String] = []
        // Hit-testing: grabber / top-bar gap / margin drag; search, button, card don't.
        c.show(); RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let f = c.testFrame, w = f.width, h = f.height
        let probes: [(String, NSPoint, Bool)] = [
            ("grabber", NSPoint(x: w / 2, y: h - 4), true),
            ("leftMargin", NSPoint(x: 4, y: h - 22), true),
            ("search", NSPoint(x: 60, y: h - 24), false),
            ("closeBtn", NSPoint(x: w - 20, y: h - 24), false),
            ("card", NSPoint(x: 60, y: 50), false),
            ("betweenCards", NSPoint(x: 12 + c.model.cardSize + 4, y: 50), true),
            ("emptyCardRow", NSPoint(x: w - 40, y: 50), true),
            ("chip", NSPoint(x: 30, y: h - 50), false),
        ]
        var hitOK = true
        for (n, p, want) in probes {
            let (can, v) = c.testCanDrag(at: p)
            log.append("\(n)=\(can)(\(v))"); if can != want { hitOK = false }
        }
        // Caret mode: user move is not persisted, panel stays open.
        st.setPanelPositionMode(remember: false)
        c.testMoveAsUser(to: NSPoint(x: f.minX + 50, y: f.minY + 40))
        let caretNotSaved = st.settings.panelOrigin == nil && c.isVisible
        // Remember mode: persisted, restored on next show.
        st.setPanelPositionMode(remember: true)
        c.testMoveAsUser(to: NSPoint(x: f.minX + 70, y: f.minY + 60))
        let saved = st.settings.panelOrigin
        c.hide(); c.show(); RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let restored = saved.map { abs(c.testFrame.minX - $0[0]) < 1 && abs(c.testFrame.minY - $0[1]) < 1 } ?? false
        // Off-screen drag is clamped to visible screens.
        c.testMoveAsUser(to: NSPoint(x: -5000, y: -5000))
        let vf = NSScreen.screens.map(\.visibleFrame)
        let clamped = vf.contains { $0.contains(c.testFrame) }
        c.hide(); st.setPanelPositionMode(remember: false)
        let ok = hitOK && caretNotSaved && restored && clamped
        AppLog.info("DRAGTEST " + log.joined(separator: " ") + " | caretNotSaved=\(caretNotSaved) remembered=\(saved ?? []) restored=\(restored) clamped=\(clamped) \(c.testFrame) | " + (ok ? "PASS" : "FAIL"))
    }

    static func runResources() {
        var r: [String: Any] = [:]
        r["idle_mb"] = footprintMB()
        let t0 = CFAbsoluteTimeGetCurrent()
        Store.shared.replaceAllForTest(makeSynthetic(count: 500, images: 100))
        r["generate_s"] = CFAbsoluteTimeGetCurrent() - t0
        r["items"] = Store.shared.items.count
        let c = ClipboardPanelController.shared
        // First open (renders thumbnails), then 50 open/close cycles
        var opens: [Double] = []
        func cycle() { autoreleasepool {
            let t = CFAbsoluteTimeGetCurrent()
            c.show()
            c.benchPanel?.displayIfNeeded()
            opens.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
            for _ in 0..<8 { c.moveSelection(1); RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
            c.benchPanel?.displayIfNeeded()
            c.hide()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        } }
        cycle()
        r["first_open_ms"] = opens[0]
        r["after_500_items_mb"] = footprintMB()
        let before = footprintMB()
        for _ in 0..<50 { cycle() }
        r["after_50_cycles_mb"] = footprintMB()
        r["growth_50_cycles_mb"] = footprintMB() - before
        let rest = opens.dropFirst()
        r["open_avg_ms"] = rest.reduce(0, +) / Double(rest.count)
        r["open_max_ms"] = rest.max() ?? 0
        // Scroll through all items once to load every thumbnail, check cache stays bounded
        r["idle_after_generate_mb"] = footprintMB()
        autoreleasepool {
        c.show()
        for _ in 0..<500 { c.moveSelection(1) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        c.benchPanel?.displayIfNeeded()
        c.hide()
        }
        r["after_scroll_all_mb"] = footprintMB()
        r["data_dir_mb"] = dirSizeMB(Store.shared.supportDir)
        let data = try! JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys])
        try? data.write(to: Store.shared.supportDir.appendingPathComponent("results.json"))
        AppLog.info("RESOURCES " + String(data: data, encoding: .utf8)!.replacingOccurrences(of: "\n", with: " "))
    }

    static func dirSizeMB(_ url: URL) -> Double {
        var total = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileAllocatedSizeKey]) {
            for case let f as URL in e { total += (try? f.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0 }
        }
        return Double(total) / 1_048_576
    }
}
