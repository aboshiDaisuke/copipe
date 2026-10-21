import AppKit
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = ClipboardStore()
    private var panel: PanelController!
    private var hotKey: HotKey?
    private var launchedAtLogin = false
    private var statusItem: NSStatusItem!

    private var showItem: NSMenuItem!
    private var pauseItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var shortcutItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()
        panel = PanelController(store: store)
        setupStatusItem()
        registerHotKey(Shortcut.current)

        if !Paster.isTrusted { Paster.requestAccess() }
        // ログイン時の自動起動でなければ、起動したことが分かるように履歴を出す
        if !launchedAtLogin {
            showAfterActivation()
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
        showItem.title = "履歴を表示（\(shortcut.title)）"

        if !key.isRegistered {
            let alert = NSAlert()
            alert.messageText = "\(shortcut.title) は他のアプリが使っています"
            alert.informativeText = "Paste など、同じキーを使うアプリを終了するか、メニューバーの Copipe アイコン →「ショートカット」から別のキーを選んでください。"
            NSApp.activate()
            alert.runModal()
        }
    }

    @objc private func selectShortcut(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let shortcut = Shortcut(rawValue: raw) else { return }
        registerHotKey(shortcut)
    }

    // MARK: - メニューバー

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Copipe")

        let menu = NSMenu()
        menu.delegate = self

        showItem = NSMenuItem(title: "履歴を表示", action: #selector(showPanel), keyEquivalent: "")
        menu.addItem(showItem)

        pauseItem = NSMenuItem(title: "記録を一時停止", action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(pauseItem)
        menu.addItem(.separator())

        let shortcutMenu = NSMenu()
        for shortcut in Shortcut.allCases {
            let item = NSMenuItem(title: shortcut.title, action: #selector(selectShortcut(_:)), keyEquivalent: "")
            item.representedObject = shortcut.rawValue
            item.target = self
            shortcutMenu.addItem(item)
        }
        shortcutItem = NSMenuItem(title: "ショートカット", action: nil, keyEquivalent: "")
        shortcutItem.submenu = shortcutMenu
        menu.addItem(shortcutItem)

        loginItem = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "アクセシビリティ設定を開く…", action: #selector(openAccessibility), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "履歴を消去（ピン留め以外）…", action: #selector(clearHistory), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Copipe を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        pauseItem.state = store.isPaused ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        for item in shortcutItem.submenu?.items ?? [] {
            item.state = item.representedObject as? String == Shortcut.current.rawValue ? .on : .off
        }
    }

    @objc private func showPanel() {
        panel.show()
    }

    @objc private func togglePause() {
        store.isPaused.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc private func openAccessibility() {
        Paster.openAccessibilitySettings()
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "履歴を消去しますか？"
        alert.informativeText = "ピン留めした項目は残ります。元に戻せません。"
        alert.addButton(withTitle: "消去")
        alert.addButton(withTitle: "キャンセル")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            store.clearUnpinned()
        }
    }
}
