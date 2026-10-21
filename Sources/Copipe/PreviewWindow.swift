import AppKit
import Quartz
import SwiftUI

/// クリックしてもキーウインドウにならないパネル（履歴パネルのキー操作や、貼り付け先のアプリの入力を邪魔しない）
final class FloatingPanel: NSPanel {
    /// プレビューの中で編集するときだけ true（文字を打てるようにする）
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    convenience init() {
        self.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
    }
}

/// キーウインドウでなくても、1回のクリックでボタンが押せる
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// space で出す大きいプレビュー（選んでいるカードの中身）。「編集」でその場で書き換えられる
struct PreviewView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var model: PanelModel
    @ObservedObject var links = LinkPreviews.shared
    var onEdit: (ClipItem) -> Void
    var onSave: () -> Void
    var onCancel: () -> Void
    var onCopyText: (ClipItem) -> Void

    private enum Field { case title, body }
    @FocusState private var focus: Field?

    var body: some View {
        let items = model.visibleItems(in: store.items)
        Group {
            if items.indices.contains(model.selection) {
                content(items[model.selection])
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffectBackground()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
        .onChange(of: model.editing) {
            guard model.editing != nil else { return }
            // プレビューがキーウインドウになってから、文字を打つ場所を選ぶ
            let item = items.indices.contains(model.selection) ? items[model.selection] : nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focus = item?.text != nil ? .body : .title }
        }
    }

    private func content(_ item: ClipItem) -> some View {
        let editing = model.editing == item.id
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let icon = AppAppearance.icon(for: item.sourceBundleID) {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                }
                if editing {
                    TextField("名前（\(item.displayTitle)）", text: $model.editTitle)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 14))
                        .frame(maxWidth: 280)
                        .focused($focus, equals: .title)
                } else {
                    Text(item.displayTitle).font(.system(size: 15, weight: .semibold))
                }
                Spacer()
                if editing {
                    if item.kind == .image {
                        Button { model.editRotation -= 1 } label: { Image(systemName: "rotate.left") }
                            .help("左に回転")
                        Button { model.editRotation += 1 } label: { Image(systemName: "rotate.right") }
                            .help("右に回転")
                    }
                    Button("キャンセル", action: onCancel)
                    Button("保存", action: onSave)
                        .buttonStyle(.borderedProminent)
                        .help("⌘S・⌘return でも保存できます")
                } else {
                    Text(ClipCard.detail(of: item, store: store))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    if let text = item.ocrText, !text.isEmpty {
                        Button("文字をコピー") { onCopyText(item) }
                            .help("画像から読み取った文字をコピーします")
                    }
                    Button("編集") { onEdit(item) }
                        .help("⌘E")
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .frame(height: 44)
            Divider()
            Group {
                if editing && item.text != nil {
                    TextEditor(text: $model.editText)
                        .font(.system(size: 15))
                        .scrollContentBackground(.hidden)
                        .focused($focus, equals: .body)
                        .padding(12)
                } else {
                    preview(item)
                        .rotationEffect(.degrees(editing ? Double(model.editRotation) * 90 : 0))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func preview(_ item: ClipItem) -> some View {
        if let rgb = item.colorValue {
            ZStack {
                Color(rgb: rgb)
                Text(rgb.hexColor)
                    .font(.system(size: 32, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppAppearance.textColor(on: NSColor(rgb: rgb)))
            }
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16, style: .continuous))
        } else {
            switch item.kind {
            case .text:
                ScrollView {
                    Text(Self.limited(item.text ?? ""))
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            case .link:
                linkPreview(item.text ?? "")
            case .image:
                if let image = store.image(for: item) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                }
            case .file:
                if let path = item.filePaths?.first {
                    QuickLookView(url: URL(fileURLWithPath: path))
                        .padding(8)
                }
            case .other:
                if let material = item.material, !material.isEmpty {
                    materialPreview(material)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("プレビュー利用不可")
                            .font(.system(size: 15, weight: .semibold))
                        Text("プレビューは表示できませんが、中身は保存してあり、そのまま貼り付けられます。")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                }
            }
        }
    }

    /// Final Cut Pro の素材の中身（クリップ名・テロップ・エフェクト・長さ）
    private func materialPreview(_ material: MaterialInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let duration = material.durationText {
                    Label("長さ \(duration)", systemImage: "clock")
                        .font(.system(size: 14, weight: .medium))
                }
                if !material.names.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("クリップ・テロップ").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(Array(material.names.enumerated()), id: \.offset) { _, name in
                            Label(name, systemImage: "film").font(.system(size: 15)).textSelection(.enabled)
                        }
                    }
                }
                if !material.effects.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("エフェクト・タイトル").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(Array(material.effects.enumerated()), id: \.offset) { _, name in
                            Label(name, systemImage: "sparkles").font(.system(size: 15))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private func linkPreview(_ link: String) -> some View {
        VStack(spacing: 12) {
            if let image = links.image(for: link) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.secondary)
            }
            Text(links.title(for: link) ?? URL(string: link)?.host ?? "")
                .font(.system(size: 17, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(link)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
            if let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) {
                Button("ブラウザで開く") { NSWorkspace.shared.open(url) }
            }
        }
        .padding(24)
        .onAppear { links.request(link) }
    }

    /// とても長い文章は先頭だけ出す（全部描くと固まるため）
    private static func limited(_ text: String) -> String {
        let limit = 100_000
        return text.count > limit ? String(text.prefix(limit)) + "\n\n…（長いので途中まで表示しています）" : text
    }
}

/// ファイルの中身を見せる（Finder のクイックルックと同じもの）
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view: QLPreviewView = QLPreviewView(frame: .zero, style: .normal)
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url {
            view.previewItem = url as NSURL
        }
    }
}
