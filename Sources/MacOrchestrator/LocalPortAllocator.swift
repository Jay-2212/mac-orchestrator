import Foundation

enum LocalPortSelectionError: Error, Equatable, LocalizedError, Sendable {
    case noAvailablePort

    var errorDescription: String? {
        switch self {
        case .noAvailablePort:
            return "Mac Orchestrator could not find an available local MCP port."
        }
    }
}

enum LocalPortAllocator {
    static func select(
        preferred: Int,
        isOccupied: (Int) -> Bool,
        candidates: ClosedRange<Int> = 8_000...8_100
    ) throws -> Int {
        var ports = [Int]()
        if candidates.contains(preferred) {
            ports.append(preferred)
        }
        ports.append(contentsOf: candidates.filter { $0 != preferred })

        for port in ports where !isOccupied(port) {
            return port
        }
        throw LocalPortSelectionError.noAvailablePort
    }

    static func isOccupied(_ port: Int) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        process.standardOutput = Pipe()
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
