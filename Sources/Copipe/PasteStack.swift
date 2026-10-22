import AppKit
import Carbon.HIToolbox
import SwiftUI

/// ペーストスタック（Paste の Paste Stack と同じ）
/// 始めてからコピーしたものをためておき、⌘V を押すたびにコピーした順に1つずつ貼り付ける
@MainActor
final class PasteStack: ObservableObject {
    /// ためたものの ID。中身はいつも履歴にある最新のものを使う（同じものをコピーし直すと保存ファイルが入れ替わるため）
    @Published private(set) var ids: [UUID] = []
    @Published private(set) var isActive = false
    /// ⌘V のあと、次のものに入れ替えるまでの間
    private var advancing = false

    private let store: ClipboardStore
    private let window = FloatingPanel()
    private var pasteMonitor: Any?

    init(store: ClipboardStore) {
        self.store = store
        window.contentView = FirstMouseHostingView(rootView: PasteStackView(stack: self, store: store))
    }

    func toggle() {
        isActive ? stop() : start()
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        ids = []
        // マウスのある画面の右端に出す
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            let size = PasteStackView.size
            window.setFrame(NSRect(x: visible.maxX - size.width - 16, y: visible.midY - size.height / 2,
                                   width: size.width, height: size.height), display: true)
        }
        window.orderFrontRegardless()
        // 他のアプリで押した ⌘V を見る（アクセシビリティの許可が必要）
        pasteMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    func stop() {
        isActive = false
        ids = []
        advancing = false
        window.orderOut(nil)
        if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
        pasteMonitor = nil
    }

    /// コピーされたものをためる。クリップボードには、次に貼り付けるものを入れておく
    func collect(_ item: ClipItem) {
        guard isActive else { return }
        ids.append(item.id)
        putNextOnClipboard()
    }

    func item(at index: Int) -> ClipItem? {
        guard ids.indices.contains(index) else { return nil }
        return store.items.first { $0.id == ids[index] }
    }

    func remove(at index: Int) {
        guard ids.indices.contains(index) else { return }
        ids.remove(at: index)
        putNextOnClipboard()
    }

    /// 履歴パネルから貼り付けたあと、クリップボードを次に貼り付けるものに戻す
    func restoreAfterPaste() {
        guard isActive, !ids.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.putNextOnClipboard() }
    }

    private func putNextOnClipboard() {
        // 履歴から消されたものは飛ばす
        ids.removeAll { id in !store.items.contains { $0.id == id } }
        guard let next = item(at: 0) else { return }
        store.copyToPasteboard(next, plainText: Preferences.alwaysPlainText, moveToTop: false)
    }

    private func handle(_ event: NSEvent) {
        // Caps Lock などは見ずに、⌘ だけが押されているかを見る
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command, Int(event.keyCode) == kVK_ANSI_V, !event.isARepeat, !ids.isEmpty,
              !Paster.isSynthetic(event) else { return }
        // 入れ替える前に続けて押された ⌘V は同じものが貼られるので、1回分として数える
        guard !advancing else { return }
        advancing = true
        // 貼り付け先のアプリがクリップボードを読み終わるのを待ってから、次のものに入れ替える
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.advancing = false
            guard !self.ids.isEmpty else { return }
            self.ids.removeFirst()
            if self.ids.isEmpty {
                self.stop() // 全部貼り終わったら閉じる
            } else {
                self.putNextOnClipboard()
            }
        }
    }
}

struct PasteStackView: View {
    @ObservedObject var stack: PasteStack
    let store: ClipboardStore

    static let size = CGSize(width: 300, height: 440)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(Color.accentColor)
                Text("ペーストスタック").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: stack.stop) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("ペーストスタックを終了")
            }
            if !Paster.isTrusted {
                Text("⌘V で次に進むには「アクセシビリティ」の許可が必要です。")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
            if stack.ids.isEmpty {
                Text("コピーすると、ここにたまります。\n⌘V を押すたびに、コピーした順に貼り付けます。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(stack.ids.indices, id: \.self) { index in
                            if let item = stack.item(at: index) {
                                StackRow(item: item, index: index, store: store) {
                                    stack.remove(at: index)
                                }
                            }
                        }
                    }
                }
                Text("\(stack.ids.count) 件 ・ 次に貼り付けるのは 1 番")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(
            VisualEffectBackground()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
    }
}

private struct StackRow: View {
    let item: ClipItem
    let index: Int
    let store: ClipboardStore
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(index == 0 ? Color.white : Color.primary)
                .frame(width: 22, height: 22)
                .background(index == 0 ? Color.accentColor : Color.primary.opacity(0.1), in: Circle())
            if let image = thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(summary).font(.system(size: 13)).lineLimit(2)
                Text(item.displayTitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("スタックから外す")
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var thumbnail: NSImage? {
        switch item.kind {
        case .image: store.image(for: item)
        case .file: item.filePaths?.first.map { NSWorkspace.shared.icon(forFile: $0) }
        default: nil
        }
    }

    private var summary: String {
        switch item.kind {
        case .text, .link:
            (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
                .replacingOccurrences(of: "\n", with: " ")
        case .image: ClipCard.detail(of: item, store: store)
        case .file: (item.filePaths ?? []).map { ($0 as NSString).lastPathComponent }.joined(separator: "、")
        case .other: "\(item.sourceAppName ?? "アプリ") の素材"
        }
    }
}
