import Foundation

final class RotatingLog {
    private let directory: URL
    private let name: String
    private let maxBytes: UInt64
    private let backups: Int
    private let lock = NSLock()

    init(directory: URL, name: String, maxBytes: UInt64 = 2 * 1024 * 1024, backups: Int = 4) {
        self.directory = directory
        self.name = name
        self.maxBytes = maxBytes
        self.backups = backups
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        rotateIfNeeded(incoming: UInt64(message.utf8.count + 1))
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"
        let url = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            // Logging must never destabilize the supervisor.
        }
    }

    func redact(_ secrets: [String]) {
        let values = secrets.filter { !$0.isEmpty }
        guard !values.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for index in 0...backups {
            let filename = index == 0 ? name : "\(name).\(index)"
            let url = directory.appendingPathComponent(filename)
            guard var contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var changed = false
            for secret in values where contents.contains(secret) {
                contents = contents.replacingOccurrences(of: secret, with: "<redacted>")
                changed = true
            }
            if changed {
                try? Data(contents.utf8).write(to: url, options: .atomic)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path
                )
            }
        }
    }

    private func rotateIfNeeded(incoming: UInt64) {
        let current = directory.appendingPathComponent(name)
        let size = (try? current.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        guard size + incoming > maxBytes else { return }

        if backups > 0 {
            let oldest = directory.appendingPathComponent("\(name).\(backups)")
            try? FileManager.default.removeItem(at: oldest)
            if backups > 1 {
                for index in stride(from: backups - 1, through: 1, by: -1) {
                    let source = directory.appendingPathComponent("\(name).\(index)")
                    let destination = directory.appendingPathComponent("\(name).\(index + 1)")
                    if FileManager.default.fileExists(atPath: source.path) {
                        try? FileManager.default.moveItem(at: source, to: destination)
                    }
                }
            }
            if FileManager.default.fileExists(atPath: current.path) {
                try? FileManager.default.moveItem(
                    at: current,
                    to: directory.appendingPathComponent("\(name).1")
                )
            }
        }
    }
}
