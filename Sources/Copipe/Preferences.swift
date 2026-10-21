import AppKit

/// 設定画面の項目（Paste の設定と同じもの）
enum Preferences {
    private static let defaults = UserDefaults.standard

    private static func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }

    /// 選んだ項目を前面のアプリに貼り付ける（false ならクリップボードに入れるだけ）
    static var pasteToActiveApp: Bool {
        get { bool("pasteToActiveApp", default: true) }
        set { defaults.set(newValue, forKey: "pasteToActiveApp") }
    }

    /// 常に書式なしの文字で貼り付ける（shift + return で書式付きになる）
    static var alwaysPlainText: Bool {
        get { bool("alwaysPlainText", default: false) }
        set { defaults.set(newValue, forKey: "alwaysPlainText") }
    }

    /// パスワード管理アプリなどが「機密」と付けたコピーを保存しない
    static var ignoreConfidential: Bool {
        get { bool("ignoreConfidential", default: true) }
        set { defaults.set(newValue, forKey: "ignoreConfidential") }
    }

    /// 他のアプリが一時的に作ったコピーを保存しない
    static var ignoreTransient: Bool {
        get { bool("ignoreTransient", default: true) }
        set { defaults.set(newValue, forKey: "ignoreTransient") }
    }

    /// リンク先のページの題名と画像を取ってくる
    static var linkPreviews: Bool {
        get { bool("linkPreviews", default: true) }
        set { defaults.set(newValue, forKey: "linkPreviews") }
    }

    /// コピー・貼り付けのときに音を鳴らす
    static var soundEffects: Bool {
        get { bool("soundEffects", default: false) }
        set { defaults.set(newValue, forKey: "soundEffects") }
    }

    static var showMenuBarIcon: Bool {
        get { bool("showMenuBarIcon", default: true) }
        set { defaults.set(newValue, forKey: "showMenuBarIcon") }
    }

    /// コピーしても保存しないアプリ（bundle ID）
    static var ignoredApps: [String] {
        get { defaults.stringArray(forKey: "ignoredApps") ?? [] }
        set { defaults.set(newValue, forKey: "ignoredApps") }
    }
}

/// 効果音（設定でオンにしたときだけ鳴らす）
@MainActor
enum Sound {
    static func copied() { play("Tink") }
    static func pasted() { play("Pop") }

    private static func play(_ name: String) {
        guard Preferences.soundEffects else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
