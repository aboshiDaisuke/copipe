import AppKit

MainActor.assumeIsolated {
    if CommandLine.arguments.contains(SuggestionTest.flag) { SuggestionTest.run(arguments: CommandLine.arguments) }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
