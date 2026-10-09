import Foundation
import Darwin

// 41F-21D.23: Host-only integration of blueprint audit, journal persistence and lease.
// Never sends guest commands, installs files, resumes operations, or grants consent.
enum SteamacHostOrchestrationError: Error {
    case invalidBlueprint, journalAlreadyExists, missingJournal, unexpectedJournalRevision
    case transactionMismatch, recoveryReviewRequired
}

enum SteamacHostTransactionOrchestrator {
    // Create-once: refuse an existing journal, including corrupt or wrong-ID journals.
    // Existing journal content is never overwritten during initial proposal.
    static func propose(blueprint: SteamacInstallationExecutionBlueprint,
                        transaction: SteamacInstallationTransaction,
                        directory: URL) throws -> SteamacInstallationRecoveryJournal {
        let audit = SteamacInstallationBlueprintAuditor.audit(blueprint, transaction: transaction)
        guard audit.structurallyValid else { throw SteamacHostOrchestrationError.invalidBlueprint }
        return try SteamacRecoveryJournalLease.withExclusiveLease(in: directory) {
            do {
                _ = try SteamacDurableRecoveryJournal.reopen(in: directory,
                                                             expectedTransactionID: transaction.id)
                throw SteamacHostOrchestrationError.journalAlreadyExists
            } catch SteamacDurableJournalError.ioFailure(let code) where code == ENOENT {
                // The only acceptable initial state is a genuinely absent journal.
            } catch SteamacHostOrchestrationError.journalAlreadyExists {
                throw SteamacHostOrchestrationError.journalAlreadyExists
            } catch {
                // Corruption, wrong transaction, unsafe path: do not overwrite.
                throw SteamacHostOrchestrationError.recoveryReviewRequired
            }
            var journal = SteamacInstallationRecoveryJournal(transactionID: transaction.id)
            try journal.append(event: .proposed, note: "Host-only proposal; installation prohibited")
            try SteamacDurableRecoveryJournal.persist(journal, in: directory)
            return journal
        }
    }

    // Optimistic sequence check while holding the exclusive cross-process lease.
    // This records intent ONLY; never an assertion that guest operations happened.
    static func recordHostIntent(transactionID: UUID, expectedEntryCount: Int,
                                 event: SteamacInstallationJournalEventKind,
                                 note: String = "", directory: URL) throws -> SteamacInstallationRecoveryJournal {
        guard expectedEntryCount >= 0 else { throw SteamacHostOrchestrationError.unexpectedJournalRevision }
        return try SteamacRecoveryJournalLease.withExclusiveLease(in: directory) {
            var journal = try SteamacDurableRecoveryJournal.reopen(in: directory,
                                                                 expectedTransactionID: transactionID)
            guard journal.entries.count == expectedEntryCount else {
                throw SteamacHostOrchestrationError.unexpectedJournalRevision
            }
            // Only planning/review events may be recorded through this interface.
            guard event == .preflightRecorded || event == .payloadValidated ||
                  event == .stagingPlanned || event == .operationPlanned ||
                  event == .recoveryNeeded else {
                throw SteamacHostOrchestrationError.recoveryReviewRequired
            }
            try journal.append(event: event, note: note)
            try SteamacDurableRecoveryJournal.persist(journal, in: directory)
            return journal
        }
    }

    static func inspect(directory: URL, transactionID: UUID) -> SteamacRecoveryDisposition {
        SteamacRecoveryJournalLease.inspect(in: directory, expectedTransactionID: transactionID)
    }

    static var permitsGuestInstallation: Bool { false }
    static var permitsAutomaticResume: Bool { false }
}
