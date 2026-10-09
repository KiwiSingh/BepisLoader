import Foundation

// 41F-21D.20: Host-only, declarative installation blueprint and recovery journal.
// No filesystem operations, guest transport, process execution, or consent credentials.
struct SteamacInstallationFileRecord: Codable, Hashable {
    let relativePath: String
    let byteCount: UInt64
    let sha256: String
}

struct SteamacInstallationExecutionBlueprint: Codable, Hashable {
    let transactionID: UUID
    let appID: UInt32
    let framework: SteamacInstallationFramework
    let payloadArchiveSHA256: String
    let files: [SteamacInstallationFileRecord]
}

enum SteamacInstallationBlueprintIssue: String, Codable, Hashable {
    case invalidScope, invalidArchiveDigest, emptyFiles, duplicateDestination
    case unsafeDestination, invalidFileDigest, invalidFileSize
    case provenanceUnauthenticated, guestRecoveryUnverified, consentUnauthenticated
}

struct SteamacInstallationBlueprintAudit: Codable, Hashable {
    let issues: [SteamacInstallationBlueprintIssue]
    var structurallyValid: Bool {
        !issues.contains(where: {
            switch $0 {
            case .invalidScope, .invalidArchiveDigest, .emptyFiles, .duplicateDestination,
                 .unsafeDestination, .invalidFileDigest, .invalidFileSize: return true
            default: return false
            }
        })
    }
    // No caller-supplied flag can turn a blueprint into executable authority.
    var permitsGuestInstallation: Bool { false }
}

enum SteamacInstallationBlueprintAuditor {
    private static func validSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func audit(_ blueprint: SteamacInstallationExecutionBlueprint,
                      transaction: SteamacInstallationTransaction) -> SteamacInstallationBlueprintAudit {
        var issues: [SteamacInstallationBlueprintIssue] = []
        if blueprint.transactionID != transaction.id || blueprint.appID == 0 ||
            blueprint.appID != transaction.appID || blueprint.framework != transaction.framework ||
            transaction.state != .proposed { issues.append(.invalidScope) }
        if !validSHA256(blueprint.payloadArchiveSHA256) { issues.append(.invalidArchiveDigest) }
        if blueprint.files.isEmpty { issues.append(.emptyFiles) }
        if Set(blueprint.files.map(\.relativePath)).count != blueprint.files.count { issues.append(.duplicateDestination) }
        for file in blueprint.files {
            let path = file.relativePath
            let segments = path.split(separator: "/", omittingEmptySubsequences: false)
            if path.isEmpty || path.hasPrefix("/") || path.contains("\\") || path.contains(":") ||
                path.contains("\u{0}") || segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
                if !issues.contains(.unsafeDestination) { issues.append(.unsafeDestination) }
            }
            if !validSHA256(file.sha256) && !issues.contains(.invalidFileDigest) { issues.append(.invalidFileDigest) }
            if file.byteCount > 2 * 1024 * 1024 * 1024 && !issues.contains(.invalidFileSize) { issues.append(.invalidFileSize) }
        }
        issues += [.provenanceUnauthenticated, .guestRecoveryUnverified, .consentUnauthenticated]
        return SteamacInstallationBlueprintAudit(issues: issues)
    }
}

enum SteamacInstallationJournalEventKind: String, Codable, Hashable {
    case proposed, preflightRecorded, payloadValidated, stagingPlanned
    case operationPlanned, recoveryNeeded, recoveryRecorded, completed
}

struct SteamacInstallationJournalEntry: Codable, Hashable {
    let sequence: UInt64
    let transactionID: UUID
    let event: SteamacInstallationJournalEventKind
    let relativePath: String?
    let note: String
}

struct SteamacInstallationRecoveryJournal: Codable, Hashable {
    let transactionID: UUID
    private(set) var entries: [SteamacInstallationJournalEntry] = []

    init(transactionID: UUID) { self.transactionID = transactionID }

    mutating func append(event: SteamacInstallationJournalEventKind,
                         relativePath: String? = nil, note: String = "") throws {
        guard entries.count < 100_000 else { throw SteamacInstallationJournalError.tooManyEntries }
        guard note.utf8.count <= 4096 else { throw SteamacInstallationJournalError.noteTooLong }
        // This journal describes intent only. It NEVER asserts that guest work occurred.
        entries.append(SteamacInstallationJournalEntry(sequence: UInt64(entries.count),
                     transactionID: transactionID, event: event, relativePath: relativePath, note: note))
    }

    func isWellFormed() -> Bool {
        entries.enumerated().allSatisfy { index, entry in
            entry.transactionID == transactionID && entry.sequence == UInt64(index)
        }
    }

    // A memory-only record is not a durable write-ahead log. This is deliberately blocked.
    var durableRecoveryVerified: Bool { false }
}

enum SteamacInstallationJournalError: Error { case tooManyEntries, noteTooLong }

enum SteamacInstallationExecutionGate {
    // This phase has no verified publisher trust, guest recovery, or consent boundary.
    // Do not add a guest execution API here.
    static func permitsGuestInstallation(blueprint: SteamacInstallationExecutionBlueprint,
                                         transaction: SteamacInstallationTransaction,
                                         journal: SteamacInstallationRecoveryJournal) -> Bool {
        _ = SteamacInstallationBlueprintAuditor.audit(blueprint, transaction: transaction)
        _ = journal.isWellFormed()
        return false
    }
}
