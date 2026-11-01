import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 前面のアプリに ⌘V（ターミナルへの画像は ⌃V）を送って貼り付ける（アクセシビリティ許可が必要）
enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Copipe が送った ⌘V に付ける印（ペーストスタックが自分の貼り付けを数えないように）
    private static let marker: Int64 = 0x4350_5045

    static func isSynthetic(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == marker
    }

    /// ターミナルのアプリ。この中の Claude Code などは、画像を ⌘V ではなく ⌃V で受け取る
    /// （VS Code はエディタにも同じ ⌘V が届き、ターミナルかどうか見分けられないので入れない）
    private static let terminalApps: Set<String> = [
        "com.mitchellh.ghostty",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "org.alacritty",
        "net.kovidgoyal.kitty",
    ]

    /// 貼るのが画像だけで、貼る先がターミナルなら ⌃V にする
    static func usesControlV(for items: [ClipItem], into app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier, terminalApps.contains(id) else { return false }
        return !items.isEmpty && items.allSatisfy { $0.kind == .image }
    }

    /// 貼り付けのキーを送る。control が true なら ⌃V、そうでなければ ⌘V
    static func sendPaste(control: Bool = false) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        let flags: CGEventFlags = control ? .maskControl : .maskCommand
        down?.flags = flags
        up?.flags = flags
        down?.setIntegerValueField(.eventSourceUserData, value: marker)
        up?.setIntegerValueField(.eventSourceUserData, value: marker)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// ほかのアプリでコピーしたものを読む許可（macOS 15.4 から。「許可」にしておかないと、コピーを記録するたびに確認が出る）
enum PasteboardAccess {
    /// システム設定の「ほかのアプリからペースト」で「許可」になっている
    static var isAllowed: Bool {
        guard #available(macOS 15.4, *) else { return true }
        return NSPasteboard.general.accessBehavior == .alwaysAllow
    }

    /// 一度確認が出て、システム設定に Copipe が並んでいるのに「許可」になっていない
    static var needsAllow: Bool {
        guard #available(macOS 15.4, *) else { return false }
        return [.ask, .alwaysDeny].contains(NSPasteboard.general.accessBehavior)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard") {
            NSWorkspace.shared.open(url)
        }
    }
}
