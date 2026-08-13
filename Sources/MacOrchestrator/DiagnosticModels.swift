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

    private enum CodingKeys: String, CodingKey {
        case reportSchemaVersion
        case generatedAt
        case results
        case summary
    }

    init(generatedAt: Date, results: [DiagnosticResult]) {
        self.reportSchemaVersion = 1
        self.generatedAt = generatedAt
        self.results = results
        self.summary = Self.summary(for: results)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let reportSchemaVersion = try container.decode(Int.self, forKey: .reportSchemaVersion)
        guard reportSchemaVersion == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .reportSchemaVersion,
                in: container,
                debugDescription: "Unsupported doctor report schema version."
            )
        }

        let generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        let results = try container.decode([DiagnosticResult].self, forKey: .results)
        let decodedSummary = try container.decode(DiagnosticSummary.self, forKey: .summary)
        let expectedSummary = Self.summary(for: results)
        guard decodedSummary == expectedSummary else {
            throw DecodingError.dataCorruptedError(
                forKey: .summary,
                in: container,
                debugDescription: "Doctor report summary does not match its results."
            )
        }

        self.init(generatedAt: generatedAt, results: results)
    }

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    private static func summary(for results: [DiagnosticResult]) -> DiagnosticSummary {
        DiagnosticSummary(
            pass: results.filter { $0.status == .pass }.count,
            warn: results.filter { $0.status == .warn }.count,
            fail: results.filter { $0.status == .fail }.count,
            skip: results.filter { $0.status == .skip }.count
        )
    }
}
