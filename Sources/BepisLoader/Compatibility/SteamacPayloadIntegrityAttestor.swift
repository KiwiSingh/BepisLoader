import Foundation
import CryptoKit

// 41F-21D.14: Host-only, read-only payload integrity check.
// Trust pins MUST be independently established; caller-supplied pins are not authenticated.
struct SteamacPayloadTrustPin: Codable, Hashable {
    let framework: SteamacInstallationFramework
    let version: String
    let publisher: String
    let sourceURL: String
    let sha256: String
    let expectedByteCount: UInt64
}

enum SteamacPayloadAttestationIssue: String, Codable, Hashable {
    case missingTrustPin, invalidTrustPin, identityMismatch, missingPayload
    case nonRegularFile, fileTooLarge, unreadablePayload, sizeMismatch, digestMismatch
}

struct SteamacPayloadAttestationResult: Codable, Hashable {
    let framework: SteamacInstallationFramework
    let version: String
    let expectedDigest: String?
    let observedDigest: String?
    let issues: [SteamacPayloadAttestationIssue]
    var integrityMatchesPin: Bool { issues.isEmpty }
    // This is NOT publisher authentication, provenance attestation, or installation approval.
    var publisherAuthenticated: Bool { false }
}

enum SteamacPayloadIntegrityAttestor {
    static let maximumPayloadBytes: UInt64 = 2 * 1024 * 1024 * 1024

    static func verify(
        fileURL: URL,
        framework: SteamacInstallationFramework,
        version: String,
        pin: SteamacPayloadTrustPin?,
        maximumBytes: UInt64 = maximumPayloadBytes
    ) -> SteamacPayloadAttestationResult {
        var issues: [SteamacPayloadAttestationIssue] = []
        var observed: String?
        func result() -> SteamacPayloadAttestationResult {
            SteamacPayloadAttestationResult(framework: framework, version: version,
                expectedDigest: pin?.sha256, observedDigest: observed, issues: issues)
        }
        guard let pin else { issues.append(.missingTrustPin); return result() }
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        guard pin.sha256.count == 64,
              pin.sha256.unicodeScalars.allSatisfy({ hex.contains($0) }),
              !pin.version.isEmpty, !pin.publisher.isEmpty,
              let source = URL(string: pin.sourceURL), source.scheme == "https",
              source.host != nil, pin.expectedByteCount > 0,
              maximumBytes > 0, pin.expectedByteCount <= maximumBytes else {
            issues.append(.invalidTrustPin); return result()
        }
        guard pin.framework == framework, pin.version == version else {
            issues.append(.identityMismatch); return result()
        }
        guard fileURL.isFileURL else { issues.append(.nonRegularFile); return result() }
        let path = fileURL.path
        var st = stat()
        guard lstat(path, &st) == 0 else { issues.append(.missingPayload); return result() }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            issues.append(.nonRegularFile); return result()
        }
        guard st.st_size >= 0, UInt64(st.st_size) <= maximumBytes else {
            issues.append(.fileTooLarge); return result()
        }
        guard UInt64(st.st_size) == pin.expectedByteCount else {
            issues.append(.sizeMismatch); return result()
        }
        // O_NOFOLLOW blocks a final-component symlink swap; fstat checks the opened inode.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { issues.append(.unreadablePayload); return result() }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0,
              (opened.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              opened.st_dev == st.st_dev, opened.st_ino == st.st_ino,
              opened.st_size == st.st_size else {
            issues.append(.nonRegularFile); return result()
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 65536)
        var count: UInt64 = 0
        while true {
            let n = buffer.withUnsafeMutableBytes { raw in read(fd, raw.baseAddress, raw.count) }
            if n < 0 { if errno == EINTR { continue }; issues.append(.unreadablePayload); return result() }
            if n == 0 { break }
            count += UInt64(n)
            if count > maximumBytes { issues.append(.fileTooLarge); return result() }
            hasher.update(data: Data(buffer[0..<n]))
        }
        guard count == pin.expectedByteCount else { issues.append(.sizeMismatch); return result() }
        observed = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if observed != pin.sha256 { issues.append(.digestMismatch) }
        return result()
    }
}
