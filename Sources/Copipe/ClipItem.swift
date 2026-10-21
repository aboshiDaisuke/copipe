import Foundation

enum ClipKind: String, Codable {
    case text, link, image, file, other

    var label: String {
        switch self {
        case .text: "テキスト"
        case .link: "リンク"
        case .image: "画像"
        case .file: "ファイル"
        case .other: "素材"
        }
    }
}

struct ClipItem: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: ClipKind
    var text: String?
    var imageName: String?
    var filePaths: [String]?
    /// クリップボードの中身を丸ごと保存したファイル名（アプリ独自の形式や書式も含む）
    var rawName: String?
    var rawSize: Int?
    var sourceAppName: String?
    var sourceBundleID: String?
    var date: Date
    /// 旧バージョンの「ピン留め」。読み込み時に「ピン留め」ピンボードへ移す
    var pinned: Bool = false
    /// 同じ内容を重複登録しないための識別子
    var signature: String
    /// 入っているピンボード（nil ならクリップボードの履歴）
    var pinboardID: UUID?
    /// 自分で付けた名前（Paste から引き継いだもの）
    var title: String?
    /// Final Cut Pro の素材の中身（クリップ名・エフェクト名・長さ）
    var material: MaterialInfo?
    /// 画像から読み取った文字（"" なら読み取り済みで文字なし、nil ならまだ）
    var ocrText: String?

    /// 検索（variants は SearchText.variants で作った、ひらがな・カタカナの言い換え）
    func matches(_ variants: [String]) -> Bool {
        if variants.isEmpty { return true }
        var haystacks = [text, sourceAppName, title, ocrText]
        haystacks += (filePaths ?? []).map { ($0 as NSString).lastPathComponent }
        haystacks += (material?.names ?? []) + (material?.effects ?? [])
        return haystacks.contains { haystack in
            guard let haystack, !haystack.isEmpty else { return false }
            return variants.contains { SearchText.contains(haystack, $0) }
        }
    }

    /// カードの上に出す名前
    var displayTitle: String {
        if let title { return title }
        if colorValue != nil { return "色" }
        if kind == .file, let count = filePaths?.count, count > 1 { return "\(count) 個のファイル" }
        return kind.label
    }

    /// 「開く」で開くもの（リンク先か、1つ目のファイル）
    var openURL: URL? {
        switch kind {
        case .link: text.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        case .file: filePaths?.first.map { URL(fileURLWithPath: $0) }
        default: nil
        }
    }

    /// 色を表す文字（#RRGGBB・rgb(…)）なら 0xRRGGBB
    /// #RGB の3桁は「#123」のような番号と見分けがつかないので色にしない
    var colorValue: Int? {
        // 長い文章を1文字ずつ数えないように、バイト数で先にはじく
        guard kind == .text, let raw = text, raw.utf8.count <= 40 else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasPrefix("#") {
            let hex = String(t.dropFirst())
            guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
            return Int(hex, radix: 16)
        }
        if t.hasPrefix("rgb"), t.hasSuffix(")"), let open = t.firstIndex(of: "(") {
            let parts = t[t.index(after: open)..<t.index(before: t.endIndex)]
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3 || parts.count == 4 else { return nil }
            let rgb = parts.prefix(3).compactMap { Int($0) }
            guard rgb.count == 3, rgb.allSatisfy({ (0...255).contains($0) }) else { return nil }
            return rgb[0] << 16 | rgb[1] << 8 | rgb[2]
        }
        return nil
    }
}

extension Int {
    /// 0xRRGGBB を "#RRGGBB" に
    var hexColor: String { String(format: "#%06X", self) }
}

enum ClipFilter: String, CaseIterable, Identifiable {
    case all = "すべて"
    case text = "テキスト"
    case link = "リンク"
    case color = "色"
    case image = "画像"
    case file = "ファイル"
    case other = "素材"

    var id: String { rawValue }

    func matches(_ item: ClipItem) -> Bool {
        switch self {
        case .all: true
        case .text: item.kind == .text && item.colorValue == nil
        case .link: item.kind == .link
        case .color: item.colorValue != nil
        case .image: item.kind == .image
        case .file: item.kind == .file
        case .other: item.kind == .other
        }
    }
}

/// Final Cut Pro の素材の中身
struct MaterialInfo: Codable, Equatable {
    /// クリップ名・テロップの文字
    var names: [String]
    /// 使っているエフェクト・タイトル・トランジション
    var effects: [String]
    /// 長さ（秒）
    var duration: Double?

    var isEmpty: Bool { names.isEmpty && effects.isEmpty }

    var durationText: String? {
        guard let duration else { return nil }
        if duration < 60 { return String(format: "%.1f 秒", duration) }
        return "\(Int(duration) / 60) 分 \(Int(duration) % 60) 秒"
    }
}

/// 日付での絞り込み（Paste の検索フィルターと同じ）
enum DateFilter: String, CaseIterable, Identifiable {
    case all = "いつでも"
    case today = "今日"
    case yesterday = "昨日"
    case week = "過去7日間"
    case month = "過去30日間"

    var id: String { rawValue }

    func matches(_ date: Date) -> Bool {
        switch self {
        case .all: true
        case .today: Calendar.current.isDateInToday(date)
        case .yesterday: Calendar.current.isDateInYesterday(date)
        case .week: date > Date().addingTimeInterval(-7 * 86_400)
        case .month: date > Date().addingTimeInterval(-30 * 86_400)
        }
    }
}

/// 名前と色を付けて項目を取っておく場所（Paste のピンボードと同じ）
struct Pinboard: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    /// 0xRRGGBB
    var color: Int

    static let palette = [0xF0544D, 0xFF9F0A, 0xFFD60A, 0x30D158, 0x40C8E0, 0x0A84FF, 0xBF5AF2, 0x8E8E93]
    static let paletteNames = ["赤", "オレンジ", "黄", "緑", "水色", "青", "紫", "グレー"]
}

/// クリップボードの全アイテム・全形式のデータ（Final Cut Pro の素材など、アプリ独自の形式もそのまま残す）
struct RawPasteboard: Codable {
    struct Entry: Codable {
        var type: String
        var data: Data
    }

    var items: [[Entry]]

    var totalSize: Int {
        items.reduce(0) { $0 + $1.reduce(0) { $0 + $1.data.count } }
    }
}
