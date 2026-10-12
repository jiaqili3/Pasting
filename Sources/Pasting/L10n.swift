import Foundation
import Combine

/// Simple in-code localization. Keys are the Chinese strings; English is the translation.
/// Switching language republishes immediately (no restart).
final class L10n: ObservableObject {
    static let shared = L10n()
    static let changed = Notification.Name("PastingLanguageChanged")

    enum Choice: String, CaseIterable { case system, zh, en }

    @Published private(set) var isChinese: Bool = true

    func apply(_ choice: Choice) {
        let zh: Bool
        switch choice {
        case .zh: zh = true
        case .en: zh = false
        case .system: zh = (Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
        }
        if zh != isChinese || !applied {
            applied = true
            isChinese = zh
            Fmt.relative.locale = Locale(identifier: zh ? "zh_Hans" : "en_US")
            NotificationCenter.default.post(name: L10n.changed, object: nil)
        }
    }
    private var applied = false

    func t(_ key: String) -> String {
        if isChinese { return L10n.zhOverrides[key] ?? key }
        return L10n.en[key] ?? key
    }

    static let zhOverrides: [String: String] = [
        "AX_ALERT_BODY": "Pasting 需要「辅助功能」权限，才能把内容粘贴到其他应用的光标位置。\n\n内容已经复制到剪贴板，你也可以手动按 ⌘V 粘贴。\n\n请在「系统设置 → 隐私与安全性 → 辅助功能」中允许 Pasting。",
    ]

    static let en: [String: String] = [
        // Menu bar
        "显示 Pasting": "Show Pasting", "暂停捕获": "Pause Capturing", "继续捕获": "Resume Capturing",
        "历史保留": "Keep History", "1 天": "1 Day", "7 天": "7 Days", "30 天": "30 Days", "永久": "Forever",
        "清空历史": "Clear History", "登录时打开": "Open at Login", "退出 Pasting": "Quit Pasting",
        "设置…": "Settings…", "显示引导": "Show Guide",
        "清空历史？": "Clear history?", "收藏的条目会保留。此操作不可撤销。": "Favorites are kept. This can't be undone.",
        "收藏": "Favorites", "取消收藏": "Remove from Favorites", "加入收藏": "Add to Favorites", "编辑…": "Edit…", "新建收藏…": "New Favorite…", "新建收藏": "New Favorite", "编辑收藏": "Edit Favorite",
        "标题（可选）": "Title (optional)", "显示在卡片上的名字": "Name shown on the card", "内容": "Content", "保存": "Save",
        "ⓘ 编辑内容会把富文本转成纯文本": "ⓘ Editing the content converts rich text to plain text", "图片和文件只能修改标题。": "Images and files: only the title can be edited.",
        "手动添加": "Manual", "面板位置": "Panel position", "跟随光标（默认）": "Follow cursor (default)", "记住上次拖动的位置": "Remember last dragged position", "拖动面板顶部的空白处即可移动面板。": "Drag an empty area at the top of the panel to move it.", "拖动以移动": "Drag to move", "收藏 / 取消收藏": "Add / Remove Favorite", "收藏 (⌘D)": "Add to Favorites (⌘D)", "取消收藏 (⌘D)": "Remove from Favorites (⌘D)",
        "清空": "Clear", "取消": "Cancel", "确定": "OK",
        // Panel
        "未知": "Unknown", "重命名": "Rename", "新建分类": "New Pinboard", "例如：工作、Travel": "e.g. Work, Travel",
        "重命名分类": "Rename Pinboard", "搜索剪贴板…": "Search clipboard…", "纯文本粘贴": "Paste as Plain Text",
        "把选中的卡片去掉格式后粘贴（⌥↵）": "Paste the selected card without formatting (⌥↵)",
        "关闭": "Close", "关闭 (Esc)": "Close (Esc)", "历史": "History", "重命名…": "Rename…", "删除": "Delete",
        "没有更多应用": "No more apps", "其他应用": "Other Apps", "新建分类…": "New Pinboard…",
        "更多应用 / 新建分类": "More apps / New pinboard", "没有内容": "Nothing here",
        "粘贴": "Paste", "粘贴为纯文本": "Paste as Plain Text", "复制": "Copy",
        "加入分类": "Add to Pinboard", "纯文本": "Plain", "粘贴为纯文本 (⌥↵)": "Paste as plain text (⌥↵)",
        "文本": "Text", "链接": "Link", "图片": "Image", "文件": "File", "颜色": "Color",
        "%d 项  ·  ↵ 粘贴  ⌥↵ 纯文本  Esc 关闭": "%d items  ·  ↵ Paste  ⌥↵ Plain  Esc Close",
        "只看来自 %@ 的内容（再点一次取消）": "Only show clips from %@ (click again to clear)",
        "+%d 个文件": "+%d files",
        // Accessibility alert
        "需要辅助功能权限": "Accessibility Permission Needed",
        "AX_ALERT_BODY": "Pasting needs Accessibility permission to paste into other apps at the cursor.\n\nThe item is already on your clipboard — you can press ⌘V manually.\n\nAllow Pasting in System Settings → Privacy & Security → Accessibility.",
        "打开系统设置": "Open System Settings", "稍后": "Later",
        // Guide
        "欢迎使用 Pasting": "Welcome to Pasting", "你的本地剪贴板历史。快速、私密、无云同步。": "Your local clipboard history. Fast, private, no cloud sync.",
        "自动记录": "Captures Everything", "文字、链接、图片、文件和颜色都会自动保存，密码管理器的内容会被跳过。": "Text, links, images, files and colors are saved automatically. Password-manager items are skipped.",
        "随时呼出": "Summon Anytime", "按 ⇧⌘V，卡片面板会出现在文字光标上方。←/→ 选择，↵ 粘贴，Esc 关闭。": "Press ⇧⌘V and the card panel appears above your text cursor. ←/→ to select, ↵ to paste, Esc to close.",
        "搜索、筛选、纯文本": "Search, Filter, Plain Text", "直接打字搜索，按来源应用筛选，一键去掉格式粘贴。": "Type to search, filter by source app, and paste without formatting in one click.",
        "辅助功能权限": "Accessibility Permission", "Pasting 需要此权限才能把内容粘贴到其他应用的光标处。": "Pasting needs this permission to paste at the cursor in other apps.",
        "打开「隐私与安全性 → 辅助功能」": "Open Privacy & Security → Accessibility", "已授权": "Granted", "尚未授权": "Not granted yet",
        "个性化设置": "Make It Yours", "开机后自动在菜单栏运行": "Run in the menu bar after you log in",
        "语言": "Language", "跟随系统": "System", "开始使用": "Start Using", "上一步": "Back", "下一步": "Next",
        // Settings
        "设置": "Settings", "通用": "General", "快捷键": "Shortcuts", "隐私": "Privacy", "关于": "About",
        "最多条数": "Maximum items", "清空历史…": "Clear History…", "超过保留时间的条目会自动删除；收藏和分类中的条目不会被删除。": "Items older than the retention period are deleted automatically; favorites and pinboard items are kept.",
        "打开面板": "Show panel", "当前快捷键：": "Current shortcut:", "暂不支持自定义快捷键。": "Custom shortcuts are not supported yet.",
        "跳过密码等敏感内容（Concealed/Transient）": "Skip sensitive items (Concealed/Transient)",
        "忽略的应用（每行一个 Bundle ID）": "Ignored apps (one bundle ID per line)", "来自这些应用的复制不会被记录。": "Copies from these apps are not recorded.",
        "面板大小": "Panel Size", "小": "Small", "中": "Medium", "大": "Large", "自定义": "Custom",
        "宽度": "Width", "卡片大小": "Card Size",
        "也可以直接拖动面板边缘调整大小。面板会出现在文字光标上方；无法获取光标时显示在屏幕底部中央。": "You can also drag the panel edges to resize. The panel appears above your text cursor; if the cursor can't be found it appears at the bottom center of the screen.",
        "授予辅助功能权限": "Grant Accessibility", "将 Pasting 拖入上方列表": "Drag Pasting into the list above",
        "把左侧图标拖到「辅助功能」列表中，然后打开开关。": "Drag the icon on the left into the Accessibility list, then turn its switch on.",
        "现在可以直接粘贴到其他应用了。": "You can now paste straight into other apps.",
        "作者": "Author", "代码仓库": "Repository", "许可证": "License",
        "版本": "Version", "在访达中显示数据文件夹": "Show Data Folder in Finder", "所有数据只保存在本机，没有云同步。": "All data stays on this Mac. No cloud sync.",
    ]
}

/// Shorthand.
func L(_ key: String) -> String { L10n.shared.t(key) }
func LF(_ key: String, _ args: CVarArg...) -> String { String(format: L(key), arguments: args) }
