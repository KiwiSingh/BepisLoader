import Foundation

// 41F-21D.4: PURE, HOST-ONLY PREFLIGHT. No I/O, guest calls or authorization.
// Caller-supplied evidence is NOT independently trusted by this type.
enum SteamacTransactionEvidence: String, Codable, Hashable {
    case verified
    case missing
    case unknown
}

enum SteamacTransactionPreflightIssue: String, Codable, Hashable, CaseIterable {
    case invalidAppID
    case guestNotConnected
    case requiredCapabilitiesMissing
    case runtimeNotStaticallyAttested
    case gameNotInstalled
    case prefixNotPresent
    case existingFrameworkStateUnknown
    case frameworkAlreadyInstalled
    case unsafeOperationDescription
    case externalInstallerSideEffectsUnbounded
    case missingPayloadIntegrityPlan
    case missingSnapshotPlan
    case missingVerificationPlan
    case missingRollbackPlan
    case authorizationRequirementsIncomplete
    case transactionNotProposed
}

struct SteamacTransactionPreflightEvidence: Codable, Hashable {
    let guestConnected: Bool
    let requiredCapabilitiesPresent: Bool
    let runtimeStaticallyAttested: Bool
    let gameInstalled: Bool
    let prefixPresent: Bool
    let frameworkInventory: SteamacTransactionEvidence
    // These describe reviewed plans, not proof that any operation was performed.
    let payloadIntegrityPlanReviewed: Bool
    let snapshotPlanReviewed: Bool
    let verificationPlanReviewed: Bool
    let rollbackPlanReviewed: Bool
}

struct SteamacTransactionPreflightResult: Codable, Hashable {
    let transactionID: UUID
    let appID: UInt32
    let framework: SteamacInstallationFramework
    let issues: [SteamacTransactionPreflightIssue]
    var isReadyForAuthorizationReview: Bool { issues.isEmpty }
    // This result NEVER constitutes authorization or permission to execute.
}

enum SteamacTransactionPreflightValidator {
    static func evaluate(
        _ transaction: SteamacInstallationTransaction,
        evidence: SteamacTransactionPreflightEvidence
    ) -> SteamacTransactionPreflightResult {
        var issues: [SteamacTransactionPreflightIssue] = []
        func reject(_ condition: Bool, _ issue: SteamacTransactionPreflightIssue) {
            if condition { issues.append(issue) }
        }
        reject(transaction.appID == 0, .invalidAppID)
        reject(!evidence.guestConnected, .guestNotConnected)
        reject(!evidence.requiredCapabilitiesPresent, .requiredCapabilitiesMissing)
        reject(!evidence.runtimeStaticallyAttested, .runtimeNotStaticallyAttested)
        reject(!evidence.gameInstalled, .gameNotInstalled)
        reject(!evidence.prefixPresent, .prefixNotPresent)
        reject(evidence.frameworkInventory == .unknown, .existingFrameworkStateUnknown)
        reject(evidence.frameworkInventory == .verified, .frameworkAlreadyInstalled)
        reject(transaction.operations.contains { $0.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, .unsafeOperationDescription)
        reject(transaction.operations.contains { $0.hasUnboundedSideEffects }, .externalInstallerSideEffectsUnbounded)
        reject(!evidence.payloadIntegrityPlanReviewed || !transaction.operations.contains { $0.kind == .validatePayload }, .missingPayloadIntegrityPlan)
        reject(!evidence.snapshotPlanReviewed || !transaction.operations.contains { $0.kind == .snapshotExistingFiles }, .missingSnapshotPlan)
        reject(!evidence.verificationPlanReviewed || !transaction.operations.contains { $0.kind == .verifyInventory }, .missingVerificationPlan)
        reject(!evidence.rollbackPlanReviewed || !transaction.operations.contains { $0.kind == .restoreSnapshot }, .missingRollbackPlan)
        let a = transaction.authorization
        reject(!(a.requiresExplicitUserApproval && a.requiresAppIDConfirmation && a.requiresFrameworkConfirmation && a.requiresPayloadIntegrityValidation), .authorizationRequirementsIncomplete)
        reject(transaction.state != .proposed, .transactionNotProposed)
        return SteamacTransactionPreflightResult(
            transactionID: transaction.id,
            appID: transaction.appID,
            framework: transaction.framework,
            issues: issues
        )
    }
}
