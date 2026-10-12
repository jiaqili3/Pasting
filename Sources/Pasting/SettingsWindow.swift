import ApplicationServices
import SwiftUI
import AppKit

final class SettingsNav: ObservableObject { @Published var tab = 0 }

struct SettingsView: View {
    @ObservedObject var nav = SettingsNav()
    @ObservedObject var store = Store.shared
    @ObservedObject var l10n = L10n.shared

    private var s: AppSettings { store.settings }

    var body: some View {
        TabView(selection: $nav.tab) {
            general.tag(0).tabItem { Label(L("通用"), systemImage: "gearshape") }
            history.tag(1).tabItem { Label(L("历史"), systemImage: "clock.arrow.circlepath") }
            shortcuts.tag(2).tabItem { Label(L("快捷键"), systemImage: "keyboard") }
            privacy.tag(3).tabItem { Label(L("隐私"), systemImage: "hand.raised") }
            about.tag(4).tabItem { Label(L("关于"), systemImage: "info.circle") }
        }
        .padding(20)
        .frame(width: 520, height: 360)
    }

    static func languagePicker() -> some View { LanguagePicker() }

    private var general: some View {
        Form {
            LanguagePicker()
            Toggle(L("登录时打开"), isOn: Binding(get: { Store.shared.settings.openAtLogin },
                                                set: { Store.shared.setOpenAtLogin($0) }))
            PanelSizeSettings()
            Toggle(L("暂停捕获"), isOn: Binding(get: { Store.shared.settings.capturingPaused },
                                              set: { Store.shared.setCapturingPaused($0) }))
        }
        .formStyle(.grouped)
    }

    private var history: some View {
        Form {
            RetentionPicker()
            Stepper(value: Binding(get: { Store.shared.settings.historyLimit },
                                   set: { Store.shared.setHistoryLimit($0) }), in: 50...5000, step: 50) {
                Text("\(L("最多条数")): \(s.historyLimit)")
            }
            Text(L("超过保留时间的条目会自动删除；收藏和分类中的条目不会被删除。"))
                .font(.caption).foregroundColor(.secondary)
            Button(L("清空历史…")) { AppDelegate.confirmClearHistory() }
        }
        .formStyle(.grouped)
    }

    private var shortcuts: some View {
        Form {
            ForEach([("打开面板", "⇧ ⌘ V"), ("粘贴", "↵"), ("粘贴为纯文本", "⌥ ↵"), ("收藏 / 取消收藏", "⌘ D"), ("设置", "⌘ ,")], id: \.0) { row in
                HStack {
                    Text(L(row.0))
                    Spacer()
                    Text(row.1).font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                }
            }
            Text(L("暂不支持自定义快捷键。")).font(.caption).foregroundColor(.secondary)
        }
        .formStyle(.grouped)
    }

    private var privacy: some View {
        Form {
            Toggle(L("跳过密码等敏感内容（Concealed/Transient）"),
                   isOn: Binding(get: { Store.shared.settings.ignoreConcealed ?? true },
                                 set: { Store.shared.setIgnoreConcealed($0) }))
            HStack {
                Text(L("辅助功能权限"))
                Spacer()
                if AXIsProcessTrusted() {
                    Label(L("已授权"), systemImage: "checkmark.circle.fill").foregroundColor(.green)
                } else {
                    Button(L("授予辅助功能权限")) { AccessibilityHelper.shared.start() }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("忽略的应用（每行一个 Bundle ID）"))
                TextEditor(text: Binding(get: { (Store.shared.settings.ignoredApps ?? []).joined(separator: "\n") },
                                         set: { Store.shared.setIgnoredApps($0.components(separatedBy: "\n")) }))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 80)
                Text(L("来自这些应用的复制不会被记录。")).font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var about: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            Text("Pasting").font(.title2.bold())
            Text("\(L("版本")) \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .foregroundColor(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text(L("作者")).foregroundColor(.secondary)
                    Link("Jiaqi Li", destination: URL(string: "https://github.com/jiaqili3")!)
                }
                GridRow {
                    Text(L("代码仓库")).foregroundColor(.secondary)
                    Link("github.com/jiaqili3/Pasting", destination: URL(string: "https://github.com/jiaqili3/Pasting")!)
                }
                GridRow {
                    Text(L("许可证")).foregroundColor(.secondary)
                    Text("MIT")
                }
            }
            .font(.callout)
            Text(L("所有数据只保存在本机，没有云同步。")).font(.caption).foregroundColor(.secondary)
            Button(L("在访达中显示数据文件夹")) {
                NSWorkspace.shared.activateFileViewerSelecting([Store.shared.supportDir])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LanguagePicker: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var l10n = L10n.shared
    var body: some View {
        Picker(L("语言"), selection: Binding(get: { store.settings.languageChoice },
                                             set: { Store.shared.setLanguage($0) })) {
            Text(L("跟随系统")).tag(L10n.Choice.system)
            Text("中文").tag(L10n.Choice.zh)
            Text("English").tag(L10n.Choice.en)
        }
    }
}

struct RetentionPicker: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var l10n = L10n.shared
    var body: some View {
        Picker(L("历史保留"), selection: Binding(get: { store.settings.effectiveRetentionDays },
                                               set: { Store.shared.setRetentionDays($0) })) {
            Text(L("1 天")).tag(1)
            Text(L("7 天")).tag(7)
            Text(L("30 天")).tag(30)
            Text(L("永久")).tag(0)
        }
    }
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.contentView = NSHostingView(rootView: SettingsView())
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
            NotificationCenter.default.addObserver(forName: L10n.changed, object: nil, queue: .main) { [weak self] _ in
                self?.window?.title = L("设置")
            }
        }
        window?.title = L("设置")
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        // Drop the SwiftUI hierarchy so nothing runs while closed.
        window?.contentView = nil
        window = nil
    }
}

struct PanelSizeSettings: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var l10n = L10n.shared
    var body: some View {
        let s = store.settings
        Picker(L("面板大小"), selection: Binding(get: { () -> Int in
            switch (Int(s.effectivePanelWidth), Int(s.effectiveCardSize)) {
            case (440, 100): return 0
            case (560, 120): return 1
            case (780, 160): return 2
            default: return 3
            }
        }, set: { v in
            switch v {
            case 0: Store.shared.setPanelSize(width: 440, card: 100)
            case 1: Store.shared.setPanelSize(width: 560, card: 120)
            case 2: Store.shared.setPanelSize(width: 780, card: 160)
            default: break
            }
        })) {
            Text(L("小")).tag(0); Text(L("中")).tag(1); Text(L("大")).tag(2); Text(L("自定义")).tag(3)
        }
        .pickerStyle(.segmented)
        HStack {
            Text(L("宽度")).frame(width: 70, alignment: .leading)
            Slider(value: Binding(get: { Double(s.effectivePanelWidth) }, set: { Store.shared.setPanelSize(width: $0.rounded()) }), in: 380...1600)
            Text("\(Int(s.effectivePanelWidth))").monospacedDigit().frame(width: 40)
        }
        HStack {
            Text(L("卡片大小")).frame(width: 70, alignment: .leading)
            Slider(value: Binding(get: { Double(s.effectiveCardSize) }, set: { Store.shared.setPanelSize(card: $0.rounded()) }), in: 90...220)
            Text("\(Int(s.effectiveCardSize))").monospacedDigit().frame(width: 40)
        }
        Text(L("也可以直接拖动面板边缘调整大小。面板会出现在文字光标上方；无法获取光标时显示在屏幕底部中央。"))
            .font(.caption).foregroundColor(.secondary)
    }
}
