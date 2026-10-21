import AppKit
@preconcurrency import LinkPresentation

/// リンク先のページの題名と画像（Paste のリンクプレビューと同じ）。取ってきたものはファイルに残す
@MainActor
final class LinkPreviews: ObservableObject {
    static let shared = LinkPreviews()

    struct Entry: Codable {
        var title: String?
        var imageName: String?
    }

    @Published private(set) var entries: [String: Entry] = [:]
    /// このあいだに取りに行ったもの（失敗したものを何度も取りに行かない）
    private var requested: Set<String> = []
    private var images: [String: NSImage] = [:]
    /// 取り終わるまで手放さないように持っておく
    private var providers: [String: LPMetadataProvider] = [:]
    private let dir: URL
    private let indexURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = support.appendingPathComponent("Copipe/links", isDirectory: true)
        indexURL = dir.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    func title(for link: String) -> String? {
        Preferences.linkPreviews ? entries[link]?.title : nil
    }

    func image(for link: String) -> NSImage? {
        guard Preferences.linkPreviews, let name = entries[link]?.imageName else { return nil }
        if let cached = images[name] { return cached }
        let image = NSImage(contentsOf: dir.appendingPathComponent(name))
        images[name] = image
        return image
    }

    func request(_ link: String) {
        guard Preferences.linkPreviews, entries[link] == nil, !requested.contains(link),
              let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        requested.insert(link)
        let provider = LPMetadataProvider()
        provider.timeout = 10
        providers[link] = provider
        provider.startFetchingMetadata(for: url) { metadata, _ in
            guard let metadata else {
                Task { @MainActor in self.providers[link] = nil }
                return
            }
            let title = metadata.title
            guard let imageProvider = metadata.imageProvider else {
                Task { @MainActor in self.save(link, title: title, image: nil) }
                return
            }
            imageProvider.loadObject(ofClass: NSImage.self) { object, _ in
                let data = (object as? NSImage)?.jpegData(maxWidth: 640)
                Task { @MainActor in self.save(link, title: title, image: data) }
            }
        }
    }

    private func save(_ link: String, title: String?, image: Data?) {
        providers[link] = nil
        var entry = Entry(title: title)
        if let image {
            let name = UUID().uuidString + ".jpg"
            if (try? image.write(to: dir.appendingPathComponent(name))) != nil { entry.imageName = name }
        }
        entries[link] = entry
        saveIndex()
    }

    /// links に入っていないリンクの題名・画像を消す
    func prune(keeping links: Set<String>) {
        let removed = entries.keys.filter { !links.contains($0) }
        guard !removed.isEmpty else { return }
        for link in removed {
            if let name = entries[link]?.imageName {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
                images[name] = nil
            }
            entries[link] = nil
            requested.remove(link)
        }
        saveIndex()
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: indexURL, options: .atomic) }
    }
}

extension NSImage {
    /// 幅を maxWidth までに縮めた JPEG
    func jpegData(maxWidth: CGFloat) -> Data? {
        let size = pixelSize
        let scale = min(1, maxWidth / max(size.width, 1))
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
    }
}
