import AppKit
import Quartz

/// Space-to-preview (Quick Look) for the selected card: images (full-size original), files,
/// and text/links (rendered to a temporary .txt). Arrow keys move the selection while open.
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()
    private var c: ClipboardPanelController { ClipboardPanelController.shared }
    private let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("Pasting-QL", isDirectory: true)

    /// Tests: exercise the logic without putting a Quick Look window on the user's screen.
    var dryRun = false
    private(set) var dryOpen = false
    var isOpen: Bool { dryRun ? dryOpen : (QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible) }

    /// URL to preview for an item (nil = not previewable, e.g. colors).
    /// Images always use our Application Support copy. External file-URL images
    /// (WeChat temp paths etc.) are promoted into the store first so QL never hits TCC.
    func previewURL(for item: ClipItem) -> URL? {
        var item = item
        if item.kind == .file {
            Store.shared.promoteFileImageIfNeeded(id: item.id)
            item = Store.shared.items.first(where: { $0.id == item.id }) ?? item
        }
        switch item.kind {
        case .image:
            guard let n = item.imageFilename else { return nil }
            let u = Store.shared.imageURL(for: n)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        case .file:
            guard let p = item.fileURLs?.first else { return nil }
            // Only preview paths we can actually open; skip app-container paths QL can't read.
            let u = URL(fileURLWithPath: p)
            if p.contains("/Library/Containers/") { return nil }
            return FileManager.default.isReadableFile(atPath: p) ? u : nil
        case .text, .url:
            guard let text = item.kind == .url ? (item.urlString ?? item.text) : item.plainText, !text.isEmpty else { return nil }
            try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let base = (item.customTitle ?? String(item.id.uuidString.prefix(8)))
                .replacingOccurrences(of: "/", with: "-").prefix(60)
            let u = tmpDir.appendingPathComponent("\(base).txt")
            try? text.write(to: u, atomically: true, encoding: .utf8)
            return u
        case .color:
            return nil
        }
    }

    func toggle() {
        if isOpen { close(); return }
        guard let item = c.model.selectedItem, previewURL(for: item) != nil else { NSSound.beep(); return }
        if dryRun { dryOpen = true; return }
        let p = QLPreviewPanel.shared()!
        p.updateController()
        p.makeKeyAndOrderFront(nil)
        AppLog.info("Quick Look opened (\(item.kind.rawValue))")
    }

    func close() {
        if dryRun { dryOpen = false; return }
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return }
        let p = QLPreviewPanel.shared()!
        if p.isVisible { p.close() }
        p.orderOut(nil)
        c.refocusAfterPreview()
        AppLog.info("Quick Look closed")
    }

    /// Selection changed (arrows) → refresh the preview in place.
    func selectionChanged() {
        guard isOpen, !dryRun else { return }
        QLPreviewPanel.shared().reloadData()
    }

    func cleanup() { try? FileManager.default.removeItem(at: tmpDir) }

    // MARK: Panel control (KeyablePanel forwards these)
    func begin(_ panel: QLPreviewPanel) { panel.dataSource = self; panel.delegate = self }
    func end(_ panel: QLPreviewPanel) { panel.dataSource = nil; panel.delegate = nil }

    // MARK: Data source
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        c.model.selectedItem.flatMap(previewURL(for:)) == nil ? 0 : 1
    }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        c.model.selectedItem.flatMap(previewURL(for:)) as NSURL?
    }

    // MARK: Delegate
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        return handleKeyWhileOpen(event.keyCode)
    }

    /// Keys while the preview is open: ←/→ move + refresh, Space/Esc close, ↵ pastes.
    @discardableResult
    func handleKeyWhileOpen(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 123: c.moveSelection(-1); selectionChanged(); return true
        case 124: c.moveSelection(1); selectionChanged(); return true
        case 49, 53: close(); return true
        case 36, 76: close(); c.pasteSelectedFromPreview(); return true
        default: return false
        }
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        c.selectedCardScreenFrame() ?? .zero
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!, contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let it = c.model.selectedItem else { return nil }
        switch it.kind {
        case .image: return it.imageFilename.flatMap { ThumbCache.shared.thumbnail(for: $0) }
        case .file: return IconCache.shared.fileIcon(path: it.fileURLs?.first)
        default: return nil
        }
    }
}
