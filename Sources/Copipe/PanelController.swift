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
    /// プレビューの中で編集しているカード
    @Published var editing: UUID?
    /// 編集を始めたときの文字（書式付き。書式のない文字は黒い字にしたもの）
    @Published var editInitialText = NSAttributedString()
    /// 編集中の文字欄（保存のときに中身を読む）
    weak var editTextView: NSTextView?
    /// 文字か書式を書き換えたか
    var editTextChanged = false
    /// 元の文字に書式があったか（あれば書式付きのまま保存する）
    var editWasRich = false
    @Published var editTitle = ""
    /// 編集中に回した回数（右回りが正。保存するときに画像に反映する）
    @Published var editRotation = 0
    /// 背景を消した画像（「背景を復元」で nil に戻す。保存するときに置き換える）
    @Published var editCutout: CGImage?
    @Published var removingBackground = false
    /// 編集中に出すお知らせ（背景を消せなかったときなど）
    @Published var editNotice: String?
    @Published var showToken = 0
    @Published var accessibilityGranted = true
    @Published var commandHeld = false
    /// ⇧ で範囲を選ぶときの起点
    var anchor = 0
    /// 並べ替えのために引っぱっているカード
    var dragging: UUID?
    /// カードを引っぱって上に乗せているピンボードのタブ（光らせる）
    @Published var dropBoard: UUID?
    /// 見えているカードの位置（引っぱり始めたカードを探すため）
    var cardFrames: [UUID: CGRect] = [:]
    /// ピンボードのタブの位置（引っぱって並べ替えるため）
    var tabFrames: [UUID: CGRect] = [:]

    var isFiltered: Bool { filter != .all || app != nil || date != .all }

    func clearFilters() {
        filter = .all
        app = nil
        date = .all
    }

    func visibleItems(in items: [ClipItem]) -> [ClipItem] {
        let variants = SearchText.variants(of: query)
        return items.filter {
            $0.pinboardID == board && filter.matches($0) && (app == nil || $0.sourceBundleID == app)
                && date.matches($0.date) && $0.matches(variants)
        }
    }

    /// 編集中の文字の、選んでいるところの書式を付け外しする
    func toggle(_ style: TextStyle) {
        if let editTextView { RichText.toggle(style, in: editTextView) }
    }

    /// Apple Intelligence の執筆ツール（書き直し・校正・要約など）を出す
    func showWritingTools() {
        guard #available(macOS 15.2, *), let editTextView else { return }
        editTextView.window?.makeFirstResponder(editTextView)
        editTextView.showWritingTools(nil)
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
    /// 編集を始めたときのカード（保存するときに使う）
    private var editingItem: ClipItem?
    private var previewSubscription: AnyCancellable?
    private var keyMonitor: Any?
    /// マウスを押した場所とカード（少し動かしたら引っぱり出しを始める）
    private var dragStart: (event: NSEvent, item: UUID)?
    /// 引っぱっているピンボードのタブ
    private var draggingTab: UUID?
    /// 引っぱり出しているカード（他のアプリに入れたら、使ったものとして数える）
    private var draggedItems: [ClipItem] = []
    /// 「…」ボタンで出すメニュー（Paste と同じ構成）
    var actionMenu: NSMenu?
    /// 前面のアプリに貼り付けたあと（ペーストスタックがクリップボードを戻すため）
    var onPasted: (() -> Void)?

    private let panelHeight: CGFloat = 352

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

        preview.delegate = self
        preview.contentView = FirstMouseHostingView(rootView: PreviewView(
            store: store, model: model,
            onEdit: { [weak self] in self?.startEdit($0) },
            onSave: { [weak self] in self?.finishEdit(save: true) },
            onCancel: { [weak self] in self?.finishEdit(save: false) },
            onCopyText: { [weak self] in self?.copyText($0) },
            onRemoveBackground: { [weak self] in self?.removeBackground(of: $0) }))
        previewSubscription = model.$previewOpen.removeDuplicates().sink { [weak self] open in
            MainActor.assumeIsolated {
                if open { self?.showPreview() } else { self?.preview.orderOut(nil) }
            }
        }
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    /// ⌃⌘1〜9: そのピンボードを開く（開いていれば閉じる）
    func toggle(board: UUID) {
        panel.isVisible && model.board == board ? hide() : show(board: board)
    }

    func show(board: UUID? = nil) {
        model.query = ""
        model.clearFilters()
        model.board = board
        model.selection = 0
        model.previewOpen = false
        endEditing()
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
    func snapshotPreview(board index: Int, editing: Bool = false, to path: String) {
        show(board: store.pinboards.indices.contains(index) ? store.pinboards[index].id : nil)
        model.previewOpen = true
        if editing, let first = model.visibleItems(in: store.items).first { startEdit(first) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.snapshot(to: path.replacingOccurrences(of: ".png", with: "-panel.png"))
            guard let view = self.preview.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    func hide() {
        endEditing()
        model.previewOpen = false
        panel.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        // Finder から開いて前面になっていた場合は、元のアプリに前面を返す（設定などの画面が開いていれば何もしない）
        let otherWindowOpen = NSApp.windows.contains { $0 !== panel && $0.isVisible && $0.canBecomeMain }
        if NSApp.isActive && !otherWindowOpen { NSApp.hide(nil) }
    }

    func windowDidResignKey(_ notification: Notification) {
        // パネルにもプレビューにも戻っていなければ（他のアプリを押したら）閉じる
        // 編集を始めてプレビューがキーになったときは、ここでプレビューがキーなので閉じない
        // 編集中に Copipe の別の小窓（執筆ツールなど）がキーになったときも閉じない
        DispatchQueue.main.async {
            guard !self.panel.isKeyWindow && !self.preview.isKeyWindow else { return }
            if self.model.editing != nil && NSApp.keyWindow != nil { return }
            self.hide()
        }
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
        case .edit, .rename: startEdit(item)
        case .pasteTransformed(let transform): paste(list, transform: transform)
        case .copyText: copyText(item)
        case .duplicate: list.forEach(store.duplicate)
        case .open: open(item, with: nil)
        case .openWith(let app): open(item, with: app)
        case .reveal:
            hide()
            NSWorkspace.shared.activateFileViewerSelecting(list.flatMap { $0.filePaths ?? [] }.map { URL(fileURLWithPath: $0) })
        case .addTo(let board):
            list.forEach { store.add($0, to: board) }
            Sound.copied()
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
        store.recordUse(list)
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
        store.recordUse(list)
        Sound.copied()
        hide()
    }

    /// 「整えて貼り付け」: 文字を整えて、書式なしで貼り付ける
    private func paste(_ list: [ClipItem], transform: TextTransform) {
        let texts = list.compactMap(\.expandedText)
        guard !texts.isEmpty else { return }
        store.copyString(transform.apply(texts.joined(separator: "\n")))
        store.recordUse(list)
        hide()
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

    /// option + return: 選んでいるカードの上に「整えて貼り付け」のメニューを出す
    private func showTransformMenu(for list: [ClipItem]) {
        guard list.contains(where: { $0.text != nil }), let view = panel.contentView else { return }
        let menu = NSMenu()
        for transform in TextTransform.allCases {
            let entry = NSMenuItem(title: transform.pasteTitle, action: #selector(pasteTransformedFromMenu(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.representedObject = transform.rawValue
            menu.addItem(entry)
        }
        let frame = list.first.flatMap { model.cardFrames[$0.id] } ?? CGRect(x: 40, y: 80, width: 0, height: 0)
        var point = CGPoint(x: frame.minX + 14, y: frame.minY + 48)
        if !view.isFlipped { point.y = view.bounds.height - point.y }
        menu.popUp(positioning: nil, at: point, in: view)
    }

    @objc private func pasteTransformedFromMenu(_ sender: NSMenuItem) {
        guard let transform = (sender.representedObject as? String).flatMap(TextTransform.init(rawValue:)) else { return }
        paste(model.selectedItems(in: model.visibleItems(in: store.items)), transform: transform)
    }

    /// 画像から読み取った文字をコピーする
    private func copyText(_ item: ClipItem) {
        guard let text = item.ocrText, !text.isEmpty else { return }
        store.copyString(text)
        Sound.copied()
        hide()
    }

    // MARK: - プレビューの中での編集

    /// 名前と中身（文字のカード）をプレビューの中で書き換える。文字は書式も変えられ、画像は回したり背景を消したりできる
    private func startEdit(_ item: ClipItem) {
        if let index = model.visibleItems(in: store.items).firstIndex(where: { $0.id == item.id }) {
            model.select(index)
        }
        editingItem = item
        let rich = store.attributedText(for: item)
        model.editWasRich = rich != nil
        model.editInitialText = rich ?? RichText.plain(item.text ?? "")
        model.editTextChanged = false
        model.editTitle = item.title ?? ""
        model.editRotation = 0
        model.editCutout = nil
        model.removingBackground = false
        model.editNotice = nil
        model.editing = item.id
        model.previewOpen = true
        // 文字を打てるように、プレビューをキーウインドウにする
        preview.allowsKey = true
        preview.makeKeyAndOrderFront(nil)
    }

    private func finishEdit(save: Bool) {
        guard let item = editingItem else { return }
        if save {
            let title = model.editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if title != (item.title ?? "") { store.rename(item, to: title.isEmpty ? nil : title) }
            if item.text != nil, model.editTextChanged, let view = model.editTextView {
                let edited = NSAttributedString(attributedString: view.attributedString())
                // 元が書式なしで、書式も付けていなければ、書式なしの文字のまま保存する
                if model.editWasRich || RichText.hasFormatting(edited) {
                    store.updateRichText(of: item, to: edited)
                } else if edited.string != item.text {
                    store.updateText(of: item, to: edited.string)
                }
            }
            if model.editRotation != 0 || model.editCutout != nil {
                store.updateImage(of: item, replacement: model.editCutout, quarterTurns: model.editRotation)
            }
        }
        endEditing()
        panel.makeKeyAndOrderFront(nil)
    }

    private func endEditing() {
        editingItem = nil
        model.editing = nil
        model.editTextView = nil
        model.editCutout = nil
        model.removingBackground = false
        preview.allowsKey = false
    }

    /// 編集中の画像の背景を消す（Mac の中だけで切り抜く。1秒ほどかかる）
    private func removeBackground(of item: ClipItem) {
        guard let image = store.image(for: item)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        model.removingBackground = true
        model.editNotice = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try BackgroundRemover.cutout(image) }
            DispatchQueue.main.async {
                // 待っている間に編集を終えていたら捨てる
                guard self.model.editing == item.id else { return }
                self.model.removingBackground = false
                switch result {
                case .success(let cutout): self.model.editCutout = cutout
                case .failure(let error): self.model.editNotice = error.localizedDescription
                }
            }
        }
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

    /// 名前を入れてもらう。キャンセルか空なら nil
    private func askName(title: String, initial: String = "", button: String) -> String? {
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
        return name.isEmpty ? nil : name
    }

    // MARK: - キー操作

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, self.model.editing != nil, self.preview.isKeyWindow {
                return self.handleEditing(event) ? nil : event
            }
            guard self.panel.isKeyWindow else { return event }
            switch event.type {
            case .leftMouseDown:
                self.dragStart = event.window === self.panel ? self.card(at: event).map { (event, $0) } : nil
                self.draggingTab = event.window === self.panel ? self.tab(at: event) : nil
                return event
            case .leftMouseDragged where self.draggingTab != nil:
                self.moveTab(to: event)
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
                self.draggingTab = nil
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

    /// パネルの左上からの座標
    private func point(of event: NSEvent) -> CGPoint? {
        guard let view = panel.contentView else { return nil }
        var point = view.convert(event.locationInWindow, from: nil)
        if !view.isFlipped { point.y = view.bounds.height - point.y }
        return point
    }

    /// マウスの下にあるカード
    private func card(at event: NSEvent) -> UUID? {
        guard let point = point(of: event) else { return nil }
        return model.cardFrames.first { $0.value.contains(point) }?.key
    }

    /// マウスの下にあるピンボードのタブ
    private func tab(at event: NSEvent) -> UUID? {
        guard let point = point(of: event) else { return nil }
        return model.tabFrames.first { $0.value.contains(point) }?.key
    }

    /// 引っぱっているタブが隣のタブの真ん中を越えたら、そこへ動かす
    private func moveTab(to event: NSEvent) {
        guard let dragged = draggingTab, let point = point(of: event),
              let from = store.pinboards.firstIndex(where: { $0.id == dragged }) else { return }
        guard let (target, frame) = model.tabFrames.first(where: { $0.key != dragged && $0.value.minX <= point.x && point.x <= $0.value.maxX }),
              let to = store.pinboards.firstIndex(where: { $0.id == target }) else { return }
        // 入れ替わったあとに行ったり来たりしないよう、真ん中を越えてから動かす
        guard to > from ? point.x > frame.midX : point.x < frame.midX else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            store.movePinboard(dragged, to: to)
        } else {
            withAnimation(.easeOut(duration: 0.15)) { store.movePinboard(dragged, to: to) }
        }
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
        draggedItems = list
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

    /// 編集中のプレビューでのキー（esc で取り消し、⌘S・⌘return で保存）。処理したら true
    private func handleEditing(_ event: NSEvent) -> Bool {
        // 日本語の変換中は esc・return を入力メソッドに渡す（変換の取り消しで編集ごと消えないように）
        if (preview.firstResponder as? NSTextInputClient)?.hasMarkedText() == true { return false }
        let command = event.modifierFlags.contains(.command)
        switch Int(event.keyCode) {
        case 53:
            finishEdit(save: false)
            return true
        case 36 where command, 76 where command:
            finishEdit(save: true)
            return true
        default:
            guard command else { return false }
            let chars = event.charactersIgnoringModifiers?.lowercased()
            if chars == "s" {
                finishEdit(save: true)
                return true
            }
            // ⌘B・⌘I・⌘U で太字・斜体・下線
            if model.editTextView != nil, let style = TextStyle.allCases.first(where: { $0.key == chars }) {
                model.toggle(style)
                return true
            }
            return sendEditAction(event)
        }
    }

    /// メニューバーのないアプリなので、⌘X・⌘C・⌘V・⌘A・⌘Z の編集操作はここで文字欄に送る。送ったら true
    private func sendEditAction(_ event: NSEvent) -> Bool {
        let shift = event.modifierFlags.contains(.shift)
        let action: Selector
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "x": action = #selector(NSText.cut(_:))
        case "c": action = #selector(NSText.copy(_:))
        case "v": action = #selector(NSText.paste(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        case "z": action = shift ? Selector(("redo:")) : Selector(("undo:"))
        default: return false
        }
        NSApp.sendAction(action, to: nil, from: self)
        return true
    }

    /// 処理したら true（検索欄には渡さない）
    private func handle(_ event: NSEvent) -> Bool {
        // 検索欄で日本語の変換中は、return・space・← → などを入力メソッドに渡す（確定の return で貼り付けないように）
        if (panel.firstResponder as? NSTextInputClient)?.hasMarkedText() == true { return false }
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
        case 36 where event.modifierFlags.contains(.option), 76 where event.modifierFlags.contains(.option):
            // option + return: 整えて貼り付け
            showTransformMenu(for: selected)
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
            if let editor = panel.firstResponder as? NSTextView, editor.selectedRange().length > 0 {
                return sendEditAction(event)
            }
            copy(selected, plainText: shift ? true : nil)
            return true
        case "e":
            if let first = selected.first { startEdit(first) }
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
        case "a" where model.query.isEmpty:
            model.marked = Set(items.map(\.id))
            return true
        case "a", "v", "x", "z": // 検索欄の文字の全選択・貼り付け・切り取り・取り消し
            return sendEditAction(event)
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
        model.dropBoard = nil
        // 他のアプリに入れたとき（Copipe の中での並べ替えは .move）は、使ったものとして数える
        if operation == .copy { store.recordUse(draggedItems) }
        draggedItems = []
    }
}
