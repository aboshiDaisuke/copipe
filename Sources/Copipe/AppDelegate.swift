import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let store = ClipboardStore()
    private let windows = WindowPresenter()
    private var panel: PanelController!
    private var stack: PasteStack!
    private var hotKey: HotKey?
    private var stackHotKey: HotKey?
    private var launchedAtLogin = false
    private var statusItem: NSStatusItem!

    private enum Tag {
        static let show = 1
        static let pause = 2
        static let resume = 3
        static let stack = 4
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()
        panel = PanelController(store: store)
        stack = PasteStack(store: store)
        store.onCapture = { [weak self] in self?.stack.collect($0) }
        panel.onPasted = { [weak self] in self?.stack.restoreAfterPaste() }
        panel.onEdit = { [weak self] in self?.edit($0) }
        panel.actionMenu = makeMenu(includeShow: false)
        setupStatusItem()
        registerHotKey(Shortcut.current)
        registerStackHotKey(StackShortcut.current)

        if !Paster.isTrusted { Paster.requestAccess() }
        // ログイン時の自動起動でなければ、起動したことが分かるように履歴を出す
        if !launchedAtLogin {
            showAfterActivation()
        }
        if let i = CommandLine.arguments.firstIndex(of: "--copy-paste-db"), i + 1 < CommandLine.arguments.count {
            PasteImporter.copyDatabase(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
        if let i = CommandLine.arguments.firstIndex(of: "--import-paste"), i + 1 < CommandLine.arguments.count {
            let summary = PasteImporter.summary(of: Result { try PasteImporter.run(into: store) })
            try? summary.write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot-preview"), i + 2 < CommandLine.arguments.count {
            let board = Int(CommandLine.arguments[i + 1]) ?? -1, path = CommandLine.arguments[i + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.panel.snapshotPreview(board: board, to: path) }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot-settings"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.showSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    guard let view = NSApp.windows.first(where: { $0.title == "Copipe の設定" })?.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.panel.snapshot(to: path) }
        }
    }

    /// 起動中にもう一度アプリを開いたら履歴を表示する
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showAfterActivation()
        return false
    }

    /// Finder などから開かれたとき。アプリが前面に来るのを待ってから出さないと、すぐ閉じてしまう
    private func showAfterActivation() {
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.panel.show() }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    // MARK: - ショートカット

    private func registerHotKey(_ shortcut: Shortcut) {
        hotKey = nil // 先に古い登録を外す
        let key = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
            self?.panel.toggle()
        }
        hotKey = key
        Shortcut.current = shortcut

        if !key.isRegistered { warnShortcutTaken(shortcut.title) }
    }

    private func registerStackHotKey(_ shortcut: StackShortcut) {
        stackHotKey = nil
        StackShortcut.current = shortcut
        guard let modifiers = shortcut.modifiers else { return }
        let key = HotKey(keyCode: shortcut.keyCode, modifiers: modifiers, id: 2) { [weak self] in
            self?.stack.toggle()
        }
        stackHotKey = key
        if !key.isRegistered { warnShortcutTaken(shortcut.title) }
    }

    private func warnShortcutTaken(_ title: String) {
        let alert = NSAlert()
        alert.messageText = "\(title) は他のアプリが使っています"
        alert.informativeText = "Paste など、同じキーを使うアプリを終了するか、Copipe の「設定…」から別のキーを選んでください。"
        NSApp.activate()
        alert.runModal()
    }

    // MARK: - メニュー（Paste と同じ構成）

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Copipe")
        statusItem.menu = makeMenu(includeShow: true)
        statusItem.isVisible = Preferences.showMenuBarIcon
    }

    private func makeMenu(includeShow: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        if includeShow {
            let show = item("履歴を表示", #selector(showPanel), symbol: "rectangle.stack")
            show.tag = Tag.show
            menu.addItem(show)
            menu.addItem(.separator())
        }

        menu.addItem(item("Copipe について", #selector(showAbout), symbol: "info.circle"))
        menu.addItem(.separator())
        menu.addItem(item("新しいテキストアイテム", #selector(newTextItem), key: "n", symbol: "square.and.pencil"))
        let stackItem = item("ペーストスタックを開始", #selector(toggleStack), symbol: "square.stack.3d.up")
        stackItem.tag = Tag.stack
        menu.addItem(stackItem)
        menu.addItem(item("設定…", #selector(showSettings), key: ",", symbol: "gearshape"))
        menu.addItem(.separator())

        let help = item("ヘルプ", nil, symbol: "questionmark.circle")
        help.submenu = NSMenu()
        help.submenu?.addItem(item("キーボードショートカット", #selector(showShortcutHelp)))
        menu.addItem(help)

        let pause = item("Copipe を一時停止", nil, symbol: "pause.circle")
        pause.tag = Tag.pause
        let pauseMenu = NSMenu()
        for (title, minutes) in [("5分間", 5), ("15分間", 15), ("1時間", 60), ("8時間", 480)] {
            let entry = item(title, #selector(pauseFor(_:)))
            entry.representedObject = minutes
            pauseMenu.addItem(entry)
        }
        pauseMenu.addItem(item("再開するまで", #selector(pauseFor(_:))))
        pauseMenu.addItem(.separator())
        let resume = item("再開する", #selector(resumeRecording))
        resume.tag = Tag.resume
        pauseMenu.addItem(resume)
        pause.submenu = pauseMenu
        menu.addItem(pause)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Copipe を終了する", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "xmark.square", accessibilityDescription: nil)
        menu.addItem(quit)
        return menu
    }

    private func item(_ title: String, _ action: Selector?, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        if let show = menu.item(withTag: Tag.show) {
            show.title = "履歴を表示（\(Shortcut.current.title)）"
        }
        if let stackItem = menu.item(withTag: Tag.stack) {
            let key = StackShortcut.current == .none ? "" : "（\(StackShortcut.current.title)）"
            stackItem.title = (stack.isActive ? "ペーストスタックを終了" : "ペーストスタックを開始") + key
        }
        if let pause = menu.item(withTag: Tag.pause) {
            if let until = store.pausedUntil, store.isPaused {
                pause.title = until == .distantFuture
                    ? "一時停止中" : "一時停止中（\(until.formatted(date: .omitted, time: .shortened)) まで）"
            } else {
                pause.title = "Copipe を一時停止"
            }
            pause.submenu?.item(withTag: Tag.resume)?.isEnabled = store.isPaused
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.tag == Tag.resume ? store.isPaused : true
    }

    // MARK: - メニューの動作

    @objc private func showPanel() {
        panel.show()
    }

    @objc private func showAbout() {
        panel.hide()
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Paste 風のクリップボード履歴アプリ",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11)]),
        ])
    }

    @objc private func newTextItem() {
        panel.hide()
        windows.present(id: "newText", title: "新しいテキストアイテム", size: CGSize(width: 420, height: 260)) {
            NewTextView(model: NewTextModel(), saveTitle: "履歴に追加", onSave: { [weak self] text in
                self?.store.addManualText(text)
                self?.windows.close(id: "newText")
            }, onCancel: { [weak self] in
                self?.windows.close(id: "newText")
            })
        }
    }

    /// 「編集…」: 文字を書き換える画面
    private func edit(_ item: ClipItem) {
        let id = "edit-\(item.id)"
        windows.present(id: id, title: "テキストを編集", size: CGSize(width: 480, height: 320)) {
            NewTextView(model: NewTextModel(text: item.text ?? ""), saveTitle: "保存", onSave: { [weak self] text in
                self?.store.updateText(of: item, to: text)
                self?.windows.close(id: id)
            }, onCancel: { [weak self] in
                self?.windows.close(id: id)
            })
        }
    }

    @objc private func toggleStack() {
        panel.hide()
        stack.toggle()
    }

    @objc private func showSettings() {
        panel.hide()
        windows.present(id: "settings", title: "Copipe の設定", size: CGSize(width: 480, height: 640)) {
            SettingsView(store: store, model: SettingsModel(),
                         onShortcutChange: { [weak self] in self?.registerHotKey($0) },
                         onStackShortcutChange: { [weak self] in self?.registerStackHotKey($0) },
                         onMenuBarIconChange: { [weak self] in self?.statusItem.isVisible = $0 })
        }
    }

    @objc private func showShortcutHelp() {
        panel.hide()
        let alert = NSAlert()
        alert.messageText = "キーボードショートカット"
        alert.informativeText = HelpText.shortcuts
        NSApp.activate()
        alert.runModal()
    }

    @objc private func pauseFor(_ sender: NSMenuItem) {
        let minutes = sender.representedObject as? Int
        store.pause(for: minutes.map { Double($0) * 60 })
    }

    @objc private func resumeRecording() {
        store.resume()
    }
}
