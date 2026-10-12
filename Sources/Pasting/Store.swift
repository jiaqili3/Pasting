import Foundation
import AppKit
import Combine

final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var items: [ClipItem] = [] {
        didSet { syncSearchKeys(); version &+= 1 }
    }

    private func syncSearchKeys() {
        var next: [UUID: String] = [:]
        next.reserveCapacity(items.count)
        for it in items {
            if let k = searchKeys[it.id], !dirtyKeys.contains(it.id) { next[it.id] = k }
            else { next[it.id] = SearchIndex.key(for: it) }
        }
        dirtyKeys.removeAll()
        searchKeys = next
    }
    private var dirtyKeys = Set<UUID>()
    @Published private(set) var pinboards: [Pinboard] = []
    @Published var settings: AppSettings = .default
    /// Precomputed normalized search keys (id -> key), maintained on load/capture/rename/update.
    private(set) var searchKeys: [UUID: String] = [:]
    /// Bumped whenever items change; lets the panel reuse previous results for incremental search.
    private(set) var version = 0

    let supportDir: URL
    let imagesDir: URL
    let storeURL: URL
    private var saveWorkItem: DispatchWorkItem?

    private init() {
        // Test mode uses an isolated data dir (never the real store).
        let base = TestMode.dataDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pasting", isDirectory: true)
        supportDir = base
        imagesDir = base.appendingPathComponent("images", isDirectory: true)
        storeURL = base.appendingPathComponent("store.json")
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        load()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            AppLog.info("No existing store; starting fresh")
            return
        }
        do {
            let data = try Data(contentsOf: storeURL)
            let decoded = try JSONDecoder().decode(PersistedStore.self, from: data)
            items = decoded.items.sorted { $0.createdAt > $1.createdAt }
            pinboards = decoded.pinboards.sorted { $0.createdAt < $1.createdAt }
            settings = decoded.settings
            L10n.shared.apply(settings.languageChoice)
            AppLog.info("Loaded \(items.count) items, \(pinboards.count) pinboards")
            migrateToFavorites()
            purgeExpired(reason: "launch")
        } catch {
            AppLog.error("Failed to load store: \(error)")
        }
    }

    func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async { self?.saveNow() }
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private let ioQueue = DispatchQueue(label: "com.jiaqili.pasting.io", qos: .utility)

    /// Encode on main (cheap snapshot), write on a background queue.
    func saveNow(sync: Bool = false) {
        let payload = PersistedStore(items: items, pinboards: pinboards, settings: settings)
        let url = storeURL
        let work = {
            do {
                let data = try JSONEncoder().encode(payload)
                try data.write(to: url, options: .atomic)
            } catch {
                AppLog.error("Failed to save store: \(error)")
            }
        }
        if sync { ioQueue.sync(execute: work) } else { ioQueue.async(execute: work) }
    }

    // MARK: - Items

    func add(_ item: ClipItem) {
        if let last = items.first, last.contentFingerprint() == item.contentFingerprint() {
            return
        }
        items.insert(item, at: 0)
        purgeExpired(reason: "capture")
        enforceLimit()
        scheduleSave()
    }

    func update(_ item: ClipItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        dirtyKeys.insert(item.id)
        items[idx] = item
        scheduleSave()
    }

    func delete(id: UUID) {
        if let item = items.first(where: { $0.id == id }), let name = item.imageFilename {
            let url = imagesDir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
            ThumbCache.shared.remove(name)
        }
        items.removeAll { $0.id == id }
        scheduleSave()
    }

    func clearHistory() {
        let pinned = items.filter(\.isFavorite)
        let toRemove = items.filter { !$0.isFavorite }
        for item in toRemove {
            if let name = item.imageFilename {
                try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(name)); ThumbCache.shared.remove(name)
            }
        }
        items = pinned
        scheduleSave()
    }

    func rename(id: UUID, title: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        dirtyKeys.insert(id)
        items[idx].customTitle = title.isEmpty ? nil : title
        scheduleSave()
    }

    /// Edit a favorite: title (all kinds) and content (text/URL; nil = leave unchanged).
    /// Editing rich text content converts it to plain text.
    func editFavorite(id: UUID, title: String, content: String?) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        dirtyKeys.insert(id)
        var it = items[idx]
        it.customTitle = title.isEmpty ? nil : title
        if let content, it.kind == .text || it.kind == .url {
            let old = it.kind == .url ? (it.urlString ?? it.text ?? "") : (it.plainText ?? "")
            if content != old {
                if it.kind == .url { it.urlString = content.trimmingCharacters(in: .whitespacesAndNewlines) }
                it.text = content
                it.rtfData = nil; it.htmlData = nil
            }
        }
        items[idx] = it
        scheduleSave()
        AppLog.info("Favorite edited (title=\(it.customTitle != nil), kind=\(it.kind.rawValue), rich=\(it.isRich))")
    }

    static let manualBundleID = "manual"

    @discardableResult
    func addManualFavorite(title: String, content: String) -> ClipItem {
        let item = ClipItem(kind: .text, text: content, customTitle: title.isEmpty ? nil : title,
                            sourceAppName: "Manual", sourceAppBundleID: Store.manualBundleID, isFavorite: true)
        items.insert(item, at: 0)
        scheduleSave()
        AppLog.info("Manual favorite added")
        return item
    }

    /// 1.1: Pin and the default "Snippets" pinboard are merged into Favorites (runs once).
    func migrateToFavorites() {
        guard settings.favoritesMigrated != true else { return }
        var pinned = 0, fromSnippets = 0
        let snippetIDs = Set(pinboards.filter { ["snippets", "片段"].contains($0.name.lowercased()) }.map(\.id))
        for i in items.indices {
            if items[i].isPinned == true { if !items[i].isFavorite { pinned += 1 }; items[i].isFavorite = true }
            if !snippetIDs.isDisjoint(with: items[i].pinboardIDs) {
                items[i].pinboardIDs.removeAll { snippetIDs.contains($0) }
                if !items[i].isFavorite { fromSnippets += 1 }
                items[i].isFavorite = true
            }
            items[i].isPinned = nil
        }
        pinboards.removeAll { snippetIDs.contains($0.id) }
        settings.favoritesMigrated = true
        scheduleSave()
        AppLog.info("Favorites migration: \(pinned) pinned + \(fromSnippets) from Snippets -> favorites; removed \(snippetIDs.count) Snippets board(s); \(pinboards.count) user board(s) kept; favorites now \(items.filter(\.isFavorite).count)")
    }

    func toggleFavorite(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].isFavorite.toggle()
        AppLog.info("Favorite \(items[idx].isFavorite ? "on" : "off")")
        scheduleSave()
    }

    func addToPinboard(itemID: UUID, pinboardID: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        if !items[idx].pinboardIDs.contains(pinboardID) {
            items[idx].pinboardIDs.append(pinboardID)
            scheduleSave()
        }
    }

    func removeFromPinboard(itemID: UUID, pinboardID: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx].pinboardIDs.removeAll { $0 == pinboardID }
        scheduleSave()
    }

    // MARK: - Pinboards

    func addPinboard(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pinboards.append(Pinboard(name: trimmed))
        scheduleSave()
    }

    func deletePinboard(id: UUID) {
        pinboards.removeAll { $0.id == id }
        for i in items.indices {
            items[i].pinboardIDs.removeAll { $0 == id }
        }
        scheduleSave()
    }

    func renamePinboard(id: UUID, name: String) {
        guard let idx = pinboards.firstIndex(where: { $0.id == id }) else { return }
        pinboards[idx].name = name
        scheduleSave()
    }

    // MARK: - Retention

    /// Items that are expired: older than `days`, not pinned, not in any pinboard.
    static func expiredIDs(in items: [ClipItem], days: Int, now: Date = Date()) -> Set<UUID> {
        guard days > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return Set(items.filter { !$0.isFavorite && $0.pinboardIDs.isEmpty && $0.createdAt < cutoff }.map(\.id))
    }

    @discardableResult
    func purgeExpired(reason: String) -> Int {
        let ids = Store.expiredIDs(in: items, days: settings.effectiveRetentionDays)
        guard !ids.isEmpty else { return 0 }
        for item in items where ids.contains(item.id) {
            if let name = item.imageFilename {
                try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(name)); ThumbCache.shared.remove(name)
            }
        }
        items.removeAll { ids.contains($0.id) }
        scheduleSave()
        AppLog.info("Purged \(ids.count) expired item(s) (\(reason), retention=\(settings.effectiveRetentionDays)d)")
        return ids.count
    }

    func setRetentionDays(_ days: Int) {
        settings.retentionDays = days
        scheduleSave()
        AppLog.info("Retention set to \(days == 0 ? "forever" : "\(days)d")")
        purgeExpired(reason: "setting")
    }

    static func retentionSelfTest() {
        let now = Date()
        let old = now.addingTimeInterval(-8 * 86_400)
        let board = UUID()
        let items = [
            ClipItem(kind: .text, createdAt: old, text: "old"),
            ClipItem(kind: .text, createdAt: old, text: "old favorite", isFavorite: true),
            ClipItem(kind: .text, createdAt: old, text: "old in board", pinboardIDs: [board]),
            ClipItem(kind: .text, createdAt: now.addingTimeInterval(-86_400), text: "recent"),
        ]
        let e7 = expiredIDs(in: items, days: 7, now: now)
        let e30 = expiredIDs(in: items, days: 30, now: now)
        let e0 = expiredIDs(in: items, days: 0, now: now)
        if e7 == [items[0].id], e30.isEmpty, e0.isEmpty {
            AppLog.info("Retention self-test PASS")
        } else {
            AppLog.error("Retention self-test FAIL (7d=\(e7.count) 30d=\(e30.count) forever=\(e0.count))")
        }
    }

    // MARK: - Settings

    func setLanguage(_ c: L10n.Choice) {
        settings.language = c.rawValue
        scheduleSave()
        L10n.shared.apply(c)
        AppLog.info("Language set to \(c.rawValue) -> isChinese=\(L10n.shared.isChinese) sample: \(L("历史"))/\(L("纯文本粘贴"))/\(L("清空历史"))")
    }

    func setHistoryLimit(_ n: Int) {
        settings.historyLimit = max(50, min(n, 5000))
        enforceLimit()
        scheduleSave()
    }

    /// Test-mode only: replace contents in the isolated store.
    func replaceAllForTest(_ newItems: [ClipItem], pinboards newBoards: [Pinboard] = []) {
        precondition(TestMode.isOn)
        pinboards = newBoards
        items = newItems.sorted { $0.createdAt > $1.createdAt }
        saveNow(sync: true)
    }

    func setPanelSize(width: Double? = nil, card: Double? = nil) {
        if let width { settings.panelWidth = min(max(width, 380), 1600) }
        if let card { settings.cardSize = min(max(card, 90), 220) }
        scheduleSave()
        NotificationCenter.default.post(name: Store.panelSizeChanged, object: nil)
    }
    func setPanelPositionMode(remember: Bool) {
        settings.panelPosition = remember ? "remember" : "caret"
        scheduleSave()
        AppLog.info("Panel position mode: \(remember ? "remember" : "caret")")
    }
    func setPanelOrigin(_ p: NSPoint) { settings.panelOrigin = [Double(p.x), Double(p.y)]; scheduleSave() }

    static let panelSizeChanged = Notification.Name("PastingPanelSizeChanged")

    func setIgnoreConcealed(_ on: Bool) { settings.ignoreConcealed = on; scheduleSave() }

    func setIgnoredApps(_ apps: [String]) {
        settings.ignoredApps = apps.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        scheduleSave()
    }

    func setCapturingPaused(_ paused: Bool) {
        settings.capturingPaused = paused
        scheduleSave()
    }

    func setOpenAtLogin(_ enabled: Bool) {
        settings.openAtLogin = enabled
        scheduleSave()
        LoginItem.setEnabled(enabled)
    }

    func setOnboardingCompleted() {
        settings.hasCompletedOnboarding = true
        scheduleSave()
    }

    // MARK: - Images

    func saveImageData(_ data: Data) -> String? {
        let name = "\(UUID().uuidString).png"
        let url = imagesDir.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            AppLog.error("Failed to save image: \(error)")
            return nil
        }
    }

    func imageURL(for filename: String) -> URL {
        imagesDir.appendingPathComponent(filename)
    }

    func loadImage(filename: String) -> NSImage? {
        NSImage(contentsOf: imageURL(for: filename))
    }

    // MARK: - Helpers

    private func enforceLimit() {
        let limit = max(settings.historyLimit, 50)
        var kept: [ClipItem] = []
        var removable: [ClipItem] = []
        for item in items {
            if item.isFavorite {
                kept.append(item)
            } else {
                removable.append(item)
            }
        }
        if removable.count > limit {
            let excess = removable.suffix(from: limit)
            for item in excess {
                if let name = item.imageFilename {
                    try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(name)); ThumbCache.shared.remove(name)
                }
            }
            removable = Array(removable.prefix(limit))
        }
        items = (kept + removable).sorted { $0.createdAt > $1.createdAt }
    }

    func filteredItems(query: String, pinboardID: UUID?, appKey: String? = nil, favoritesOnly: Bool = false, within base: [ClipItem]? = nil) -> [ClipItem] {
        var list = base ?? items
        if base == nil {
            if let pinboardID { list = list.filter { $0.pinboardIDs.contains(pinboardID) } }
            if favoritesOnly { list = list.filter(\.isFavorite) }
            if let appKey { list = list.filter { $0.appKey == appKey } }
        }
        return SearchIndex.filter(list, keys: searchKeys, query: query)
    }

}
