import AppKit
import SwiftUI

/// 書式（太字・斜体・下線・取り消し線）
enum TextStyle: CaseIterable {
    case bold, italic, underline, strikethrough

    var title: String {
        switch self {
        case .bold: "太字"
        case .italic: "斜体"
        case .underline: "下線"
        case .strikethrough: "取り消し線"
        }
    }

    var symbol: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .underline: "underline"
        case .strikethrough: "strikethrough"
        }
    }

    /// ⌘ と一緒に押すキー
    var key: String? {
        switch self {
        case .bold: "b"
        case .italic: "i"
        case .underline: "u"
        case .strikethrough: nil
        }
    }
}

/// 書式付きの文字（RTF）の読み書きと、書式の付け外し
@MainActor
enum RichText {
    /// 書式のない文字を編集するときの字（RTF にそのまま書くので、他のアプリでも使える実在のフォントにする）
    static var defaultFont: NSFont { NSFont(name: "HiraginoSans-W3", size: 14) ?? .systemFont(ofSize: 14) }

    /// 太字にする前のフォント（太字を外したときに元の太さに戻すため。RTF には残らない）
    private static let regularFontKey = NSAttributedString.Key("jp.daisukeaboshi.copipe.regularFont")

    /// Apple Intelligence の執筆ツールが使えるか（オンにしていない Mac ではボタンを出さない）
    static var writingToolsAvailable: Bool {
        if #available(macOS 15.2, *) { return NSWritingToolsCoordinator.isWritingToolsAvailable }
        return false
    }

    /// 書式のない文字を、編集欄に出す形にする（黒い字。ダークモードでは表示のときだけ明るくなる）
    static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: defaultFont, .foregroundColor: NSColor.black])
    }

    /// クリップボードの丸ごとのデータから書式付きの文字を取り出す（RTF がなければ nil）
    /// HTML は読み込むときにページの画像などを取りに行くことがあるので使わない
    static func attributedString(from raw: RawPasteboard) -> NSAttributedString? {
        guard let entries = raw.items.first else { return nil }
        let limit = 5_000_000
        if let rtf = entries.first(where: { $0.type == NSPasteboard.PasteboardType.rtf.rawValue }), rtf.data.count < limit {
            return NSAttributedString(rtf: rtf.data, documentAttributes: nil)
        }
        if let rtfd = entries.first(where: { $0.type == NSPasteboard.PasteboardType.rtfd.rawValue }),
           rtfd.data.count < limit {
            return NSAttributedString(rtfd: rtfd.data, documentAttributes: nil)
        }
        return nil
    }

    /// 書式付きの文字を、貼り付けに使う丸ごとのデータ（RTF と書式なしの文字）にする
    static func raw(for text: NSAttributedString) -> RawPasteboard {
        var entries: [RawPasteboard.Entry] = []
        let range = NSRange(location: 0, length: text.length)
        if let rtf = text.rtf(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            entries.append(.init(type: NSPasteboard.PasteboardType.rtf.rawValue, data: rtf))
        }
        entries.append(.init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.string.utf8)))
        return RawPasteboard(items: [entries])
    }

    /// 太字・斜体・下線・取り消し線のどれかが付いているか
    static func hasFormatting(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, stop in
            if TextStyle.allCases.contains(where: { isOn($0, in: attributes) }) {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// 選んでいる文字の書式を付け外しする（全部に付いていれば外す）。何も選んでいなければ、これから打つ文字に
    static func toggle(_ style: TextStyle, in view: NSTextView) {
        guard let storage = view.textStorage else { return }
        let range = view.selectedRange()
        if range.length == 0 {
            view.typingAttributes = apply(style, on: !isOn(style, in: view.typingAttributes), to: view.typingAttributes)
            return
        }
        var allOn = true
        storage.enumerateAttributes(in: range) { attributes, _, stop in
            if !isOn(style, in: attributes) {
                allOn = false
                stop.pointee = true
            }
        }
        // 取り消し（⌘Z）できるように、変更をテキストビューに知らせる
        guard view.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttributes(in: range) { attributes, subrange, _ in
            storage.setAttributes(apply(style, on: !allOn, to: attributes), range: subrange)
        }
        storage.endEditing()
        view.didChangeText()
    }

    private static func isOn(_ style: TextStyle, in attributes: [NSAttributedString.Key: Any]) -> Bool {
        let font = attributes[.font] as? NSFont
        switch style {
        case .bold:
            return font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false
        case .italic:
            let italicFont = font.map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } ?? false
            return italicFont || (attributes[.obliqueness] as? Double ?? 0) > 0
        case .underline:
            return (attributes[.underlineStyle] as? Int ?? 0) != 0
        case .strikethrough:
            return (attributes[.strikethroughStyle] as? Int ?? 0) != 0
        }
    }

    private static func apply(_ style: TextStyle, on: Bool,
                              to attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var result = attributes
        let manager = NSFontManager.shared
        let font = attributes[.font] as? NSFont ?? defaultFont
        switch style {
        case .bold:
            if on {
                result[.font] = manager.convert(font, toHaveTrait: .boldFontMask)
                result[regularFontKey] = font.fontName
            } else {
                // ヒラギノは太字を外すと元より1段太くなるので、太字にする前のフォントがあればそれに戻す
                let original = (attributes[regularFontKey] as? String).flatMap { NSFont(name: $0, size: font.pointSize) }
                result[.font] = original ?? manager.convert(font, toNotHaveTrait: .boldFontMask)
                result[regularFontKey] = nil
            }
        case .italic:
            if on {
                let italic = manager.convert(font, toHaveTrait: .italicFontMask)
                // 日本語のフォントには斜体がないので、字を傾けて斜体にする
                if manager.traits(of: italic).contains(.italicFontMask) {
                    result[.font] = italic
                } else {
                    result[.obliqueness] = 0.2
                }
            } else {
                result[.font] = manager.convert(font, toNotHaveTrait: .italicFontMask)
                result[.obliqueness] = nil
            }
        case .underline:
            result[.underlineStyle] = on ? NSUnderlineStyle.single.rawValue : nil
        case .strikethrough:
            result[.strikethroughStyle] = on ? NSUnderlineStyle.single.rawValue : nil
        }
        return result
    }
}

/// 書式付きの文字を見せる・編集する欄（SwiftUI の TextEditor は書式を扱えないため NSTextView を使う）
struct RichTextView: NSViewRepresentable {
    let text: NSAttributedString
    var editable = false
    /// 編集欄ができたとき（保存のときに中身を読むため）
    var onCreate: ((NSTextView) -> Void)?
    /// 中身か書式を変えたとき
    var onChange: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        guard let view = scrollView.documentView as? NSTextView else { return scrollView }
        view.isRichText = true
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        // 黒い字のまま保存しつつ、ダークモードでは明るく見せる
        view.usesAdaptiveColorMappingForDarkAppearance = true
        view.textContainerInset = NSSize(width: 12, height: 14)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isEditable = editable
        view.isSelectable = true
        view.textStorage?.setAttributedString(text)
        context.coordinator.shown = text
        context.coordinator.onChange = onChange
        view.delegate = context.coordinator
        if editable {
            onCreate?(view)
            // プレビューがキーウインドウになってから、文字を打つ場所にする
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { view.window?.makeFirstResponder(view) }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // 見るだけの欄は、選んでいるカードが変わったら中身を入れ替える（編集中の欄は打った文字を残す）
        guard !editable, context.coordinator.shown !== text,
              let view = scrollView.documentView as? NSTextView else { return }
        view.textStorage?.setAttributedString(text)
        context.coordinator.shown = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var shown: NSAttributedString?
        var onChange: (() -> Void)?

        func textDidChange(_ notification: Notification) {
            onChange?()
        }
    }
}
