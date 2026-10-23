import AppKit
import FoundationModels
import NaturalLanguage

/// 「提案」タブ：いま貼り付けようとしているアプリの様子から、次に貼りそうなものを選ぶ
/// （Paste のインテリジェントクリップボードと同じ。Apple Intelligence を Mac の中だけで使う）
enum SuggestionState: Equatable {
    case idle, thinking, ready
}

/// 貼り付け先のアプリの様子（アクセシビリティで読む。「提案」を開いたときだけ）
struct WorkContext {
    var appName: String
    var bundleID: String?
    var windowTitle: String?
    /// 入力欄の名前（宛先・件名・郵便番号など）
    var fieldLabel: String?
    /// 入力欄の、カーソルのまわりの文章
    var typing: String?
    /// 窓に出ている文字（少しだけ）
    var visibleText: String?

    /// AI と言葉の一致に使う文字
    var allText: String {
        [windowTitle, fieldLabel, typing, visibleText].compactMap { $0 }.joined(separator: "\n")
    }

    /// 他のアプリに問い合わせるので、メインスレッドの外で呼ぶ（返事が遅いアプリでも 1 秒ほどで切り上げる）
    static func read(from app: NSRunningApplication) -> WorkContext {
        var context = WorkContext(appName: app.localizedName ?? "", bundleID: app.bundleIdentifier)
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        let window = Self.element(element, kAXFocusedWindowAttribute)
        context.windowTitle = window.flatMap { string($0, kAXTitleAttribute) }.map { limited($0, 120) }

        if let field = Self.element(element, kAXFocusedUIElementAttribute) {
            var labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute]
                .compactMap { string(field, $0) }
            if let titleElement = Self.element(field, kAXTitleUIElementAttribute) {
                labels += [string(titleElement, kAXValueAttribute), string(titleElement, kAXTitleAttribute)].compactMap { $0 }
            }
            var unique: [String] = []
            for label in labels where !unique.contains(label) { unique.append(label) }
            context.fieldLabel = unique.isEmpty ? nil : limited(unique.joined(separator: " / "), 100)
            // パスワードの欄は読まない
            let secure = string(field, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
            if !secure, let value = string(field, kAXValueAttribute) {
                context.typing = around(cursor: cursorLocation(of: field), in: value)
            }
        }
        if let window { context.visibleText = visibleText(in: window) }
        return context
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let text = attribute(element, name) as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func cursorLocation(of element: AXUIElement) -> Int? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range.location : nil
    }

    /// 長い文章は、カーソルの前 400 字と後ろ 100 字だけ（カーソルが分からなければ最後の 500 字）
    private static func around(cursor: Int?, in text: String) -> String {
        let ns = text as NSString
        let end = min(ns.length, (cursor ?? ns.length) + 100)
        let start = max(0, end - 500)
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    /// 窓に出ている文字を、上から少しだけ集める
    private static func visibleText(in window: AXUIElement) -> String? {
        var queue = [window]
        var texts: [String] = []
        var length = 0, visited = 0
        let deadline = Date().addingTimeInterval(0.8)
        while !queue.isEmpty, visited < 300, length < 600, Date() < deadline {
            let node = queue.removeFirst()
            visited += 1
            let role = string(node, kAXRoleAttribute)
            if role == kAXStaticTextRole || role == "AXHeading", let text = string(node, kAXValueAttribute) ?? string(node, kAXTitleAttribute) {
                texts.append(limited(text, 120))
                length += min(text.count, 120)
            }
            if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] { queue += children.prefix(40) }
        }
        return texts.isEmpty ? nil : texts.joined(separator: " ")
    }

    fileprivate static func limited(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}

@MainActor
enum Suggestions {
    /// 出す数
    static let limit = 8
    /// AI に見せる候補の数（多すぎると Mac の中の AI が一度に読める量を超える）
    private static let candidateLimit = 24

    /// 次に貼りそうな項目を、合う順に選ぶ
    static func pick(from items: [ClipItem], pinboards: [Pinboard], context: WorkContext?) async -> [UUID] {
        let pastedHere = items.filter { item in context?.bundleID.map { item.pastedApps?.contains($0) == true } ?? false }
            .sorted { $0.date > $1.date }
        guard let context else { return Array(pastedHere.prefix(limit).map(\.id)) }
        let keywords = Self.keywords(in: context.allText)
        let candidates = Self.candidates(from: items, context: context, keywords: keywords)
        var picked: [ClipItem]
        if #available(macOS 26.0, *), let chosen = await ask(context: context, candidates: candidates, pinboards: pinboards) {
            picked = chosen
        } else {
            // AI が使えないときは、言葉が合うものを多い順に
            picked = candidates.filter { score($0, keywords: keywords, bundleID: nil) > 0 }
        }
        // このアプリに前に貼ったものも後ろに足す（使ううちに賢くなる）
        for item in pastedHere where !picked.contains(where: { $0.signature == item.signature }) { picked.append(item) }
        return Array(picked.prefix(limit).map(\.id))
    }

    // MARK: - 候補を絞る

    /// 言葉が合うもの・このアプリに貼ったもの・最近のもの・よく使うピンボードの項目から、AI に見せる候補を選ぶ
    private static func candidates(from items: [ClipItem], context: WorkContext, keywords: [String]) -> [ClipItem] {
        var seen = Set<String>()
        var result: [ClipItem] = []
        func add(_ list: some Sequence<ClipItem>) {
            for item in list where result.count < candidateLimit && seen.insert(item.signature).inserted {
                result.append(item)
            }
        }
        let scored = items.map { ($0, score($0, keywords: keywords, bundleID: context.bundleID)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        add(scored.prefix(14))
        add(items.filter { $0.pinboardID == nil }.prefix(6))
        add(items.filter { $0.pinboardID != nil }.sorted { ($0.useCount ?? 0) > ($1.useCount ?? 0) }.prefix(4))
        add(scored)
        return result
    }

    private static func score(_ item: ClipItem, keywords: [String], bundleID: String?) -> Double {
        let haystack = [String((item.text ?? "").prefix(3000)), item.title, item.ocrText,
                        item.material?.names.joined(separator: " "), item.filePaths?.joined(separator: " ")]
            .compactMap { $0 }.joined(separator: "\n")
        var score = Double(keywords.filter { SearchText.contains(haystack, $0) }.count)
        if let bundleID, item.pastedApps?.contains(bundleID) == true { score += 3 }
        return score
    }

    /// 作業中の文字から、探すのに使う言葉（日本語も単語に分ける）
    private static func keywords(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var words: [String] = []
        var seen = Set<String>()
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range])
            if word.count >= 2, !word.allSatisfy(\.isNumber), seen.insert(word.lowercased()).inserted { words.append(word) }
            return words.count < 80
        }
        return words
    }

    // MARK: - AI に選んでもらう

    @available(macOS 26.0, *)
    private static func ask(context: WorkContext, candidates: [ClipItem], pinboards: [Pinboard]) async -> [ClipItem]? {
        guard !candidates.isEmpty, case .available = SystemLanguageModel.default.availability else { return nil }
        let session = LanguageModelSession(instructions: """
        あなたはクリップボード履歴アプリの手伝いです。ユーザーがいま作業している画面の様子と、前にコピーした項目の一覧を渡します。
        ユーザーが次に貼り付けそうな項目を、可能性が高い順に最大\(limit)個選び、番号だけを半角のカンマ区切りで答えてください（例: 3,1,7）。
        入力欄の名前（宛先・件名・住所・URL など）や、入力中の文章の続きに合うものを優先してください。合うものがなければ「なし」と答えてください。
        """)
        var lines = ["作業中のアプリ: \(context.appName)"]
        if let title = context.windowTitle { lines.append("ウインドウの題名: \(title)") }
        if let label = context.fieldLabel { lines.append("入力欄: \(label)") }
        if let typing = context.typing { lines.append("入力中の文章: \(WorkContext.limited(typing, 500))") }
        if let visible = context.visibleText { lines.append("画面に出ている文字: \(WorkContext.limited(visible, 300))") }
        lines.append("")
        lines.append("候補:")
        for (index, item) in candidates.enumerated() {
            lines.append("\(index + 1). \(describe(item, pinboards: pinboards, bundleID: context.bundleID))")
        }
        guard let response = try? await session.respond(to: lines.joined(separator: "\n"),
                                                         options: GenerationOptions(temperature: 0.1, maximumResponseTokens: 40))
        else { return nil }
        var picked: [ClipItem] = []
        for match in response.content.split(whereSeparator: { !$0.isNumber }) {
            guard let number = Int(match), candidates.indices.contains(number - 1) else { continue }
            let item = candidates[number - 1]
            if !picked.contains(where: { $0.id == item.id }) { picked.append(item) }
        }
        return picked
    }

    /// AI に見せる1行（種類・ピンボード名・中身の先頭）
    private static func describe(_ item: ClipItem, pinboards: [Pinboard], bundleID: String?) -> String {
        var tags = [item.colorValue != nil ? "色" : item.kind == .other ? "動画編集の素材" : item.kind.label]
        if let board = pinboards.first(where: { $0.id == item.pinboardID }) { tags.append("ピンボード「\(board.name)」") }
        if let bundleID, item.pastedApps?.contains(bundleID) == true { tags.append("このアプリに貼ったことあり") }
        let body: String
        switch item.kind {
        case .text: body = item.text ?? ""
        case .link:
            let link = item.text ?? ""
            body = [LinkPreviews.shared.title(for: link), link].compactMap { $0 }.joined(separator: " ")
        case .image: body = item.ocrText ?? ""
        case .file: body = (item.filePaths ?? []).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        case .other: body = (item.material?.names ?? []).joined(separator: ", ")
        }
        let title = item.title.map { "「\($0)」 " } ?? ""
        return "[\(tags.joined(separator: "・"))] " + title + WorkContext.limited(body, 60)
    }
}

/// 動作確認用: `--suggest-test <bundle ID> <架空の履歴.json> <書き出し先.txt>`
/// そのアプリの様子を読んで、架空の履歴から提案を選び、ファイルに書き出す（本物の履歴は使わない）
enum SuggestionTest {
    static let flag = "--suggest-test"

    @MainActor
    static func run(arguments: [String]) -> Never {
        guard let i = arguments.firstIndex(of: flag), i + 3 < arguments.count,
              let data = try? Data(contentsOf: URL(fileURLWithPath: arguments[i + 2])),
              let items = try? JSONDecoder().decode([ClipItem].self, from: data) else { exit(1) }
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: arguments[i + 1]).first
        var finished = false
        Task {
            let started = Date()
            let context = app.map(WorkContext.read)
            let picked = await Suggestions.pick(from: items, pinboards: [], context: context)
            var lines = ["アクセシビリティ: \(AXIsProcessTrusted())", "アプリ: \(context?.appName ?? "なし")",
                         "窓: \(context?.windowTitle ?? "")", "入力欄: \(context?.fieldLabel ?? "")",
                         "入力中: \(context?.typing ?? "")", "画面の文字: \(context?.visibleText ?? "")",
                         "秒: \(String(format: "%.1f", Date().timeIntervalSince(started)))", "提案:"]
            lines += picked.compactMap { id in items.first { $0.id == id }.map { "- " + ($0.text ?? $0.kind.label) } }
            try? lines.joined(separator: "\n").write(toFile: arguments[i + 3], atomically: true, encoding: .utf8)
            finished = true
        }
        while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        exit(0)
    }
}
