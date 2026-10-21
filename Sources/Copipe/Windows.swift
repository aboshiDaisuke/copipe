import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

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
    @Published var stackShortcut = StackShortcut.current
    @Published var retention = Retention.current
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var showMenuBarIcon = Preferences.showMenuBarIcon { didSet { Preferences.showMenuBarIcon = showMenuBarIcon } }
    @Published var soundEffects = Preferences.soundEffects { didSet { Preferences.soundEffects = soundEffects } }
    @Published var pasteToActiveApp = Preferences.pasteToActiveApp { didSet { Preferences.pasteToActiveApp = pasteToActiveApp } }
    @Published var alwaysPlainText = Preferences.alwaysPlainText { didSet { Preferences.alwaysPlainText = alwaysPlainText } }
    @Published var ignoreConfidential = Preferences.ignoreConfidential {
        didSet { Preferences.ignoreConfidential = ignoreConfidential }
    }
    @Published var ignoreTransient = Preferences.ignoreTransient { didSet { Preferences.ignoreTransient = ignoreTransient } }
    @Published var linkPreviews = Preferences.linkPreviews { didSet { Preferences.linkPreviews = linkPreviews } }
    @Published var ignoredApps = Preferences.ignoredApps { didSet { Preferences.ignoredApps = ignoredApps } }
    @Published var pinboardHotKeys = Preferences.pinboardHotKeys { didSet { Preferences.pinboardHotKeys = pinboardHotKeys } }
    @Published var autoRules = Preferences.autoRules { didSet { Preferences.autoRules = autoRules } }
    @Published var transferMessage: String?
    @Published var accessibilityGranted = Paster.isTrusted
    @Published var confirmClear = false
    @Published var importMessage: String?
}

struct SettingsView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var model: SettingsModel
    var onShortcutChange: (Shortcut) -> Void
    var onStackShortcutChange: (StackShortcut) -> Void
    var onPinboardHotKeysChange: (Bool) -> Void
    var onMenuBarIconChange: (Bool) -> Void

    var body: some View {
        Form {
            Section("一般") {
                Picker("履歴を開くキー", selection: $model.shortcut) {
                    ForEach(Shortcut.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .onChange(of: model.shortcut) { onShortcutChange(model.shortcut) }

                Picker("ペーストスタックのキー", selection: $model.stackShortcut) {
                    ForEach(StackShortcut.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .onChange(of: model.stackShortcut) { onStackShortcutChange(model.stackShortcut) }

                Toggle(isOn: $model.pinboardHotKeys) {
                    Text("⌃⌘1〜9 でピンボードを直接開く")
                    Text("左から数えて 1 番目のピンボードが ⌃⌘1 です。")
                }
                .onChange(of: model.pinboardHotKeys) { onPinboardHotKeysChange(model.pinboardHotKeys) }

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

                Toggle(isOn: $model.showMenuBarIcon) {
                    Text("メニューバーに表示する")
                    Text("消しても、履歴の右上の「…」から同じメニューを出せます。")
                }
                .onChange(of: model.showMenuBarIcon) { onMenuBarIconChange(model.showMenuBarIcon) }

                Toggle("効果音（コピー・貼り付けのときに音を鳴らす）", isOn: $model.soundEffects)
            }

            Section("貼り付け") {
                Picker("アイテムを貼り付ける", selection: $model.pasteToActiveApp) {
                    Text("アクティブなアプリへ（そのまま貼り付ける）").tag(true)
                    Text("クリップボードへ（あとで自分で ⌘V する）").tag(false)
                }
                .pickerStyle(.radioGroup)

                Toggle(isOn: $model.alwaysPlainText) {
                    Text("常に書式なしで貼り付ける")
                    Text("オンのときは、shift + return で書式付きで貼り付けます。")
                }

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

            Section("履歴") {
                Picker("保存期間", selection: $model.retention) {
                    ForEach(Retention.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: model.retention) { store.setRetention(model.retention) }

                HStack {
                    Text("クリップボードの履歴 \(store.items.filter { $0.pinboardID == nil }.count) 件（最大 \(store.maxItems) 件）")
                    Spacer()
                    Button("履歴を消去…") { model.confirmClear = true }
                }
            }

            Section("プライバシー") {
                Toggle(isOn: $model.ignoreConfidential) {
                    Text("機密情報を無視する")
                    Text("パスワード管理アプリなどが「機密」と指定したコピーは保存しません。")
                }
                Toggle(isOn: $model.ignoreTransient) {
                    Text("一時的なコンテンツを無視する")
                    Text("他のアプリが一時的に作ったデータは保存しません。")
                }
                Toggle(isOn: $model.linkPreviews) {
                    Text("リンクプレビューを生成する")
                    Text("リンク先のページの題名と画像を取ってきます。1回しか使えないリンクなどに影響することがあります。")
                }
            }

            Section {
                ForEach(model.ignoredApps, id: \.self) { id in
                    HStack {
                        if let icon = AppAppearance.icon(for: id) {
                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                        }
                        Text(Self.appName(id))
                        Spacer()
                        Button("外す") { model.ignoredApps.removeAll { $0 == id } }
                            .controlSize(.small)
                    }
                }
                if model.ignoredApps.isEmpty {
                    Text("なし").foregroundStyle(.secondary)
                }
                Button("アプリを追加…", action: addIgnoredApps)
            } header: {
                Text("次のアプリでコピーしたものは保存しない")
            }

            Section {
                ForEach($model.autoRules) { $rule in
                    HStack(spacing: 6) {
                        Picker("", selection: $rule.app) {
                            Text("どのアプリでも").tag(String?.none)
                            ForEach(appChoices(including: rule.app), id: \.id) { Text($0.name).tag(String?.some($0.id)) }
                        }
                        Picker("", selection: $rule.kind) {
                            Text("どの種類でも").tag(String?.none)
                            ForEach(ClipFilter.allCases.filter { $0 != .all }) { Text($0.rawValue).tag(String?.some($0.rawValue)) }
                        }
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Picker("", selection: $rule.board) {
                            Text("ピンボードを選ぶ").tag(UUID?.none)
                            ForEach(store.pinboards) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                        Button {
                            model.autoRules.removeAll { $0.id == rule.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("この決まりを消す")
                    }
                    .labelsHidden()
                }
                Button("決まりを追加") {
                    model.autoRules.append(AutoRule(board: store.pinboards.first?.id))
                }
                .disabled(store.pinboards.isEmpty)
            } header: {
                Text("自動でピンボードに入れる")
            } footer: {
                Text("「このアプリで」「この種類を」コピーしたら、履歴に加えて、選んだピンボードにも入れます。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Section("書き出し・読み込み") {
                HStack {
                    Text("履歴とピンボードを1つのファイルにします。バックアップや、別の Mac への引っ越しに。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("書き出す…") {
                        do {
                            if let url = try DataTransfer.export(store) {
                                model.transferMessage = "書き出しました: \(url.lastPathComponent)"
                            }
                        } catch {
                            model.transferMessage = error.localizedDescription
                        }
                    }
                    Button("読み込む…") {
                        do {
                            if let count = try DataTransfer.import(into: store) {
                                model.transferMessage = "\(count) 件を読み込みました（同じものは飛ばしました）。"
                            }
                        } catch {
                            model.transferMessage = error.localizedDescription
                        }
                    }
                }
                if let message = model.transferMessage {
                    Text(message).font(.system(size: 12))
                }
            }

            Section("Paste から引っ越す") {
                HStack {
                    Text("Paste の履歴とピンボードを読み込みます。Paste のデータは変更しません。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("読み込む…") {
                        model.importMessage = PasteImporter.summary(of: Result { try PasteImporter.run(into: store) })
                    }
                }
                if let message = model.importMessage {
                    Text(message).font(.system(size: 12))
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.accessibilityGranted = Paster.isTrusted
        }
        .confirmationDialog("履歴を消去しますか？", isPresented: $model.confirmClear) {
            Button("消去", role: .destructive) { store.clearHistory() }
        } message: {
            Text("ピンボードの項目は残ります。元に戻せません。")
        }
    }

    private func addIgnoredApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "追加"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !model.ignoredApps.contains(id) {
                model.ignoredApps.append(id)
            }
        }
    }

    /// 決まりで選べるアプリ（履歴にあるアプリ。今選んでいるものは必ず入れる）
    private func appChoices(including current: String?) -> [(id: String, name: String)] {
        var names: [String: String] = [:]
        for item in store.items {
            if let id = item.sourceBundleID, names[id] == nil { names[id] = item.sourceAppName ?? Self.appName(id) }
        }
        if let current, names[current] == nil { names[current] = Self.appName(current) }
        return names.map { ($0.key, $0.value) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
    }
}

// MARK: - 新しいテキストアイテム・テキストの編集

@MainActor
final class NewTextModel: ObservableObject {
    @Published var text: String

    init(text: String = "") {
        self.text = text
    }
}

struct NewTextView: View {
    @ObservedObject var model: NewTextModel
    var saveTitle: String
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
            Text("{今日} {時刻} などと書いておくと、貼り付けるときにその日の日付・時刻に変わります。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("キャンセル", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(saveTitle) { onSave(model.text) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = true }
    }
}

// MARK: - ヘルプ

enum HelpText {
    static var shortcuts: String {
        """
        履歴を開く / 閉じる　\(Shortcut.current.title)
        カードを選ぶ　← →（shift を押しながらでまとめて選ぶ）
        まとめて選ぶ　command・shift を押しながらクリック / command + A
        貼り付け　return（ダブルクリック）
        書式なしで貼り付け　shift + return
        整えて貼り付け（改行を消す・半角にするなど）　option + return
        すぐ貼り付け　command + 1〜9
        コピーだけする　command + C
        プレビュー　space
        編集（名前・文字・画像の向き）　command + E　保存は command + S、取り消しは esc
        複製　command + D
        開く　command + O
        探す　そのまま文字を打つ
        クリップボード・ピンボードの切り替え　command + ← →（tab でも可）
        ピンボードに追加 / 外す　command + P
        削除　command + delete
        閉じる　esc
        ペーストスタック　\(StackShortcut.current.title)（始めてからコピーしたものを、⌘V のたびに順に貼り付け）
        ピンボードを直接開く　control + command + 1〜9

        検索は、ひらがな・カタカナ、全角・半角、大文字・小文字を区別しません。
        画像の中の文字や、Final Cut Pro の素材のクリップ名・テロップ・エフェクト名でも探せます。

        文字の中に次のように書いておくと、貼り付けるときに置き換わります。
        \(TextTemplate.examples)

        カードは引っぱって他のアプリに入れられます（文字は書式なし。option を押しながらだと書式付き）。
        ピンボードの中では引っぱって並べ替えられます。
        """
    }
}
