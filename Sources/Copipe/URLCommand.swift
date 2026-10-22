import Foundation

/// copipe:// のリンクで外から Copipe を動かす（ショートカット App の「URL を開く」などから使う）
///
/// - copipe://open（?pinboard=名前）: 履歴（そのピンボード）を開く
/// - copipe://add?text=文字（&pinboard=名前）: 文字を履歴に入れる。ピンボードの名前があればそこにも入れる（なければ作る）
/// - copipe://pause（?minutes=分）: 記録を一時停止する（分がなければ再開するまで）
/// - copipe://resume: 記録を再開する
/// - copipe://stack: ペーストスタックを始める / 終える
///
/// 中身を読み出す命令は作らない（どのアプリやページからでも開けるリンクなので）
struct URLCommand {
    static let scheme = "copipe"

    enum Action: String {
        case open, add, pause, resume, stack
    }

    let action: Action
    let text: String?
    let pinboard: String?
    let minutes: Double?

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // copipe://add と copipe:add のどちらでも受け付ける
        let name = (url.host ?? components.path).lowercased()
        guard let action = name.isEmpty ? .open : Action(rawValue: name) else { return nil }
        let query = components.queryItems ?? []
        func value(_ key: String) -> String? {
            query.first { $0.name == key }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        self.action = action
        text = value("text")
        pinboard = value("pinboard")
        minutes = value("minutes").flatMap(Double.init)
    }
}
