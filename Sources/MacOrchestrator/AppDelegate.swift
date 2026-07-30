import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var supervisor: ProcessSupervisor?
    private var menuController: MenuController?
    private var lockDescriptor: Int32 = -1

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
