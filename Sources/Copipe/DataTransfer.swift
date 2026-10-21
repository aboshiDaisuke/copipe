import AppKit
import UniformTypeIdentifiers

/// 履歴とピンボードを1つの .zip に書き出す・読み込む（バックアップや、別の Mac への引っ越し用）
@MainActor
enum DataTransfer {
    /// 書き出す。成功したら保存先、やめたら nil
    static func export(_ store: ClipboardStore) throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Copipe のバックアップ \(Date().formatted(.iso8601.year().month().day())).zip"
        panel.prompt = "書き出す"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        store.saveNow()
        try? FileManager.default.removeItem(at: url)
        // Copipe のフォルダを丸ごと（履歴・ピンボード・画像・丸ごとのデータ）
        try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", store.dataDirectory.path, url.path])
        return url
    }

    /// 読み込む。今の履歴・ピンボードに足す（同じものは飛ばす）。読み込んだ件数、やめたら nil
    static func `import`(into store: ClipboardStore) throws -> Int? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.prompt = "読み込む"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("copipe-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        try run("/usr/bin/ditto", ["-x", "-k", url.path, temp.path])
        // 書き出したときのフォルダ（Copipe/）か、zip の中身がそのまま並んでいるか
        let dir = [temp.appendingPathComponent("Copipe"), temp]
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("history.json").path) }
        guard let dir else { throw TransferError.notBackup }

        let decoder = JSONDecoder()
        let items = try decoder.decode([ClipItem].self, from: Data(contentsOf: dir.appendingPathComponent("history.json")))
        let boards = (try? Data(contentsOf: dir.appendingPathComponent("pinboards.json")))
            .flatMap { try? decoder.decode([Pinboard].self, from: $0) } ?? []
        return store.merge(items: items, pinboards: boards, from: dir)
    }

    enum TransferError: LocalizedError {
        case notBackup
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notBackup: "Copipe のバックアップではないようです。"
            case .failed(let message): message
            }
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw TransferError.failed("うまくいきませんでした。\(message)")
        }
    }
}
