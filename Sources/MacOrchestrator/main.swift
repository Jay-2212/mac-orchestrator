import AppKit
import Darwin

if let exitCode = await TerminalCommand.runAsync(arguments: Array(CommandLine.arguments.dropFirst())) {
    exit(exitCode)
}

await MainActor.run {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
