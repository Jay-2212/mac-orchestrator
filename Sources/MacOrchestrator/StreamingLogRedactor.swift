import Foundation

struct StreamingLogRedactor: Sendable {
    private let redactor: SensitiveDataRedactor
    private var pending = ""

    init(secrets: [String], homeDirectory: String? = NSHomeDirectory()) {
        self.redactor = SensitiveDataRedactor(exactSecrets: secrets, homeDirectory: homeDirectory)
    }

    mutating func append(_ chunk: String, flush: Bool) -> [String] {
        pending.append(chunk)
        var lines = [String]()
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline]).trimmingCharacters(in: .newlines)
            pending.removeSubrange(...newline)
            lines.append(redact(line))
        }
        if flush && !pending.isEmpty {
            lines.append(redact(pending.trimmingCharacters(in: .newlines)))
            pending.removeAll(keepingCapacity: true)
        }
        return lines
    }

    private func redact(_ line: String) -> String {
        redactor.redact(line)
    }
}

final class LockedStreamingLogRedactor: @unchecked Sendable {
    private var redactor: StreamingLogRedactor
    private let lock = NSLock()

    init(secrets: [String]) {
        redactor = StreamingLogRedactor(secrets: secrets)
    }

    func append(_ chunk: String, flush: Bool) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return redactor.append(chunk, flush: flush)
    }
}
