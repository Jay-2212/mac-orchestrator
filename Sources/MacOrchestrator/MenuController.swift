import AppKit

@MainActor
final class MenuController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let supervisor: ProcessSupervisor
    private let operations: Phase3OperationCoordinator
    private var snapshot = ServiceSnapshot()

    init(
        supervisor: ProcessSupervisor,
        operations: Phase3OperationCoordinator = Phase3OperationCoordinator()
    ) {
        self.supervisor = supervisor
        self.operations = operations
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
        let copyConnectorURL = action("Copy Connector URL", #selector(copyConnectorURL))
        copyConnectorURL.isEnabled = snapshot.tunnel == .running
        menu.addItem(copyConnectorURL)
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
    @objc private func copyConnectorURL() {
        supervisor.copyConnectorURLRequested { [weak self] result in
            switch result {
            case let .success(classification):
                let details: String
                switch classification {
                case .unchanged:
                    details = "The current authenticated connector URL was copied. Existing client handoff is current."
                case .changed, .notAvailable:
                    details = "The current authenticated connector URL was copied. Give it only to a trusted client."
                }
                self?.show(message: "Connector URL copied", details: details)
            case .failure:
                self?.showFailure()
            }
        }
    }
    @objc private func restart() { supervisor.restartRequested() }
    @objc private func runDoctor() {
        let operations = self.operations
        Task.detached {
            do {
                let result = try await operations.runDoctor()
                await MainActor.run { [weak self] in
                    self?.show(message: "Doctor", details: Self.doctorFeedback(for: result))
                }
            } catch {
                await MainActor.run { [weak self] in self?.showFailure() }
            }
        }
    }

    @objc private func repairPrimaryFailure() {
        let operations = self.operations
        Task.detached {
            do {
                let doctor = try await operations.runDoctor()
                await MainActor.run { [weak self] in
                    self?.confirmPrimaryRepair(doctor, operations: operations)
                }
            } catch {
                await MainActor.run { [weak self] in self?.showFailure() }
            }
        }
    }

    @objc private func previewSupportBundle() {
        let operations = self.operations
        Task.detached {
            do {
                let result = try await operations.previewSupportBundle()
                await MainActor.run { [weak self] in
                    self?.show(message: "Support Bundle Preview", details: Self.supportPreviewFeedback(for: result))
                }
            } catch {
                await MainActor.run { [weak self] in self?.showFailure() }
            }
        }
    }

    @objc private func createSupportBundle() {
        let operations = self.operations
        Task.detached {
            do {
                let result = try await operations.createSupportBundle()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.show(message: "Support Bundle Created", details: Self.supportCreationFeedback(for: result))
                    NSWorkspace.shared.activateFileViewerSelecting([result.archiveURL])
                }
            } catch {
                await MainActor.run { [weak self] in self?.showFailure() }
            }
        }
    }

    @objc private func checkForUpdates() {
        let operations = self.operations
        Task.detached {
            do {
                let result = try operations.checkForUpdates()
                await MainActor.run { [weak self] in
                    self?.show(message: "Authenticated Updates", details: Self.updateFeedback(for: result))
                }
            } catch {
                await MainActor.run { [weak self] in self?.showFailure() }
            }
        }
    }

    @objc private func applyUpdate() {
        let alert = NSAlert()
        alert.messageText = "Apply authenticated update?"
        alert.informativeText = "Mac Orchestrator will stop its managed services, verify the release, and restore them after a successful update."
        alert.addButton(withTitle: "Apply Update")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let operations = self.operations
        Task.detached {
            do {
                let result = try operations.applyUpdate()
                await MainActor.run { [weak self] in
                    self?.show(message: "Authenticated Update", details: Self.updateFeedback(for: result))
                }
            } catch {
                await MainActor.run { [weak self] in self?.showFailure() }
            }
        }
    }

    @objc private func planUninstall() {
        let operations = self.operations
        Task.detached {
            do {
                let result = try operations.planRemoval()
                await MainActor.run { [weak self] in
                    self?.show(message: "Removal Plan", details: Self.removalPlanFeedback(for: result))
                }
            } catch {
                await MainActor.run { [weak self] in self?.showFailure() }
            }
        }
    }
    @objc private func openLogs() { supervisor.openLogs() }
    @objc private func openPrivacySettings() { supervisor.openPrivacySettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func confirmPrimaryRepair(
        _ doctor: Phase3DoctorOperationResult,
        operations: Phase3OperationCoordinator
    ) {
        guard let descriptor = doctor.primaryRepair else {
            show(message: "Repair Primary Failure", details: "No bounded repair is currently available.")
            return
        }
        let alert = NSAlert()
        alert.messageText = descriptor.title
        alert.informativeText = "\(descriptor.guidance)\n\nMac Orchestrator will run only this bounded repair, then run Doctor again."
        alert.addButton(withTitle: "Repair")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task.detached {
            do {
                let result = try await operations.executeRepair(
                    descriptor: descriptor,
                    before: doctor.report
                )
                await MainActor.run { [weak self] in
                    self?.show(message: "Repair Primary Failure", details: Self.repairFeedback(for: result))
                }
            } catch {
                await MainActor.run { [weak self] in self?.showFailure() }
            }
        }
    }

    private func show(message: String, details: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = details
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showFailure() {
        show(
            message: "Mac Orchestrator",
            details: "This operation could not be completed safely. Run Doctor for details."
        )
    }

    static func doctorFeedback(for result: Phase3DoctorOperationResult) -> String {
        let summary = result.report.summary
        let overall: String
        if summary.fail > 0 {
            overall = "FAIL"
        } else if summary.warn > 0 {
            overall = "WARN"
        } else {
            overall = "PASS"
        }
        var lines = [
            "Overall: \(overall)",
            "PASS \(summary.pass)  WARN \(summary.warn)  FAIL \(summary.fail)  SKIP \(summary.skip)"
        ]
        let issues = result.report.results
            .filter { $0.status == .fail || $0.status == .warn }
            .prefix(4)
        if issues.isEmpty {
            lines.append("No failing or warning checks.")
        } else {
            lines.append("Issues:")
            for issue in issues {
                let status = issue.status == .fail ? "FAIL" : "WARN"
                lines.append("• \(status): \(safeDisplay(issue.title)) — \(safeDisplay(issue.reason))")
            }
        }
        if let repair = result.primaryRepair {
            lines.append("Primary bounded repair: \(safeDisplay(repair.title))")
            lines.append(safeDisplay(repair.guidance))
        }
        return lines.joined(separator: "\n")
    }

    static func repairFeedback(for result: Phase3RepairOperationResult) -> String {
        let before = result.before.summary
        let after = result.after.summary
        return [
            "Repair: \(safeDisplay(result.descriptor.title))",
            "Result: \(result.outcome.status.rawValue)",
            safeDisplay(result.outcome.safeReason),
            "Before: FAIL \(before.fail), WARN \(before.warn)",
            "After: PASS \(after.pass), WARN \(after.warn), FAIL \(after.fail), SKIP \(after.skip)"
        ].joined(separator: "\n")
    }

    static func supportPreviewFeedback(for result: Phase3SupportBundlePreviewResult) -> String {
        let categories = Array(Set(result.plan.entries.map(\.category))).sorted()
        let included = categories.isEmpty ? "none" : categories.joined(separator: ", ")
        let excluded = result.plan.excludedSensitiveCategories.joined(separator: ", ")
        let transforms = result.plan.redactionSummary.appliedTransforms.joined(separator: ", ")
        return [
            "Included categories: \(included)",
            "Explicitly excluded: \(excluded)",
            "Redaction: \(transforms)",
            "Preview collected files: \(result.collectedFileCount)"
        ].joined(separator: "\n")
    }

    static func supportCreationFeedback(for result: Phase3SupportBundleCreationResult) -> String {
        "Redacted archive created at:\n\(result.archiveURL.path)\n\nThe archive is ready to reveal in Finder."
    }

    static func updateFeedback(for result: Phase3UpdateOperationResult) -> String {
        result.message
    }

    static func removalPlanFeedback(for result: Phase3RemovalPlanOperationResult) -> String {
        let removals = result.plan.entries.filter { $0.intent == .remove }.map(\.relativePath)
        let retained = result.plan.entries.filter { $0.intent == .retain }.map(\.relativePath)
        let manual = result.plan.entries.filter { $0.intent == .manualActionRequired }.map(\.relativePath)
        func section(_ title: String, _ values: [String]) -> String {
            guard !values.isEmpty else { return "\(title): none" }
            return "\(title):\n" + values.map { "• \(safeDisplay($0))" }.joined(separator: "\n")
        }
        return [
            section("Items to remove", removals),
            section("Items retained", retained),
            section("Manual review", manual),
            "Credentials: \(result.plan.keychainItemsToDelete.isEmpty ? "preserved by default" : "explicitly selected for deletion")",
            "Provider-side resources: untouched",
            "Viewing this plan performs no uninstall."
        ].joined(separator: "\n")
    }

    private static func safeDisplay(_ value: String) -> String {
        // UI feedback is a separate redaction boundary. Read known values
        // only for in-memory replacement so an unexpectedly secret-bearing
        // diagnostic cannot reach the native alert; the values are never
        // included in the typed result or displayed.
        let redactor = SensitiveDataRedactor(
            exactSecrets: TerminalCommand.supportBundleSecretValues(),
            homeDirectory: NSHomeDirectory()
        )
        return String(redactor.redact(value).prefix(240))
    }
}
