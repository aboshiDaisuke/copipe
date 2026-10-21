import AppKit
import Vision

/// 日本語に強い検索：全角・半角、大文字・小文字、ひらがな・カタカナの違いを気にしない
enum SearchText {
    /// 検索語の言い換え（そのまま・カタカナにしたもの・ひらがなにしたもの）
    static func variants(of query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var result = [q]
        for reverse in [false, true] {
            if let v = q.applyingTransform(.hiraganaToKatakana, reverse: reverse), !result.contains(v) {
                result.append(v)
            }
        }
        return result
    }

    static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .widthInsensitive]) != nil
    }
}

/// 「整えて貼り付け」の整え方
enum TextTransform: String, CaseIterable, Identifiable {
    case removeLineBreaks = "改行を消す"
    case toHalfWidth = "英数字を半角にする"
    case toFullWidth = "英数字を全角にする"
    case trim = "前後の空白を取る"
    case quote = "「」で囲む"

    var id: String { rawValue }

    func apply(_ text: String) -> String {
        switch self {
        case .removeLineBreaks:
            // 英単語どうしの間だけ空白を入れて、日本語はそのままつなぐ（PDF からコピーした文章など）
            let isWord: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber) }
            var result = ""
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            for line in lines where !line.isEmpty {
                if let last = result.last, let first = line.first, last.isASCII, !last.isWhitespace, isWord(first) {
                    result += " "
                }
                result += line
            }
            return result
        case .toHalfWidth:
            // 全角の英数字・記号と全角スペースだけを半角に（カタカナはそのまま）
            return String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
                switch scalar.value {
                case 0xFF01...0xFF5E: Unicode.Scalar(scalar.value - 0xFEE0) ?? scalar
                case 0x3000: " "
                default: scalar
                }
            }))
        case .toFullWidth:
            return String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
                switch scalar.value {
                case 0x21...0x7E: Unicode.Scalar(scalar.value + 0xFEE0) ?? scalar
                case 0x20: "\u{3000}"
                default: scalar
                }
            }))
        case .trim:
            return text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .quote:
            return "「" + text.trimmingCharacters(in: .whitespacesAndNewlines) + "」"
        }
    }
}

/// 定型文の差し込み：{今日} などを、貼り付けるときの日付・時刻に置き換える
enum TextTemplate {
    static let placeholders = ["{今日}", "{明日}", "{昨日}", "{日付}", "{曜日}", "{時刻}", "{年}", "{月}", "{日}"]

    /// 説明用：「{今日} → 2026年10月21日」のような一覧（今の日付で作る）
    static var examples: String {
        placeholders.map { "\($0) → \(expandIfNeeded($0) ?? "")" }.joined(separator: "　")
    }

    /// 差し込みがあれば置き換えた文字、なければ nil
    static func expandIfNeeded(_ text: String, now: Date = Date()) -> String? {
        guard text.contains("{"), placeholders.contains(where: { text.contains($0) }) else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        func format(_ pattern: String, _ date: Date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ja_JP")
            f.calendar = calendar
            f.dateFormat = pattern
            return f.string(from: date)
        }
        let day: (Int) -> Date = { calendar.date(byAdding: .day, value: $0, to: now) ?? now }
        // 書いてある差し込みの分だけ日付を作る
        let values: [String: () -> String] = [
            "{今日}": { format("y年M月d日", now) }, "{明日}": { format("y年M月d日", day(1)) },
            "{昨日}": { format("y年M月d日", day(-1)) }, "{日付}": { format("yyyy/MM/dd", now) },
            "{曜日}": { format("EEEEE", now) }, "{時刻}": { format("H:mm", now) },
            "{年}": { format("y", now) }, "{月}": { format("M", now) }, "{日}": { format("d", now) },
        ]
        var result = text
        for (key, value) in values where result.contains(key) {
            result = result.replacingOccurrences(of: key, with: value())
        }
        return result
    }
}

extension ClipItem {
    /// 貼り付けるときの文字（{今日} などの差し込みは置き換える）
    var expandedText: String? {
        text.map { TextTemplate.expandIfNeeded($0) ?? $0 }
    }
}

/// 画像の中の文字を読み取る（Mac に入っている文字認識。日本語・英語）
enum TextRecognizer {
    static func recognize(imageAt url: URL) async -> String {
        await Task.detached(priority: .utility) {
            guard let image = NSImage(contentsOf: url),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ja-JP", "en-US"]
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cgImage).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }
}

/// Final Cut Pro がコピーした素材から、クリップ名・エフェクト名・長さを読み取る
enum FinalCutMaterial {
    static let pasteboardType = "com.apple.flexo.proFFPasteboardUTI"

    /// 名前を拾う種類（クリップ・テロップ）と、エフェクトとして拾う種類
    private static let clipClasses: Set<String> = [
        "FFAnchoredCollection", "FFAnchoredClip", "FFAnchoredGeneratorComponent", "FFAnchoredMediaComponent",
    ]
    private static let effectClasses: Set<String> = ["FFMotionEffect", "FFFxPlugEffect", "FFAnchoredTransition"]
    private static let containerName = "__timelineContainerClip"

    static func read(_ raw: RawPasteboard) -> MaterialInfo? {
        guard let data = raw.items.joined().first(where: { $0.type == pasteboardType })?.data,
              let outer = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let archived = outer["ffpasteboardobject"] as? Data,
              let archive = try? PropertyListSerialization.propertyList(from: archived, format: nil) as? [String: Any],
              let objects = archive["$objects"] as? [Any] else { return nil }

        func object(_ ref: Any?) -> Any? {
            guard let ref, let index = uid(ref), objects.indices.contains(index) else { return nil }
            return objects[index]
        }
        func className(of dict: [String: Any]) -> String? {
            (object(dict["$class"]) as? [String: Any])?["$classname"] as? String
        }

        var names: [String] = [], effects: [String] = []
        var duration: Double?
        for case let dict as [String: Any] in objects {
            guard let cls = className(of: dict), let name = object(dict["displayName"]) as? String else { continue }
            if name == containerName {
                duration = duration ?? (object(dict["clippedRange"]) as? String).flatMap(rangeDuration)
            } else if clipClasses.contains(cls) {
                // 音声などの部品は「クリップ名 - a1」になるので、もとのクリップ名にまとめる
                let base = name.replacingOccurrences(of: #" - [a-z]\d+$"#, with: "", options: .regularExpression)
                if !names.contains(base) { names.append(base) }
            } else if effectClasses.contains(cls), !effects.contains(name) {
                effects.append(name)
            }
        }
        return MaterialInfo(names: names, effects: effects, duration: duration)
    }

    /// NSKeyedArchiver の参照番号。Swift から値を取り出す手段がないので、説明文の「value = 12」から読む
    private static func uid(_ ref: Any) -> Int? {
        let description = String(describing: ref)
        guard description.contains("CFKeyedArchiverUID"),
              let range = description.range(of: #"value = (\d+)"#, options: .regularExpression) else { return nil }
        return Int(description[range].dropFirst("value = ".count))
    }

    /// "{(開始),(長さ)}" の長さ（"9400/3000" のような分数）を秒に
    private static func rangeDuration(_ text: String) -> Double? {
        let parts = text.components(separatedBy: CharacterSet(charactersIn: "{}(),")).filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        let fraction = parts[1].split(separator: "/").compactMap { Double($0) }
        guard fraction.count == 2, fraction[1] != 0 else { return nil }
        return fraction[0] / fraction[1]
    }
}
