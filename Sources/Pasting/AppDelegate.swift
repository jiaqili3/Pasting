import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var pauseMenuItem: NSMenuItem?
    private var loginMenuItem: NSMenuItem?
    private var retentionItems: [NSMenuItem] = []
    private var purgeTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.info("Pasting launching")
        NSApp.setActivationPolicy(.accessory)

        L10n.shared.apply(Store.shared.settings.languageChoice)
        if TestMode.isOn {
            TestMode.start()
            return
        }
        setupStatusItem()
        installEditMenu()
        HotKeyManager.shared.onHotKey = { [weak self] in
            DispatchQueue.main.async {
                self?.showPanel()
            }
        }
        HotKeyManager.shared.register()
        ClipboardMonitor.shared.start()
        RichText.selfTest()
        // Dev-only benchmark hook: `defaults write com.jiaqili.pasting DevBench -bool YES`
        if UserDefaults.standard.bool(forKey: "DevBench") { Bench.install() }
        ClipboardPanelController.shared.prepare()
        ThumbCache.shared.prewarm(Store.shared.items.compactMap(\.imageFilename))
        Store.retentionSelfTest()
        PanelPlacement.selfTest()
        Store.shared.purgeExpired(reason: "launch")
        purgeTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            DispatchQueue.main.async { Store.shared.purgeExpired(reason: "hourly") }
        }
        GuideWindowController.shared.showIfNeeded()
        AppLog.info("Pasting ready")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Store.shared.saveNow(sync: true)
        HotKeyManager.shared.unregister()
        ClipboardMonitor.shared.stop()
        AppLog.info("Pasting terminated")
    }

    /// Hidden main menu so standard edit shortcuts (⌘A/C/V/X/Z, ⇧⌘Z) reach the search field.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = NSMenu(); main.addItem(appItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Pasting")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        rebuildMenu(menu)
    }

    /// Rebuilt each time it opens, so titles follow the language and checkmarks follow Settings.
    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu(menu) }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        retentionItems = []
        func add(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let m = NSMenuItem(title: title, action: action, keyEquivalent: key)
            m.keyEquivalentModifierMask = mods
            m.target = self
            menu.addItem(m)
            return m
        }
        _ = add(L("显示 Pasting"), #selector(showPanel), "v", [.command, .shift])
        menu.addItem(.separator())
        pauseMenuItem = add(L("暂停捕获"), #selector(togglePause))
        let retention = add(L("历史保留"), nil)
        let sub = NSMenu()
        for (title, days) in [(L("1 天"), 1), (L("7 天"), 7), (L("30 天"), 30), (L("永久"), 0)] {
            let m = NSMenuItem(title: title, action: #selector(setRetention(_:)), keyEquivalent: "")
            m.target = self
            m.tag = days
            sub.addItem(m)
            retentionItems.append(m)
        }
        retention.submenu = sub
        _ = add(L("清空历史"), #selector(clearHistory))
        menu.addItem(.separator())
        loginMenuItem = add(L("登录时打开"), #selector(toggleLogin))
        _ = add(L("设置…"), #selector(openSettings), ",")
        _ = add(L("显示引导"), #selector(showGuide))
        menu.addItem(.separator())
        _ = add(L("退出 Pasting"), #selector(quit), "q")
        refreshMenuState()
    }

    private func refreshMenuState() {
        let paused = Store.shared.settings.capturingPaused
        pauseMenuItem?.title = paused ? L("继续捕获") : L("暂停捕获")
        loginMenuItem?.state = Store.shared.settings.openAtLogin ? .on : .off
        let days = Store.shared.settings.effectiveRetentionDays
        for m in retentionItems { m.state = m.tag == days ? .on : .off }
    }

    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func showGuide() { GuideWindowController.shared.show() }

    @objc private func showPanel() {
        ClipboardPanelController.shared.toggle()
    }

    @objc private func togglePause() {
        let next = !Store.shared.settings.capturingPaused
        Store.shared.setCapturingPaused(next)
        refreshMenuState()
        AppLog.info(next ? "Capturing paused" : "Capturing resumed")
    }

    @objc private func setRetention(_ sender: NSMenuItem) {
        Store.shared.setRetentionDays(sender.tag)
        refreshMenuState()
    }

    @objc private func clearHistory() { AppDelegate.confirmClearHistory() }

    static func confirmClearHistory() {
        let alert = NSAlert()
        alert.messageText = L("清空历史？")
        alert.informativeText = L("收藏的条目会保留。此操作不可撤销。")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("清空"))
        alert.addButton(withTitle: L("取消"))
        if alert.runModal() == .alertFirstButtonReturn {
            Store.shared.clearHistory()
        }
    }

    @objc private func toggleLogin() {
        let next = !Store.shared.settings.openAtLogin
        Store.shared.setOpenAtLogin(next)
        refreshMenuState()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
