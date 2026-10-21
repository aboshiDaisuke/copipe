import AppKit
import SwiftUI

struct PanelView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var model: PanelModel
    var onPaste: (ClipItem) -> Void
    var onMenu: () -> Void
    var onOpenSettings: () -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        let items = model.visibleItems(in: store.items)
        VStack(spacing: 10) {
            topBar
            if !model.accessibilityGranted { accessibilityBanner }
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
                kindMenu
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
                tab("クリップボード", dot: .secondary, active: model.filter != .pinned) { model.filter = .all }
                tab("ピン留め", dot: .red, active: model.filter == .pinned) { model.filter = .pinned }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 30)
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

    private func tab(_ title: String, dot: Color, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 8, height: 8)
                Text(title).font(.system(size: 13, weight: active ? .semibold : .regular))
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(active ? Color.primary.opacity(0.12) : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var kindMenu: some View {
        Menu {
            ForEach([ClipFilter.all, .text, .link, .image, .file, .other]) { filter in
                Button {
                    model.filter = filter
                } label: {
                    if model.filter == filter {
                        Label(filter.rawValue, systemImage: "checkmark")
                    } else {
                        Text(filter.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                if model.filter != .all && model.filter != .pinned {
                    Text(model.filter.rawValue)
                }
            }
            .font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("種類で絞り込み（tab）")
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
            Text(store.items.isEmpty ? "まだ履歴がありません。何かコピーしてみてください。" : "見つかりませんでした")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - カード列

    private func cards(_ items: [ClipItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        ClipCard(item: item, index: index, selected: index == model.selection,
                                 showShortcut: model.commandHeld, store: store)
                            .id(item.id)
                            .onTapGesture(count: 2) { onPaste(item) }
                            .onTapGesture { model.selection = index }
                            .contextMenu {
                                Button("貼り付け") { onPaste(item) }
                                Button(item.pinned ? "ピン留めを外す" : "ピン留め") { store.togglePin(item) }
                                Divider()
                                Button("削除", role: .destructive) { store.delete(item) }
                            }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
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
}

// MARK: - カード

struct ClipCard: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    let showShortcut: Bool
    let store: ClipboardStore

    static let width: CGFloat = 236
    static let headerHeight: CGFloat = 58
    static let footerHeight: CGFloat = 28
    static let bodyHeight: CGFloat = 186

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(width: Self.width, height: Self.bodyHeight, alignment: .topLeading)
                .clipped()
            footer
        }
        .frame(width: Self.width)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 4)
                .padding(-4)
                .opacity(selected ? 1 : 0)
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(Date().timeIntervalSince(item.date) < 60
                     ? "たった今" : Self.relative.localizedString(for: item.date, relativeTo: Date()))
                    .font(.system(size: 12))
                    .opacity(0.85)
            }
            .padding(.leading, 12)
            Spacer(minLength: 4)
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12))
                    .padding(.trailing, 6)
            }
            if let icon = AppAppearance.icon(for: item.sourceBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 52, height: 52)
                    .offset(x: 8)
            }
        }
        .foregroundStyle(.white)
        .frame(width: Self.width, height: Self.headerHeight)
        .background(AppAppearance.color(for: item.sourceBundleID))
        .clipped()
        .help(item.sourceAppName ?? "")
    }

    private var title: String {
        if item.kind == .file, let count = item.filePaths?.count, count > 1 {
            return "\(count) 個のファイル"
        }
        return item.kind.label
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            Text(item.text ?? "")
                .font(.system(size: 13))
                .lineSpacing(2)
                .padding(12)
        case .link:
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    Color.primary.opacity(0.05)
                    Image(systemName: "globe")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 96)
                VStack(alignment: .leading, spacing: 3) {
                    Text(URL(string: item.text ?? "")?.host ?? "")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(item.text ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .padding(.horizontal, 12)
            }
        case .image:
            if let image = store.image(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Self.width, height: Self.bodyHeight)
                    .clipped()
            }
        case .file:
            let paths = item.filePaths ?? []
            VStack(spacing: 8) {
                if let first = paths.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: first))
                        .resizable()
                        .frame(width: 88, height: 88)
                    Text((first as NSString).lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .truncationMode(.middle)
                }
                if paths.count > 1 {
                    Text("ほか \(paths.count - 1) 件").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(width: Self.width, height: Self.bodyHeight)
        case .other:
            VStack(spacing: 10) {
                if let icon = AppAppearance.icon(for: item.sourceBundleID) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 88, height: 88)
                } else {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(.secondary)
                }
                Text("\(item.sourceAppName ?? "アプリ") の素材")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(12)
            .frame(width: Self.width, height: Self.bodyHeight)
        }
    }

    private var footer: some View {
        HStack {
            Text(detail)
            Spacer()
            if showShortcut && index < 9 {
                Text("⌘\(index + 1)").fontWeight(.semibold)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(width: Self.width, height: Self.footerHeight)
    }

    private var detail: String {
        switch item.kind {
        case .text: "\(item.text?.count ?? 0) 文字"
        case .link: URL(string: item.text ?? "")?.host ?? ""
        case .image:
            if let size = store.image(for: item)?.pixelSize { "\(Int(size.width)) × \(Int(size.height))" } else { "" }
        case .file: "\(item.filePaths?.count ?? 0) 項目"
        case .other: ByteCountFormatter.string(fromByteCount: Int64(item.rawSize ?? 0), countStyle: .file)
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.unitsStyle = .full
        return f
    }()
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

/// コピー元アプリのアイコンと、アイコンから取った色
@MainActor
enum AppAppearance {
    private static var iconCache: [String: NSImage] = [:]
    private static var colorCache: [String: Color] = [:]
    private static let fallback = Color(white: 0.35)

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = icon
        return icon
    }

    static func color(for bundleID: String?) -> Color {
        guard let bundleID else { return fallback }
        if let cached = colorCache[bundleID] { return cached }
        guard let icon = icon(for: bundleID) else { return fallback }
        let color = Color(nsColor: readableForWhiteText(dominantColor(of: icon)))
        colorCache[bundleID] = color
        return color
    }

    /// アイコンで一番多い色味を拾う（色相を12分割して、彩度の高い色を優先）
    private static func dominantColor(of image: NSImage) -> NSColor {
        let size = 32
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return .gray
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()

        var bins = Array(repeating: (weight: 0.0, r: 0.0, g: 0.0, b: 0.0), count: 12)
        var gray = (weight: 0.0, r: 0.0, g: 0.0, b: 0.0)
        for x in 0..<size {
            for y in 0..<size {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { continue }
                let s = Double(c.saturationComponent), v = Double(c.brightnessComponent)
                if s > 0.25 && v > 0.2 {
                    let i = min(11, Int(c.hueComponent * 12))
                    let w = s * v
                    bins[i].weight += w
                    bins[i].r += Double(c.redComponent) * w
                    bins[i].g += Double(c.greenComponent) * w
                    bins[i].b += Double(c.blueComponent) * w
                } else {
                    gray.weight += 1
                    gray.r += Double(c.redComponent)
                    gray.g += Double(c.greenComponent)
                    gray.b += Double(c.blueComponent)
                }
            }
        }
        let best = bins.max { $0.weight < $1.weight }!
        // 色のついた部分がほとんどないアイコンはグレー系にする
        let chosen = best.weight > gray.weight * 0.08 ? best : gray
        guard chosen.weight > 0 else { return .gray }
        return NSColor(red: chosen.r / chosen.weight, green: chosen.g / chosen.weight,
                       blue: chosen.b / chosen.weight, alpha: 1)
    }

    /// 白文字とのコントラストが 4.5:1 以上になるまで暗くする
    private static func readableForWhiteText(_ color: NSColor) -> NSColor {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        (color.usingColorSpace(.deviceRGB) ?? color).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        var result = NSColor(hue: h, saturation: s, brightness: v, alpha: 1)
        while v > 0.05 && luminance(result) > 0.18 {
            v -= 0.02
            result = NSColor(hue: h, saturation: s, brightness: v, alpha: 1)
        }
        return result
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
