import AppKit
import Combine
import SwiftUI

/// 枠なしでもキー入力を受け取れるパネル
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PanelModel: ObservableObject {
    @Published var query = "" { didSet { resetSelection() } }
    @Published var filter: ClipFilter = .all { didSet { resetSelection() } }
    /// コピー元アプリでの絞り込み（bundle ID）
    @Published var app: String? { didSet { resetSelection() } }
    @Published var date: DateFilter = .all { didSet { resetSelection() } }
    /// 表示中のピンボード（nil ならクリップボードの履歴）
    @Published var board: UUID? { didSet { resetSelection() } }
    /// カーソルのあるカード
    @Published var selection = 0
    /// ⌘・⇧ でまとめて選んだカード（空ならカーソルのカードだけ）
    @Published var marked: Set<UUID> = []
    @Published var previewOpen = false
    @Published var showToken = 0
    @Published var accessibilityGranted = true
    @Published var commandHeld = false
    /// ⇧ で範囲を選ぶときの起点
    var anchor = 0
    /// 並べ替えのために引っぱっているカード
    var dragging: UUID?
    /// 見えているカードの位置（引っぱり始めたカードを探すため）
    var cardFrames: [UUID: CGRect] = [:]

    var isFiltered: Bool { filter != .all || app != nil || date != .all }

    func clearFilters() {
        filter = .all
        app = nil
        date = .all
    }

    func visibleItems(in items: [ClipItem]) -> [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return items.filter {
            $0.pinboardID == board && filter.matches($0) && (app == nil || $0.sourceBundleID == app)
                && date.matches($0.date) && $0.matches(query: q)
        }
    }

    func selectedItems(in items: [ClipItem]) -> [ClipItem] {
        if !marked.isEmpty { return items.filter { marked.contains($0.id) } }
        return items.indices.contains(selection) ? [items[selection]] : []
    }

    func isSelected(_ item: ClipItem, at index: Int) -> Bool {
        marked.isEmpty ? index == selection : marked.contains(item.id)
    }

    /// クリックで選ぶ。⌘ なら1つずつ足し引き、⇧ なら範囲で選ぶ
    func click(_ index: Int, in items: [ClipItem]) {
        guard items.indices.contains(index) else { return }
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) {
            extend(to: index, in: items)
        } else if flags.contains(.command) {
            if marked.isEmpty, items.indices.contains(selection) { marked = [items[selection].id] }
            let id = items[index].id
            if marked.contains(id) { marked.remove(id) } else { marked.insert(id) }
            selection = index
            anchor = index
        } else {
            select(index)
        }
    }

    /// 1つだけ選ぶ
    func select(_ index: Int) {
        selection = index
        anchor = index
        marked = []
    }

    /// 起点から index までをまとめて選ぶ
    func extend(to index: Int, in items: [ClipItem]) {
        guard items.indices.contains(index) else { return }
        if marked.isEmpty { anchor = selection }
        let lower = min(max(anchor, 0), items.count - 1)
        marked = Set(items[min(lower, index)...max(lower, index)].map(\.id))
        selection = index
    }

    private func resetSelection() {
        selection = 0
        anchor = 0
        marked = []
    }
}

/// 画面下に出る履歴パネルの表示・キー操作・貼り付けを担当
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let store: ClipboardStore
    private let model = PanelModel()
    private var panel: KeyPanel!
    private let preview = FloatingPanel()
    private var previewSubscription: AnyCancellable?
    private var keyMonitor: Any?
    /// マウスを押した場所とカード（少し動かしたら引っぱり出しを始める）
    private var dragStart: (event: NSEvent, item: UUID)?
    /// 「…」ボタンで出すメニュー（Paste と同じ構成）
    var actionMenu: NSMenu?
    /// 「編集…」で編集画面を開く
    var onEdit: ((ClipItem) -> Void)?
    /// 前面のアプリに貼り付けたあと（ペーストスタックがクリップボードを戻すため）
    var onPasted: (() -> Void)?

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
                             onAction: { [weak self] in self?.perform($0, on: $1) },
                             onMenu: { [weak self] in self?.showActionMenu() },
                             onNewPinboard: { [weak self] in self?.newPinboard(adding: []) },
                             onRenamePinboard: { [weak self] in self?.renamePinboard($0) },
                             onDeletePinboard: { [weak self] in self?.deletePinboard($0) },
                             onOpenSettings: { Paster.openAccessibilitySettings() })
        panel.contentView = NSHostingView(rootView: view)

        preview.contentView = FirstMouseHostingView(rootView: PreviewView(store: store, model: model))
        previewSubscription = model.$previewOpen.removeDuplicates().sink { [weak self] open in
            MainActor.assumeIsolated {
                if open { self?.showPreview() } else { self?.preview.orderOut(nil) }
            }
        }
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show(board: UUID? = nil) {
        model.query = ""
        model.clearFilters()
        model.board = board
        model.selection = 0
        model.previewOpen = false
        model.dragging = nil
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

    /// 動作確認用: ピンボードを開いて、大きいプレビューも PNG に書き出す
    func snapshotPreview(board index: Int, to path: String) {
        show(board: store.pinboards.indices.contains(index) ? store.pinboards[index].id : nil)
        model.previewOpen = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.snapshot(to: path.replacingOccurrences(of: ".png", with: "-panel.png"))
            guard let view = self.preview.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    func hide() {
        model.previewOpen = false
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

    /// 履歴パネルの上に、選んでいるカードの大きいプレビューを出す
    private func showPreview() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = min(860, visible.width - 80)
        let height = min(560, visible.height - panelHeight - 40)
        guard height > 120 else { return }
        preview.setFrame(NSRect(x: visible.midX - width / 2, y: panel.frame.maxY + 16, width: width, height: height),
                         display: true)
        preview.orderFrontRegardless()
    }

    // MARK: - カードの操作

    /// 右クリックしたカードがまとめて選んだものの1つなら、選んだもの全部
    private func targets(for item: ClipItem) -> [ClipItem] {
        guard model.marked.contains(item.id) else { return [item] }
        return model.selectedItems(in: model.visibleItems(in: store.items))
    }

    private func perform(_ action: CardAction, on item: ClipItem) {
        let list = targets(for: item)
        switch action {
        case .paste: paste(list)
        case .pastePlain: paste(list, plainText: true)
        case .copy: copy(list)
        case .copyPlain: copy(list, plainText: true)
        case .preview:
            if let index = model.visibleItems(in: store.items).firstIndex(where: { $0.id == item.id }) {
                model.select(index)
            }
            model.previewOpen = true
        case .edit: edit(item)
        case .rename: rename(item)
        case .duplicate: list.forEach(store.duplicate)
        case .open: open(item, with: nil)
        case .openWith(let app): open(item, with: app)
        case .reveal:
            hide()
            NSWorkspace.shared.activateFileViewerSelecting(list.flatMap { $0.filePaths ?? [] }.map { URL(fileURLWithPath: $0) })
        case .addTo(let board): list.forEach { store.add($0, to: board) }
        case .newPinboard: newPinboard(adding: list)
        case .delete:
            store.delete(list)
            model.marked = []
            model.selection = min(model.selection, max(model.visibleItems(in: store.items).count - 1, 0))
        }
    }

    /// plainText が nil なら設定（常に書式なし）に従う
    private func paste(_ list: [ClipItem], plainText: Bool? = nil) {
        guard !list.isEmpty else { return }
        store.copyToPasteboard(list, plainText: plainText ?? Preferences.alwaysPlainText)
        hide()
        // 「クリップボードへ」の設定か、許可がなければクリップボードに入れるだけ
        guard Preferences.pasteToActiveApp, Paster.isTrusted else {
            Sound.copied()
            return
        }
        Sound.pasted()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            Paster.sendCommandV()
            self.onPasted?()
        }
    }

    private func copy(_ list: [ClipItem], plainText: Bool? = nil) {
        guard !list.isEmpty else { return }
        store.copyToPasteboard(list, plainText: plainText ?? Preferences.alwaysPlainText)
        Sound.copied()
        hide()
    }

    private func edit(_ item: ClipItem) {
        guard item.text != nil else { return }
        hide()
        onEdit?(item)
    }

    private func rename(_ item: ClipItem) {
        let board = model.board
        if let name = askName(title: "名前を変更", initial: item.title ?? "", button: "変更", allowEmpty: true) {
            store.rename(item, to: name.isEmpty ? nil : name)
        }
        show(board: board)
    }

    private func open(_ item: ClipItem, with app: URL?) {
        guard let url = item.openURL else { return }
        hide()
        if let app {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - ピンボード

    /// 新しいピンボードを作る。items を渡すと、それを入れる
    private func newPinboard(adding items: [ClipItem]) {
        guard let name = askName(title: "新しいピンボード", button: "作成") else { return }
        let board = store.createPinboard(name: name)
        items.forEach { store.add($0, to: board) }
        show(board: board.id)
    }

    private func renamePinboard(_ board: Pinboard) {
        guard let name = askName(title: "ピンボードの名前を変更", initial: board.name, button: "変更") else { return }
        store.renamePinboard(board, to: name)
        show(board: board.id)
    }

    private func deletePinboard(_ board: Pinboard) {
        hide()
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "ピンボード「\(board.name)」を削除しますか？"
        alert.informativeText = "中の項目もすべて削除されます。元に戻せません。"
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")
        if alert.runModal() == .alertFirstButtonReturn {
            store.deletePinboard(board)
        }
        show()
    }

    /// 名前を入れてもらう。キャンセルなら nil（allowEmpty なら空の名前も返す）
    private func askName(title: String, initial: String = "", button: String, allowEmpty: Bool = false) -> String? {
        hide()
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = "名前"
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty && !allowEmpty ? nil : name
    }

    // MARK: - キー操作

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            switch event.type {
            case .leftMouseDown:
                self.dragStart = event.window === self.panel ? self.card(at: event).map { (event, $0) } : nil
                return event
            case .leftMouseDragged:
                guard let start = self.dragStart else { return event }
                let a = start.event.locationInWindow, b = event.locationInWindow
                guard hypot(b.x - a.x, b.y - a.y) > 5 else { return event }
                self.dragStart = nil
                self.beginDrag(from: start.event, itemID: start.item)
                return nil
            case .leftMouseUp:
                self.dragStart = nil
                return event
            case .flagsChanged:
                // ⌘ を押している間だけカードに番号を出す
                self.model.commandHeld = event.modifierFlags.contains(.command)
                return event
            case .scrollWheel:
                return event.window === self.panel ? Self.horizontalScroll(event) : event
            default:
                return self.handle(event) ? nil : event
            }
        }
    }

    // MARK: - 引っぱり出し

    /// マウスの下にあるカード
    private func card(at event: NSEvent) -> UUID? {
        guard let view = panel.contentView else { return nil }
        var point = view.convert(event.locationInWindow, from: nil)
        if !view.isFlipped { point.y = view.bounds.height - point.y }
        return model.cardFrames.first { $0.value.contains(point) }?.key
    }

    /// カードを他のアプリやピンボードの中に引っぱる。コピーしたときと同じ中身を丸ごと渡す
    private func beginDrag(from event: NSEvent, itemID: UUID) {
        guard let view = panel.contentView,
              let item = model.visibleItems(in: store.items).first(where: { $0.id == itemID }) else { return }
        let list = targets(for: item)
        // 文字は書式なしで渡す（option を押しながら引っぱると書式付き）
        let plainText = !NSEvent.modifierFlags.contains(.option)
        var pbItems = list.flatMap { store.pasteboardItems(for: $0, plainText: plainText) }
        // ピンボードの中での並べ替え用の印
        if pbItems.isEmpty { pbItems = [NSPasteboardItem()] }
        pbItems[0].setString(item.id.uuidString, forType: NSPasteboard.PasteboardType(ReorderDrop.type.identifier))

        let image = dragImage(for: item, count: list.count)
        let point = view.convert(event.locationInWindow, from: nil)
        let frame = NSRect(x: point.x - image.size.width / 2, y: point.y - image.size.height / 2,
                           width: image.size.width, height: image.size.height)
        let draggingItems = pbItems.enumerated().map { index, pbItem in
            let draggingItem = NSDraggingItem(pasteboardWriter: pbItem)
            draggingItem.setDraggingFrame(frame, contents: index == 0 ? image : nil)
            return draggingItem
        }
        model.dragging = item.id
        let session = view.beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    /// 引っぱっている間に出す、カードを小さくした絵
    private func dragImage(for item: ClipItem, count: Int) -> NSImage {
        let card = ClipCard(item: item, index: 0, selected: false, showShortcut: false, tagColor: nil, store: store)
            .overlay(alignment: .topTrailing) {
                if count > 1 {
                    Text("\(count)")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 30, minHeight: 30)
                        .background(Color.red, in: Capsule())
                        .offset(x: 8, y: -8)
                }
            }
            .padding(10)
        let renderer = ImageRenderer(content: card)
        renderer.scale = panel.backingScaleFactor
        let image = renderer.nsImage ?? NSWorkspace.shared.icon(for: .data)
        image.size = NSSize(width: image.size.width * 0.6, height: image.size.height * 0.6)
        return image
    }

    /// マウスのホイール（縦回し）でもカードが横に流れるようにする（トラックパッドはそのまま）
    private static func horizontalScroll(_ event: NSEvent) -> NSEvent {
        guard !event.hasPreciseScrollingDeltas, event.scrollingDeltaX == 0, event.scrollingDeltaY != 0,
              let cg = event.cgEvent?.copy() else { return event }
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: cg.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2,
                                value: cg.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2,
                               value: cg.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        return NSEvent(cgEvent: cg) ?? event
    }

    /// 隣のタブ（クリップボード・ピンボード）に移る。端まで行ったら反対側に戻る
    private func switchBoard(by step: Int) {
        let tabs: [UUID?] = [nil] + store.pinboards.map(\.id)
        let current = tabs.firstIndex(of: model.board) ?? 0
        model.board = tabs[(current + step + tabs.count) % tabs.count]
    }

    /// 処理したら true（検索欄には渡さない）
    private func handle(_ event: NSEvent) -> Bool {
        let items = model.visibleItems(in: store.items)
        let selected = model.selectedItems(in: items)
        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        let last = max(items.count - 1, 0)

        switch Int(event.keyCode) {
        case 53: // esc: プレビュー → 検索の文字 → パネルの順に閉じる
            if model.previewOpen {
                model.previewOpen = false
            } else if !model.query.isEmpty {
                model.query = ""
            } else {
                hide()
            }
            return true
        case 49 where !command && model.query.isEmpty: // space でプレビュー
            model.previewOpen.toggle()
            return true
        case 123 where command, 124 where command: // ⌘← ⌘→ でクリップボードとピンボードを切り替え
            switchBoard(by: event.keyCode == 123 ? -1 : 1)
            return true
        case 123: // ←（shift 付きならまとめて選ぶ）
            let index = max(0, model.selection - 1)
            shift ? model.extend(to: index, in: items) : model.select(index)
            return true
        case 124: // →
            let index = min(last, model.selection + 1)
            shift ? model.extend(to: index, in: items) : model.select(index)
            return true
        case 115: // home
            model.select(0)
            return true
        case 119: // end
            model.select(last)
            return true
        case 36, 76: // return / enter（shift 付きなら書式の扱いを逆にする）
            paste(selected, plainText: shift ? !Preferences.alwaysPlainText : nil)
            return true
        case 48: // tab でも切り替え
            switchBoard(by: shift ? -1 : 1)
            return true
        case 51 where command: // ⌘⌫
            if !selected.isEmpty {
                store.delete(selected)
                model.marked = []
                model.selection = min(model.selection, max(items.count - selected.count - 1, 0))
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
        switch chars {
        case "p":
            selected.forEach(store.togglePin)
            model.marked = []
            return true
        case "c":
            // 検索欄の文字を選んでいるときは、その文字をコピーする
            if let editor = panel.firstResponder as? NSTextView, editor.selectedRange().length > 0 { return false }
            copy(selected, plainText: shift ? true : nil)
            return true
        case "e":
            if let first = selected.first { edit(first) }
            return true
        case "d":
            selected.forEach(store.duplicate)
            return true
        case "o":
            if let first = selected.first { open(first, with: nil) }
            return true
        case "y":
            model.previewOpen.toggle()
            return true
        case "a" where model.query.isEmpty: // 検索中は検索欄の文字を全選択
            model.marked = Set(items.map(\.id))
            return true
        default:
            break
        }
        if let number = Int(chars), (1...9).contains(number) {
            if items.indices.contains(number - 1) { paste([items[number - 1]]) }
            return true
        }
        return false
    }
}

extension PanelController: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Copipe の中では並べ替え、他のアプリにはコピーとして渡す
        context == .withinApplication ? .move : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // どこで離しても（取り消しても）印を消す
        model.dragging = nil
    }
}
