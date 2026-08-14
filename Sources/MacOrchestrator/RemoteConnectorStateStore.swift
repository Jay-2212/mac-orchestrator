import Darwin
import Foundation

enum RemoteConnectorStateStoreError: Error, Equatable, LocalizedError, Sendable {
    case notFound
    case malformed
    case unsupportedSchema(Int)
    case unsafePath
    case unsafePermissions
    case providerMismatch
    case generationRegression
    case staleHandoff
    case readFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Remote connector state was not found."
        case .malformed:
            return "Remote connector state is malformed."
        case let .unsupportedSchema(version):
            return "Unsupported remote connector state schema " + String(version) + "."
        case .unsafePath:
            return "Remote connector state path is unsafe."
        case .unsafePermissions:
            return "Remote connector state permissions are unsafe."
        case .providerMismatch:
            return "Remote connector state belongs to a different provider."
        case .generationRegression:
            return "Remote connector state generation would move backwards."
        case .staleHandoff:
            return "The connector handoff does not match current authenticated state."
        case .readFailed:
            return "Remote connector state could not be read safely."
        case .writeFailed:
            return "Remote connector state could not be written safely."
        }
    }
}

protocol RemoteConnectorStatePersisting {
    func load() throws -> RemoteConnectorStateV1?
    func loadOrCreate(provider: RemoteConnectorProvider) throws -> RemoteConnectorStateV1
    @discardableResult
    func save(_ state: RemoteConnectorStateV1) throws -> RemoteConnectorStateV1
    @discardableResult
    func recordHandoff(
        generation: UInt64,
        origin: RemotePublicOrigin,
        at date: Date
    ) throws -> RemoteConnectorStateV1
}

extension RemoteConnectorStatePersisting {
    @discardableResult
    func recordHandoff(
        generation: UInt64,
        origin: RemotePublicOrigin,
        at date: Date
    ) throws -> RemoteConnectorStateV1 {
        throw RemoteConnectorStateStoreError.staleHandoff
    }

    @discardableResult
    func recordHandoff(
        generation: UInt64,
        origin: RemotePublicOrigin
    ) throws -> RemoteConnectorStateV1 {
        try recordHandoff(generation: generation, origin: origin, at: Date())
    }

    @discardableResult
    func recordHandoff(
        connectorCredentialGeneration: UInt64,
        publicOrigin: RemotePublicOrigin,
        handedOffAt date: Date = Date()
    ) throws -> RemoteConnectorStateV1 {
        try recordHandoff(generation: connectorCredentialGeneration, origin: publicOrigin, at: date)
    }
}

final class RemoteConnectorStateStore: RemoteConnectorStatePersisting {
    static let stateFileName = "remote-connector-state-v1.json"

    let directoryURL: URL
    let stateURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
        ConfigurationStore.defaultDirectoryURL(fileManager: fileManager)
    }

    convenience init(fileManager: FileManager = .default) {
        self.init(directoryURL: Self.defaultDirectoryURL(fileManager: fileManager), fileManager: fileManager)
    }

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.stateURL = directoryURL.standardizedFileURL
            .appendingPathComponent(Self.stateFileName, isDirectory: false)
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func load() throws -> RemoteConnectorStateV1? {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked()
    }

    @discardableResult
    func loadOrCreate(provider: RemoteConnectorProvider) throws -> RemoteConnectorStateV1 {
        lock.lock()
        defer { lock.unlock() }

        if let existing = try loadUnlocked() {
            guard existing.provider == provider else {
                throw RemoteConnectorStateStoreError.providerMismatch
            }
            return existing
        }

        let fresh = RemoteConnectorStateV1.fresh(provider: provider)
        try persistUnlocked(fresh, existing: nil)
        return fresh
    }

    @discardableResult
    func save(_ state: RemoteConnectorStateV1) throws -> RemoteConnectorStateV1 {
        lock.lock()
        defer { lock.unlock() }

        let candidate = try validated(state)
        let existing = try loadUnlocked()
        try persistUnlocked(candidate, existing: existing)
        return candidate
    }

    @discardableResult
    func recordHandoff(
        generation: UInt64,
        origin: RemotePublicOrigin,
        at date: Date = Date()
    ) throws -> RemoteConnectorStateV1 {
        lock.lock()
        defer { lock.unlock() }

        guard let current = try loadUnlocked(),
              current.recoveryPhase == .stable,
              current.pendingConnectorCredentialGeneration == nil,
              current.lastRemoteResult == .ready,
              current.lastSuccessfulRemoteProbeAt != nil,
              current.connectorCredentialGeneration == generation,
              current.lastVerifiedPublicOrigin == origin else {
            throw RemoteConnectorStateStoreError.staleHandoff
        }

        var candidate = current
        candidate.handoffReceipt = RemoteConnectorHandoffReceipt(
            connectorCredentialGeneration: generation,
            publicOrigin: origin,
            handedOffAt: date
        )
        let validatedCandidate = try validated(candidate)
        try persistUnlocked(
            validatedCandidate,
            existing: current,
            allowHandoffReplacement: true
        )
        return validatedCandidate
    }

    @discardableResult
    func update(
        _ body: (inout RemoteConnectorStateV1) throws -> Void
    ) throws -> RemoteConnectorStateV1 {
        lock.lock()
        defer { lock.unlock() }

        let current: RemoteConnectorStateV1
        if let loaded = try loadUnlocked() {
            current = loaded
        } else {
            throw RemoteConnectorStateStoreError.notFound
        }
        var candidate = current
        try body(&candidate)
        let validatedCandidate = try validated(candidate)
        try persistUnlocked(validatedCandidate, existing: current)
        return validatedCandidate
    }

    private func validated(_ state: RemoteConnectorStateV1) throws -> RemoteConnectorStateV1 {
        do {
            return try state.validated()
        } catch let error as RemoteConnectorStateValidationError {
            if case let .unsupportedSchema(version) = error {
                throw RemoteConnectorStateStoreError.unsupportedSchema(version)
            }
            throw RemoteConnectorStateStoreError.malformed
        } catch {
            throw RemoteConnectorStateStoreError.malformed
        }
    }

    private func loadUnlocked() throws -> RemoteConnectorStateV1? {
        guard DiagnosticPathSafety.isSafe(directoryURL) else {
            throw RemoteConnectorStateStoreError.unsafePath
        }

        guard let directoryInfo = metadata(for: directoryURL) else {
            return nil
        }
        guard isDirectory(directoryInfo) else {
            throw RemoteConnectorStateStoreError.unsafePath
        }
        guard isOwned(directoryInfo), hasPrivateDirectoryMode(directoryInfo) else {
            throw RemoteConnectorStateStoreError.unsafePermissions
        }

        guard DiagnosticPathSafety.isSafe(stateURL) else {
            throw RemoteConnectorStateStoreError.unsafePath
        }

        var stateInfo = stat()
        guard lstat(stateURL.path, &stateInfo) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw RemoteConnectorStateStoreError.readFailed
        }
        guard isRegularFile(stateInfo) else {
            throw RemoteConnectorStateStoreError.unsafePath
        }
        guard isOwned(stateInfo), hasPrivateFileMode(stateInfo) else {
            throw RemoteConnectorStateStoreError.unsafePermissions
        }

        let data = try readStateData()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: RemoteConnectorStateV1.knownCodingKeyNames) else {
            throw RemoteConnectorStateStoreError.malformed
        }

        do {
            return try decoder.decode(RemoteConnectorStateV1.self, from: data)
        } catch let error as RemoteConnectorStateValidationError {
            if case let .unsupportedSchema(version) = error {
                throw RemoteConnectorStateStoreError.unsupportedSchema(version)
            }
            throw RemoteConnectorStateStoreError.malformed
        } catch {
            throw RemoteConnectorStateStoreError.malformed
        }
    }

    private func persistUnlocked(
        _ state: RemoteConnectorStateV1,
        existing: RemoteConnectorStateV1?,
        allowHandoffReplacement: Bool = false
    ) throws {
        guard existing?.provider == nil || existing?.provider == state.provider else {
            throw RemoteConnectorStateStoreError.providerMismatch
        }
        if let existing,
           state.connectorCredentialGeneration < existing.connectorCredentialGeneration
            || (existing.pendingConnectorCredentialGeneration != nil
                && state.pendingConnectorCredentialGeneration == nil
                && state.connectorCredentialGeneration < (existing.pendingConnectorCredentialGeneration ?? 0))
            || (existing.pendingConnectorCredentialGeneration != nil
                && state.pendingConnectorCredentialGeneration != nil
                && (state.pendingConnectorCredentialGeneration ?? 0)
                    < (existing.pendingConnectorCredentialGeneration ?? 0))
            || handoffRegresses(
                state.handoffReceipt,
                from: existing.handoffReceipt,
                allowReplacement: allowHandoffReplacement
            ) {
            throw RemoteConnectorStateStoreError.generationRegression
        }

        let data: Data
        do {
            data = try encoder.encode(state)
        } catch {
            throw RemoteConnectorStateStoreError.writeFailed
        }

        try ensureDirectory()
        if let existingState = metadata(for: stateURL) {
            guard isRegularFile(existingState) else {
                throw RemoteConnectorStateStoreError.unsafePath
            }
            guard isOwned(existingState), hasPrivateFileMode(existingState) else {
                throw RemoteConnectorStateStoreError.unsafePermissions
            }
        }
        try atomicWrite(data)
    }

    private func handoffRegresses(
        _ candidate: RemoteConnectorHandoffReceipt?,
        from existing: RemoteConnectorHandoffReceipt?,
        allowReplacement: Bool
    ) -> Bool {
        guard let existing else { return false }
        guard let candidate else { return true }
        if candidate.connectorCredentialGeneration < existing.connectorCredentialGeneration {
            return true
        }
        if candidate.connectorCredentialGeneration > existing.connectorCredentialGeneration {
            return !allowReplacement
        }
        if candidate.publicOrigin != existing.publicOrigin {
            return !allowReplacement
        }
        return candidate.handedOffAt < existing.handedOffAt
    }

    private func ensureDirectory() throws {
        guard DiagnosticPathSafety.isSafe(directoryURL) else {
            throw RemoteConnectorStateStoreError.unsafePath
        }

        if let existing = metadata(for: directoryURL) {
            guard isDirectory(existing) else {
                throw RemoteConnectorStateStoreError.unsafePath
            }
            guard isOwned(existing), hasPrivateDirectoryMode(existing) else {
                throw RemoteConnectorStateStoreError.unsafePermissions
            }
            return
        }

        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        } catch {
            throw RemoteConnectorStateStoreError.writeFailed
        }

        guard let created = metadata(for: directoryURL),
              isDirectory(created),
              isOwned(created),
              hasPrivateDirectoryMode(created) else {
            throw RemoteConnectorStateStoreError.unsafePermissions
        }
    }

    private func readStateData() throws -> Data {
        let directoryFD = try openVerifiedDirectory(forWriting: false)
        defer { _ = close(directoryFD) }

        let fileFD = Self.stateFileName.withCString {
            openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW)
        }
        guard fileFD >= 0 else {
            throw RemoteConnectorStateStoreError.readFailed
        }
        defer { _ = close(fileFD) }

        var info = stat()
        guard fstat(fileFD, &info) == 0,
              isRegularFile(info),
              isOwned(info),
              hasPrivateFileMode(info) else {
            throw RemoteConnectorStateStoreError.unsafePermissions
        }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fileFD, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            guard count > 0 else {
                throw RemoteConnectorStateStoreError.readFailed
            }
            output.append(buffer, count: count)
        }
        return output
    }

    private func atomicWrite(_ data: Data) throws {
        let directoryFD = try openVerifiedDirectory(forWriting: true)
        defer { _ = close(directoryFD) }

        let temporaryName = ".remote-connector-state-\(UUID().uuidString.lowercased()).tmp"
        var temporaryFD: Int32 = -1
        let openResult = temporaryName.withCString {
            temporaryFD = openat(
                directoryFD,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                mode_t(0o600)
            )
            return temporaryFD
        }
        guard openResult >= 0 else {
            throw RemoteConnectorStateStoreError.writeFailed
        }

        do {
            guard fchmod(temporaryFD, mode_t(0o600)) == 0 else {
                throw RemoteConnectorStateStoreError.writeFailed
            }
            try writeAll(data, to: temporaryFD)
            guard fsync(temporaryFD) == 0 else {
                throw RemoteConnectorStateStoreError.writeFailed
            }
            guard close(temporaryFD) == 0 else {
                temporaryFD = -1
                throw RemoteConnectorStateStoreError.writeFailed
            }
            temporaryFD = -1

            let renameStatus = temporaryName.withCString { source in
                Self.stateFileName.withCString { destination in
                    renameat(directoryFD, source, directoryFD, destination)
                }
            }
            guard renameStatus == 0, fsync(directoryFD) == 0 else {
                throw RemoteConnectorStateStoreError.writeFailed
            }
        } catch let error as RemoteConnectorStateStoreError {
            if temporaryFD >= 0 { _ = close(temporaryFD) }
            _ = temporaryName.withCString { unlinkat(directoryFD, $0, 0) }
            throw error
        } catch {
            if temporaryFD >= 0 { _ = close(temporaryFD) }
            _ = temporaryName.withCString { unlinkat(directoryFD, $0, 0) }
            throw RemoteConnectorStateStoreError.writeFailed
        }
    }

    private func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else {
                    throw RemoteConnectorStateStoreError.writeFailed
                }
                offset += count
            }
        }
    }

    private func openVerifiedDirectory(forWriting: Bool) throws -> Int32 {
        guard DiagnosticPathSafety.isSafe(directoryURL) else {
            throw RemoteConnectorStateStoreError.unsafePath
        }
        let directoryFD = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else {
            if forWriting {
                throw RemoteConnectorStateStoreError.writeFailed
            }
            throw RemoteConnectorStateStoreError.readFailed
        }
        var info = stat()
        guard fstat(directoryFD, &info) == 0, isDirectory(info) else {
            _ = close(directoryFD)
            throw RemoteConnectorStateStoreError.unsafePath
        }
        guard isOwned(info), hasPrivateDirectoryMode(info) else {
            _ = close(directoryFD)
            throw RemoteConnectorStateStoreError.unsafePermissions
        }
        return directoryFD
    }

    private func metadata(for url: URL) -> stat? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info
    }

    private func isOwned(_ info: stat) -> Bool {
        info.st_uid == getuid()
    }

    private func isDirectory(_ info: stat) -> Bool {
        UInt32(info.st_mode) & UInt32(S_IFMT) == UInt32(S_IFDIR)
    }

    private func isRegularFile(_ info: stat) -> Bool {
        UInt32(info.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG)
    }

    private func hasPrivateDirectoryMode(_ info: stat) -> Bool {
        UInt32(info.st_mode) & 0o7777 == 0o700
    }

    private func hasPrivateFileMode(_ info: stat) -> Bool {
        UInt32(info.st_mode) & 0o7777 == 0o600
    }
}
