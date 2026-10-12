import SwiftUI
import AppKit

struct PanelActions {
    var select: (Int) -> Void
    var paste: (Int, Bool) -> Void          // index, plainText
    var copy: (Int) -> Void
    var rename: (ClipItem) -> Void
    var edit: (ClipItem) -> Void
    var newFavorite: () -> Void
    var toggleFavorite: (ClipItem) -> Void
    var delete: (ClipItem) -> Void
    var addToPinboard: (ClipItem, UUID) -> Void
    var selectTab: (PanelTab) -> Void
    var addPinboard: () -> Void
    var renamePinboard: (Pinboard) -> Void
    var deletePinboard: (Pinboard) -> Void
}

private let quick = Animation.easeOut(duration: 0.15)

struct PanelContentView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var l10n = L10n.shared
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            tabBar
            cards
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            // Chips scroll horizontally (wheel is routed here by ClipboardPanelController.handleScroll);
            // the ">" menu and the count stay pinned on the right.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    TabChip(title: L("历史"), selected: model.selectedTab == .history) { actions.selectTab(.history) }
                    TabChip(title: L("收藏"), selected: model.selectedTab == .favorites, icon: "star.fill") { actions.selectTab(.favorites) }
                    if model.selectedTab == .favorites {
                        Button(action: actions.newFavorite) {
                            Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                                .frame(width: 20, height: 18)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                        }
                        .buttonStyle(.plain).help(L("新建收藏…"))
                    }
                    ForEach(model.pinboards) { board in
                        TabChip(title: board.name, selected: model.selectedTab == .pinboard(board.id)) {
                            actions.selectTab(.pinboard(board.id))
                        }
                        .contextMenu {
                            Button(L("重命名…")) { actions.renamePinboard(board) }
                            Button(L("删除")) { actions.deletePinboard(board) }
                        }
                    }
                    if !model.appStats.isEmpty {
                        Divider().frame(height: 14).padding(.horizontal, 2)
                    }
                    ForEach(model.appStats.prefix(5)) { s in
                        AppChip(stat: s, selected: model.selectedTab == .app(s.key)) { actions.selectTab(.app(s.key)) }
                    }
                }
                .padding(.leading, 12).padding(.trailing, 4)
            }
            Menu {
                let rest = Array(model.appStats.dropFirst(5))
                if rest.isEmpty {
                    Text(L("没有更多应用"))
                } else {
                    Section(L("其他应用")) {
                        ForEach(rest) { s in
                            Button {
                                actions.selectTab(.app(s.key))
                            } label: {
                                if let icon = IconCache.shared.appIcon(bundleID: s.key == "unknown" ? nil : s.key) {
                                    Image(nsImage: icon)
                                }
                                Text("\(s.name)  (\(s.count))")
                            }
                        }
                    }
                }
                Divider()
                Button(L("新建收藏…")) { actions.newFavorite() }
            Button(L("新建分类…")) { actions.addPinboard() }
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("更多应用 / 新建分类"))
            Text(LF("%d 项  ·  ↵ 粘贴  ⌥↵ 纯文本  Esc 关闭", model.items.count))
                .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                .layoutPriority(-1)
                .padding(.trailing, 12)
        }
        .frame(height: 22)
    }

    private var cards: some View {
        Group {
            if model.items.isEmpty {
                Text(L("没有内容")).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .contextMenu { Button(L("新建收藏…")) { actions.newFavorite() } }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .center, spacing: 8) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                                CardView(item: item, selected: index == model.selectedIndex, zh: l10n.isChinese, size: model.cardSize,
                                         hovered: model.hoveredID == item.id,
                                         showEdit: model.selectedTab == .favorites,
                                         onPlain: { actions.paste(index, true) },
                                         onEdit: { actions.edit(item) },
                                         onStar: { actions.toggleFavorite(item) })
                                    .equatable()
                                    .contentShape(Rectangle())
                                    .onTapGesture { actions.select(index) }
                                    .simultaneousGesture(TapGesture(count: 2).onEnded { actions.paste(index, false) })
                                    .onHover { h in
                                        if h { model.hoveredID = item.id } else if model.hoveredID == item.id { model.hoveredID = nil }
                                    }
                                    .contextMenu { contextMenu(item, index) }
                                    .id(item.id)
                                    .transition(.opacity)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .animation(quick, value: model.items.map(\.id))
                    }
                    .onChange(of: model.selectedIndex) { _, idx in
                        guard model.items.indices.contains(idx) else { return }
                        proxy.scrollTo(model.items[idx].id)   // no animation: arrows feel instant
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func contextMenu(_ item: ClipItem, _ index: Int) -> some View {
        Button(L("粘贴")) { actions.paste(index, false) }
        if item.plainText != nil, item.kind == .text || item.kind == .url {
            Button(L("粘贴为纯文本")) { actions.paste(index, true) }
        }
        Button(L("复制")) { actions.copy(index) }
        Button(L("编辑…")) { actions.edit(item) }
        Button(L("重命名…")) { actions.rename(item) }
        Button(item.isFavorite ? L("取消收藏") : L("加入收藏")) { actions.toggleFavorite(item) }
        if !model.pinboards.isEmpty {
            Menu(L("加入分类")) {
                ForEach(model.pinboards) { b in
                    Button(b.name) { actions.addToPinboard(item, b.id) }
                }
            }
        }
        Divider()
        Button(L("删除")) { actions.delete(item) }
    }
}

struct AppChip: View {
    let stat: AppStat
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon = IconCache.shared.appIcon(bundleID: stat.key == "unknown" ? nil : stat.key) {
                    Image(nsImage: icon).resizable().frame(width: 13, height: 13)
                } else {
                    Image(systemName: "questionmark.app").font(.system(size: 10))
                }
                Text(stat.name).font(.system(size: 11, weight: selected ? .semibold : .regular)).lineLimit(1)
                Text("\(stat.count)").font(.system(size: 9)).foregroundColor(.secondary)
            }
            .foregroundColor(selected ? .accentColor : .primary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(LF("只看来自 %@ 的内容（再点一次取消）", stat.name))
    }
}

struct TabChip: View {
    let title: String
    let selected: Bool
    var icon: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let icon { Image(systemName: icon).font(.system(size: 9)).foregroundColor(.yellow) }
                Text(title)
            }
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .accentColor : .primary)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}

struct CardView: View, Equatable {
    let item: ClipItem
    let selected: Bool
    let zh: Bool
    let size: CGFloat
    var hovered: Bool = false
    var showEdit: Bool = false
    let onPlain: () -> Void
    var onEdit: () -> Void = {}
    var onStar: () -> Void = {}

    static func == (a: CardView, b: CardView) -> Bool { a.selected == b.selected && a.hovered == b.hovered && a.showEdit == b.showEdit && a.zh == b.zh && a.size == b.size && a.item == b.item }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                badge(kindLabel, .accentColor)
                if item.isRich { badge("Rich", .purple) }
                Spacer(minLength: 0)
                if let icon = IconCache.shared.appIcon(bundleID: item.sourceAppBundleID) {
                    Image(nsImage: icon).resizable().frame(width: 13, height: 13)
                }
                if showEdit && (hovered || selected) {
                    Button(action: onEdit) {
                        Image(systemName: "pencil").font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary).frame(width: 16, height: 16).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help(L("编辑…"))
                    .transition(.opacity)
                }
                if item.isFavorite || hovered || selected {
                    Button(action: onStar) {
                        Image(systemName: item.isFavorite ? "star.fill" : "star")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(item.isFavorite ? .yellow : .secondary)
                            .symbolEffect(.bounce, value: item.isFavorite)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(item.isFavorite ? L("取消收藏 (⌘D)") : L("收藏 (⌘D)"))
                    .transition(.scale.combined(with: .opacity))
                }
            }
            preview.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 4) {
                Text(Fmt.relative.localizedString(for: item.createdAt, relativeTo: Date()))
                    .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if selected, item.plainText != nil, item.kind == .text || item.kind == .url {
                    Button(action: onPlain) {
                        Text(L("纯文本")).font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    }
                    .buttonStyle(.plain).help(L("粘贴为纯文本 (⌥↵)"))
                }
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: item.isFavorite)
        .animation(.easeOut(duration: 0.12), value: hovered || selected)
        .padding(8)
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(selected ? 0.10 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundColor(color)
    }

    private var kindLabel: String {
        switch item.kind {
        case .text: return L("文本")
        case .url: return L("链接")
        case .image: return L("图片")
        case .file: return L("文件")
        case .color: return L("颜色")
        }
    }

    @ViewBuilder private var preview: some View {
        switch item.kind {
        case .text:
            VStack(alignment: .leading, spacing: 3) {
                if let t = item.customTitle, !t.isEmpty {
                    Text(t).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                        .highPriorityGesture(TapGesture(count: 2).onEnded { if item.isFavorite { onEdit() } })
                    Text(String((item.plainText ?? "").prefix(200)))
                        .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(size < 130 ? 2 : 4)
                } else {
                    Text(String((item.plainText ?? "").prefix(300)))
                        .font(.system(size: 11)).lineLimit(size < 130 ? 4 : 6)
                }
            }
        case .url:
            VStack(alignment: .leading, spacing: 3) {
                Text(item.customTitle ?? URL(string: item.urlString ?? "")?.host ?? "Link")
                    .font(.system(size: 11, weight: .semibold)).lineLimit(2)
                Text(item.urlString ?? "").font(.system(size: 9)).foregroundColor(.secondary).lineLimit(3)
            }
        case .image:
            if let n = item.imageFilename, let img = ThumbCache.shared.thumbnail(for: n) {
                Image(nsImage: img).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: "photo").font(.system(size: 22)).foregroundColor(.secondary)
            }
        case .file:
            HStack(alignment: .top, spacing: 6) {
                if let icon = IconCache.shared.fileIcon(path: item.fileURLs?.first) {
                    Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle).font(.system(size: 11, weight: .medium)).lineLimit(3)
                    if let c = item.fileURLs?.count, c > 1 {
                        Text(LF("+%d 个文件", c - 1)).font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }
            }
        case .color:
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: NSColor.fromHex(item.colorHex ?? "#000000") ?? .black))
                    .frame(height: 56)
                Text(item.colorHex ?? "").font(.system(size: 11, design: .monospaced))
            }
        }
    }
}
