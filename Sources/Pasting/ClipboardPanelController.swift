import Foundation
import AppKit
import SwiftUI
import Combine

/// Owns the non-activating bottom panel. Top bar (search + 纯文本粘贴 button) is AppKit
/// for reliable focus/typing; tabs and cards are SwiftUI (NSHostingView).
final class ClipboardPanelController: NSObject, NSSearchFieldDelegate, NSWindowDelegate {
    static let shared = ClipboardPanelController()

    let model = PanelModel()
    private(set) var previousApp: NSRunningApplication?
    private(set) var isVisible = false
    private var panel: NSPanel?
    var benchPanel: NSPanel? { panel }
    /// Test mode: render offscreen-equivalent (alpha 0) so tests never flash on the user's screen.
    var testInvisible = false
    private var searchField: NSSearchField!
    private var plainButton: NSButton!
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var scrollMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var searchText = ""
    private var lastSearch: (query: String, tab: PanelTab, version: Int, results: [ClipItem])?

    private override init() {
        super.init()
        Store.shared.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                guard let self else { return }
                self.recomputeAppStats(items)
                if self.isVisible { self.reloadItems() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: Store.panelSizeChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self, let panel = self.panel, !panel.inLiveResize else { return }
            self.model.cardSize = Store.shared.settings.effectiveCardSize
            if self.isVisible { self.positionPanel() }
        }
        NotificationCenter.default.addObserver(forName: L10n.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.searchField?.placeholderString = L("搜索剪贴板…")
            self.plainButton?.title = L("纯文本粘贴")
            self.plainButton?.toolTip = L("把选中的卡片去掉格式后粘贴（⌥↵）")
            self.recomputeAppStats(Store.shared.items)
        }
        model.$selectedIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updatePlainButton() }
            .store(in: &cancellables)
    }

    /// Build the panel at launch so the hotkey only has to orderFront.
    func prepare() {
        ensurePanel()
        reloadItems()
        positionPanel()
        panel?.displayIfNeeded()
    }

    /// Apply a query synchronously (bench/self-test) and return result count.
    func applySearch(_ q: String) -> Int {
        searchField.stringValue = q
        searchText = q
        model.selectedIndex = 0
        reloadItems()
        return model.items.count
    }
    func benchType(_ s: String) {
        panel?.makeFirstResponder(searchField)
        (searchField.currentEditor() as? NSTextView)?.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    func benchAppFilter(_ key: String?, query: String = "") -> Int {
        model.selectedTab = key.map { .app($0) } ?? .history
        return applySearch(query)
    }
    /// Internal test: feed a ⌘-key NSEvent through the real key handler.
    func benchCmdKey(_ ch: String, keyCode: UInt16) {
        guard let panel, let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: keyCode) else { return }
        _ = handleKey(ev)
    }
    var fieldSelection: NSRange { searchField.currentEditor()?.selectedRange ?? NSRange(location: 0, length: 0) }
    var fieldText: String { searchField.stringValue }
    /// Screenshot helpers.
    func shotSetSearch(_ q: String) { searchField.stringValue = q; searchText = q; model.selectedIndex = 0; reloadItems() }
    func shotRefresh() { recomputeAppStats(Store.shared.items); reloadItems() }
    func shotSetTab(_ tab: PanelTab) { model.selectedTab = tab; model.selectedIndex = 0; reloadItems() }
    var shotContentView: NSView? { panel?.contentView }
    var isPanelKey: Bool { panel?.isKeyWindow ?? false }
    var searchHasFocus: Bool { panel?.firstResponder === searchField.currentEditor() }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        searchText = ""
        model.selectedIndex = 0
        model.selectedTab = .history
        ensurePanel()
        searchField.stringValue = ""
        reloadItems()
        positionPanel()
        panel?.alphaValue = testInvisible ? 0 : 1
        panel?.orderFrontRegardless()
        if !testInvisible {   // tests must never steal the user's keyboard focus
            panel?.makeKey()
            panel?.makeFirstResponder(searchField)
        }
        isVisible = true
        installMonitors()
        AppLog.info("Panel shown")
    }

    func hide() {
        guard let panel else { return }
        isVisible = false
        removeMonitors()
        panel.orderOut(nil)
        AppLog.info("Panel hidden")
    }

    // MARK: - Actions

    func paste(index: Int, plainText: Bool) {
        guard model.items.indices.contains(index) else { return }
        let item = model.items[index]
        let app = previousApp
        hide()
        Paster.paste(item: item, into: app, plainText: plainText)
    }

    func pasteSelected(plainText: Bool = false) { paste(index: model.selectedIndex, plainText: plainText) }

    func copy(index: Int) {
        guard model.items.indices.contains(index) else { return }
        Paster.writeToPasteboard(model.items[index])
    }

    func moveSelection(_ delta: Int) {
        let n = model.items.count
        guard n > 0 else { return }
        model.selectedIndex = (model.selectedIndex + delta + n) % n
    }

    @objc private func closeClicked() { hide() }

    @objc private func plainButtonClicked() { pasteSelected(plainText: true) }

    private func canPlain(_ item: ClipItem?) -> Bool {
        guard let item else { return false }
        return (item.kind == .text || item.kind == .url) && item.plainText != nil
    }

    private func updatePlainButton() {
        plainButton?.isEnabled = canPlain(model.selectedItem)
    }

    static func appStats(for items: [ClipItem]) -> [AppStat] {
        var acc: [String: (name: String, count: Int, latest: Date)] = [:]
        for it in items {
            let k = it.appKey
            var e = acc[k] ?? (it.sourceAppName ?? L("未知"), 0, .distantPast)
            e.count += 1
            if it.createdAt > e.latest { e.latest = it.createdAt; if let n = it.sourceAppName { e.name = n } }
            acc[k] = e
        }
        return acc.map { AppStat(key: $0.key, name: $0.key == "unknown" ? L("未知") : $0.value.name, count: $0.value.count, latest: $0.value.latest) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.latest > $1.latest }
    }

    private func recomputeAppStats(_ items: [ClipItem]) {
        let s = Self.appStats(for: items)
        if s != model.appStats { model.appStats = s }
    }

    private func reloadItems() {
        var pinID: UUID?
        var appKey: String?
        switch model.selectedTab {
        case .pinboard(let id): pinID = id
        case .app(let k): appKey = k
        case .history, .favorites: break
        }
        // Incremental narrowing: if the query extends the last one on the same tab and data is unchanged,
        // filter the previous results instead of all items.
        let store = Store.shared
        let incremental = lastSearch.map { $0.version == store.version && $0.tab == model.selectedTab
            && !$0.query.isEmpty && searchText.hasPrefix($0.query) } ?? false
        let t0 = CFAbsoluteTimeGetCurrent()
        let newItems = store.filteredItems(query: searchText, pinboardID: pinID, appKey: appKey, favoritesOnly: model.selectedTab == .favorites,
                                           within: incremental ? lastSearch?.results : nil)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        if ms > 5 { AppLog.info(String(format: "slow filter %.1fms (%d items)", ms, newItems.count)) }
        lastSearch = (searchText, model.selectedTab, store.version, newItems)
        if model.pinboards != Store.shared.pinboards { model.pinboards = Store.shared.pinboards }
        if model.items != newItems { model.items = newItems }
        if model.selectedIndex >= newItems.count { model.selectedIndex = max(0, newItems.count - 1) }
        updatePlainButton()
    }

    private lazy var actions = PanelActions(
        select: { [weak self] i in self?.model.selectedIndex = i },
        paste: { [weak self] i, plain in self?.paste(index: i, plainText: plain) },
        copy: { [weak self] i in self?.copy(index: i) },
        rename: { [weak self] item in self?.renameItem(item) },
        toggleFavorite: { [weak self] item in self?.toggleFavorite(item.id) },
        delete: { [weak self] item in Store.shared.delete(id: item.id); self?.reloadItems() },
        addToPinboard: { [weak self] item, b in Store.shared.addToPinboard(itemID: item.id, pinboardID: b); self?.reloadItems() },
        selectTab: { [weak self] tab in
            guard let self else { return }
            if case .app = tab, self.model.selectedTab == tab {
                self.model.selectedTab = .history
            } else {
                self.model.selectedTab = tab
            }
            self.model.selectedIndex = 0
            self.reloadItems()
        },
        addPinboard: { [weak self] in self?.addPinboard() },
        renamePinboard: { [weak self] b in self?.renamePinboard(b) },
        deletePinboard: { [weak self] b in
            guard let self else { return }
            Store.shared.deletePinboard(id: b.id)
            if self.model.selectedTab == .pinboard(b.id) { self.model.selectedTab = .history }
            self.reloadItems()
        }
    )

    // MARK: - Dialogs

    private func prompt(_ title: String, value: String = "", placeholder: String = "", info: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: L("确定"))
        alert.addButton(withTitle: L("取消"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let ok = alert.runModal() == .alertFirstButtonReturn
        panel?.makeKey()
        return ok ? field.stringValue : nil
    }

    private func renameItem(_ item: ClipItem) {
        if let s = prompt(L("重命名"), value: item.customTitle ?? "", placeholder: item.displayTitle) {
            Store.shared.rename(id: item.id, title: s); reloadItems()
        }
    }
    func toggleFavorite(_ id: UUID) {
        Store.shared.toggleFavorite(id: id)
        reloadItems()
        if !model.items.isEmpty { model.selectedIndex = min(model.selectedIndex, model.items.count - 1) }
    }

    private func addPinboard() {
        if let s = prompt(L("新建分类"), info: L("例如：工作、Travel")) {
            Store.shared.addPinboard(name: s); reloadItems()
        }
    }
    private func renamePinboard(_ b: Pinboard) {
        if let s = prompt(L("重命名分类"), value: b.name) {
            Store.shared.renamePinboard(id: b.id, name: s); reloadItems()
        }
    }

    // MARK: - Panel construction

    private func ensurePanel() {
        if panel != nil { return }
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 210),
                            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless, .resizable],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.delegate = self
        panel.minSize = NSSize(width: 380, height: PanelPlacement.height(forCard: 90))
        panel.maxSize = NSSize(width: 1600, height: PanelPlacement.height(forCard: 220))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let fx = NSVisualEffectView(frame: panel.contentRect(forFrameRect: panel.frame))
        fx.autoresizingMask = [.width, .height]
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 14
        fx.layer?.masksToBounds = true

        let search = NSSearchField()
        search.placeholderString = L("搜索剪贴板…")
        search.delegate = self
        search.controlSize = .regular
        search.translatesAutoresizingMaskIntoConstraints = false
        searchField = search

        let plain = NSButton(title: L("纯文本粘贴"), target: self, action: #selector(plainButtonClicked))
        plain.image = NSImage(systemSymbolName: "textformat", accessibilityDescription: nil)
        plain.imagePosition = .imageLeading
        plain.bezelStyle = .rounded
        plain.controlSize = .regular
        plain.bezelColor = .controlAccentColor
        plain.keyEquivalent = ""
        plain.toolTip = L("把选中的卡片去掉格式后粘贴（⌥↵）")
        plain.translatesAutoresizingMaskIntoConstraints = false
        plainButton = plain

        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("关闭"))!,
                             target: self, action: #selector(closeClicked))
        close.isBordered = false
        close.bezelStyle = .inline
        close.contentTintColor = .secondaryLabelColor
        close.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        close.toolTip = L("关闭 (Esc)")
        close.translatesAutoresizingMaskIntoConstraints = false

        let hosting = NSHostingView(rootView: PanelContentView(model: model, actions: actions))
        hosting.translatesAutoresizingMaskIntoConstraints = false

        fx.addSubview(search)
        fx.addSubview(plain)
        fx.addSubview(close)
        fx.addSubview(hosting)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: fx.topAnchor, constant: 8),
            search.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: plain.leadingAnchor, constant: -8),
            plain.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            plain.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -10),
            close.widthAnchor.constraint(equalToConstant: 20),
            hosting.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 4),
            hosting.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        panel.contentView = fx
        self.panel = panel
    }

    private func positionPanel() {
        guard let panel else { return }
        let st = Store.shared.settings
        model.cardSize = st.effectiveCardSize
        let size = NSSize(width: st.effectivePanelWidth, height: PanelPlacement.height(forCard: st.effectiveCardSize))
        let caret = PanelPlacement.caretRect()
        let mouse = NSEvent.mouseLocation
        let fallbackScreen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        let (f, mode) = PanelPlacement.frame(size: size, caret: caret,
                                             screens: NSScreen.screens.map { ($0.frame, $0.visibleFrame) },
                                             fallbackVisible: fallbackScreen?.visibleFrame ?? .zero)
        isPositioning = true
        panel.setFrame(f, display: false)
        isPositioning = false
        AppLog.info("Panel placed: \(mode) frame=\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))")
    }

    private var isPositioning = false

    // User drag-resize: persist width; height maps to card size.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel else { return }
        let card = Double(panel.frame.height - PanelPlacement.chromeHeight)
        Store.shared.setPanelSize(width: Double(panel.frame.width), card: card)
        model.cardSize = Store.shared.settings.effectiveCardSize
        AppLog.info("Panel resized by user: \(Int(panel.frame.width))x\(Int(panel.frame.height)) card=\(Int(model.cardSize))")
    }

    // MARK: - Search

    private var searchWork: DispatchWorkItem?
    func controlTextDidChange(_ obj: Notification) {
        searchWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.searchText = self.searchField.stringValue
            self.model.selectedIndex = 0
            self.reloadItems()
        }
        searchWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: w)
    }

    // MARK: - Keyboard / clicks (AppKit for reliability)

    private func installMonitors() {
        removeMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.handleKey(e) }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self, e.window === self.panel else { return e }
            return self.handleScroll(e) ? nil : e
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isVisible, let panel = self.panel else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) { self.hide() }
            }
        }
    }

    private func removeMonitors() {
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
    }

    /// The SwiftUI horizontal card row is backed by an NSScrollView; pick the tallest one (not the tab bar).
    func cardScrollView() -> NSScrollView? {
        guard let root = panel?.contentView else { return nil }
        var found: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView { found.append(s) }
            v.subviews.forEach(walk)
        }
        walk(root)
        return found.filter { $0.frame.height > 60 }.max { $0.frame.height < $1.frame.height }
    }

    /// Map vertical wheel / two-finger vertical to horizontal scrolling of the card row.
    /// Returns true if handled (event consumed). Horizontal-dominant events pass through untouched.
    @discardableResult
    func handleScroll(_ e: NSEvent) -> Bool {
        let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        guard abs(dy) > abs(dx), let sv = cardScrollView(), let doc = sv.documentView else { return false }
        let clip = sv.contentView
        let maxX = max(0, doc.frame.width - clip.bounds.width)
        guard maxX > 0 else { return true }
        let step = e.hasPreciseScrollingDeltas ? dy : dy * 40   // wheel notches are line units
        var origin = clip.bounds.origin
        origin.x = min(max(0, origin.x - step), maxX)
        clip.setBoundsOrigin(origin)
        sv.reflectScrolledClipView(clip)
        return true
    }

    private func handleKey(_ e: NSEvent) -> NSEvent? {
        guard isVisible, e.window === panel else { return e }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch e.keyCode {
        case 53: hide(); return nil
        case 36, 76:
            pasteSelected(plainText: flags.contains(.option))
            return nil
        case 123: moveSelection(-1); return nil
        case 124: moveSelection(1); return nil
        default:
            if flags.contains(.command), let ch = e.charactersIgnoringModifiers?.lowercased() {
                // ⌘C with no text selected in the field copies the selected card.
                if flags == .command, ch == "c", searchField.currentEditor()?.selectedRange.length ?? 0 == 0 {
                    copy(index: model.selectedIndex); return nil
                }
                if flags == .command, ch == "d", let it = model.selectedItem {
                    toggleFavorite(it.id); return nil
                }
                if flags == .command, ch == "," {
                    hide(); SettingsWindowController.shared.show(); return nil
                }
                // Route standard edit shortcuts to the search field editor.
                let sel: Selector?
                switch (ch, flags.contains(.shift)) {
                case ("a", false): sel = #selector(NSText.selectAll(_:))
                case ("x", false): sel = #selector(NSText.cut(_:))
                case ("c", false): sel = #selector(NSText.copy(_:))
                case ("v", false): sel = #selector(NSText.paste(_:))
                case ("z", false): sel = Selector(("undo:"))
                case ("z", true):  sel = Selector(("redo:"))
                default: sel = nil
                }
                if let sel {
                    if panel?.firstResponder !== searchField.currentEditor() { panel?.makeFirstResponder(searchField) }
                    NSApp.sendAction(sel, to: searchField.currentEditor(), from: self)
                    return nil
                }
                return e
            }
            if panel?.firstResponder !== searchField.currentEditor() {
                panel?.makeFirstResponder(searchField)
            }
            return e
        }
    }
}


/// Borderless panels return canBecomeKey = false by default, so the search field
/// never received keystrokes. This keeps it non-activating but able to be key.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
