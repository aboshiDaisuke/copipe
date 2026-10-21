import Carbon.HIToolbox
import Foundation

/// 履歴を開くショートカットの候補
enum Shortcut: String, CaseIterable {
    case controlCommandV
    case shiftCommandV
    case optionCommandV
    case shiftOptionCommandV

    var title: String {
        switch self {
        case .controlCommandV: "⌃⌘V"
        case .shiftCommandV: "⇧⌘V"
        case .optionCommandV: "⌥⌘V"
        case .shiftOptionCommandV: "⇧⌥⌘V"
        }
    }

    var modifiers: Int {
        switch self {
        case .controlCommandV: controlKey | cmdKey
        case .shiftCommandV: shiftKey | cmdKey
        case .optionCommandV: optionKey | cmdKey
        case .shiftOptionCommandV: shiftKey | optionKey | cmdKey
        }
    }

    var keyCode: Int { kVK_ANSI_V }

    private static let defaultsKey = "shortcut"

    static var current: Shortcut {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(Shortcut.init(rawValue:)) ?? .controlCommandV }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}
