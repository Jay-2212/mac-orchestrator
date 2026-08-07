import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var supervisor: ProcessSupervisor?
    private var menuController: MenuController?
    private var lockDescriptor: Int32 = -1
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard acquireSingletonLock() else {
            NSApp.terminate(nil)
            return
        }
        do {
            let supervisor = try ProcessSupervisor()
            self.supervisor = supervisor
            menuController = MenuController(supervisor: supervisor)
            NSWorkspace.shared.notificationCenter.addObserver(
                self,
                selector: #selector(didWake),
                name: NSWorkspace.didWakeNotification,
                object: nil
            )
            // A raw SIGTERM (launchctl bootout/stop, `kill <pid>`) does not go
            // through AppKit's normal quit path, so applicationWillTerminate
            // would never fire and owned children (server, tunnel) would be
            // orphaned instead of cleaned up. Route SIGTERM through
            // NSApp.terminate so shutdown is always graceful regardless of how
            // it's requested.
            let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signal(SIGTERM, SIG_IGN)
            sigtermSource = source
            supervisor.launch()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Mac Orchestrator could not start"
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        supervisor?.stopForQuit()
        if lockDescriptor >= 0 {
            flock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
        }
    }

    @objc private func didWake() {
        supervisor?.handleWake()
    }

    private func acquireSingletonLock() -> Bool {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let directory = library
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Mac Orchestrator", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("supervisor.lock").path
        lockDescriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        return lockDescriptor >= 0 && flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0
    }
}
