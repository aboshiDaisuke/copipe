import AppKit
@preconcurrency import LinkPresentation

/// リンク先のページの題名と画像（Paste のリンクプレビューと同じ）。取ってきたものはファイルに残す
@MainActor
final class LinkPreviews: ObservableObject {
    static let shared = LinkPreviews()

    struct Entry: Codable {
        var title: String?
        var imageName: String?
        /// サイトのアイコン（ページの画像が取れないときにカードに出す）
        var iconName: String?
        /// 取ったときの取り方の版（古い取り方で画像がなかったものは取り直す）
        var version: Int?
    }

    /// 取り方の版。2 からサイトのアイコンも取る
    private static let version = 2

    @Published private(set) var entries: [String: Entry] = [:]
    /// このあいだに取りに行ったもの（失敗したものを何度も取りに行かない）
    private var requested: Set<String> = []
    private var images: [String: NSImage] = [:]
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
        guard Preferences.linkPreviews else { return nil }
        return loadImage(entries[link]?.imageName)
    }

    /// サイトのアイコン（ページの画像がないときに出す）
    func icon(for link: String) -> NSImage? {
        guard Preferences.linkPreviews else { return nil }
        return loadImage(entries[link]?.iconName)
    }

    private func loadImage(_ name: String?) -> NSImage? {
        guard let name else { return nil }
        if let cached = images[name] { return cached }
        let image = NSImage(contentsOf: dir.appendingPathComponent(name))
        images[name] = image
        return image
    }

    func request(_ link: String) {
        // 取ってあるものは取りに行かない（古い取り方で画像がなかったものだけ、アイコンを取りに行き直す）
        if let entry = entries[link], entry.imageName != nil || (entry.version ?? 1) >= Self.version { return }
        guard Preferences.linkPreviews, !requested.contains(link),
              let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        requested.insert(link)
        Task {
            let provider = LPMetadataProvider()
            provider.timeout = 10
            let metadata = try? await provider.startFetchingMetadata(for: url)
            let image = await Self.loadImage(from: metadata?.imageProvider)?.jpegData(maxWidth: 640)
            // ページの画像がない（公開前の動画・ログインが要るページなど）ときは、サイトのアイコンを出す
            let icon = image == nil ? await Self.siteIcon(of: url, fallback: metadata?.iconProvider) : nil
            // 何も取れなかったら何も残さない（次に起動したときにもう一度取りに行く）
            guard metadata != nil || icon != nil else { return }
            save(link, title: Self.cleaned(metadata?.title), image: image, icon: icon)
        }
    }

    /// サイトのアイコン（PNG）。LinkPresentation のアイコンは 16px と小さいことが多いので、
    /// ページに書いてある一番大きいアイコンを取りに行く
    private static func siteIcon(of page: URL, fallback: NSItemProvider?) async -> Data? {
        let small = await loadImage(from: fallback).flatMap(largestPNG)
        if let small, small.width >= 48 { return small.png }
        guard let iconURL = await declaredIconURL(of: page),
              let (data, response) = try? await URLSession.shared.data(from: iconURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let icon = NSImage(data: data).flatMap(largestPNG) else { return small?.png }
        return icon.width >= (small?.width ?? 0) ? icon.png : small?.png
    }

    /// ページの <link rel="icon" sizes="144x144" href="…"> などから、一番大きいアイコンの場所
    private static func declaredIconURL(of page: URL) async -> URL? {
        var request = URLRequest(url: page, timeoutInterval: 10)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
                         + "Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let html = String(decoding: data.prefix(500_000), as: UTF8.self)
        let base = response.url ?? page
        var best: (size: Int, url: URL)?
        for tag in matches(#"<link\b[^>]*>"#, in: html) {
            var attributes: [String: String] = [:]
            for pair in matchGroups(#"([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#, in: tag) {
                attributes[pair[0].lowercased()] = pair[1]
            }
            guard let rel = attributes["rel"]?.lowercased(), rel.contains("icon"),
                  let href = attributes["href"], let url = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
            // 大きさが書いていなければ、apple-touch-icon は 180px、それ以外は小さいものとみなす
            let size = attributes["sizes"].flatMap { Int($0.lowercased().split(separator: "x").first ?? "") }
                ?? (rel.contains("apple-touch-icon") ? 180 : 16)
            if size > (best?.size ?? -1) { best = (size, url) }
        }
        return best?.url
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// 1つ目の () と、2つ目か3つ目の () の中身
    private static func matchGroups(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            func group(_ i: Int) -> String? { Range(match.range(at: i), in: text).map { String(text[$0]) } }
            guard let name = group(1), let value = group(2) ?? group(3) else { return nil }
            return [name, value]
        }
    }

    /// いくつかの大きさが入った画像（.ico など）から、一番大きいものを PNG にする
    private static func largestPNG(_ image: NSImage) -> (png: Data, width: Int)? {
        let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        if let rep = reps.max(by: { $0.pixelsWide < $1.pixelsWide }),
           let png = rep.representation(using: .png, properties: [:]) {
            return (png, rep.pixelsWide)
        }
        return image.pngData().map { ($0, Int(image.pixelSize.width)) }
    }

    private static func loadImage(from provider: NSItemProvider?) async -> NSImage? {
        guard let provider, provider.canLoadObject(ofClass: NSImage.self) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSImage.self) { object, _ in
                continuation.resume(returning: object as? NSImage)
            }
        }
    }

    /// 公開前の YouTube の動画などは、題名が「- YouTube」のようにサイト名だけになるので、それは使わない
    private static func cleaned(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              !title.hasPrefix("- "), !title.hasPrefix("| ") else { return nil }
        return title
    }

    private func save(_ link: String, title: String?, image: Data?, icon: Data?) {
        if let old = entries[link] { removeFiles(of: old) }
        var entry = Entry(title: title, version: Self.version)
        entry.imageName = write(image, ext: "jpg")
        // アイコンはページの画像がないときにだけ使う
        if entry.imageName == nil { entry.iconName = write(icon, ext: "png") }
        entries[link] = entry
        saveIndex()
    }

    /// 画像をファイルに書いて、その名前を返す
    private func write(_ data: Data?, ext: String) -> String? {
        guard let data, data.count < 2_000_000 else { return nil }
        let name = UUID().uuidString + "." + ext
        return (try? data.write(to: dir.appendingPathComponent(name))) != nil ? name : nil
    }

    private func removeFiles(of entry: Entry) {
        for name in [entry.imageName, entry.iconName].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            images[name] = nil
        }
    }

    /// links に入っていないリンクの題名・画像を消す
    func prune(keeping links: Set<String>) {
        let removed = entries.keys.filter { !links.contains($0) }
        guard !removed.isEmpty else { return }
        for link in removed {
            if let entry = entries[link] { removeFiles(of: entry) }
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
