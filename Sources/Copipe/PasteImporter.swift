import Foundation
import SQLite3

/// Paste（com.wiheads.paste）の履歴とピンボードを Copipe に取り込む
/// 読み込みにはフルディスクアクセスが必要。Paste のデータは読むだけで書き換えない
@MainActor
enum PasteImporter {
    struct Result {
        var imported = 0
        var skipped = 0
        var failed = 0
        var pinboards: [String] = []
    }

    enum ImportError: LocalizedError {
        case notFound
        case noPermission
        case database(String)

        var errorDescription: String? {
            switch self {
            case .notFound: "Paste の履歴が見つかりませんでした。"
            case .noPermission: "Paste のデータを読む許可がありません。システム設定の「フルディスクアクセス」で Copipe をオンにしてください。"
            case .database(let message): "Paste の履歴を読めませんでした（\(message)）"
            }
        }
    }

    static func summary(of result: Swift.Result<Result, Error>) -> String {
        switch result {
        case .success(let r):
            var text = "\(r.imported) 件を読み込みました。"
            if r.skipped > 0 { text += "（読み込み済みの \(r.skipped) 件は飛ばしました）" }
            if r.failed > 0 { text += "\n読めなかったもの: \(r.failed) 件" }
            if !r.pinboards.isEmpty { text += "\nピンボード: " + r.pinboards.joined(separator: "、") }
            return text
        case .failure(let error):
            return error.localizedDescription
        }
    }

    static let storeFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.wiheads.paste/Data/Library/Application Support/Paste")

    /// 調査用: Paste のデータベースを dest にコピーする
    static func copyDatabase(to dest: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let name = "db.sqlite" + suffix
            try? fm.removeItem(at: dest.appendingPathComponent(name))
            try? fm.copyItem(at: storeFolder.appendingPathComponent(name), to: dest.appendingPathComponent(name))
        }
    }

    static func run(into store: ClipboardStore) throws -> Result {
        let fm = FileManager.default
        let db = storeFolder.appendingPathComponent("db.sqlite")
        guard fm.isReadableFile(atPath: storeFolder.path) || fm.fileExists(atPath: db.path) else {
            throw ImportError.notFound
        }

        // Paste が使用中でも読めるように、データベースを作業用フォルダにコピーしてから開く
        let work = fm.temporaryDirectory.appendingPathComponent("copipe-paste-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let source = storeFolder.appendingPathComponent("db.sqlite" + suffix)
                if fm.fileExists(atPath: source.path) {
                    try fm.copyItem(at: source, to: work.appendingPathComponent("db.sqlite" + suffix))
                }
            }
        } catch {
            throw ImportError.noPermission
        }

        let database = try Database(path: work.appendingPathComponent("db.sqlite").path)
        let externalDir = storeFolder.appendingPathComponent(".db_SUPPORT/_EXTERNAL_DATA")

        var result = Result()

        // ピンボード（ZRAWTYPE 2）。1 は「クリップボード」の履歴
        var boards: [Int64: Pinboard] = [:]
        for row in try database.rows("SELECT Z_PK, ZRAWTYPE, ZNAME, ZRAWATTRIBUTES FROM ZLISTENTITY ORDER BY Z_PK") {
            guard row.int(1) == 2, let name = row.string(2) else { continue }
            // ZRAWATTRIBUTES は BLOB 列に JSON 文字列が入っている（例: {"type":"pinboard","colorCode":15750477}）
            let json = row.data(3) ?? row.string(3).map { Data($0.utf8) }
            let attributes = json.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let color = attributes?["colorCode"] as? Int ?? Pinboard.palette[boards.count % Pinboard.palette.count]
            boards[row.int(0)] = store.pinboard(named: name, color: color)
            result.pinboards.append(name)
        }

        // コピー元のアプリ
        var apps: [Int64: ClipboardStore.Source] = [:]
        for row in try database.rows("SELECT Z_PK, ZNAME, ZBUNDLEIDENTIFIER FROM ZAPPLICATIONENTITY") {
            apps[row.int(0)] = (row.string(1), row.string(2))
        }

        let query = """
            SELECT i.ZLIST, i.ZSOURCEAPPLICATION, i.ZTIMESTAMP, i.ZTITLE, d.ZRAWPASTEBOARDITEMS
            FROM ZITEMENTITY i JOIN ZITEMDATAENTITY d ON d.Z_PK = i.ZDATA
            ORDER BY i.ZLIST, i.ZDISPLAYORDERINPINBOARD, i.ZTIMESTAMP DESC
            """
        for row in try database.rows(query) {
            guard let blob = row.data(4), let raw = decodePasteboard(blob, externalDir: externalDir) else {
                result.failed += 1
                continue
            }
            let title = row.string(3).flatMap { $0.isEmpty ? nil : $0 }
            let imported = store.importItem(raw: raw, source: apps[row.int(1)] ?? (nil, nil),
                                            date: Date(timeIntervalSinceReferenceDate: row.double(2)),
                                            pinboard: row.isNull(0) ? nil : boards[row.int(0)], title: title)
            if imported { result.imported += 1 } else { result.skipped += 1 }
        }
        store.finishImport()
        return result
    }

    // MARK: - Paste の保存形式

    /// Paste が保存しているクリップボード 1 件分（types の順番どおりに戻す）
    private struct PasteboardItemData: Decodable {
        var types: [String]
        var dataByType: [String: Data]
    }

    /// 先頭1バイトが 1 ならそのまま、2 なら続く名前の外部ファイルに本体がある（Core Data の外部保存）
    /// 本体は bplist / JSON のどちらかで、Apple 独自圧縮（bvx〜）か deflate で圧縮されていることがある
    static func decodePasteboard(_ blob: Data, externalDir: URL) -> RawPasteboard? {
        guard let marker = blob.first else { return nil }
        var body = blob.dropFirst()
        if marker == 2 {
            let name = String(decoding: body.prefix { $0 != 0 }, as: UTF8.self)
            guard let data = try? Data(contentsOf: externalDir.appendingPathComponent(name)) else { return nil }
            body = data[...]
        }
        guard let payload = decompress(Data(body)) else { return nil }

        let decoded: [PasteboardItemData]?
        if payload.starts(with: Array("bplist".utf8)) {
            decoded = try? PropertyListDecoder().decode([PasteboardItemData].self, from: payload)
        } else {
            decoded = try? JSONDecoder().decode([PasteboardItemData].self, from: payload)
        }
        guard let decoded else { return nil }

        let items = decoded.map { item in
            item.types.compactMap { type in item.dataByType[type].map { RawPasteboard.Entry(type: type, data: $0) } }
        }.filter { !$0.isEmpty }
        return items.isEmpty ? nil : RawPasteboard(items: items)
    }

    private static func decompress(_ data: Data) -> Data? {
        if data.starts(with: Array("bplist".utf8)) || data.first == UInt8(ascii: "[") { return data }
        if data.starts(with: Array("bvx".utf8)) {
            return try? (data as NSData).decompressed(using: .lzfse) as Data
        }
        return try? (data as NSData).decompressed(using: .zlib) as Data
    }
}

// MARK: - SQLite（読み取り専用）

private final class Database {
    private var handle: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            throw PasteImporter.ImportError.database(message)
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    func rows(_ sql: String) throws -> [Row] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw PasteImporter.ImportError.database(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(Row(statement: statement!))
        }
        return rows
    }

    /// 1 行分の値をコピーして持つ
    struct Row {
        private var values: [Any?] = []

        init(statement: OpaquePointer) {
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: values.append(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: values.append(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: values.append(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    values.append(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, column), count: count))
                default: values.append(nil)
                }
            }
        }

        func isNull(_ i: Int) -> Bool { values[i] == nil }
        func int(_ i: Int) -> Int64 { values[i] as? Int64 ?? Int64(values[i] as? Double ?? 0) }
        func double(_ i: Int) -> Double { values[i] as? Double ?? Double(values[i] as? Int64 ?? 0) }
        func string(_ i: Int) -> String? { values[i] as? String }
        func data(_ i: Int) -> Data? { values[i] as? Data }
    }
}
