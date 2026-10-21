import AppKit
import SwiftUI

/// 枠なしでもキー入力を受け取れるパネル
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PanelModel: ObservableObject {
    @Published var query = "" { didSet { selection = 0 } }
    @Published var filter: ClipFilter = .all { didSet { selection = 0 } }
    @Published var selection = 0
    @Published var showToken = 0
    @Published var accessibilityGranted = true
    @Published var commandHeld = false

    func visibleItems(in items: [ClipItem]) -> [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return items.filter { filter.matches($0) && $0.matches(query: q) }
    }
}

/// 画面下に出る履歴パネルの表示・キー操作・貼り付けを担当
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let store: ClipboardStore
    private let model = PanelModel()
    private var panel: KeyPanel!
    private var keyMonitor: Any?
    /// 「…」ボタンで出すメニュー（Paste と同じ構成）
    var actionMenu: NSMenu?

    private let panelHeight: CGFloat = 380

    init(store: ClipboardStore) {
        self.store = store
        super.init()

        panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let view = PanelView(store: store, model: model,
                             onPaste: { [weak self] in self?.paste($0) },
                             onMenu: { [weak self] in self?.showActionMenu() },
                             onOpenSettings: { Paster.openAccessibilitySettings() })
        panel.contentView = NSHostingView(rootView: view)
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        model.query = ""
        model.filter = .all
        model.selection = 0
        model.accessibilityGranted = Paster.isTrusted
        model.commandHeld = false
        model.showToken += 1

        // 画面の下端いっぱいに出す
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let target = NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: panelHeight)

        installKeyMonitor()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(target, display: true)
            panel.alphaValue = 1
            panel.makeKeyAndOrderFront(nil)
            return
        }
        // 下からスッと出す
        panel.setFrame(target.offsetBy(dx: 0, dy: -40), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    /// 動作確認用: パネルの中身を PNG に書き出す
    func snapshot(to path: String) {
        guard let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func hide() {
        panel.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        // Finder から開いて前面になっていた場合は、元のアプリに前面を返す（設定などの画面が開いていれば何もしない）
        let otherWindowOpen = NSApp.windows.contains { $0 !== panel && $0.isVisible && $0.canBecomeMain }
        if NSApp.isActive && !otherWindowOpen { NSApp.hide(nil) }
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func showActionMenu() {
        actionMenu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func paste(_ item: ClipItem, plainText: Bool = false) {
        store.copyToPasteboard(item, plainText: plainText)
        hide()
        guard Paster.isTrusted else { return } // 許可がなければクリップボードに入れるだけ
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            Paster.sendCommandV()
        }
    }

    // MARK: - キー操作

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            if event.type == .flagsChanged {
                // ⌘ を押している間だけカードに番号を出す
                self.model.commandHeld = event.modifierFlags.contains(.command)
                return event
            }
            return self.handle(event) ? nil : event
        }
    }

    /// 処理したら true（検索欄には渡さない）
    private func handle(_ event: NSEvent) -> Bool {
        let items = model.visibleItems(in: store.items)
        let selected = items.indices.contains(model.selection) ? items[model.selection] : nil
        let command = event.modifierFlags.contains(.command)

        switch Int(event.keyCode) {
        case 53: // esc
            if model.query.isEmpty { hide() } else { model.query = "" }
            return true
        case 123: // ←
            model.selection = max(0, model.selection - 1)
            return true
        case 124: // →
            model.selection = min(max(items.count - 1, 0), model.selection + 1)
            return true
        case 36, 76: // return / enter（shift 付きなら書式なしの文字だけ）
            if let selected { paste(selected, plainText: event.modifierFlags.contains(.shift)) }
            return true
        case 48: // tab で絞り込みを切り替え
            let all = ClipFilter.allCases
            let current = all.firstIndex(of: model.filter) ?? 0
            let step = event.modifierFlags.contains(.shift) ? all.count - 1 : 1
            model.filter = all[(current + step) % all.count]
            return true
        case 51 where command: // ⌘⌫
            if let selected {
                store.delete(selected)
                model.selection = min(model.selection, max(items.count - 2, 0))
            }
            return true
        default:
            break
        }

        guard command, let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        // ⌘N・⌘,・⌘Q はメニューの項目を実行する
        if ["n", ",", "q"].contains(chars), actionMenu?.performKeyEquivalent(with: event) == true {
            return true
        }
        if chars == "p" {
            if let selected { store.togglePin(selected) }
            return true
        }
        if let number = Int(chars), (1...9).contains(number) {
            if items.indices.contains(number - 1) { paste(items[number - 1]) }
            return true
        }
        return false
    }
}
