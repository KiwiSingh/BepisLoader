import Foundation

// 41F-21D.2: DESIGN-ONLY transaction description.
// This file contains no I/O, execution, guest commands, or installation API.
// A successful preflight is NOT authorization to apply a transaction.

enum SteamacInstallationFramework: String, Codable, Hashable {
    case bepInEx
    case reloadedII
}

enum SteamacInstallationTransactionState: String, Codable, Hashable {
    case proposed
    case preflighted
    case authorized
    case staged
    case validated
    case applying
    case verifying
    case committed
    case rollingBack
    case rolledBack
    case recoveryRequired
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .committed, .rolledBack, .recoveryRequired, .cancelled: return true
        default: return false
        }
    }
}

/// Declarative operations only. No operation is executable from this model.
enum SteamacInstallationOperationKind: String, Codable, Hashable {
    case acquirePayload
    case validatePayload
    case snapshotExistingFiles
    case stagePayload
    case applyStagedFiles
    case runExternalInstaller
    case verifyInventory
    case restoreSnapshot
}

struct SteamacInstallationOperation: Codable, Hashable {
    let kind: SteamacInstallationOperationKind
    /// Human-readable description; MUST NOT be interpreted as a shell command.
    let description: String
    /// An external installer may change paths not controlled by this transaction.
    let hasUnboundedSideEffects: Bool
}

/// Represents a separately granted permission, not an executable credential.
/// The model intentionally cannot mint or validate user consent.
struct SteamacInstallationAuthorizationRequirement: Codable, Hashable {
    let requiresExplicitUserApproval: Bool
    let requiresAppIDConfirmation: Bool
    let requiresFrameworkConfirmation: Bool
    let requiresPayloadIntegrityValidation: Bool

    static let installation = SteamacInstallationAuthorizationRequirement(
        requiresExplicitUserApproval: true,
        requiresAppIDConfirmation: true,
        requiresFrameworkConfirmation: true,
        requiresPayloadIntegrityValidation: true
    )
}

enum SteamacInstallationRecoveryDisposition: String, Codable, Hashable {
    case notNeeded
    case rollbackRequired
    case rollbackInProgress
    case rolledBack
    case manualRecoveryRequired
}

struct SteamacInstallationTransaction: Codable, Hashable {
    let id: UUID
    let appID: UInt32
    let framework: SteamacInstallationFramework
    let operations: [SteamacInstallationOperation]
    let authorization: SteamacInstallationAuthorizationRequirement
    private(set) var state: SteamacInstallationTransactionState

    init(id: UUID = UUID(),
         appID: UInt32,
         framework: SteamacInstallationFramework,
         operations: [SteamacInstallationOperation],
         authorization: SteamacInstallationAuthorizationRequirement = .installation) {
        self.id = id
        self.appID = appID
        self.framework = framework
        self.operations = operations
        self.authorization = authorization
        self.state = .proposed
    }

    /// Describes permitted *model* transitions. Never performs an operation.
    /// Authorization must be checked by a future, separately reviewed executor.
    mutating func recordTransition(to next: SteamacInstallationTransactionState) throws {
        guard Self.allowedTransitions[state, default: []].contains(next) else {
            throw SteamacInstallationTransactionError.invalidTransition(from: state, to: next)
        }
        state = next
    }

    var recoveryDisposition: SteamacInstallationRecoveryDisposition {
        switch state {
        case .applying, .verifying: return .rollbackRequired
        case .rollingBack: return .rollbackInProgress
        case .rolledBack: return .rolledBack
        case .recoveryRequired: return .manualRecoveryRequired
        default: return .notNeeded
        }
    }

    private static let allowedTransitions: [SteamacInstallationTransactionState: Set<SteamacInstallationTransactionState>] = [
        .proposed: [.preflighted, .cancelled],
        .preflighted: [.authorized, .cancelled],
        .authorized: [.staged, .cancelled],
        .staged: [.validated, .cancelled],
        .validated: [.applying, .cancelled],
        .applying: [.verifying, .rollingBack, .recoveryRequired],
        .verifying: [.committed, .rollingBack, .recoveryRequired],
        .rollingBack: [.rolledBack, .recoveryRequired]
    ]
}

enum SteamacInstallationTransactionError: Error, Equatable {
    case invalidTransition(from: SteamacInstallationTransactionState,
                           to: SteamacInstallationTransactionState)
}
