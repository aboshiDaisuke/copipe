import AppKit
import Quartz
import SwiftUI

/// クリックしてもキーウインドウにならないパネル（履歴パネルのキー操作や、貼り付け先のアプリの入力を邪魔しない）
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
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

/// space で出す大きいプレビュー（選んでいるカードの中身）
struct PreviewView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var model: PanelModel
    @ObservedObject var links = LinkPreviews.shared

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
    }

    private func content(_ item: ClipItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let icon = AppAppearance.icon(for: item.sourceBundleID) {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                }
                Text(item.displayTitle).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(ClipCard.detail(of: item, store: store))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            Divider()
            preview(item)
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
