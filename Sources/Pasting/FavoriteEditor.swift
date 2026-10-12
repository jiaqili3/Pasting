import AppKit

/// Editor for a favorite's title/content, and for manually created favorites.
/// AppKit window (not a sheet on the non-activating panel) that becomes key so typing,
/// IME and the standard Edit-menu shortcuts work. ⌘↵ saves, Esc cancels.
final class FavoriteEditor: NSObject, NSWindowDelegate {
    static let shared = FavoriteEditor()

    private var window: NSPanel?
    private var titleField: NSTextField!
    private var contentView: NSTextView!
    private var editingID: UUID?
    private var contentEditable = true
    private var onDone: (() -> Void)?
    private(set) var isOpen = false

    /// item == nil → create a new manual favorite.
    func open(item: ClipItem?, above parent: NSWindow?, onDone: @escaping () -> Void) {
        close()
        editingID = item?.id
        self.onDone = onDone
        let editable = item.map { $0.kind == .text || $0.kind == .url } ?? true
        contentEditable = editable
        let w: CGFloat = 420, h: CGFloat = editable ? 300 : 130
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        p.title = item == nil ? L("新建收藏") : L("编辑收藏")
        p.level = .floating + 1
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.minSize = NSSize(width: 320, height: editable ? 220 : 130)

        let root = NSView(frame: p.contentRect(forFrameRect: p.frame))
        let tLabel = NSTextField(labelWithString: L("标题（可选）"))
        titleField = NSTextField(string: item?.customTitle ?? "")
        titleField.placeholderString = item?.displayTitle ?? L("显示在卡片上的名字")
        var views: [String: NSView] = ["tl": tLabel, "tf": titleField]
        var vfl = "V:|-14-[tl]-4-[tf]"

        let cLabel = NSTextField(labelWithString: L("内容"))
        let scroll = NSTextView.scrollableTextView()
        contentView = scroll.documentView as? NSTextView
        if editable {
            contentView.isRichText = false
            contentView.font = .systemFont(ofSize: 13)
            contentView.isAutomaticQuoteSubstitutionEnabled = false
            contentView.isAutomaticDashSubstitutionEnabled = false
            contentView.string = item.map { $0.kind == .url ? ($0.urlString ?? $0.text ?? "") : ($0.plainText ?? "") } ?? ""
            scroll.borderType = .bezelBorder
            views["cl"] = cLabel; views["sc"] = scroll
            vfl += "-12-[cl]-4-[sc(>=80)]"
            if let item, item.isRich {
                let warn = NSTextField(labelWithString: L("ⓘ 编辑内容会把富文本转成纯文本"))
                warn.font = .systemFont(ofSize: 11); warn.textColor = .secondaryLabelColor
                views["wn"] = warn; vfl += "-4-[wn]"
            }
        } else {
            let note = NSTextField(labelWithString: L("图片和文件只能修改标题。"))
            note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
            views["nt"] = note; vfl += "-6-[nt]"
        }
        let save = NSButton(title: L("保存"), target: self, action: #selector(saveAction))
        save.keyEquivalent = "\r"; save.keyEquivalentModifierMask = .command
        let cancel = NSButton(title: L("取消"), target: self, action: #selector(cancelAction))
        cancel.keyEquivalent = "\u{1b}"
        let hint = NSTextField(labelWithString: "⌘↵ " + L("保存") + "  ·  Esc " + L("取消"))
        hint.font = .systemFont(ofSize: 10); hint.textColor = .tertiaryLabelColor
        views["sv"] = save; views["cn"] = cancel; views["hn"] = hint
        vfl += "-12-[sv]-12-|"
        for v in views.values { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        var cs = NSLayoutConstraint.constraints(withVisualFormat: vfl, metrics: nil, views: views)
        for k in views.keys where !["sv", "cn", "hn"].contains(k) {
            cs += NSLayoutConstraint.constraints(withVisualFormat: "H:|-16-[\(k)]-16-|", metrics: nil, views: views)
        }
        cs += NSLayoutConstraint.constraints(withVisualFormat: "H:|-16-[hn]-(>=8)-[cn]-8-[sv]-16-|", options: [.alignAllCenterY], metrics: nil, views: views)
        NSLayoutConstraint.activate(cs)
        p.contentView = root

        if let parent {
            let f = parent.frame
            p.setFrameTopLeftPoint(NSPoint(x: f.midX - w / 2, y: min(f.maxY + h + 30, (parent.screen ?? NSScreen.main)!.visibleFrame.maxY)))
        } else { p.center() }
        window = p
        isOpen = true
        if TestMode.isOn { p.alphaValue = 0; p.orderFrontRegardless() } else {
            NSApp.activate(ignoringOtherApps: true)
            p.makeKeyAndOrderFront(nil)
        }
        p.makeFirstResponder(editable && item != nil ? contentView : titleField)
        AppLog.info("Favorite editor opened (\(item == nil ? "new" : "edit"))")
    }

    @objc private func saveAction() {
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = contentView.string
        if let id = editingID {
            Store.shared.editFavorite(id: id, title: title, content: contentEditable ? content : nil)
        } else {
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !title.isEmpty else { NSSound.beep(); return }
            Store.shared.addManualFavorite(title: title, content: content)
        }
        finish()
    }

    @objc private func cancelAction() { finish() }

    // Test hooks: drive the real editor UI path.
    func testFill(title: String, content: String?) {
        titleField.stringValue = title
        if let content { contentView.string = content }
    }
    func testSave() { saveAction() }
    func testCancel() { cancelAction() }
    var testContentView: NSView? { window?.contentView }
    var testHasWarning: Bool { window?.contentView?.subviews.contains { ($0 as? NSTextField)?.stringValue.hasPrefix("ⓘ") ?? false } ?? false }

    private func finish() {
        let cb = onDone
        close()
        cb?()
    }

    func close() {
        guard let w = window else { return }
        window = nil; isOpen = false
        w.delegate = nil
        w.orderOut(nil)
        onDone = nil
    }

    func windowWillClose(_ notification: Notification) { finish() }
}
