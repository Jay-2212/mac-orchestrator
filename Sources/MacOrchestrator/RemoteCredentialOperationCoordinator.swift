import Foundation

enum RemoteCredentialOperationError: Error, Equatable, LocalizedError, Sendable {
    case operationInProgress

    var errorDescription: String? {
        "Another remote credential operation is already in progress."
    }
}

/// Serializes connector-token rotation and provider-credential replacement
/// without owning lifecycle state or blocking a calling actor/thread.
actor RemoteCredentialOperationCoordinator {
    static let shared = RemoteCredentialOperationCoordinator()

    private var operationInFlight = false

    func acquire() throws {
        guard !operationInFlight else {
            throw RemoteCredentialOperationError.operationInProgress
        }
        operationInFlight = true
    }

    func release() {
        operationInFlight = false
    }
}
