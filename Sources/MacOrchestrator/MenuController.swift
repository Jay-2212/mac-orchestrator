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
        for title in Self.runtimeStatusTitles(for: snapshot) {
            menu.addItem(label(title))
        }
        menu.addItem(.separator())

        if snapshot.server == .stopped || snapshot.server == .failed {
            menu.addItem(action("Start Local Automation", #selector(startServer)))
        } else {
            menu.addItem(action("Stop Local Automation", #selector(stopServer)))
        }
        if snapshot.tunnel == .running || snapshot.tunnel == .starting || snapshot.tunnel == .reconnecting {
            menu.addItem(action("Disable Optional Remote Access", #selector(disableConnector)))
        } else {
            menu.addItem(action("Enable Optional Remote Access", #selector(enableConnector)))
        }
        menu.addItem(action("Run Doctor", #selector(runDoctor)))
        menu.addItem(action("Repair Primary Failure", #selector(repairPrimaryFailure)))
        menu.addItem(action("Restart Services", #selector(restart)))
        menu.addItem(.separator())
        menu.addItem(action("Support Bundle Preview", #selector(previewSupportBundle)))
        menu.addItem(action("Create Redacted Support Bundle", #selector(createSupportBundle)))
        menu.addItem(action("Check for Authenticated Updates", #selector(checkForUpdates)))
        menu.addItem(action("Apply Authenticated Update…", #selector(applyUpdate)))
        menu.addItem(action("Open Logs", #selector(openLogs)))
        menu.addItem(action("Open Privacy & Security Settings", #selector(openPrivacySettings)))
        menu.addItem(action("Plan Removal…", #selector(planUninstall)))
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

    static func runtimeStatusTitles(for snapshot: ServiceSnapshot) -> [String] {
        let readiness: String
        switch snapshot.productReadiness {
        case .ready: readiness = "Ready"
        case .partiallyReady: readiness = "Partially ready"
        case .needsAttention: readiness = "Needs attention"
        }
        let local = snapshot.server == .running ? "Running" : snapshot.server.rawValue
        let remote: String
        switch snapshot.tunnel {
        case .running: remote = "Ready"
        case .stopped: remote = "Optional and disabled"
        default: remote = snapshot.tunnel.rawValue
        }
        var titles = [
            "Readiness: \(readiness)",
            "Local automation: \(local)",
            "Optional remote access: \(remote)",
        ]
        if let profile = snapshot.controlProfile {
            let profileName = profile == .guided ? "Guided Control" : "Full Control"
            titles.append("Profile: \(profileName)")
            titles.append(
                "Capabilities ready: \(snapshot.readyCapabilityCount)/\(snapshot.totalCapabilityCount)"
            )
            if !snapshot.pendingPermissions.isEmpty {
                titles.append("Permissions pending: \(snapshot.pendingPermissions.joined(separator: ", "))")
            }
        }
        if let error = snapshot.error {
            titles.append("Error: \(String(error.prefix(70)))")
        }
        if snapshot.clientRefreshRequired {
            titles.append("MCP client refresh/reconnection required")
        }
        return titles
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

    @objc private func startServer() { supervisor.startServerRequested() }
    @objc private func stopServer() { supervisor.stopServerRequested() }
    @objc private func enableConnector() { supervisor.enableConnectorRequested() }
    @objc private func disableConnector() { supervisor.disableConnectorRequested() }
    @objc private func restart() { supervisor.restartRequested() }
    @objc private func runDoctor() { runTerminalCommandInBackground(["doctor"]) }
    @objc private func repairPrimaryFailure() {
        let action = snapshot.server == .failed ? "retryMCPServer" : "retryRemoteConnector"
        runTerminalCommandInBackground(["doctor", "--repair", action])
    }
    @objc private func previewSupportBundle() { runTerminalCommandInBackground(["support-bundle", "--preview"]) }
    @objc private func createSupportBundle() { runTerminalCommandInBackground(["support-bundle", "--create"]) }
    @objc private func checkForUpdates() { runTerminalCommandInBackground(["update", "--check"]) }
    @objc private func applyUpdate() {
        let alert = NSAlert()
        alert.messageText = "Apply authenticated update?"
        alert.informativeText = "Mac Orchestrator will stop its managed services, verify the release, and restore them after a successful update."
        alert.addButton(withTitle: "Apply Update")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runTerminalCommandInBackground(["update", "--apply"])
    }
    @objc private func planUninstall() { runTerminalCommandInBackground(["uninstall", "--plan"]) }
    @objc private func openLogs() { supervisor.openLogs() }
    @objc private func openPrivacySettings() { supervisor.openPrivacySettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func runTerminalCommandInBackground(_ arguments: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = TerminalCommand.run(arguments: arguments)
        }
    }
}
