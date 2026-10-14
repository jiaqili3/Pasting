import Foundation
import AppKit
import Quartz
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
        panel?.invalidateShadow()
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
        setTrashArmed(false)
        QuickLookController.shared.close()
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
        QuickLookController.shared.selectionChanged()
    }

    // MARK: - Quick Look support
    func panelScreen() -> NSScreen? { panel?.screen }
    func refocusAfterPreview() {
        guard isVisible, !testInvisible else { return }
        panel?.makeKey(); panel?.makeFirstResponder(searchField)
    }
    func pasteSelectedFromPreview() { pasteSelected(plainText: false) }

    /// Approximate on-screen frame of the selected card (zoom source for Quick Look).
    func selectedCardScreenFrame() -> NSRect? {
        guard let sv = cardScrollView(), let doc = sv.documentView, let win = sv.window else { return nil }
        let size = model.cardSize, i = CGFloat(model.selectedIndex)
        var r = NSRect(x: PanelPlacement.rowInsetH + i * (size + 8), y: (doc.bounds.height - size) / 2, width: size, height: size)
        if doc.isFlipped { r.origin.y = (doc.bounds.height - size) / 2 }
        let inWin = doc.convert(r, to: nil)
        return win.convertToScreen(inWin)
    }

    /// Test hook: run a key event through the panel's key handler; returns true if consumed.
    func testKey(_ keyCode: UInt16, chars: String) -> Bool {
        guard let panel, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: panel.windowNumber, context: nil, characters: chars,
                                                  charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode) else { return false }
        return handleKey(e) == nil
    }
    func testSetSearch(_ q: String) { shotSetSearch(q) }

    @objc private func closeClicked() { hide() }

    // MARK: - One-click clear (two-step confirm, 5 s undo)
    private(set) var trashButton: ClearButton!
    private var toast: UndoToastView!

    private func setToast(_ n: Int?) {
        model.clearedCount = n
        guard let toast else { return }
        if let n {
            toast.label.stringValue = LF("已清空 %d 条", n)
            toast.undo.title = L("撤销")
            toast.present(duration: undoDelay)
        } else {
            toast.dismiss()
        }
    }
    private var trashArmed = false
    // Timers (not GCD) so they also fire inside nested run loops (menus, tests).
    private var disarmTimer: Timer?
    private var finalizeTimer: Timer?
    private var pendingCleared: [ClipItem] = []
    var undoDelay: TimeInterval = 5
    var confirmWindow: TimeInterval = 3

    @objc func trashClicked() {
        guard model.selectedTab != .favorites else { return }
        if !trashArmed {
            setTrashArmed(true)
            disarmTimer = Timer.scheduledTimer(withTimeInterval: confirmWindow, repeats: false) { [weak self] _ in self?.setTrashArmed(false) }
            RunLoop.main.add(disarmTimer!, forMode: .common)
            return
        }
        setTrashArmed(false)
        finalizePendingClear()                       // a previous clear's undo window ends now
        let removed = Store.shared.clearHistoryDeferred()
        guard !removed.isEmpty else { return }
        pendingCleared = removed
        // Phase 1: cards animate out (staggered) while still in the list; phase 2: drop them.
        let removedIDs = Set(removed.map(\.id))
        model.staggerReverse = false
        model.hiddenIDs = removedIDs
        setToast(removed.count)
        let visible = model.items.prefix(16).filter { removedIDs.contains($0.id) }.count
        let outDur = Motion.reduce ? 0.18 : min(0.3, 0.2 + Double(max(0, visible - 1)) * 0.02)
        Timer.scheduledTimer(withTimeInterval: outDur, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.model.selectedIndex = 0
            self.recomputeAppStats(Store.shared.items)
            withAnimation(.easeOut(duration: 0.25)) { self.reloadItems() }
            self.model.hiddenIDs = []
        }
        finalizeTimer = Timer.scheduledTimer(withTimeInterval: undoDelay, repeats: false) { [weak self] _ in self?.finalizePendingClear() }
        RunLoop.main.add(finalizeTimer!, forMode: .common)
    }

    @objc private func undoClicked() { undoClear() }

    func undoClear() {
        guard !pendingCleared.isEmpty else { return }
        finalizeTimer?.invalidate(); finalizeTimer = nil
        let restored = Set(pendingCleared.map(\.id))
        Store.shared.undoClear(pendingCleared)
        pendingCleared = []
        setToast(nil)
        recomputeAppStats(Store.shared.items)
        // Insert hidden, then reveal with a reverse stagger.
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            model.staggerReverse = true
            model.hiddenIDs = restored
            reloadItems()
        }
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: false) { [weak self] _ in self?.model.hiddenIDs = [] }
    }

    func finalizePendingClear() {
        finalizeTimer?.invalidate(); finalizeTimer = nil
        if !pendingCleared.isEmpty { Store.shared.finalizeClear(pendingCleared); pendingCleared = [] }
        if model.clearedCount != nil { setToast(nil) }
    }

    private func setTrashArmed(_ on: Bool) {
        disarmTimer?.invalidate(); disarmTimer = nil
        trashArmed = on
        trashButton?.setArmed(on, countdown: confirmWindow)
    }

    private func updateTrashVisibility() {
        let fav = model.selectedTab == .favorites
        trashButton?.isHidden = fav
        if fav && trashArmed { setTrashArmed(false) }
    }

    var testTrashArmed: Bool { trashArmed }
    var testToast: UndoToastView? { toast }
    var testPendingCount: Int { pendingCleared.count }

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
        for it in items where !it.isSuggested {
            let k = it.appKey
            var e = acc[k] ?? (it.sourceAppName ?? L("未知"), 0, .distantPast)
            e.count += 1
            if it.createdAt > e.latest { e.latest = it.createdAt; if let n = it.sourceAppName { e.name = n } }
            acc[k] = e
        }
        return acc.map { AppStat(key: $0.key, name: $0.key == "unknown" ? L("未知") : $0.key == Store.manualBundleID ? L("手动添加") : $0.value.name, count: $0.value.count, latest: $0.value.latest) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.latest > $1.latest }
    }

    private func recomputeAppStats(_ items: [ClipItem]) {
        let s = Self.appStats(for: items)
        if s != model.appStats { model.appStats = s }
    }

    private func reloadItems() {
        var pinID: UUID?
        var appKey: String?
        var imageOnly = false
        switch model.selectedTab {
        case .pinboard(let id): pinID = id
        case .app(let k): appKey = k
        case .images: imageOnly = true
        case .history, .favorites: break
        }
        // Incremental narrowing: if the query extends the last one on the same tab and data is unchanged,
        // filter the previous results instead of all items.
        let store = Store.shared
        let incremental = lastSearch.map { $0.version == store.version && $0.tab == model.selectedTab
            && !$0.query.isEmpty && searchText.hasPrefix($0.query) } ?? false
        let t0 = CFAbsoluteTimeGetCurrent()
        let newItems = store.filteredItems(query: searchText, pinboardID: pinID, appKey: appKey, favoritesOnly: model.selectedTab == .favorites,
                                           kind: imageOnly ? .image : nil,
                                           within: incremental ? lastSearch?.results : nil)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        if ms > 5 { AppLog.info(String(format: "slow filter %.1fms (%d items)", ms, newItems.count)) }
        lastSearch = (searchText, model.selectedTab, store.version, newItems)
        updateTrashVisibility()
        if model.pinboards != Store.shared.pinboards { model.pinboards = Store.shared.pinboards }
        if model.items != newItems { model.items = newItems }
        if model.selectedIndex >= newItems.count { model.selectedIndex = max(0, newItems.count - 1) }
        updatePlainButton()
    }

    private lazy var actions = PanelActions(
        select: { [weak self] i in self?.model.selectedIndex = i; QuickLookController.shared.selectionChanged() },
        paste: { [weak self] i, plain in self?.paste(index: i, plainText: plain) },
        copy: { [weak self] i in self?.copy(index: i) },
        rename: { [weak self] item in self?.renameItem(item) },
        edit: { [weak self] item in self?.editItem(item) },
        newFavorite: { [weak self] in self?.editItem(nil) },
        undoClear: { [weak self] in self?.undoClear() },
        toggleFavorite: { [weak self] item in self?.toggleFavorite(item.id) },
        delete: { [weak self] item in Store.shared.delete(id: item.id); self?.reloadItems() },
        addToPinboard: { [weak self] item, b in Store.shared.addToPinboard(itemID: item.id, pinboardID: b); self?.reloadItems() },
        selectTab: { [weak self] tab in
            guard let self else { return }
            let togglingOff: Bool = {
                guard self.model.selectedTab == tab else { return false }
                switch tab {
                case .app, .images: return true
                default: return false
                }
            }()
            self.model.selectedTab = togglingOff ? .history : tab
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
    /// Open the favorite editor (nil = new manual favorite). The panel stays up underneath.
    func editItem(_ item: ClipItem?) {
        FavoriteEditor.shared.open(item: item, above: panel) { [weak self] in
            guard let self else { return }
            if item == nil { self.model.selectedTab = .favorites; self.model.selectedIndex = 0 }
            self.reloadItems()
            if self.isVisible { self.panel?.makeKey() }
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
        // Explicit drag regions only (isMovableByWindowBackground would also let SwiftUI cards drag the window).
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let fx = DragRootView(frame: panel.contentRect(forFrameRect: panel.frame))
        fx.autoresizingMask = [.width, .height]

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
        if Motion.hasGlass, #available(macOS 26, *) { plain.bezelStyle = .glass }
        plain.controlSize = .regular
        plain.bezelColor = .controlAccentColor
        plain.keyEquivalent = ""
        plain.translatesAutoresizingMaskIntoConstraints = false
        plainButton = plain

        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("关闭"))!,
                             target: self, action: #selector(closeClicked))
        close.isBordered = false
        close.bezelStyle = .inline
        close.contentTintColor = .secondaryLabelColor
        close.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        close.translatesAutoresizingMaskIntoConstraints = false

        let hosting = NSHostingView(rootView: PanelContentView(model: model, actions: actions))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear

        let grabber = GrabberView()
        grabber.translatesAutoresizingMaskIntoConstraints = false
        grabber.toolTip = L("拖动以移动")
        grabber.onDragEnd = { [weak self] in self?.userMovedPanel() }
        fx.addSubview(grabber)
        fx.addSubview(search)
        fx.addSubview(plain)
        fx.addSubview(close)
        let trash = ClearButton()
        trash.onClick = { [weak self] in self?.trashClicked() }
        trash.translatesAutoresizingMaskIntoConstraints = false
        trashButton = trash
        fx.addSubview(trash)
        let toastView = UndoToastView()
        toastView.undo.target = self; toastView.undo.action = #selector(undoClicked)
        toastView.isHidden = true
        toastView.translatesAutoresizingMaskIntoConstraints = false
        toast = toastView
        fx.addSubview(hosting)
        NSLayoutConstraint.activate([
            grabber.topAnchor.constraint(equalTo: fx.topAnchor, constant: 0),
            grabber.centerXAnchor.constraint(equalTo: fx.centerXAnchor),
            grabber.widthAnchor.constraint(equalToConstant: 80),
            grabber.heightAnchor.constraint(equalToConstant: 10),
            search.topAnchor.constraint(equalTo: fx.topAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: plain.leadingAnchor, constant: -8),
            plain.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            plain.trailingAnchor.constraint(equalTo: trash.leadingAnchor, constant: -8),
            trash.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            trash.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -6),
            close.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -10),
            close.widthAnchor.constraint(equalToConstant: 20),
            hosting.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 4),
            hosting.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        let container = TransparentView(frame: fx.frame)
        container.autoresizingMask = [.width, .height]
        backdrop = PanelBackdrop.make(frame: fx.frame, radius: Self.cornerRadius, content: fx)
        container.addSubview(backdrop!)
        fx.addSubview(toastView)   // above the hosting view
        NSLayoutConstraint.activate([
            toastView.centerXAnchor.constraint(equalTo: fx.centerXAnchor),
            toastView.bottomAnchor.constraint(equalTo: fx.bottomAnchor, constant: -14),
        ])
        panel.contentView = container
        self.panel = panel
    }

    static let cornerRadius: CGFloat = 16
    private(set) var backdrop: NSView?

    /// Resizable 9-slice mask: opaque rounded rect, transparent corners.
    static func roundedMask(radius r: CGFloat) -> NSImage {
        let d = r * 2 + 1
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }

    /// Test: render the real panel window and sample alpha at corners/center (light + dark).
    func cornerAlphaReport() -> String {
        guard let panel else { return "no panel" }
        var out: [String] = []
        let savedAlpha = panel.alphaValue, savedOrigin = panel.frame.origin
        panel.setFrameOrigin(NSPoint(x: -20000, y: -20000))   // off-screen: never flash on the user's display
        for (name, app) in [("light", NSAppearance(named: .aqua)), ("dark", NSAppearance(named: .darkAqua))] {
            panel.appearance = app
            panel.alphaValue = 1
            panel.contentView?.needsDisplay = true
            panel.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            var parts: [String] = []
            if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
               let rep = Optional(NSBitmapImageRep(cgImage: cg)) {
                let w = rep.pixelsWide, h = rep.pixelsHigh
                func a(_ x: Int, _ y: Int) -> String { String(format: "%.2f", rep.colorAt(x: x, y: y)?.alphaComponent ?? -1) }
                parts.append("window \(w)x\(h) corners TL=\(a(1,1)) TR=\(a(w-2,1)) BL=\(a(1,h-2)) BR=\(a(w-2,h-2)) edgeMid=\(a(w/2,1)) center=\(a(w/2,h/2))")
            } else { parts.append("window capture unavailable") }
            if let v = panel.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                let w = rep.pixelsWide, h = rep.pixelsHigh
                func a(_ x: Int, _ y: Int) -> String { String(format: "%.2f", rep.colorAt(x: x, y: y)?.alphaComponent ?? -1) }
                parts.append("view TL=\(a(1,1)) TR=\(a(w-2,1)) BL=\(a(1,h-2)) BR=\(a(w-2,h-2)) center=\(a(w/2,h/2))")
            }
            out.append("\(name): " + parts.joined(separator: "; "))
        }
        panel.appearance = nil
        panel.alphaValue = savedAlpha
        panel.setFrameOrigin(savedOrigin)
        return out.joined(separator: " | ")
    }

    private func positionPanel() {
        guard let panel else { return }
        let st = Store.shared.settings
        model.cardSize = st.effectiveCardSize
        let size = NSSize(width: st.effectivePanelWidth, height: PanelPlacement.height(forCard: st.effectiveCardSize))
        if st.remembersPanelPosition, let o = st.panelOrigin, o.count == 2 {
            let f = Self.clampToScreens(NSRect(origin: NSPoint(x: o[0], y: o[1]), size: size))
            isPositioning = true; panel.setFrame(f, display: false); isPositioning = false
            AppLog.info("Panel placed: remembered frame=\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))")
            return
        }
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

    /// Keep a rect fully on the visible screen it overlaps most (or the main screen).
    static func clampToScreens(_ r: NSRect, screens: [NSRect] = NSScreen.screens.map(\.visibleFrame)) -> NSRect {
        let best = screens.max { a, b in
            let ia = a.intersection(r), ib = b.intersection(r)
            return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
        } ?? r
        let target = best.intersects(r) ? best : (screens.first ?? r)
        var f = r
        f.size.width = min(f.width, target.width); f.size.height = min(f.height, target.height)
        f.origin.x = min(max(f.minX, target.minX), target.maxX - f.width)
        f.origin.y = min(max(f.minY, target.minY), target.maxY - f.height)
        return f
    }

    /// User dragged the panel (background or grabber). Persist only in "remember" mode.
    func windowDidMove(_ notification: Notification) {
        guard !isPositioning, isVisible else { return }
        userMovedPanel()
    }

    /// Test: does a mouse-down at this window point start a window drag?
    func testCanDrag(at p: NSPoint) -> (Bool, String) {
        guard let root = panel?.contentView, let v = root.hitTest(root.superview?.convert(p, from: nil) ?? p) else { return (false, "nil") }
        return (v is DragRootView || v is DraggableEffectView || v is GrabberView || v is DragAreaView, String(describing: type(of: v)))
    }
    func testMoveAsUser(to p: NSPoint) { panel?.setFrameOrigin(p) }   // goes through windowDidMove like a real drag
    var testFrame: NSRect { panel?.frame ?? .zero }

    func userMovedPanel() {
        guard let panel, !isPositioning else { return }
        let f = Self.clampToScreens(panel.frame)
        if f.origin != panel.frame.origin { isPositioning = true; panel.setFrameOrigin(f.origin); isPositioning = false }
        if Store.shared.settings.remembersPanelPosition { Store.shared.setPanelOrigin(f.origin) }
        AppLog.info("Panel moved by user to \(Int(f.minX)),\(Int(f.minY)) (remember=\(Store.shared.settings.remembersPanelPosition))")
    }

    // User drag-resize: persist width; height maps to card size.
    func windowDidResize(_ notification: Notification) { panel?.invalidateShadow() }

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
    /// Horizontal scroll views in the panel (chips row and card row), in window coordinates.
    func horizontalScrollViews() -> [NSScrollView] {
        guard let root = panel?.contentView else { return [] }
        var found: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, !(s.documentView is NSTextView) { found.append(s) }
            v.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    /// The chips (tabs/app) row: the shortest horizontal scroll view.
    func chipsScrollView() -> NSScrollView? {
        horizontalScrollViews().filter { $0.frame.height <= 60 }.min { $0.frame.height < $1.frame.height }
    }

    /// Scroll view under a window point; falls back to the card row (wheel over the search bar etc. scrolls cards).
    func scrollTarget(at p: NSPoint) -> NSScrollView? {
        let hit = horizontalScrollViews().filter { $0.convert($0.bounds, to: nil).contains(p) }
            .min { $0.frame.height < $1.frame.height }
        return hit ?? cardScrollView()
    }

    @discardableResult
    func handleScroll(_ e: NSEvent) -> Bool {
        let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        guard let panel else { return false }
        let p = e.window === panel ? e.locationInWindow : panel.convertPoint(fromScreen: e.locationInWindow)
        guard abs(dy) > abs(dx), let sv = scrollTarget(at: p), let doc = sv.documentView else { return false }
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
        // Quick Look becomes key when open, so e.window !== panel. Still intercept Space/Esc/arrows/↵.
        if isVisible, QuickLookController.shared.isOpen,
           QuickLookController.shared.handleKeyWhileOpen(e.keyCode) {
            return nil
        }
        // ⌘C with text selected in the preview copies just that selection.
        if isVisible, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           e.charactersIgnoringModifiers?.lowercased() == "c",
           QuickLookController.shared.copyPreviewSelection() {
            return nil
        }
        guard isVisible, e.window === panel else { return e }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch e.keyCode {
        case 53:
            hide()   // preview already handled above when open
            return nil
        case 49 where flags.subtracting([.capsLock, .numericPad, .function]).isEmpty && searchField.stringValue.isEmpty:
            QuickLookController.shared.toggle()   // Space previews only when the search field is empty
            return nil
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
    // Quick Look: the panel is in the responder chain, so it owns the shared preview panel.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLookController.shared.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLookController.shared.end(panel) }
}


/// Plain non-drawing container so nothing paints a rectangular background behind the rounded panel.
final class TransparentView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {}
}


/// Root vibrancy view; empty areas (margins, top bar gaps) drag the window.
final class DraggableEffectView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
        ClipboardPanelController.shared.userMovedPanel()
    }
}

/// Subtle pill at top center; dragging it moves the panel.
final class GrabberView: NSView {
    var onDragEnd: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let pill = NSRect(x: bounds.midX - 18, y: bounds.midY - 2, width: 36, height: 4)
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 2, yRadius: 2).fill()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)   // returns after the drag ends
        onDragEnd?()
    }
}


