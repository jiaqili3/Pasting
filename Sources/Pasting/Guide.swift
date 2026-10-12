import SwiftUI
import AppKit
import ApplicationServices

/// Guide state (ObservableObject instead of @State: this toolchain lacks SwiftUI macro plugins).
final class GuideModel: ObservableObject {
    static let pageCount = 6
    @Published var page = 0
    @Published var forward = true
    @Published var pageStart = Date()
    @Published var axTrusted = AXIsProcessTrusted()
    private var axTimer: Timer?

    func go(_ p: Int) {
        guard p >= 0, p < GuideModel.pageCount, p != page else { return }
        forward = p > page
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { page = p }
        pageStart = Date()
        updateAXPolling()
    }

    func updateAXPolling() {
        axTimer?.invalidate(); axTimer = nil
        guard page == 4 else { return }
        axTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            let t = AXIsProcessTrusted()
            if t != self?.axTrusted { withAnimation(.spring()) { self?.axTrusted = t } }
        }
    }

    func stop() { axTimer?.invalidate(); axTimer = nil }
}

struct GuideView: View {
    @ObservedObject var model: GuideModel
    @ObservedObject var l10n = L10n.shared
    let finish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page(model.page)
                    .id(model.page)
                    .transition(.asymmetric(
                        insertion: .move(edge: model.forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: model.forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            HStack {
                Button(L("上一步")) { model.go(model.page - 1) }
                    .opacity(model.page == 0 ? 0 : 1)
                    .disabled(model.page == 0)
                Spacer()
                HStack(spacing: 7) {
                    ForEach(0..<GuideModel.pageCount, id: \.self) { i in
                        Capsule().fill(i == model.page ? Color.accentColor : Color.primary.opacity(0.2))
                            .frame(width: i == model.page ? 18 : 7, height: 7)
                            .onTapGesture { model.go(i) }
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.page)
                Spacer()
                if model.page == GuideModel.pageCount - 1 {
                    Button(L("开始使用"), action: finish).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                } else {
                    Button(L("下一步")) { model.go(model.page + 1) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 18).padding(.top, 6)
        }
        .frame(width: 640, height: 460)
    }

    @ViewBuilder private func page(_ p: Int) -> some View {
        switch p {
        case 0: GuidePage(title: L("欢迎使用 Pasting"), text: L("你的本地剪贴板历史。快速、私密、无云同步。"), start: model.pageStart) { t in WelcomeAnim(t: t) }
        case 1: GuidePage(title: L("自动记录"), text: L("文字、链接、图片、文件和颜色都会自动保存，密码管理器的内容会被跳过。"), start: model.pageStart) { t in CaptureAnim(t: t) }
        case 2: GuidePage(title: L("随时呼出"), text: L("按 ⇧⌘V，卡片面板会出现在文字光标上方。←/→ 选择，↵ 粘贴，Esc 关闭。"), start: model.pageStart) { t in HotkeyAnim(t: t) }
        case 3: GuidePage(title: L("搜索、筛选、纯文本"), text: L("直接打字搜索，按来源应用筛选，一键去掉格式粘贴。"), start: model.pageStart) { t in SearchAnim(t: t) }
        case 4: AccessibilityPage(model: model)
        default: FinalPage()
        }
    }
}

/// Generic page: animated illustration on top (driven by TimelineView only while visible), title + text fade up.
struct GuidePage<Illustration: View>: View {
    let title: String
    let text: String
    let start: Date
    let illustration: (Double) -> Illustration

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSince(start)
            VStack(spacing: 18) {
                illustration(t).frame(height: 230)
                Text(title).font(.system(size: 26, weight: .bold))
                    .opacity(ease(t, 0.15, 0.5)).offset(y: (1 - ease(t, 0.15, 0.5)) * 14)
                Text(text).font(.system(size: 14)).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 460)
                    .opacity(ease(t, 0.3, 0.5)).offset(y: (1 - ease(t, 0.3, 0.5)) * 14)
            }
            .padding(.top, 24)
        }
    }
}

/// 0→1 ease-out between `delay` and `delay+dur`.
func ease(_ t: Double, _ delay: Double, _ dur: Double) -> Double {
    let x = min(max((t - delay) / dur, 0), 1)
    return 1 - pow(1 - x, 3)
}
/// Damped spring 0→1 (overshoots slightly).
func springv(_ t: Double, _ delay: Double) -> Double {
    let x = max(t - delay, 0)
    return 1 - exp(-6 * x) * cos(10 * x)
}

struct WelcomeAnim: View {
    let t: Double
    var body: some View {
        let s = springv(t, 0)
        let pulse = 0.5 + 0.5 * sin(t * 2.4)
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.25 + 0.15 * pulse))
                .frame(width: 170 + 30 * pulse, height: 170 + 30 * pulse).blur(radius: 30)
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128)
                .scaleEffect(0.4 + 0.6 * s)
                .rotationEffect(.degrees((1 - min(s, 1)) * -20))
                .opacity(min(1, t * 3))
        }
    }
}

struct MiniCard: View {
    let kind: Int
    var w: CGFloat = 92
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(["文本", "链接", "图片", "颜色"].map(L)[kind]).font(.system(size: 8, weight: .bold))
                .foregroundColor(.accentColor)
            switch kind {
            case 0: VStack(alignment: .leading, spacing: 3) { ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.25)).frame(width: w * [0.8, 0.65, 0.5][i] - 14, height: 4) } }
            case 1: Text("github.com").font(.system(size: 9, weight: .semibold)).foregroundColor(.blue)
            case 2: LinearGradient(colors: [.orange, .pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .clipShape(RoundedRectangle(cornerRadius: 4)).frame(height: 30)
            default: RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.2, green: 0.6, blue: 1)).frame(height: 24)
            }
            Spacer(minLength: 0)
        }
        .padding(7)
        .frame(width: w, height: w * 0.8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.1)))
    }
}

struct CaptureAnim: View {
    let t: Double
    var body: some View {
        let cycle = t.truncatingRemainder(dividingBy: 4.0)
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(Color.accentColor.opacity(0.12)).frame(width: 140, height: 110)
                .overlay(Image(systemName: "tray.full.fill").font(.system(size: 28)).foregroundColor(.accentColor).offset(y: 34))
            ForEach(0..<4, id: \.self) { i in
                let p = ease(cycle, Double(i) * 0.45, 0.7)
                let startX: CGFloat = [-230, 230, -200, 210][i]
                let startY: CGFloat = [-70, -80, 70, 60][i]
                MiniCard(kind: i)
                    .rotationEffect(.degrees(Double(1 - p) * [-25, 20, 15, -18][i] + Double(i) * 3 - 4))
                    .offset(x: startX * (1 - p), y: startY * (1 - p) - CGFloat(i) * 5 - 12)
                    .scaleEffect(1 - 0.15 * p)
                    .opacity(cycle > 3.6 ? (4.0 - cycle) / 0.4 : 1)
            }
        }
    }
}

struct Keycap: View {
    let label: String
    let down: Bool
    var body: some View {
        Text(label).font(.system(size: 22, weight: .medium, design: .rounded))
            .frame(width: 54, height: 50)
            .background(RoundedRectangle(cornerRadius: 9).fill(down ? Color.accentColor.opacity(0.3) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.15)))
            .shadow(color: .black.opacity(down ? 0.05 : 0.2), radius: 0, y: down ? 1 : 4)
            .offset(y: down ? 3 : 0)
    }
}

struct HotkeyAnim: View {
    let t: Double
    var body: some View {
        let c = t.truncatingRemainder(dividingBy: 4.5)
        let down = [c > 0.4 && c < 1.4, c > 0.6 && c < 1.4, c > 0.8 && c < 1.4]
        let slide = c > 1.2 ? springv(c, 1.2) : 0
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                Keycap(label: "⇧", down: down[0]); Keycap(label: "⌘", down: down[1]); Keycap(label: "V", down: down[2])
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
                HStack(spacing: 8) {
                    ForEach(0..<4, id: \.self) { i in
                        MiniCard(kind: i, w: 70)
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor, lineWidth: i == Int(max(0, c - 2.2) * 2) % 4 && c > 2.2 ? 2 : 0))
                            .opacity(ease(c, 1.4 + Double(i) * 0.08, 0.3))
                    }
                }
            }
            .frame(width: 340, height: 82)
            .offset(y: (1 - slide) * 120)
            .opacity(min(1, slide * 1.5))
        }
    }
}

struct SearchAnim: View {
    let t: Double
    var body: some View {
        let c = t.truncatingRemainder(dividingBy: 6)
        let query = "meeting"
        let typed = String(query.prefix(Int(max(0, min(Double(query.count), (c - 0.4) * 7)))))
        let chip = c > 2.2 ? (c > 3.4 ? 1 : 0) : -1
        let pulse = c > 4 ? 0.5 + 0.5 * sin((c - 4) * 9) : 0
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    Text(typed.isEmpty ? L("搜索剪贴板…") : typed).foregroundColor(typed.isEmpty ? .secondary : .primary)
                    Rectangle().fill(Color.accentColor).frame(width: 1.5, height: 15).opacity(sin(t * 8) > 0 ? 1 : 0)
                    Spacer()
                }
                .padding(7).frame(width: 240)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
                Text(L("纯文本粘贴")).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.accentColor))
                    .scaleEffect(1 + 0.08 * pulse)
                    .shadow(color: .accentColor.opacity(0.6 * pulse), radius: 8 * pulse)
            }
            HStack(spacing: 6) {
                ForEach(Array(["Safari", "Notes", "Slack"].enumerated()), id: \.offset) { i, n in
                    Text(n).font(.system(size: 11, weight: chip == i ? .semibold : .regular))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(chip == i ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.07)))
                        .foregroundColor(chip == i ? .accentColor : .primary)
                        .scaleEffect(chip == i ? 1.08 : 1)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: chip)
                }
            }
            HStack(spacing: 8) {
                ForEach(0..<(typed.count > 3 ? 2 : 4), id: \.self) { i in MiniCard(kind: i, w: 72).transition(.scale.combined(with: .opacity)) }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: typed.count > 3)
        }
    }
}

struct AccessibilityPage: View {
    @ObservedObject var model: GuideModel
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill((model.axTrusted ? Color.green : Color.orange).opacity(0.18)).frame(width: 150, height: 150)
                Image(systemName: model.axTrusted ? "checkmark.seal.fill" : "hand.raised.fill")
                    .font(.system(size: 64)).foregroundColor(model.axTrusted ? .green : .orange)
                    .scaleEffect(model.axTrusted ? 1.08 : 1)
            }
            .frame(height: 200)
            .animation(.spring(response: 0.4, dampingFraction: 0.5), value: model.axTrusted)
            Text(L("辅助功能权限")).font(.system(size: 26, weight: .bold))
            Text(L("Pasting 需要此权限才能把内容粘贴到其他应用的光标处。")).foregroundColor(.secondary)
            HStack(spacing: 12) {
                Button(L("授予辅助功能权限")) { AccessibilityHelper.shared.start() }
                    .buttonStyle(.borderedProminent).disabled(model.axTrusted)
                Label(model.axTrusted ? L("已授权") : L("尚未授权"),
                      systemImage: model.axTrusted ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundColor(model.axTrusted ? .green : .secondary)
            }
        }
        .padding(.top, 24)
    }
}

struct FinalPage: View {
    @ObservedObject var store = Store.shared
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 44)).foregroundColor(.accentColor).padding(.top, 30)
            Text(L("个性化设置")).font(.system(size: 26, weight: .bold))
            Form {
                Toggle(isOn: Binding(get: { Store.shared.settings.openAtLogin }, set: { Store.shared.setOpenAtLogin($0) })) {
                    VStack(alignment: .leading) {
                        Text(L("登录时打开"))
                        Text(L("开机后自动在菜单栏运行")).font(.caption).foregroundColor(.secondary)
                    }
                }
                LanguagePicker()
                RetentionPicker()
            }
            .formStyle(.grouped)
            .frame(width: 440, height: 190)
            .scrollDisabled(true)
        }
    }
}

final class GuideWindowController: NSObject, NSWindowDelegate {
    static let shared = GuideWindowController()
    private var window: NSWindow?
    private var model: GuideModel?
    private var keyMonitor: Any?
    var isOpen: Bool { window != nil }

    func showIfNeeded() {
        guard !Store.shared.settings.hasCompletedOnboarding else { return }
        show()
    }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let model = GuideModel()
        self.model = model
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        let fx = NSVisualEffectView()
        fx.material = .underWindowBackground
        fx.blendingMode = .behindWindow
        fx.state = .active
        let host = NSHostingView(rootView: GuideView(model: model, finish: { [weak self] in self?.finish() }))
        host.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: fx.topAnchor), host.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: fx.leadingAnchor), host.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
        ])
        w.contentView = fx
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window = w
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let m = self.model, e.window === self.window else { return e }
            switch e.keyCode {
            case 123: m.go(m.page - 1); return nil
            case 124: m.go(m.page + 1); return nil
            default: return e   // Enter handled by default buttons
            }
        }
        AppLog.info("Guide window opened")
    }

    /// Test hook.
    func goTo(_ p: Int) { model?.go(p) }
    var currentPage: Int { model?.page ?? -1 }

    private func finish() {
        Store.shared.setOnboardingCompleted()
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model?.stop()
        model = nil
        window?.contentView = nil   // stop TimelineView; no CPU while closed
        window = nil
        AppLog.info("Guide window closed")
    }
}
