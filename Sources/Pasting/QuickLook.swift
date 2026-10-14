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
    var isOpen: Bool { dryRun ? dryOpen : (previewWindow?.isVisible ?? false) }

    /// Our own non-activating preview window hosting a QLPreviewView.
    /// The system QLPreviewPanel steals key status from our non-activating panel (keys then go to the
    /// previous app), and in an inactive LSUIElement app it ignored orderOut — so Space never closed it.
    private var previewWindow: NSPanel?
    private var previewView: QLPreviewView?
    /// Text/link items use a selectable (read-only) text view so part of the text can be copied.
    private var textScroll: NSScrollView?
    private var textView: NSTextView?

    private func ensureWindow() -> NSPanel {
        if let w = previewWindow { return w }
        let w = PreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.isFloatingPanel = true
        w.level = .popUpMenu
        w.hidesOnDeactivate = false
        w.becomesKeyOnlyIfNeeded = false   // a click (e.g. into the text) makes it key so ⌘C works
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let v = QLPreviewView(frame: w.contentView!.bounds, style: .normal)!
        v.autoresizingMask = [.width, .height]
        v.autostarts = true
        w.contentView?.addSubview(v)
        let sv = NSScrollView(frame: w.contentView!.bounds)
        sv.autoresizingMask = [.width, .height]
        sv.hasVerticalScroller = true
        sv.drawsBackground = true
        sv.automaticallyAdjustsContentInsets = false
        sv.contentInsets = NSEdgeInsets(top: 28, left: 0, bottom: 0, right: 0)
        let tv = PreviewTextView(frame: sv.contentView.bounds)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textContainerInset = NSSize(width: 12, height: 10)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        sv.documentView = tv
        sv.isHidden = true
        w.contentView?.addSubview(sv)
        previewWindow = w; previewView = v; textScroll = sv; textView = tv
        return w
    }

    private func showPreview(_ url: URL, title: String, text: String? = nil) {
        let w = ensureWindow()
        if let text {
            previewView?.previewItem = nil
            previewView?.isHidden = true
            textScroll?.isHidden = false
            textView?.string = text
            textView?.setSelectedRange(NSRange(location: 0, length: 0))
            textView?.scrollToBeginningOfDocument(nil)
        } else {
            textScroll?.isHidden = true
            previewView?.isHidden = false
            previewView?.previewItem = url as NSURL
        }
        w.title = title
        if !w.isVisible {
            let scr = c.panelScreen() ?? NSScreen.main
            if let vf = scr?.visibleFrame {
                let size = NSSize(width: min(820, vf.width * 0.7), height: min(640, vf.height * 0.75))
                w.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2 + 60, width: size.width, height: size.height), display: false)
            }
        }
        w.orderFrontRegardless()   // not key until the user clicks into the text; the clipboard panel keeps focus
        c.refocusAfterPreview()
    }

    /// ⌘C fallback: copy the selected part of the previewed text (works even if the preview isn't key).
    func copyPreviewSelection() -> Bool {
        guard isOpen, !dryRun, let tv = textView, textScroll?.isHidden == false else { return false }
        let r = tv.selectedRange()
        guard r.length > 0 else { return false }
        let str = (tv.string as NSString).substring(with: r)
        let pb = NSPasteboard.general
        pb.clearContents(); pb.setString(str, forType: .string)
        AppLog.info("Copied \(r.length) chars from preview selection")
        return true
    }

    /// Plain text shown in the selectable text view (text/link items only).
    func previewText(for item: ClipItem) -> String? {
        switch item.kind {
        case .text: return item.plainText
        case .url: return item.urlString ?? item.text
        default: return nil
        }
    }

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
        guard let url = previewURL(for: item) else { return }
        showPreview(url, title: url.lastPathComponent, text: previewText(for: item))
        AppLog.info("Quick Look opened (\(item.kind.rawValue))")
    }

    func close() {
        if dryRun { dryOpen = false; return }
        guard let w = previewWindow, w.isVisible else { return }
        w.orderOut(nil)
        previewView?.previewItem = nil
        c.refocusAfterPreview()
        AppLog.info("Quick Look closed (visible=\(w.isVisible))")
    }

    /// Selection changed (arrows) → refresh the preview in place.
    func selectionChanged() {
        guard isOpen, !dryRun else { return }
        guard let item = c.model.selectedItem, let url = previewURL(for: item) else { close(); return }
        showPreview(url, title: url.lastPathComponent, text: previewText(for: item))
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

/// Preview window: non-activating, but may become key when the user clicks into the
/// selectable text view (becomesKeyOnlyIfNeeded), so ⌘C / right-click Copy work.
final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PreviewTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
}
