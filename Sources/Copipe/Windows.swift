import AppKit
import ServiceManagement
import SwiftUI

/// 設定・新しいテキストアイテムなどの普通のウィンドウを開く
@MainActor
final class WindowPresenter {
    private var windows: [String: NSWindow] = [:]

    func present<Content: View>(id: String, title: String, size: CGSize, @ViewBuilder content: () -> Content) {
        NSApp.activate()
        if let window = windows[id] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content())
        window.center()
        window.makeKeyAndOrderFront(nil)
        windows[id] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windows[id] = nil }
        }
    }

    func close(id: String) {
        windows[id]?.close()
    }
}

// MARK: - 設定

/// 設定画面の状態（この環境では @State マクロが使えないため ObservableObject で持つ）
@MainActor
final class SettingsModel: ObservableObject {
    @Published var shortcut = Shortcut.current
    @Published var retention = Retention.current
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var accessibilityGranted = Paster.isTrusted
    @Published var confirmClear = false
}

struct SettingsView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var model: SettingsModel
    var onShortcutChange: (Shortcut) -> Void

    var body: some View {
        Form {
            Section("一般") {
                Picker("履歴を開くキー", selection: $model.shortcut) {
                    ForEach(Shortcut.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .onChange(of: model.shortcut) { onShortcutChange(model.shortcut) }

                Toggle("ログイン時に起動", isOn: $model.launchAtLogin)
                    .onChange(of: model.launchAtLogin) {
                        do {
                            if model.launchAtLogin {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            model.launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("履歴") {
                Picker("保存期間", selection: $model.retention) {
                    ForEach(Retention.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: model.retention) { store.setRetention(model.retention) }

                HStack {
                    Text("ピン留め以外の履歴 \(store.items.filter { !$0.pinned }.count) 件")
                    Spacer()
                    Button("履歴を消去…") { model.confirmClear = true }
                }
            }

            Section("貼り付け") {
                HStack {
                    Text("アクセシビリティ")
                    Spacer()
                    if model.accessibilityGranted {
                        Label("許可済み", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("許可する…") { Paster.openAccessibilitySettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.accessibilityGranted = Paster.isTrusted
        }
        .confirmationDialog("履歴を消去しますか？", isPresented: $model.confirmClear) {
            Button("消去", role: .destructive) { store.clearUnpinned() }
        } message: {
            Text("ピン留めした項目は残ります。元に戻せません。")
        }
    }
}

// MARK: - 新しいテキストアイテム

@MainActor
final class NewTextModel: ObservableObject {
    @Published var text = ""
}

struct NewTextView: View {
    @ObservedObject var model: NewTextModel
    var onSave: (String) -> Void
    var onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            TextEditor(text: $model.text)
                .font(.system(size: 14))
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
            HStack {
                Button("キャンセル", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("履歴に追加") { onSave(model.text) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420, height: 260)
        .onAppear { focused = true }
    }
}

// MARK: - ヘルプ

enum HelpText {
    static let shortcuts = """
    履歴を開く / 閉じる　\(Shortcut.current.title)
    カードを選ぶ　← →
    貼り付け　return（ダブルクリック）
    書式なしで貼り付け　shift + return
    すぐ貼り付け　command + 1〜9
    探す　そのまま文字を打つ
    種類の絞り込み　tab
    ピン留め　command + P
    削除　command + delete
    閉じる　esc
    """
}
