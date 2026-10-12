import AppKit
import QuartzCore

/// Debug benchmark: `osascript`/swift can post distributed notification "com.jiaqili.pasting.bench".
/// Measures show() -> drawn, and arrow-selection -> drawn, logging to Pasting.log.
enum Bench {
    static func install() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.jiaqili.pasting.bench"), object: nil, queue: .main) { _ in
            run()
        }
    }

    static func run() {
        // Language switch test (restores original choice)
        let orig = Store.shared.settings.languageChoice
        Store.shared.setLanguage(.en)
        let en = [L("历史"), L("纯文本粘贴"), L("搜索剪贴板…"), L("清空历史"), Fmt.relative.localizedString(fromTimeInterval: -3600)]
        Store.shared.setLanguage(.zh)
        let zh = [L("历史"), L("纯文本粘贴"), L("搜索剪贴板…"), L("清空历史"), Fmt.relative.localizedString(fromTimeInterval: -3600)]
        Store.shared.setLanguage(orig)
        AppLog.info("BENCH l10n: en=\(en) zh=\(zh) restored=\(orig.rawValue) isChinese=\(L10n.shared.isChinese) system=\(Locale.preferredLanguages.first ?? "?")")
        let c = ClipboardPanelController.shared
        if c.isVisible { c.hide() }
        let t0 = CACurrentMediaTime()
        c.show()
        c.benchPanel?.displayIfNeeded()
        let tShow = (CACurrentMediaTime() - t0) * 1000
        DispatchQueue.main.async {
            c.benchPanel?.displayIfNeeded()
            let tShow2 = (CACurrentMediaTime() - t0) * 1000
            var times: [Double] = []
            for _ in 0..<10 {
                let t = CACurrentMediaTime()
                c.moveSelection(1)
                RunLoop.main.run(until: Date())
                c.benchPanel?.displayIfNeeded()
                times.append((CACurrentMediaTime() - t) * 1000)
            }
            let avg = times.reduce(0, +) / Double(times.count)
            AppLog.info(String(format: "BENCH show=%.1fms (next runloop %.1fms) arrow avg=%.1fms max=%.1fms items=%d",
                               tShow, tShow2, avg, times.max() ?? 0, c.model.items.count))
            // Synthetic wheel events (non-precise, vertical): should move card row horizontally.
            if let sv = c.cardScrollView() {
                let before = sv.contentView.bounds.origin.x
                var handled = 0
                for _ in 0..<5 {
                    if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: -3, wheel2: 0, wheel3: 0),
                       let ev = NSEvent(cgEvent: cg), c.handleScroll(ev) { handled += 1 }
                }
                let mid = sv.contentView.bounds.origin.x
                for _ in 0..<2 {
                    if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 3, wheel2: 0, wheel3: 0),
                       let ev = NSEvent(cgEvent: cg) { c.handleScroll(ev) }
                }
                let after = sv.contentView.bounds.origin.x
                // Horizontal-dominant event must pass through (not handled).
                var passH = false
                if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -20, wheel3: 0),
                   let ev = NSEvent(cgEvent: cg) { passH = !c.handleScroll(ev) }
                AppLog.info(String(format: "BENCH scroll: x %.0f -> %.0f (5 down) -> %.0f (2 up), handled=%d, horizontal passthrough=%@, docW=%.0f clipW=%.0f",
                                   before, mid, after, handled, passH ? "yes" : "no",
                                   sv.documentView?.frame.width ?? 0, sv.contentView.bounds.width))
            } else {
                AppLog.error("BENCH scroll: card scroll view not found")
            }
            // Edit shortcuts in search field (internal, through real handleKey)
            _ = c.applySearch("")
            c.benchType("hello")
            c.benchCmdKey("a", keyCode: 0)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let selA = c.fieldSelection
            let textBeforeV = c.fieldText
            let savedPB = NSPasteboard.general.string(forType: .string)
            Store.shared.setCapturingPaused(true)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString("XYZ", forType: .string)
            c.benchCmdKey("v", keyCode: 9)
            let afterV = c.fieldText
            NSPasteboard.general.clearContents(); if let s = savedPB { NSPasteboard.general.setString(s, forType: .string) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { Store.shared.setCapturingPaused(false) }
            AppLog.info("BENCH edit: cmdA selection=\(selA.location),\(selA.length) (want 0,5) text='\(textBeforeV)'; cmdV field='\(afterV)' (want XYZ), panel still visible=\(c.isVisible)")
            _ = c.applySearch("")
            // Search perf on 500 synthetic in-memory items (not saved)
            do {
                var synth: [ClipItem] = []
                let words = ["模型","权重","optimizer","FlexiCodec","meeting","travel","https://example.com/a","bold","深度学习","Résumé"]
                for i in 0..<500 {
                    let body = (0..<40).map { words[($0 * 7 + i) % words.count] }.joined(separator: " ") + " #\(i)"
                    synth.append(ClipItem(kind: .text, text: String(repeating: body + "\n", count: i % 50 == 0 ? 60 : 1),
                                          customTitle: i % 10 == 0 ? "Title \(i)" : nil, sourceAppName: i % 2 == 0 ? "Safari" : "备忘录"))
                }
                var t0 = CFAbsoluteTimeGetCurrent()
                var keys: [UUID: String] = [:]
                for it in synth { keys[it.id] = SearchIndex.key(for: it) }
                let indexMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                var res: [String] = [String(format: "index500=%.1fms", indexMs)]
                var prev = synth
                for q in ["o", "op", "opt", "optimizer", "模", "模型", "resume", "title 1", "zzz"] {
                    t0 = CFAbsoluteTimeGetCurrent()
                    let full = SearchIndex.filter(synth, keys: keys, query: q)
                    let fullMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                    t0 = CFAbsoluteTimeGetCurrent()
                    let base = (q.hasPrefix("o") || q.hasPrefix("模")) ? prev : synth
                    let inc = SearchIndex.filter(base, keys: keys, query: q)
                    let incMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                    prev = inc
                    res.append(String(format: "'%@'=%d full %.2fms inc %.2fms", q, full.count, fullMs, incMs))
                }
                AppLog.info("BENCH search500: " + res.joined(separator: "; "))
            }
            // App filters
            let stats = ClipboardPanelController.appStats(for: Store.shared.items)
            var ap: [String] = []
            for s in stats { ap.append("\(s.name)[\(s.count)]->\(c.benchAppFilter(s.key))") }
            if let top = stats.first { ap.append("\(top.name)+query'e'->\(c.benchAppFilter(top.key, query: "e"))") }
            ap.append("history->\(c.benchAppFilter(nil))")
            AppLog.info("BENCH apps: " + ap.joined(separator: ", "))
            // Search
            AppLog.info("BENCH search: panelKey=\(c.isPanelKey) searchFocused=\(c.searchHasFocus)")
            let all = c.applySearch("")
            var parts: [String] = ["''=\(all)"]
            for q in ["BOLD", "bold", "example.com", "FlexiCodec", "模型", "zzzz-none"] {
                parts.append("'\(q)'=\(c.applySearch(q))")
            }
            // Simulated typing through the field editor + real debounce path
            _ = c.applySearch("")
            c.benchType("bol")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                AppLog.info("BENCH search counts: " + parts.joined(separator: " ") + " | typed 'bol' via field editor -> \(c.model.items.count)")
                _ = c.applySearch("")
                c.hide()
            }
        }
    }
}
