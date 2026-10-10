import Foundation
import CryptoKit

// 42A-13: Host-only evidence preparation. Never grants authorization.
// Local-file hashing is not independent release provenance authentication.
struct SteamacPreparedPayloadEvidence: Codable, Hashable {
    let fileName: String
    let byteCount: UInt64
    let computedSHA256: String
    let expectedSHA256: String
    let digestMatches: Bool
    let provenanceAuthenticated: Bool
    let installationAuthorized: Bool
}

enum SteamacEvidencePreparationError: Error, Equatable {
    case invalidExpectedDigest
    case notRegularFile
    case invalidPayloadSize
    case changedDuringRead
}

enum SteamacTransactionEvidencePreparation {
    // 512 MiB maximum, consistent with the 42A-3 downloader hard limit.
    private static let maximumBytes: UInt64 = 512 * 1024 * 1024

    static func verifyLocalPayload(at url: URL, expectedSHA256: String) throws -> SteamacPreparedPayloadEvidence {
        let expected = expectedSHA256.lowercased()
        guard expected.count == 64 && expected.utf8.allSatisfy({
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }) else { throw SteamacEvidencePreparationError.invalidExpectedDigest }
        // No downloads or guest requests. Only hash an existing regular local file.
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (before[.type] as? FileAttributeType) == .typeRegular else {
            throw SteamacEvidencePreparationError.notRegularFile
        }
        guard let size = (before[.size] as? NSNumber)?.uint64Value,
              size >= 64 * 1024 && size <= maximumBytes else {
            throw SteamacEvidencePreparationError.invalidPayloadSize
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var count: UInt64 = 0
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            count += UInt64(chunk.count)
            guard count <= maximumBytes else { throw SteamacEvidencePreparationError.invalidPayloadSize }
            digest.update(data: chunk)
        }
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        guard count == size,
              before[.size] as? NSNumber == after[.size] as? NSNumber,
              before[.modificationDate] as? Date == after[.modificationDate] as? Date,
              before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber else {
            throw SteamacEvidencePreparationError.changedDuringRead
        }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        return SteamacPreparedPayloadEvidence(
            fileName: url.lastPathComponent, byteCount: count,
            computedSHA256: actual, expectedSHA256: expected,
            digestMatches: actual == expected,
            provenanceAuthenticated: false, installationAuthorized: false
        )
    }
}

// Descriptive checklist only. No snapshot or restore operation is implemented.
struct SteamacRecoveryReadinessChecklist: Codable, Hashable {
    let appID: UInt32
    let framework: SteamacInstallationFramework
    let items: [String]
    let snapshotVerified: Bool
    let rollbackVerified: Bool
    let verificationCriteriaApproved: Bool
    let installationAuthorized: Bool
}

enum SteamacRecoveryReadinessPreparation {
    static func checklist(appID: UInt32, framework: SteamacInstallationFramework) -> SteamacRecoveryReadinessChecklist {
        SteamacRecoveryReadinessChecklist(
            appID: appID, framework: framework,
            items: [
                "Inventory all possible installer write locations; a Proton prefix alone may be insufficient.",
                "Capture a consistent, AppID-scoped backup only after separate authorization; include relevant external paths.",
                "Verify backup contents and permissions against a recorded manifest.",
                "Test restoration in an isolated disposable environment, never against the live game or prefix.",
                "Define post-install inventory checks and separately attest actual runtime loading.",
                "Obtain independent review of snapshot, rollback, provenance and verification evidence."
            ],
            snapshotVerified: false, rollbackVerified: false,
            verificationCriteriaApproved: false, installationAuthorized: false
        )
    }
}
