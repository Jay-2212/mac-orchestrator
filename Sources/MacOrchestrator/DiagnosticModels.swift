import Foundation

enum DiagnosticStatus: String, Codable, Sendable {
    case pass
    case warn
    case fail
    case skip
}

enum RepairActionID: String, Codable, Sendable {
    case retryMCPServer
    case retryRemoteConnector
    case openAccessibilitySettings
    case openScreenRecordingSettings
    case openAutomationSettings
    case restoreConfigurationBackup
    case reassignLocalPort
    case repairLaunchAgent
    case rerunVerifiedBootstrap
}

struct RepairActionDescriptor: Codable, Equatable, Sendable {
    let id: RepairActionID
    let title: String
    let guidance: String
}

struct DiagnosticResult: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let status: DiagnosticStatus
    let reason: String
    let repair: RepairActionDescriptor?

    init(
        id: String,
        title: String,
        status: DiagnosticStatus,
        reason: String,
        repair: RepairActionDescriptor? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.reason = reason
        self.repair = repair
    }
}

struct DiagnosticSummary: Codable, Equatable, Sendable {
    let pass: Int
    let warn: Int
    let fail: Int
    let skip: Int
}

struct DoctorReport: Codable, Equatable, Sendable {
    let reportSchemaVersion: Int
    let generatedAt: Date
    let results: [DiagnosticResult]
    let summary: DiagnosticSummary

    init(generatedAt: Date, results: [DiagnosticResult]) {
        self.reportSchemaVersion = 1
        self.generatedAt = generatedAt
        self.results = results
        self.summary = DiagnosticSummary(
            pass: results.filter { $0.status == .pass }.count,
            warn: results.filter { $0.status == .warn }.count,
            fail: results.filter { $0.status == .fail }.count,
            skip: results.filter { $0.status == .skip }.count
        )
    }

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
