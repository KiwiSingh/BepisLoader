import Foundation

// 41F-21D.16: Host-only, pure pre-installation manifest audit.
// A passing structural audit is NOT provenance, restorability, consent, or permission to install.
struct SteamacInstallationSafetyManifest: Codable, Hashable {
    let transactionID: UUID
    let appID: UInt32
    let framework: SteamacInstallationFramework
    let endpointProcessID: Int32
    let payloadPin: SteamacPayloadTrustPin
    let guestPathsToChange: [String]
    let snapshotPaths: [String]
    let rollbackPaths: [String]
    let verificationCriteria: [String]
}

enum SteamacInstallationManifestIssue: String, Codable, Hashable {
    case invalidScope, unsafeOperation, invalidPin, unsafePath, duplicatePath
    case snapshotCoverageMissing, rollbackCoverageMissing, missingVerificationCriteria
    case provenanceNotAuthenticated, snapshotNotTested, rollbackNotTested, consentNotAuthenticated
}

struct SteamacInstallationManifestAudit: Codable, Hashable {
    let issues: [SteamacInstallationManifestIssue]
    var readyForInstallation: Bool { false }
    var structurallyValid: Bool {
        !issues.contains(where: {
            switch $0 {
            case .invalidScope, .unsafeOperation, .invalidPin, .unsafePath,
                 .duplicatePath, .snapshotCoverageMissing, .rollbackCoverageMissing,
                 .missingVerificationCriteria: return true
            default: return false
            }
        })
    }
}

enum SteamacInstallationManifestAuditor {
    static func audit(_ manifest: SteamacInstallationSafetyManifest,
                      transaction: SteamacInstallationTransaction) -> SteamacInstallationManifestAudit {
        var issues: [SteamacInstallationManifestIssue] = []
        func flag(_ condition: Bool, _ issue: SteamacInstallationManifestIssue) {
            if condition { issues.append(issue) }
        }
        flag(transaction.id != manifest.transactionID || transaction.appID == 0 ||
             transaction.appID != manifest.appID || transaction.framework != manifest.framework ||
             manifest.endpointProcessID <= 0 || transaction.state != .proposed, .invalidScope)
        flag(transaction.operations.contains { $0.hasUnboundedSideEffects || $0.kind == .runExternalInstaller }, .unsafeOperation)
        let pin = manifest.payloadPin
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        let url = URL(string: pin.sourceURL)
        flag(pin.framework != manifest.framework || pin.version.isEmpty || pin.publisher.isEmpty ||
             pin.expectedByteCount == 0 || pin.expectedByteCount > SteamacPayloadIntegrityAttestor.maximumPayloadBytes ||
             pin.sha256.count != 64 || !pin.sha256.unicodeScalars.allSatisfy { hex.contains($0) } ||
             url?.scheme != "https" || url?.host == nil, .invalidPin)
        let all = manifest.guestPathsToChange + manifest.snapshotPaths + manifest.rollbackPaths
        func safe(_ path: String) -> Bool {
            guard path.hasPrefix("/home/steamos/"), !path.contains("\u{0}"), !path.contains("\\"),
                  !path.hasSuffix("/"), !path.contains("//") else { return false }
            return !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        }
        flag(manifest.guestPathsToChange.isEmpty || all.contains(where: { !safe($0) }), .unsafePath)
        flag(Set(manifest.guestPathsToChange).count != manifest.guestPathsToChange.count ||
             Set(manifest.snapshotPaths).count != manifest.snapshotPaths.count ||
             Set(manifest.rollbackPaths).count != manifest.rollbackPaths.count, .duplicatePath)
        let changed = Set(manifest.guestPathsToChange)
        flag(!changed.isSubset(of: Set(manifest.snapshotPaths)), .snapshotCoverageMissing)
        flag(!changed.isSubset(of: Set(manifest.rollbackPaths)), .rollbackCoverageMissing)
        flag(manifest.verificationCriteria.isEmpty ||
             manifest.verificationCriteria.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
             .missingVerificationCriteria)
        // These requirements CANNOT be established by caller-authored manifest text.
        issues += [.provenanceNotAuthenticated, .snapshotNotTested, .rollbackNotTested, .consentNotAuthenticated]
        return SteamacInstallationManifestAudit(issues: issues)
    }
}
