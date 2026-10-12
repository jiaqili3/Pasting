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
