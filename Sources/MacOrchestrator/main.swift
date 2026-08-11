import AppKit
import Darwin

if let exitCode = TerminalCommand.run(arguments: Array(CommandLine.arguments.dropFirst())) {
    exit(exitCode)
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
