import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// カードの右クリックメニューの項目
enum CardAction {
    case paste, pastePlain, pasteTransformed(TextTransform), copy, copyPlain, copyText
    case preview, edit, rename, duplicate
    case open, openWith(URL), reveal
    case addTo(Pinboard), newPinboard
    case delete
}

struct PanelView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var model: PanelModel
    var onAction: (CardAction, ClipItem) -> Void
    var onMenu: () -> Void
    var onNewPinboard: () -> Void
    var onRenamePinboard: (Pinboard) -> Void
    var onDeletePinboard: (Pinboard) -> Void
    var onOpenSettings: () -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        let items = model.visibleItems(in: store.items)
        VStack(spacing: 10) {
            topBar
            if !model.accessibilityGranted && Preferences.pasteToActiveApp { accessibilityBanner }
            if items.isEmpty {
                emptyState
            } else {
                cards(items)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            VisualEffectBackground()
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16, style: .continuous))
        )
        .onAppear { searchFocused = true }
        .onChange(of: model.showToken) { searchFocused = true }
    }

    // MARK: - 上の段

    private var topBar: some View {
        ZStack {
            HStack {
                searchField
                Spacer()
                filterMenu
                Button(action: onMenu) {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("メニュー")
            }
            HStack(spacing: 4) {
                tab("クリップボード", dot: .secondary, active: model.board == nil) { model.board = nil }
                ForEach(store.pinboards) { board in
                    tab(board.name, dot: Color(rgb: board.color), active: model.board == board.id,
                        dropping: model.dropBoard == board.id) {
                        model.board = board.id
                    }
                    // カードをタブに落とすと、そのピンボードに入る（まとめて選んだカードは全部）
                    .onDrop(of: [ReorderDrop.type], delegate: PinboardDrop(board: board, model: model) { id in
                        if let item = store.items.first(where: { $0.id == id }) { onAction(.addTo(board), item) }
                    })
                    // 引っぱって並べ替えるために、タブの位置を知らせる（動かすのは PanelController）
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: TabFrames.self, value: [board.id: geo.frame(in: .global)])
                    })
                    .contextMenu {
                        Button("名前を変更…") { onRenamePinboard(board) }
                        let index = store.pinboards.firstIndex { $0.id == board.id } ?? 0
                        Button("左へ移動") { store.movePinboard(board.id, to: index - 1) }
                            .disabled(index == 0)
                        Button("右へ移動") { store.movePinboard(board.id, to: index + 1) }
                            .disabled(index == store.pinboards.count - 1)
                        Menu("色") {
                            ForEach(Pinboard.palette.indices, id: \.self) { i in
                                checkButton(Pinboard.paletteNames[i], on: board.color == Pinboard.palette[i]) {
                                    store.setColor(of: board, to: Pinboard.palette[i])
                                }
                            }
                        }
                        Divider()
                        Button("削除…", role: .destructive) { onDeletePinboard(board) }
                    }
                }
                Button(action: onNewPinboard) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("新しいピンボード")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 30)
        .onPreferenceChange(TabFrames.self) { frames in
            MainActor.assumeIsolated { model.tabFrames = frames }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("検索", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
        }
        .padding(.horizontal, 10)
        .frame(width: 220, height: 28)
        .background(Color.primary.opacity(model.query.isEmpty ? 0.05 : 0.1), in: Capsule())
    }

    private func tab(_ title: String, dot: Color, active: Bool, dropping: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 8, height: 8)
                Text(title).font(.system(size: 13, weight: active || dropping ? .semibold : .regular))
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(dropping ? dot.opacity(0.35) : active ? Color.primary.opacity(0.12) : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(dot, lineWidth: dropping ? 2 : 0))
            .scaleEffect(dropping ? 1.1 : 1)
            .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.12), value: dropping)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func checkButton(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if on {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    /// 種類・アプリ・日付で絞り込む（Paste の検索フィルターと同じ）
    private var filterMenu: some View {
        let apps = appChoices
        return Menu {
            Section("種類") {
                ForEach(ClipFilter.allCases) { filter in
                    checkButton(filter.rawValue, on: model.filter == filter) { model.filter = filter }
                }
            }
            Section("アプリ") {
                checkButton("すべてのアプリ", on: model.app == nil) { model.app = nil }
                ForEach(apps, id: \.id) { app in
                    checkButton(app.name, on: model.app == app.id) { model.app = app.id }
                }
            }
            Section("日付") {
                ForEach(DateFilter.allCases) { date in
                    checkButton(date.rawValue, on: model.date == date) { model.date = date }
                }
            }
            if model.isFiltered {
                Divider()
                Button("絞り込みを解除") { model.clearFilters() }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                if model.isFiltered {
                    Text(filterSummary(apps))
                }
            }
            .font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("種類・アプリ・日付で絞り込み")
    }

    /// 今のタブの履歴にあるアプリ（多い順）
    private var appChoices: [(id: String, name: String)] {
        var counts: [String: (name: String, count: Int)] = [:]
        for item in store.items where item.pinboardID == model.board {
            guard let id = item.sourceBundleID else { continue }
            counts[id, default: (item.sourceAppName ?? id, 0)].count += 1
        }
        return counts.sorted { $0.value.count > $1.value.count }.prefix(15).map { ($0.key, $0.value.name) }
    }

    private func filterSummary(_ apps: [(id: String, name: String)]) -> String {
        var parts: [String] = []
        if model.filter != .all { parts.append(model.filter.rawValue) }
        if let app = model.app { parts.append(apps.first { $0.id == app }?.name ?? "アプリ") }
        if model.date != .all { parts.append(model.date.rawValue) }
        return parts.joined(separator: "・")
    }

    private var accessibilityBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("自動で貼り付けるには「アクセシビリティ」の許可が必要です。今はクリップボードにコピーするだけになります。")
                .font(.system(size: 12))
            Button("設定を開く", action: onOpenSettings)
                .controlSize(.small)
        }
        .padding(.horizontal, 20)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard").font(.system(size: 32)).foregroundStyle(.secondary)
            Text(emptyMessage)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyMessage: String {
        if !model.query.isEmpty || model.isFiltered { return "見つかりませんでした" }
        if model.board != nil { return "このピンボードは空です。カードを右クリックして「ピンボードに追加」で入れられます。" }
        return "まだ履歴がありません。何かコピーしてみてください。"
    }

    // MARK: - カード列

    private func cards(_ items: [ClipItem]) -> some View {
        let tagColors = store.pinboardColorsBySignature()
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        ClipCard(item: item, index: index, selected: model.isSelected(item, at: index),
                                 showShortcut: model.commandHeld, tagColor: tagColors[item.signature], store: store)
                            .id(item.id)
                            .onTapGesture(count: 2) { onAction(.paste, item) }
                            .onTapGesture { model.click(index, in: items) }
                            // 引っぱり出しは PanelController が AppKit で始める（カードの位置をここで知らせる）
                            .background(GeometryReader { geo in
                                Color.clear.preference(key: CardFrames.self, value: [item.id: geo.frame(in: .global)])
                            })
                            .onDrop(of: [ReorderDrop.type, .item], delegate: ReorderDrop(target: item, model: model, store: store))
                            .contextMenu { cardMenu(item) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .onPreferenceChange(CardFrames.self) { frames in
                MainActor.assumeIsolated { model.cardFrames = frames }
            }
            .onChange(of: model.selection) {
                guard items.indices.contains(model.selection) else { return }
                let target = items[model.selection].id
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    proxy.scrollTo(target, anchor: .center)
                } else {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(target, anchor: .center) }
                }
            }
        }
    }

    /// 右クリックメニュー（Paste と同じ項目）。まとめて選んでいるカードなら、選んだもの全部に効く
    @ViewBuilder
    private func cardMenu(_ item: ClipItem) -> some View {
        let count = model.marked.contains(item.id) ? model.marked.count : 1
        let suffix = count > 1 ? "（\(count) 件）" : ""
        Button("貼り付け" + suffix) { onAction(.paste, item) }
        if item.text != nil {
            Button("書式なしで貼り付け" + suffix) { onAction(.pastePlain, item) }
            Menu("整えて貼り付け" + suffix) {
                ForEach(TextTransform.allCases) { transform in
                    Button(transform.rawValue) { onAction(.pasteTransformed(transform), item) }
                }
            }
        }
        Button("コピー" + suffix) { onAction(.copy, item) }
        if item.text != nil {
            Button("書式なしでコピー" + suffix) { onAction(.copyPlain, item) }
        }
        if let text = item.ocrText, !text.isEmpty {
            Button("画像の文字をコピー") { onAction(.copyText, item) }
        }
        Divider()
        Button("プレビュー") { onAction(.preview, item) }
        Button("編集…") { onAction(.edit, item) }
        Button("名前を変更…") { onAction(.rename, item) }
        Button("複製" + suffix) { onAction(.duplicate, item) }
        if let url = item.openURL {
            Divider()
            Button(item.kind == .link ? "ブラウザで開く" : "開く") { onAction(.open, item) }
            Menu("アプリで開く") {
                ForEach(NSWorkspace.shared.urlsForApplications(toOpen: url).prefix(12), id: \.self) { app in
                    Button(FileManager.default.displayName(atPath: app.path)) { onAction(.openWith(app), item) }
                }
            }
            if item.kind == .file {
                Button("Finder で表示") { onAction(.reveal, item) }
            }
        }
        shareLink(item)
        Divider()
        Menu("ピンボードに追加" + suffix) {
            ForEach(store.pinboards) { board in
                Button(board.name) { onAction(.addTo(board), item) }
            }
            if !store.pinboards.isEmpty { Divider() }
            Button("新しいピンボード…") { onAction(.newPinboard, item) }
        }
        Divider()
        Button((item.pinboardID == nil ? "削除" : "ピンボードから削除") + suffix, role: .destructive) {
            onAction(.delete, item)
        }
    }

    @ViewBuilder
    private func shareLink(_ item: ClipItem) -> some View {
        switch item.kind {
        case .text:
            ShareLink("シェア", item: item.text ?? "")
        case .link:
            if let url = item.openURL { ShareLink("シェア", item: url) }
        case .image:
            if let url = store.imageURL(for: item) { ShareLink("シェア", item: url) }
        case .file:
            ShareLink("シェア", items: (item.filePaths ?? []).map { URL(fileURLWithPath: $0) })
        case .other:
            EmptyView()
        }
    }
}

/// 見えているカードの位置（パネルの左上からの座標）
struct CardFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// ピンボードのタブの位置（パネルの左上からの座標）
struct TabFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// ピンボードの中で、カードを引っぱって並べ替える
struct ReorderDrop: DropDelegate {
    /// 並べ替え用の印の種類（Info.plist にも登録してある）
    static let type = UTType(exportedAs: "jp.daisukeaboshi.copipe.item", conformingTo: .data)

    let target: ClipItem
    let model: PanelModel
    let store: ClipboardStore

    func validateDrop(info: DropInfo) -> Bool {
        model.dragging != nil && target.pinboardID != nil
    }

    func dropEntered(info: DropInfo) {
        guard let dragged = model.dragging, dragged != target.id, target.pinboardID != nil else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            store.move(dragged, to: target.id)
        } else {
            withAnimation(.easeOut(duration: 0.15)) { store.move(dragged, to: target.id) }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        model.dragging = nil
        return true
    }
}

/// カードをピンボードのタブに落としたとき
struct PinboardDrop: DropDelegate {
    let board: Pinboard
    let model: PanelModel
    let onDrop: (UUID) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        model.dragging != nil
    }

    func dropEntered(info: DropInfo) {
        model.dropBoard = board.id
    }

    func dropExited(info: DropInfo) {
        if model.dropBoard == board.id { model.dropBoard = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Copipe の中で引っぱったときは「移動」しか受けつけないので、それに合わせる
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let id = model.dragging else { return false }
        model.dragging = nil
        model.dropBoard = nil
        onDrop(id)
        return true
    }
}

// MARK: - カード

/// 履歴のカード（Paste 7 と同じ形：中身を大きく出し、左上に種類と時間、右上にアプリのアイコン）
struct ClipCard: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    let showShortcut: Bool
    /// この内容が入っているピンボードの色（ピンボードに入れたら履歴のカードもその色になる）
    let tagColor: Int?
    let store: ClipboardStore

    static let width: CGFloat = 240
    static let height: CGFloat = 256
    static let cornerRadius: CGFloat = 18
    /// 画像を出すリンクのカードで、画像の高さ
    static let linkImageHeight: CGFloat = 150

    var body: some View {
        content
            .frame(width: Self.width, height: Self.height, alignment: .top)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
            .overlay(alignment: .bottomTrailing) {
                if showShortcut && index < 9 {
                    Text("⌘\(index + 1)")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .padding(10)
                }
            }
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius + 4, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 4)
                    .padding(-4)
                    .opacity(selected ? 1 : 0)
            )
            .help(item.sourceAppName ?? "")
    }

    /// カードの地は白（ダークモードでは黒）。ピンボードに入っているものだけ、その色を薄く敷く
    private var background: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            boardColor?.opacity(0.12)
        }
    }

    /// 入っているピンボードの色
    private var boardColor: Color? {
        if let id = item.pinboardID, let board = store.pinboards.first(where: { $0.id == id }) {
            return Color(rgb: board.color)
        }
        return tagColor.map { Color(rgb: $0) }
    }

    private var timeText: String {
        Date().timeIntervalSince(item.date) < 60
            ? "たった今" : Self.relative.localizedString(for: item.date, relativeTo: Date())
    }

    /// 左上の「種類・時間」と右上のアプリのアイコン。onMedia なら画像の上に白い文字で重ねる
    private func header(onMedia: Bool, color: Color = .primary) -> some View {
        HStack(spacing: 6) {
            if let boardColor {
                Circle()
                    .fill(boardColor)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(.white.opacity(onMedia ? 0.9 : 0), lineWidth: 1))
            }
            Text(item.displayTitle)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Text(timeText)
                .font(.system(size: 14))
                .opacity(0.7)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if let icon = AppAppearance.icon(for: item.sourceBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 26, height: 26)
            }
        }
        .foregroundStyle(onMedia ? Color.white : color)
        .shadow(color: .black.opacity(onMedia ? 0.4 : 0), radius: 3, y: 1)
        .padding(.horizontal, 14)
        .frame(width: Self.width, height: 44)
        .background(alignment: .top) {
            // 明るい画像の上でも白い文字が読めるように、上だけ暗くする
            if onMedia {
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 76)
            }
        }
    }

    /// 下の小さい説明（文字数・大きさなど）
    private func footer(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 画像の上に重ねる小さい説明
    private func mediaCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.middle)
            .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        let detail = Self.detail(of: item, store: store)
        if let rgb = item.colorValue {
            // 色の見本
            let textColor = AppAppearance.textColor(on: NSColor(rgb: rgb))
            ZStack(alignment: .top) {
                Color(rgb: rgb)
                Text(rgb.hexColor)
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .foregroundStyle(textColor)
                    .frame(maxHeight: .infinity)
                header(onMedia: false, color: textColor)
            }
        } else {
            switch item.kind {
            case .text:
                VStack(alignment: .leading, spacing: 2) {
                    header(onMedia: false)
                    // カードに見えるのは数行なので、長い文章は先頭だけ描く
                    Text(String((item.text ?? "").prefix(1_200)))
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .clipped()
                    footer(detail)
                }
            case .link:
                LinkCardBody(link: item.text ?? "", previews: .shared) { onMedia in
                    header(onMedia: onMedia)
                }
            case .image:
                ZStack(alignment: .top) {
                    if let image = store.image(for: item) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: Self.width, height: Self.height)
                            .clipped()
                    }
                    header(onMedia: true)
                }
                .overlay(alignment: .bottomLeading) { mediaCaption(detail) }
            case .file:
                if let first = item.filePaths?.first {
                    FileCardBody(path: first, cache: .shared,
                                 header: { onMedia in header(onMedia: onMedia) },
                                 caption: { onMedia in
                                     if onMedia { mediaCaption(detail) } else { footer(detail) }
                                 })
                }
            case .other:
                if let material = item.material, !material.isEmpty {
                    materialCard(material)
                } else {
                    VStack(spacing: 0) {
                        header(onMedia: false)
                        Spacer(minLength: 0)
                        otherIcon
                        Text("\(item.sourceAppName ?? "アプリ") の素材")
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                        Spacer(minLength: 0)
                        footer(detail)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var otherIcon: some View {
        if let icon = AppAppearance.icon(for: item.sourceBundleID) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 84, height: 84)
        } else {
            Image(systemName: "shippingbox")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
        }
    }

    /// Final Cut Pro の素材：中のクリップ名・テロップと、使っているエフェクト
    private func materialCard(_ material: MaterialInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(onMedia: false)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(material.names.prefix(4).enumerated()), id: \.offset) { _, name in
                    Label(name, systemImage: "film")
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                }
                if material.names.count > 4 {
                    Text("ほか \(material.names.count - 4) 個")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                if !material.effects.isEmpty {
                    Label(material.effects.joined(separator: "・"), systemImage: "sparkles")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer([material.durationText, ClipCard.detail(of: item, store: store)].compactMap { $0 }.joined(separator: " ・ "))
        }
    }

    /// カードの下・プレビューの右上に出す説明（文字数・大きさ・ファイル名など）
    static func detail(of item: ClipItem, store: ClipboardStore) -> String {
        if let rgb = item.colorValue { return rgb.hexColor }
        switch item.kind {
        case .text: return "\(item.text?.count ?? 0) 文字"
        case .link: return URL(string: item.text ?? "")?.host ?? ""
        case .image:
            if let size = store.image(for: item)?.pixelSize { return "\(Int(size.width)) × \(Int(size.height))" }
            return ""
        case .file:
            if let paths = item.filePaths, paths.count == 1 { return (paths[0] as NSString).lastPathComponent }
            return "\(item.filePaths?.count ?? 0) 項目"
        case .other: return ByteCountFormatter.string(fromByteCount: Int64(item.rawSize ?? 0), countStyle: .file)
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.unitsStyle = .full
        return f
    }()
}

/// リンクのカード：上にページの画像、下に題名とサイト名（画像が取れないときは地球のマーク）
struct LinkCardBody<Header: View>: View {
    let link: String
    @ObservedObject var previews: LinkPreviews
    @ViewBuilder var header: (Bool) -> Header

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image = previews.image(for: link) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: ClipCard.width, height: ClipCard.linkImageHeight)
                    .clipped()
                    .overlay(alignment: .top) { header(true) }
            } else {
                header(false)
                Image(systemName: "globe")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: ClipCard.width, height: ClipCard.linkImageHeight - 44)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(previews.title(for: link) ?? URL(string: link)?.host ?? link)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                Text(URL(string: link)?.host ?? link)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            Spacer(minLength: 0)
        }
        .onAppear { previews.request(link) }
    }
}

/// ウィンドウの後ろを透かすすりガラス背景
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// コピー元アプリのアイコンと、色の上に載せる文字の色
@MainActor
enum AppAppearance {
    private static var iconCache: [String: NSImage] = [:]

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = icon
        return icon
    }

    /// その色の上で読みやすいほう（白か黒）
    static func textColor(on color: NSColor) -> Color {
        let l = luminance(color)
        return (1.05 / (l + 0.05)) >= ((l + 0.05) / 0.05) ? .white : .black
    }

    private static func luminance(_ color: NSColor) -> Double {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ x: CGFloat) -> Double {
            let x = Double(x)
            return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }
}

extension NSColor {
    /// 0xRRGGBB から色を作る
    convenience init(rgb: Int) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
                  blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
}

extension Color {
    /// 0xRRGGBB から色を作る
    init(rgb: Int) {
        self.init(red: Double((rgb >> 16) & 0xff) / 255, green: Double((rgb >> 8) & 0xff) / 255,
                  blue: Double(rgb & 0xff) / 255)
    }
}

/// ファイルのカード。中身のサムネイル（画像・動画・PDF など）が作れればカードいっぱいに出し、
/// 作れないファイルはアイコンと名前を出す
struct FileCardBody<Header: View, Caption: View>: View {
    let path: String
    @ObservedObject var cache: ThumbnailCache
    @ViewBuilder var header: (Bool) -> Header
    @ViewBuilder var caption: (Bool) -> Caption

    var body: some View {
        Group {
            if let image = cache.images[path] {
                ZStack(alignment: .top) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: ClipCard.width, height: ClipCard.height)
                        .clipped()
                    header(true)
                }
                .overlay(alignment: .bottomLeading) { caption(true) }
            } else {
                VStack(spacing: 0) {
                    header(false)
                    Spacer(minLength: 0)
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .frame(width: 84, height: 84)
                    Spacer(minLength: 0)
                    caption(false)
                }
            }
        }
        .onAppear { cache.request(path) }
    }
}

@MainActor
final class ThumbnailCache: ObservableObject {
    static let shared = ThumbnailCache()
    @Published private(set) var images: [String: NSImage] = [:]
    private var requested: Set<String> = []

    func request(_ path: String) {
        guard !requested.contains(path) else { return }
        requested.insert(path)
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path),
                                                   size: CGSize(width: ClipCard.width, height: ClipCard.height),
                                                   scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let image = representation?.nsImage else { return }
            Task { @MainActor in self.images[path] = image }
        }
    }
}
