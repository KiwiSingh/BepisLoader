import Foundation

// 41F-21D.12: host-only, in-memory REVIEW coordinator.
// This type has no guest access, execution API, or authorization credential.
// No result produced here grants installation permission.
enum SteamacTransactionReviewCoordinatorError: Error, Equatable {
    case reviewRejected
    case invalidReviewTransition
    case reviewAlreadyConsumed
    case reviewNotStarted
}

struct SteamacTransactionReviewCoordinator {
    private(set) var transaction: SteamacInstallationTransaction
    private(set) var lastReview: SteamacTransactionSafetyResult?
    private(set) var reviewAttempted = false

    init(transaction: SteamacInstallationTransaction) {
        self.transaction = transaction
    }

    /// A single-use review attempt. A failed attempt cannot be retried on the
    /// same coordinator: create a NEW coordinator after obtaining fresh evidence.
    /// The caller's reviews are assertions, not authenticated approvals.
    mutating func review(
        snapshot: SteamacCollectedTransactionEvidence,
        expectedEndpointProcessID: Int32,
        reviews: SteamacTransactionSafetyReviews = .unreviewed,
        now: Date = Date(),
        maximumAge: TimeInterval = 30
    ) throws -> SteamacTransactionSafetyResult {
        guard !reviewAttempted else { throw SteamacTransactionReviewCoordinatorError.reviewAlreadyConsumed }
        guard transaction.state == .proposed else { throw SteamacTransactionReviewCoordinatorError.invalidReviewTransition }
        reviewAttempted = true // Consume BEFORE evaluation; fail closed.
        let result = SteamacTransactionSafetyGate.evaluate(
            transaction, snapshot: snapshot,
            expectedEndpointProcessID: expectedEndpointProcessID,
            reviews: reviews, now: now, maximumAge: maximumAge
        )
        lastReview = result
        guard SteamacTransactionSafetyGate.permitsReviewTransition(
            from: transaction, to: .preflighted, result: result
        ) else { throw SteamacTransactionReviewCoordinatorError.reviewRejected }
        try transaction.recordTransition(to: .preflighted)
        return result
    }

    /// Explicitly close a proposed or preflighted review without authorization.
    mutating func cancelReview() throws {
        guard transaction.state == .proposed || transaction.state == .preflighted else {
            throw SteamacTransactionReviewCoordinatorError.invalidReviewTransition
        }
        try transaction.recordTransition(to: .cancelled)
    }

    /// Deny ALL requests to authorize, stage, validate, apply, verify, commit,
    /// or perform recovery transitions. A future executor needs its own boundary.
    mutating func requestTransition(to next: SteamacInstallationTransactionState) throws {
        _ = next
        throw SteamacTransactionReviewCoordinatorError.invalidReviewTransition
    }
}