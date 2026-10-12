import AppKit
import SwiftUI
import ApplicationServices

/// "Drag Pasting into the list" helper shown next to System Settings → Accessibility.
final class AXHelperModel: ObservableObject {
    @Published var trusted = AXIsProcessTrusted()
}

final class AccessibilityHelper: NSObject {
    static let shared = AccessibilityHelper()
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    private var panel: NSPanel?
    private var model: AXHelperModel?
    private var timer: Timer?

    /// The item dragged into the Accessibility list: the app bundle's file URL.
    static func pasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(Bundle.main.bundleURL.absoluteString, forType: .fileURL)
        return item
    }

    func start() {
        NSWorkspace.shared.open(Self.settingsURL)
        if AXIsProcessTrusted() { return }
        show()
        // System Settings opens asynchronously; reposition once it's on screen.
        for d in [0.6, 1.5] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in self?.position() } }
    }

    private func show() {
        if panel != nil { panel?.orderFrontRegardless(); return }
        let m = AXHelperModel(); model = m
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 112),
                        styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let fx = NSVisualEffectView()
        fx.material = .hudWindow; fx.blendingMode = .behindWindow; fx.state = .active
        fx.wantsLayer = true; fx.layer?.cornerRadius = 16; fx.layer?.masksToBounds = true
        let host = NSHostingView(rootView: AXHelperView(model: m, close: { [weak self] in self?.dismiss() }))
        host.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: fx.topAnchor), host.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: fx.leadingAnchor), host.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
        ])
        p.contentView = fx
        panel = p
        position()
        p.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let m = self.model, AXIsProcessTrusted() else { return }
            if !m.trusted {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) { m.trusted = true }
                AppLog.info("Accessibility granted (helper)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { self.dismiss() }
            }
        }
        AppLog.info("Accessibility drag helper shown")
    }

    /// Bottom area of the System Settings window if visible (bounds are readable without Screen Recording), else bottom-center.
    private func position() {
        guard let panel else { return }
        let size = panel.frame.size
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        var target: NSRect?
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            guard (w[kCGWindowOwnerName as String] as? String).map({ ["System Settings", "系统设置"].contains($0) }) == true,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let wd = b["Width"], let h = b["Height"], wd > 300 else { continue }
            target = NSRect(x: x, y: primaryMaxY - y - h, width: wd, height: h)
            break
        }
        let f: NSRect
        if let t = target {
            f = NSRect(x: t.midX - size.width / 2 + 60, y: t.minY + 24, width: size.width, height: size.height)
        } else {
            let v = NSScreen.main?.visibleFrame ?? .zero
            f = NSRect(x: v.midX - size.width / 2, y: v.minY + 40, width: size.width, height: size.height)
        }
        panel.setFrame(f, display: true)
        AppLog.info("AX helper placed \(target == nil ? "bottom-center" : "over System Settings") at \(Int(f.minX)),\(Int(f.minY))")
    }

    func dismiss() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        model = nil
    }
}

/// AppKit drag source wrapping the app icon.
final class AppIconDragView: NSView, NSDraggingSource {
    override var mouseDownCanMoveWindow: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds)
    }
    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: AccessibilityHelper.pasteboardItem())
        item.setDraggingFrame(bounds, contents: NSApp.applicationIconImage)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .link, .generic]
    }
}

struct AppIconDrag: NSViewRepresentable {
    func makeNSView(context: Context) -> AppIconDragView { AppIconDragView() }
    func updateNSView(_ nsView: AppIconDragView, context: Context) {}
}

struct AXHelperView: View {
    @ObservedObject var model: AXHelperModel
    @ObservedObject var l10n = L10n.shared
    let close: () -> Void
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 14) {
                ZStack {
                    if model.trusted {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 52)).foregroundColor(.green)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        AppIconDrag().frame(width: 60, height: 60)
                            .help(L("将 Pasting 拖入上方列表"))
                    }
                }
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.trusted ? L("已授权") : L("将 Pasting 拖入上方列表"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(model.trusted ? L("现在可以直接粘贴到其他应用了。") : L("把左侧图标拖到「辅助功能」列表中，然后打开开关。"))
                        .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if !model.trusted {
                    Image(systemName: "arrow.up").font(.system(size: 22, weight: .bold)).foregroundColor(.accentColor)
                        .offset(y: CGFloat(-6 * abs(sin(t * 3))))
                }
                Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                    .buttonStyle(.plain).frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(16)
        }
        .frame(width: 400, height: 112)
    }
}
