import AppKit
import CryptoKit
import IOKit
import SystemConfiguration

/// iCloud Drive を通して、ほかの Mac の Copipe と履歴・ピンボードをそろえる
///
/// iCloud Drive の「Copipe」フォルダに、Mac ごとに自分の分のファイル（devices/<Mac の ID>.json）だけを書き、
/// ほかの Mac のファイルは読むだけにする（2台が同じファイルを同時に書いて壊さないように）。
/// 画像と丸ごとのデータは images/・raw/ に置く。同じ名前なら中身も同じなので、上書きはしない。
/// 項目・ピンボードごとに最後に変えた時刻を覚えておき、2台で違うときは新しいほうを使う。
/// 消したものも消した時刻を残して、ほかの Mac でも消す
@MainActor
final class CloudSync: ObservableObject {
    enum Status: Equatable {
        case off
        case unavailable
        case syncing
        case synced(Date)
        case failed(String)

        var text: String {
            switch self {
            case .off: "オフ"
            case .unavailable: "iCloud Drive がオフになっています（システム設定 > Apple アカウント > iCloud > iCloud Drive）"
            case .syncing: "同期しています…"
            case .synced(let date): "同期済み " + date.formatted(date: .omitted, time: .shortened)
            case .failed(let message): "同期できませんでした（\(message)）"
            }
        }
    }

    /// iCloud Drive を読み書きする許可がない
    private struct NoPermission: LocalizedError {
        var errorDescription: String? {
            "iCloud Drive を読み書きする許可がありません。システム設定 > プライバシーとセキュリティ > ファイルとフォルダ で、Copipe の「iCloud Drive」をオンにしてください"
        }
    }

    @Published private(set) var status: Status = .off
    /// 同じ iCloud で同期しているほかの Mac の名前
    @Published private(set) var otherMacs: [String] = []
    /// ほかの Mac の項目で、画像などが iCloud から届くのを待っているものの数
    @Published private(set) var waitingItems = 0

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "iCloudSync") }
        set { UserDefaults.standard.set(newValue, forKey: "iCloudSync") }
    }

    static let iCloudDrive = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    static let folder = iCloudDrive.appendingPathComponent("Copipe", isDirectory: true)

    /// 消した記録はこの日数で忘れる（これより長く同期していなかった Mac から、消したものが戻ることがある）
    private static let tombstoneDays = 90.0
    /// 画像などが iCloud から届くのをこの時間まで待つ。過ぎたら丸ごとのデータなしで取り込む
    /// （初めて同期する Mac は数百 MB を受け取ることがあるので長めに）
    private static let missingFileWait: TimeInterval = 6 * 3600

    private let store: ClipboardStore
    private let stateURL: URL
    private var state: State
    private var timer: Timer?
    private(set) var busy = false
    /// 同期中にまた頼まれた
    private var again = false
    /// 前に書き出してから、履歴・ピンボードを保存した
    private var changedSinceExport = true
    private var exportRequested = false
    /// ほかの Mac のファイルを最後に読んだときの更新日時（変わっていなければ読み直さない）
    private var readDates: [String: Date] = [:]
    /// ほかの Mac のファイルが使っている画像・丸ごとのデータの名前（iCloud の古いファイルを消すときに残す）
    private var remoteFiles: [String: Set<String>] = [:]
    /// 画像などがまだ届いていなくて取り込めなかった項目と、最初に気づいた時刻
    private var missingSince: [UUID: Date] = [:]
    private var lastWritten: Data?
    private var lastCleanup = Date.distantPast

    /// この Mac の ID（devices/ の中のファイル名）
    private let deviceID: String

    init(store: ClipboardStore, deviceID: String = CloudSync.hardwareID) {
        self.store = store
        self.deviceID = deviceID
        stateURL = store.dataDirectory.appendingPathComponent("sync.json")
        state = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    func start() {
        store.onSave = { [weak self] in self?.requestExport() }
        if Self.isEnabled { begin() }
    }

    func setEnabled(_ enabled: Bool) {
        Self.isEnabled = enabled
        if enabled {
            begin()
        } else {
            timer?.invalidate()
            timer = nil
            status = .off
            otherMacs = []
        }
    }

    private func begin() {
        timer?.invalidate()
        // ほかの Mac が書いたかどうかは、20秒ごとにファイルの更新日時だけ見る
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncNow() }
        }
        changedSinceExport = true
        syncNow()
    }

    /// 保存したら、続けて保存することが多いので少し待ってから書き出す
    private func requestExport() {
        changedSinceExport = true
        guard Self.isEnabled, !exportRequested else { return }
        exportRequested = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.exportRequested = false
            self.syncNow()
        }
    }

    func syncNow() {
        guard Self.isEnabled else { return }
        guard !busy else {
            again = true
            return
        }
        guard FileManager.default.fileExists(atPath: Self.iCloudDrive.path) else {
            status = .unavailable
            return
        }
        busy = true
        if case .synced = status {} else { status = .syncing }
        Task {
            do {
                try await cycle()
                status = .synced(Date())
            } catch {
                status = .failed(Self.isPermissionError(error) ? NoPermission().localizedDescription : error.localizedDescription)
            }
            waitingItems = missingSince.count
            busy = false
            if again {
                again = false
                syncNow()
            }
        }
    }

    // MARK: - 1回分の同期

    private func cycle() async throws {
        let folder = Self.folder, own = deviceID, known = readDates
        let localImages = store.dataDirectory.appendingPathComponent("images")
        let localRaw = store.dataDirectory.appendingPathComponent("raw")
        // 取り込めなかったものがあれば、変わっていなくても読み直す
        let rereadAll = !missingSince.isEmpty

        let remotes = try await Task.detached {
            try Self.fetch(folder: folder, own: own, known: rereadAll ? [:] : known,
                           localImages: localImages, localRaw: localRaw)
        }.value

        for remote in remotes {
            readDates[remote.file] = remote.date
            remoteFiles[remote.file] = remote.snapshot.fileNames
        }
        if !remotes.isEmpty {
            otherMacs = Array(Set(otherMacs + remotes.map(\.snapshot.device))).sorted()
        }
        if merge(remotes.map(\.snapshot)) { changedSinceExport = true }
        guard changedSinceExport else { return }
        changedSinceExport = false
        try await export()
    }

    /// ほかの Mac のファイルのうち、前に読んでから変わったものを読む。使う画像・丸ごとのデータでこの Mac にないものも取ってくる
    private nonisolated static func fetch(folder: URL, own: String, known: [String: Date],
                                          localImages: URL, localRaw: URL) throws -> [Remote] {
        let fm = FileManager.default
        let devices = folder.appendingPathComponent("devices")
        for dir in [devices, folder.appendingPathComponent("images"), folder.appendingPathComponent("raw")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let decoder = JSONDecoder()
        var result: [Remote] = []
        for url in try fm.contentsOfDirectory(at: devices, includingPropertiesForKeys: [.contentModificationDateKey],
                                              options: [.skipsHiddenFiles])
        where url.pathExtension == "json" && url.deletingPathExtension().lastPathComponent != own {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard known[url.lastPathComponent] != date else { continue }
            // まだ iCloud から届いていなければ、取りに行くよう頼んで次の回に読む
            guard isDownloaded(url) else { continue }
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? decoder.decode(Snapshot.self, from: data) else { continue }
            for entry in snapshot.items {
                if let name = entry.item.imageName {
                    download(folder.appendingPathComponent("images").appendingPathComponent(name),
                             to: localImages.appendingPathComponent(name))
                }
                if let name = entry.item.rawName {
                    download(folder.appendingPathComponent("raw").appendingPathComponent(name),
                             to: localRaw.appendingPathComponent(name))
                }
            }
            result.append(Remote(file: url.lastPathComponent, date: date, snapshot: snapshot))
        }
        return result
    }

    /// iCloud のファイルをこの Mac に写す（まだ iCloud から届いていなければ、取りに行くよう頼むだけで待たない）
    private nonisolated static func download(_ source: URL, to dest: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dest.path), isDownloaded(source),
              let data = try? Data(contentsOf: source) else { return }
        try? data.write(to: dest, options: .atomic)
    }

    /// iCloud のファイルの中身がこの Mac にあるか。なければ取りに行くよう頼んで false
    /// （中身のないファイルをそのまま読むと、届くまで待たされる。初めての Mac では数百 MB になるので待たない）
    private nonisolated static func isDownloaded(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard FileManager.default.fileExists(atPath: url.path),
              values?.isUbiquitousItem != true || values?.ubiquitousItemDownloadingStatus == .current else {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return false
        }
        return true
    }

    private nonisolated static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
           [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code) { return true }
        let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError) ?? error
        return posix.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(posix.code)
    }

    // MARK: - そろえる

    /// ほかの Mac の中身と合わせる。この Mac の中身が変わったら true
    private func merge(_ remotes: [Snapshot]) -> Bool {
        guard !remotes.isEmpty else { return false }
        refreshStamps()
        let now = Date()
        let fm = FileManager.default
        let imagesDir = store.dataDirectory.appendingPathComponent("images")
        let rawDir = store.dataDirectory.appendingPathComponent("raw")

        var deletedItems = state.deletedItems
        var deletedBoards = state.deletedBoards
        for remote in remotes {
            deletedItems.merge(remote.deletedItems, uniquingKeysWith: max)
            deletedBoards.merge(remote.deletedBoards, uniquingKeysWith: max)
        }

        // 項目: 同じ ID なら、最後に変えたほうを使う
        var chosen = Dictionary(store.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var modified = state.items.mapValues(\.modified)
        var incoming: [UUID: Stamp] = [:]
        var stillMissing: [UUID: Date] = [:]
        for remote in remotes {
            for entry in remote.items {
                var item = entry.item
                let id = item.id
                if let date = deletedItems[id], date >= entry.modified { continue }
                if chosen[id] != nil, let date = modified[id], date >= entry.modified { continue }
                // 画像・丸ごとのデータがまだ届いていなければ次の回に
                // 待っても届かなければ、丸ごとのデータはなしで取り込む（画像が届かない画像は取り込まない）
                let missingImage = item.imageName.map { !fm.fileExists(atPath: imagesDir.appendingPathComponent($0).path) } ?? false
                let missingRaw = item.rawName.map { !fm.fileExists(atPath: rawDir.appendingPathComponent($0).path) } ?? false
                if missingImage || missingRaw {
                    let since = missingSince[id] ?? now
                    if now.timeIntervalSince(since) < Self.missingFileWait {
                        stillMissing[id] = since
                        continue
                    }
                    if missingImage { continue }
                    item.rawName = nil
                    item.rawSize = nil
                }
                chosen[id] = item
                modified[id] = entry.modified
                // 取り込んだ形のハッシュを覚える（この Mac で変えたことにならないように）
                incoming[id] = Stamp(hash: Self.digest(item), modified: entry.modified)
            }
        }
        // 読み直すのは取り込めなかったものがあるときだけなので、今回読んだ分でまるごと置き換えてよい
        missingSince = stillMissing
        for (id, date) in deletedItems where (modified[id] ?? .distantPast) <= date {
            chosen[id] = nil
        }

        // ピンボード: 項目と同じく、最後に変えたほうを使う
        var boards = Dictionary(store.pinboards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var boardModified = state.boards.mapValues(\.modified)
        var boardOrders: [UUID: [UUID]] = [:]
        var incomingBoards: [UUID: Stamp] = [:]
        for remote in remotes {
            for entry in remote.boards {
                let id = entry.board.id
                if let date = deletedBoards[id], date >= entry.modified { continue }
                if boards[id] != nil, let date = boardModified[id], date >= entry.modified { continue }
                boards[id] = entry.board
                boardModified[id] = entry.modified
                boardOrders[id] = entry.order
                incomingBoards[id] = Stamp(hash: Self.digest(entry.board, order: entry.order), modified: entry.modified)
            }
        }
        for (id, date) in deletedBoards where (boardModified[id] ?? .distantPast) <= date {
            boards[id] = nil
        }

        // タブの並びも、最後に並べ替えたほうを使う
        var tabOrder = store.pinboards.map(\.id)
        var tabOrderStamp = state.boardOrder
        for remote in remotes where remote.boardOrderModified > tabOrderStamp.modified {
            tabOrder = remote.boardOrder
            tabOrderStamp = Stamp(hash: Self.digest(remote.boardOrder), modified: remote.boardOrderModified)
        }
        var orderedBoards = tabOrder.compactMap { boards[$0] }
        orderedBoards += boards.values.filter { !tabOrder.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }

        // 2台で別々に作った同じ名前のピンボード（Paste から読み込んだ「よく使う」など）は、初めて出会ったときに1つにまとめる
        // どの Mac でも同じほうが残るように、ID の小さいほうに寄せる（この Mac の中で同じ名前にしたものはまとめない）
        let localBoards = Set(store.pinboards.map(\.id))
        var keeper: [String: UUID] = [:]
        var redirect: [UUID: UUID] = [:]
        for board in orderedBoards.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            if let id = keeper[board.name], !localBoards.contains(board.id) || !localBoards.contains(id) {
                redirect[board.id] = id
                deletedBoards[board.id] = now
            } else if keeper[board.name] == nil {
                keeper[board.name] = board.id
            }
        }
        orderedBoards.removeAll { redirect[$0.id] != nil }
        let boardIDs = Set(orderedBoards.map(\.id))
        if !redirect.isEmpty {
            Preferences.autoRules = Preferences.autoRules.map { rule in
                var rule = rule
                if let board = rule.board, let to = redirect[board] { rule.board = to }
                return rule
            }
        }

        // 消えたピンボードの項目は除き、まとめたピンボードの項目は残すほうへ移す
        for (id, item) in chosen {
            guard let board = item.pinboardID else { continue }
            if let to = redirect[board] {
                chosen[id]?.pinboardID = to
            } else if !boardIDs.contains(board) {
                chosen[id] = nil
            }
        }

        // 同じ場所に同じ内容が重なったら（ユニバーサルクリップボードで両方の Mac が記録したものなど）1つにする
        // 新しいほうを残し、同じなら ID の小さいほう（どの Mac でも同じほうが残るように）
        var bySignature: [String: ClipItem] = [:]
        for item in chosen.values {
            let key = (item.pinboardID?.uuidString ?? "") + "\n" + item.signature
            guard let other = bySignature[key] else {
                bySignature[key] = item
                continue
            }
            let keep = (item.date, other.id.uuidString) > (other.date, item.id.uuidString) ? item : other
            let drop = keep.id == item.id ? other : item
            bySignature[key] = keep
            chosen[drop.id] = nil
            deletedItems[drop.id] = now
        }

        // 並べる: 履歴は新しい順、ピンボードの中はそのピンボードを最後に変えた Mac での並び
        let localOrder = Dictionary(store.items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var newItems = chosen.values.filter { $0.pinboardID == nil }
            .sorted { ($0.date, $1.id.uuidString) > ($1.date, $0.id.uuidString) }
        for board in orderedBoards {
            let members = chosen.values.filter { $0.pinboardID == board.id }
            let order = boardOrders[board.id].map { ids in
                Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            } ?? localOrder
            newItems += members.sorted { a, b in
                let x = order[a.id] ?? Int.max, y = order[b.id] ?? Int.max
                return x != y ? x < y : (a.date, a.id.uuidString) < (b.date, b.id.uuidString)
            }
        }

        // 取り込んだものは、ほかの Mac で変えた時刻のまま覚えておく（この Mac で変えたことにしない）
        state.deletedItems = deletedItems
        state.deletedBoards = deletedBoards
        for (id, stamp) in incoming { state.items[id] = stamp }
        for (id, stamp) in incomingBoards { state.boards[id] = stamp }
        state.boardOrder = tabOrderStamp
        let keptItems = Set(newItems.map(\.id))
        state.items = state.items.filter { keptItems.contains($0.key) }
        state.boards = state.boards.filter { boardIDs.contains($0.key) }
        saveState()

        guard newItems != store.items || orderedBoards != store.pinboards else { return false }
        store.replaceForSync(items: newItems, pinboards: orderedBoards)
        return true
    }

    // MARK: - 書き出す

    /// この Mac の中身を iCloud に書き出す（画像・丸ごとのデータを先に置いてから、一覧のファイルを書く）
    private func export() async throws {
        refreshStamps()
        let snapshot = Snapshot(
            device: SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac",
            items: store.items.map { SyncedItem(item: $0, modified: state.items[$0.id]?.modified ?? $0.date) },
            boards: store.pinboards.map { board in
                SyncedBoard(board: board, order: store.items.filter { $0.pinboardID == board.id }.map(\.id),
                            modified: state.boards[board.id]?.modified ?? Date())
            },
            boardOrder: store.pinboards.map(\.id), boardOrderModified: state.boardOrder.modified,
            deletedItems: state.deletedItems, deletedBoards: state.deletedBoards)

        let folder = Self.folder, own = deviceID, local = store.dataDirectory, previous = lastWritten
        // ほかの Mac のファイルを全部読めていれば、どこからも使われなくなった古い画像などを1時間に1回消す
        let cleanup = Date().timeIntervalSince(lastCleanup) > 3600 && missingSince.isEmpty
        let keep = cleanup ? remoteFiles.values.reduce(snapshot.fileNames) { $0.union($1) } : nil
        let readFiles = Set(readDates.keys)

        let written = try await Task.detached {
            try Self.write(snapshot, folder: folder, own: own, local: local, previous: previous,
                           keep: keep, readFiles: readFiles)
        }.value
        lastWritten = written
        if cleanup { lastCleanup = Date() }
    }

    private nonisolated static func write(_ snapshot: Snapshot, folder: URL, own: String, local: URL, previous: Data?,
                                          keep: Set<String>?, readFiles: Set<String>) throws -> Data {
        let fm = FileManager.default
        var snapshot = snapshot
        for sub in ["devices", "images", "raw"] {
            try fm.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        for idx in snapshot.items.indices {
            let item = snapshot.items[idx].item
            if let name = item.imageName {
                upload(local.appendingPathComponent("images").appendingPathComponent(name),
                       to: folder.appendingPathComponent("images").appendingPathComponent(name))
            }
            // この Mac にない丸ごとのデータは、ないものとして書く（ほかの Mac が届くのを待ち続けないように）
            if let name = item.rawName,
               !upload(local.appendingPathComponent("raw").appendingPathComponent(name),
                       to: folder.appendingPathComponent("raw").appendingPathComponent(name)) {
                snapshot.items[idx].item.rawName = nil
                snapshot.items[idx].item.rawSize = nil
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(snapshot)
        let url = folder.appendingPathComponent("devices").appendingPathComponent(own + ".json")
        if data != previous || !fm.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }

        if let keep {
            // 書いている途中のものを消さないように、3日以上前のものだけ
            let devices = (try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent("devices").path)) ?? []
            let others = Set(devices.filter { $0.hasSuffix(".json") && $0 != own + ".json" })
            if others.isSubset(of: readFiles) {
                let limit = Date().addingTimeInterval(-3 * 86_400)
                for sub in ["images", "raw"] {
                    let dir = folder.appendingPathComponent(sub)
                    for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                            options: [.skipsHiddenFiles])) ?? []
                    where !keep.contains(url.lastPathComponent) {
                        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                        if let date, date < limit { try? fm.removeItem(at: url) }
                    }
                }
            }
        }
        return data
    }

    /// この Mac のファイルを iCloud に置く（同じ名前があれば中身も同じなので何もしない）。この Mac にファイルがなければ false
    @discardableResult
    private nonisolated static func upload(_ source: URL, to dest: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return false }
        if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: source, to: dest) }
        return true
    }

    // MARK: - 変えた時刻

    /// 前に見たときから中身が変わった項目・ピンボードに、今の時刻を付ける。なくなったものは消した記録にする
    private func refreshStamps() {
        let now = Date()
        var seen = Set<UUID>()
        for item in store.items {
            seen.insert(item.id)
            let hash = Self.digest(item)
            if let stamp = state.items[item.id] {
                if stamp.hash != hash { state.items[item.id] = Stamp(hash: hash, modified: now) }
            } else {
                // 初めて見る項目は、コピーした時刻を変えた時刻にする
                state.items[item.id] = Stamp(hash: hash, modified: min(item.date, now))
            }
        }
        for id in state.items.keys where !seen.contains(id) {
            state.items[id] = nil
            state.deletedItems[id] = now
        }

        var seenBoards = Set<UUID>()
        for board in store.pinboards {
            seenBoards.insert(board.id)
            let hash = Self.digest(board, order: store.items.filter { $0.pinboardID == board.id }.map(\.id))
            if state.boards[board.id]?.hash != hash { state.boards[board.id] = Stamp(hash: hash, modified: now) }
        }
        for id in state.boards.keys where !seenBoards.contains(id) {
            state.boards[id] = nil
            state.deletedBoards[id] = now
        }

        let tabHash = Self.digest(store.pinboards.map(\.id))
        if state.boardOrder.hash != tabHash { state.boardOrder = Stamp(hash: tabHash, modified: now) }

        let limit = now.addingTimeInterval(-Self.tombstoneDays * 86_400)
        state.deletedItems = state.deletedItems.filter { $0.value > limit }
        state.deletedBoards = state.deletedBoards.filter { $0.value > limit }
        saveState()
    }

    private func saveState() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    /// Mac 本体の番号（移行アシスタントで設定ごと移しても、別の Mac は別の ID になる）
    nonisolated static let hardwareID: String = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        if let uuid = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String {
            return uuid
        }
        if let id = UserDefaults.standard.string(forKey: "syncDeviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "syncDeviceID")
        return id
    }()

    private static func digest(_ item: ClipItem) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return hash((try? encoder.encode(item)) ?? Data())
    }

    private static func digest(_ board: Pinboard, order: [UUID]) -> String {
        hash(Data((board.name + "\n" + board.color.hexColor + "\n" + order.map(\.uuidString).joined(separator: ",")).utf8))
    }

    private static func digest(_ ids: [UUID]) -> String {
        hash(Data(ids.map(\.uuidString).joined(separator: ",").utf8))
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 保存の形

    /// 中身を最後に見たときのハッシュと、そのとき変わっていたら付けた時刻
    struct Stamp: Codable {
        var hash: String
        var modified: Date
    }

    /// この Mac で覚えておく同期の状態（Copipe のフォルダの sync.json）
    struct State: Codable {
        var items: [UUID: Stamp] = [:]
        var boards: [UUID: Stamp] = [:]
        var boardOrder = Stamp(hash: "", modified: .distantPast)
        var deletedItems: [UUID: Date] = [:]
        var deletedBoards: [UUID: Date] = [:]
    }

    struct SyncedItem: Codable {
        var item: ClipItem
        var modified: Date
    }

    struct SyncedBoard: Codable {
        var board: Pinboard
        /// ピンボードの中の並び
        var order: [UUID]
        var modified: Date
    }

    /// 1台の Mac が iCloud に書く中身（devices/<Mac の ID>.json）
    struct Snapshot: Codable {
        var device: String
        var items: [SyncedItem]
        var boards: [SyncedBoard]
        var boardOrder: [UUID]
        var boardOrderModified: Date
        var deletedItems: [UUID: Date]
        var deletedBoards: [UUID: Date]

        /// 使っている画像・丸ごとのデータの名前
        var fileNames: Set<String> {
            Set(items.flatMap { [$0.item.imageName, $0.item.rawName].compactMap { $0 } })
        }
    }

    private struct Remote {
        var file: String
        var date: Date
        var snapshot: Snapshot
    }
}
