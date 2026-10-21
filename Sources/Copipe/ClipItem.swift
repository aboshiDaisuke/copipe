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
    var pinned: Bool = false
    /// 同じ内容を重複登録しないための識別子
    var signature: String

    func matches(query: String) -> Bool {
        if query.isEmpty { return true }
        let haystacks = [text, sourceAppName] + (filePaths ?? []).map { ($0 as NSString).lastPathComponent }
        return haystacks.contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }
}

enum ClipFilter: String, CaseIterable, Identifiable {
    case all = "すべて"
    case text = "テキスト"
    case link = "リンク"
    case image = "画像"
    case file = "ファイル"
    case other = "素材"
    case pinned = "ピン留め"

    var id: String { rawValue }

    func matches(_ item: ClipItem) -> Bool {
        switch self {
        case .all: true
        case .text: item.kind == .text
        case .link: item.kind == .link
        case .image: item.kind == .image
        case .file: item.kind == .file
        case .other: item.kind == .other
        case .pinned: item.pinned
        }
    }
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
