import Foundation

// 41F-21D.11: PURE, HOST-ONLY SAFETY REVIEW GATE.
// No I/O, authorization minting, execution, installation, or guest writes.
// All review assertions are caller-supplied and are NOT authenticated by this type.
enum SteamacTransactionSafetyIssue: String, Codable, Hashable, CaseIterable {
    case invalidEvidenceAge
    case evidenceScopeMismatch
    case evidenceExpired
    case guestUnverified
    case capabilitiesUnverified
    case runtimeUnverified
    case gameUnverified
    case prefixUnverified
    case inventoryNotConfirmedAbsent
    case payloadDigestNotVerified
    case payloadProvenanceNotVerified
    case snapshotRestorabilityNotVerified
    case rollbackRestorabilityNotVerified
    case verificationCriteriaNotReviewed
    case preflightBlocked
}

/// These flags must eventually be established by independently reviewed mechanisms.
/// Supplying `true` here is NOT cryptographic evidence or user authorization.
struct SteamacTransactionSafetyReviews: Codable, Hashable {
    let payloadDigestVerified: Bool
    let payloadProvenanceVerified: Bool
    let snapshotRestorabilityVerified: Bool
    let rollbackRestorabilityVerified: Bool
    let verificationCriteriaReviewed: Bool

    static let unreviewed = SteamacTransactionSafetyReviews(
        payloadDigestVerified: false,
        payloadProvenanceVerified: false,
        snapshotRestorabilityVerified: false,
        rollbackRestorabilityVerified: false,
        verificationCriteriaReviewed: false
    )
}

enum SteamacTransactionSafetyDecision: String, Codable, Hashable {
    case blocked
    case readyForAuthorizationReview
}

struct SteamacTransactionSafetyResult: Codable, Hashable {
    let transactionID: UUID
    let appID: UInt32
    let framework: SteamacInstallationFramework
    let decision: SteamacTransactionSafetyDecision
    let issues: [SteamacTransactionSafetyIssue]
    let preflightIssues: [SteamacTransactionPreflightIssue]

    // A positive decision is only a REVIEW milestone; NEVER authorization.
    var isReadyForAuthorizationReview: Bool { decision == .readyForAuthorizationReview }
}

enum SteamacTransactionSafetyGate {
    static func evaluate(
        _ transaction: SteamacInstallationTransaction,
        snapshot: SteamacCollectedTransactionEvidence,
        expectedEndpointProcessID: Int32,
        reviews: SteamacTransactionSafetyReviews = .unreviewed,
        now: Date = Date(),
        maximumAge: TimeInterval = 30
    ) -> SteamacTransactionSafetyResult {
        var issues: [SteamacTransactionSafetyIssue] = []
        func reject(_ condition: Bool, _ issue: SteamacTransactionSafetyIssue) {
            if condition { issues.append(issue) }
        }

        let scopeMatches = transaction.appID == snapshot.appID &&
            transaction.framework == snapshot.framework &&
            expectedEndpointProcessID > 0 &&
            snapshot.endpointProcessID == expectedEndpointProcessID
        let validAge = maximumAge.isFinite && maximumAge > 0
        let current = scopeMatches && validAge && now >= snapshot.collectedAt &&
            now.timeIntervalSince(snapshot.collectedAt) <= maximumAge
        reject(!validAge, .invalidEvidenceAge)
        reject(!scopeMatches, .evidenceScopeMismatch)
        reject(!current, .evidenceExpired)
        func verified(_ fact: SteamacCollectedEvidenceFact) -> Bool {
            current && fact.status == .verified
        }
        reject(!verified(snapshot.guest), .guestUnverified)
        reject(!verified(snapshot.capabilities), .capabilitiesUnverified)
        reject(!verified(snapshot.runtime), .runtimeUnverified)
        reject(!verified(snapshot.game), .gameUnverified)
        reject(!verified(snapshot.prefix), .prefixUnverified)
        reject(!current || snapshot.frameworkInventory.status != .missing, .inventoryNotConfirmedAbsent)
        reject(!reviews.payloadDigestVerified, .payloadDigestNotVerified)
        reject(!reviews.payloadProvenanceVerified, .payloadProvenanceNotVerified)
        reject(!reviews.snapshotRestorabilityVerified, .snapshotRestorabilityNotVerified)
        reject(!reviews.rollbackRestorabilityVerified, .rollbackRestorabilityNotVerified)
        reject(!reviews.verificationCriteriaReviewed, .verificationCriteriaNotReviewed)

        // Do not treat collector observations as approvals of independent plans.
        // Even a fully reviewed caller-supplied plan is not authenticated here.
        let preflight = SteamacTransactionPreflightValidator.evaluate(
            transaction,
            evidence: SteamacTransactionPreflightEvidence(
                guestConnected: verified(snapshot.guest),
                requiredCapabilitiesPresent: verified(snapshot.capabilities),
                runtimeStaticallyAttested: verified(snapshot.runtime),
                gameInstalled: verified(snapshot.game),
                prefixPresent: verified(snapshot.prefix),
                frameworkInventory: current ? {
                    switch snapshot.frameworkInventory.status {
                    case .missing: return .missing
                    case .verified: return .verified
                    case .unknown, .stale: return .unknown
                    }
                }() : .unknown,
                payloadIntegrityPlanReviewed: reviews.payloadDigestVerified && reviews.payloadProvenanceVerified,
                snapshotPlanReviewed: reviews.snapshotRestorabilityVerified,
                verificationPlanReviewed: reviews.verificationCriteriaReviewed,
                rollbackPlanReviewed: reviews.rollbackRestorabilityVerified
            )
        )
        reject(!preflight.issues.isEmpty, .preflightBlocked)
        return SteamacTransactionSafetyResult(
            transactionID: transaction.id,
            appID: transaction.appID,
            framework: transaction.framework,
            decision: issues.isEmpty ? .readyForAuthorizationReview : .blocked,
            issues: issues,
            preflightIssues: preflight.issues
        )
    }

    /// Diagnostic transition guard only. The transaction model still exposes
    /// recordTransition; a future executor MUST enforce its own authenticated gate.
    /// This guard NEVER permits the authorization transition or execution states.
    static func permitsReviewTransition(
        from transaction: SteamacInstallationTransaction,
        to next: SteamacInstallationTransactionState,
        result: SteamacTransactionSafetyResult
    ) -> Bool {
        transaction.state == .proposed && next == .preflighted &&
            result.isReadyForAuthorizationReview &&
            result.transactionID == transaction.id &&
            result.appID == transaction.appID &&
            result.framework == transaction.framework
    }
}
