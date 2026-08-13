import Darwin
import Foundation

struct OwnedProcessObservation: Equatable, Sendable {
    let commandLine: String
    let processGroupID: Int32?
}

protocol OwnedProcessInspecting: Sendable {
    /// Returns nil only when the PID is definitely no longer live. Any other
    /// inability to inspect the PID is an error so cleanup fails closed.
    func inspect(pid: Int32) throws -> OwnedProcessObservation?
}

protocol OwnedProcessTerminating: Sendable {
    func terminate(
        pid: Int32,
        component: SupervisorComponent,
        ownerID: String,
        processGroupID: Int32?
    ) throws
}

struct SystemOwnedProcessInspector: OwnedProcessInspecting {
    private let processRunner: OwnedProcessCommandRunning

    init(processRunner: OwnedProcessCommandRunning = SystemOwnedProcessCommandRunner()) {
        self.processRunner = processRunner
    }

    func inspect(pid: Int32) throws -> OwnedProcessObservation? {
        guard pid > 0 else { throw UninstallError.processOwnershipNotProven }

        let liveness = kill(pid, 0)
        if liveness != 0 {
            guard errno == ESRCH else { throw UninstallError.processOwnershipNotProven }
            return nil
        }

        let commandLine = try processRunner.commandLine(for: pid)
        guard !commandLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UninstallError.processOwnershipNotProven
        }

        let processGroupID: Int32?
        let groupID = getpgid(pid)
        if groupID == -1 {
            // A process can exit between the liveness check and getpgid. The
            // terminator will revalidate the PID before sending any signal.
            processGroupID = nil
        } else {
            processGroupID = groupID
        }
        return OwnedProcessObservation(commandLine: commandLine, processGroupID: processGroupID)
    }
}

protocol OwnedProcessCommandRunning: Sendable {
    func commandLine(for pid: Int32) throws -> String
}

struct SystemOwnedProcessCommandRunner: OwnedProcessCommandRunning {
    func commandLine(for pid: Int32) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw UninstallError.processOwnershipNotProven
        }
        guard process.terminationStatus == 0 else {
            throw UninstallError.processOwnershipNotProven
        }
        return String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }
}

struct SystemOwnedProcessTerminator: OwnedProcessTerminating {
    private let commandRunner: OwnedProcessCommandRunning
    private let clock: @Sendable () -> Date
    private let sleeper: @Sendable (TimeInterval) -> Void

    init(
        commandRunner: OwnedProcessCommandRunning = SystemOwnedProcessCommandRunner(),
        clock: @escaping @Sendable () -> Date = { Date() },
        sleeper: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.commandRunner = commandRunner
        self.clock = clock
        self.sleeper = sleeper
    }

    func terminate(
        pid: Int32,
        component: SupervisorComponent,
        ownerID: String,
        processGroupID: Int32?
    ) throws {
        guard pid > 0, kill(pid, 0) == 0 else {
            if errno == ESRCH { return }
            throw UninstallError.processOwnershipNotProven
        }

        // Re-read the command line after the adapter's observation. This
        // closes the PID-reuse window between inspection and the first signal.
        let commandLine = try commandRunner.commandLine(for: pid)
        guard ProcessOwnership.authorizesTermination(
            pidExists: true,
            commandLine: commandLine,
            component: component,
            ownerID: ownerID
        ) else {
            throw UninstallError.processOwnershipNotProven
        }

        let groupOwned = processGroupID == pid
        let target = groupOwned ? -pid : pid
        guard kill(target, SIGTERM) == 0 || errno == ESRCH else {
            throw UninstallError.processOwnershipNotProven
        }

        let deadline = clock().addingTimeInterval(3)
        while processIsLive(pid), clock() < deadline {
            sleeper(0.05)
        }
        guard processIsLive(pid) else { return }
        guard kill(target, SIGKILL) == 0 || errno == ESRCH else {
            throw UninstallError.processOwnershipNotProven
        }
    }

    private func processIsLive(_ pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 else { return errno != ESRCH }
        return true
    }
}

/// Production cleanup for the exact project-owned state artifact. The
/// UninstallEngine establishes maintenance quiescing before invoking this
/// adapter; this adapter then proves process ownership independently.
struct ProductionOwnedProcessRemovalAdapter: OwnedProcessRemovalAdapter, @unchecked Sendable {
    let ownerID: String
    let stateURL: URL
    let fileManager: FileManager
    let inspector: any OwnedProcessInspecting
    let terminator: any OwnedProcessTerminating

    init(
        ownerID: String,
        stateURL: URL,
        fileManager: FileManager = .default,
        inspector: any OwnedProcessInspecting = SystemOwnedProcessInspector(),
        terminator: any OwnedProcessTerminating = SystemOwnedProcessTerminator()
    ) {
        self.ownerID = ownerID
        self.stateURL = stateURL.standardizedFileURL
        self.fileManager = fileManager
        self.inspector = inspector
        self.terminator = terminator
    }

    func removeOwnedProcesses() throws {
        guard !ownerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              safeStatePath() else {
            throw UninstallError.processOwnershipNotProven
        }
        guard stateExists() else { return }

        let state = try readState()
        guard state.ownerID == ownerID else {
            throw UninstallError.processOwnershipNotProven
        }
        guard (state.serverPID.map { $0 > 0 } ?? true),
              (state.tunnelPID.map { $0 > 0 } ?? true),
              state.serverPID != nil || state.tunnelPID != nil,
              state.serverPID != state.tunnelPID else {
            throw UninstallError.processOwnershipNotProven
        }

        var authorizedTargets: [(pid: Int32, component: SupervisorComponent, processGroupID: Int32?)] = []
        try inspect(
            pid: state.serverPID,
            component: .server,
            into: &authorizedTargets
        )
        try inspect(
            pid: state.tunnelPID,
            component: .tunnel,
            into: &authorizedTargets
        )

        // Every live recorded PID has passed the current ownership proof
        // before any signal is sent. This prevents a mixed-validity state
        // from partially terminating one component before failing closed on
        // another.
        for target in authorizedTargets {
            try terminator.terminate(
                pid: target.pid,
                component: target.component,
                ownerID: ownerID,
                processGroupID: target.processGroupID
            )
        }

        // Recheck the exact inode before removal. A swapped symlink or a
        // replacement state artifact is never followed or deleted.
        guard safeStatePath(), stateExists() else {
            throw UninstallError.processOwnershipNotProven
        }
        do {
            try fileManager.removeItem(at: stateURL)
        } catch {
            throw UninstallError.processOwnershipNotProven
        }
    }

    private func inspect(
        pid: Int32?,
        component: SupervisorComponent,
        into targets: inout [(pid: Int32, component: SupervisorComponent, processGroupID: Int32?)]
    ) throws {
        guard let pid else { return }
        guard let observation = try inspector.inspect(pid: pid) else {
            // LaunchAgent quiescing may already have stopped this process.
            return
        }
        guard ProcessOwnership.authorizesTermination(
            pidExists: true,
            commandLine: observation.commandLine,
            component: component,
            ownerID: ownerID
        ) else {
            throw UninstallError.processOwnershipNotProven
        }
        targets.append((pid: pid, component: component, processGroupID: observation.processGroupID))
    }

    private func readState() throws -> OwnedProcessState {
        guard safeStatePath(),
              let data = try? Data(contentsOf: stateURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["ownerID", "serverPID", "tunnelPID"]),
              let state = try? JSONDecoder().decode(OwnedProcessState.self, from: data) else {
            throw UninstallError.processOwnershipNotProven
        }
        return state
    }

    private func stateExists() -> Bool {
        var info = stat()
        return lstat(stateURL.path, &info) == 0
    }

    private func safeStatePath() -> Bool {
        guard stateURL.path.hasPrefix("/"), stateURL.lastPathComponent == "owned-processes.json" else {
            return false
        }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        let components = stateURL.path.split(separator: "/", omittingEmptySubsequences: true)
        for (index, component) in components.enumerated() {
            current.appendPathComponent(String(component), isDirectory: index < components.count - 1)
            var info = stat()
            guard lstat(current.path, &info) == 0 else {
                guard errno == ENOENT, index == components.count - 1 else { return false }
                continue
            }
            let type = info.st_mode & S_IFMT
            if type == S_IFLNK {
                guard index < components.count - 1,
                      VerifiedMacOSSystemAlias.isAllowed(current) else {
                    return false
                }
                continue
            }
            if index < components.count - 1,
               type != S_IFDIR {
                return false
            }
            if index == components.count - 1 {
                guard type == S_IFREG,
                      info.st_uid == getuid(),
                      info.st_mode & 0o777 == 0o600 else {
                    // A missing state file is valid; an existing one must be
                    // a private regular file owned by this user.
                    return !stateExists()
                }
            }
        }
        return true
    }
}
