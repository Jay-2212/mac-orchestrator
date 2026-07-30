import AppKit

@MainActor
final class MenuController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let supervisor: ProcessSupervisor
    private var snapshot = ServiceSnapshot()

    init(supervisor: ProcessSupervisor) {
        self.supervisor = supervisor
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Mac Orchestrator")
        statusItem.button?.imagePosition = .imageOnly
        supervisor.onSnapshot = { [weak self] snapshot in
            self?.snapshot = snapshot
            self?.rebuildMenu()
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(label("Server: \(snapshot.server.rawValue)"))
        menu.addItem(label("Tunnel: \(snapshot.tunnel.rawValue)"))
        if let error = snapshot.error {
            menu.addItem(label("Error: \(String(error.prefix(70)))"))
        }
        if let url = snapshot.connectorURL {
            menu.addItem(label("URL: \(url.host ?? "Available")"))
            menu.addItem(action("Copy Connector URL", #selector(copyURL)))
        } else {
            menu.addItem(label("Connector URL unavailable"))
        }
        menu.addItem(.separator())

        if snapshot.server == .stopped || snapshot.server == .failed {
            menu.addItem(action("Start Server", #selector(startServer)))
        } else {
            menu.addItem(action("Stop Server", #selector(stopServer)))
        }
        if snapshot.tunnel == .running || snapshot.tunnel == .starting || snapshot.tunnel == .reconnecting {
            menu.addItem(action("Disable Public Connector", #selector(disableConnector)))
        } else {
            menu.addItem(action("Enable Public Connector", #selector(enableConnector)))
        }
        menu.addItem(action("Restart", #selector(restart)))
        menu.addItem(.separator())
        menu.addItem(action("Open Logs", #selector(openLogs)))
        menu.addItem(label("Launch at Login: Enabled"))
        menu.addItem(.separator())
        menu.addItem(action("Quit Mac Orchestrator", #selector(quit)))
        statusItem.menu = menu

        let color: NSColor
        if snapshot.error != nil || snapshot.server == .failed || snapshot.tunnel == .failed {
            color = .systemRed
        } else if snapshot.server == .starting || snapshot.server == .stopping ||
                    snapshot.tunnel == .starting || snapshot.tunnel == .reconnecting {
            color = .systemYellow
        } else if snapshot.server == .running {
            color = snapshot.tunnel == .running ? .systemGreen : .systemBlue
        } else {
            color = .systemGray
        }
        statusItem.button?.contentTintColor = color
    }

    private func label(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func copyURL() {
        guard let url = snapshot.connectorURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc private func startServer() { supervisor.startServerRequested() }
    @objc private func stopServer() { supervisor.stopServerRequested() }
    @objc private func enableConnector() { supervisor.enableConnectorRequested() }
    @objc private func disableConnector() { supervisor.disableConnectorRequested() }
    @objc private func restart() { supervisor.restartRequested() }
    @objc private func openLogs() { supervisor.openLogs() }
    @objc private func quit() { NSApp.terminate(nil) }
}
