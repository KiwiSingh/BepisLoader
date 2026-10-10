import Foundation
import CryptoKit

// 42A-15: Host-only acquisition. No bridge, installer, or review-attestation access.
final class SteamacReloadedReleaseFetcher: NSObject, URLSessionTaskDelegate {
    private static let repository = "https://github.com/Reloaded-Project/Reloaded-II"
    private static let maximumBytes = 128 * 1024 * 1024
    private struct Release: Decodable {
        let id: Int64
        let tag_name: String
        let name: String?
        let html_url: String
        let published_at: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }
    private struct Asset: Decodable {
        let id: Int64
        let name: String
        let size: Int
        let state: String
        let digest: String?
        let browser_download_url: String
    }
    enum Failure: LocalizedError {
        case rejected(String)
        var errorDescription: String? {
            switch self { case .rejected(let reason): return reason }
        }
    }
    private static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return ["api.github.com", "github.com", "release-assets.githubusercontent.com",
                "objects.githubusercontent.com"].contains(url.host?.lowercased() ?? "")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map { Self.allowed($0) } == true ? request : nil)
    }
    private func stream(_ url: URL, session: URLSession, limit: Int,
                        acceptedStatuses: Set<Int> = [200],
                        status: (Int) -> Void = { _ in },
                        consume: (Data) throws -> Void) async throws -> Int {
        guard Self.allowed(url) else { throw Failure.rejected("Unapproved source URL") }
        var request = URLRequest(url: url)
        request.setValue("BepisLoader-42A-15", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, acceptedStatuses.contains(http.statusCode),
              let finalURL = http.url, Self.allowed(finalURL),
              response.expectedContentLength <= Int64(limit) else {
            throw Failure.rejected("Release request rejected (HTTP status, source, or size)")
        }
        status(http.statusCode)
        var chunk = Data()
        var total = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            total += 1
            guard total <= limit else { throw Failure.rejected("Response exceeds size limit") }
            chunk.append(byte)
            if chunk.count == 65536 { try consume(chunk); chunk.removeAll(keepingCapacity: true) }
        }
        if !chunk.isEmpty { try consume(chunk) }
        return total
    }
    func fetch(discoverProvenance: Bool = false) async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let api = URL(string: "https://api.github.com/repos/Reloaded-Project/Reloaded-II/releases/latest")!
        var metadata = Data()
        _ = try await stream(api, session: session, limit: 2 * 1024 * 1024) { metadata.append($0) }
        let release = try JSONDecoder().decode(Release.self, from: metadata)
        let matches = release.assets.filter { $0.name == "Setup-Linux.exe" }
        guard !release.draft, !release.prerelease, !release.tag_name.isEmpty,
              release.html_url.hasPrefix(Self.repository + "/releases/tag/"),
              matches.count == 1, let asset = matches.first,
              asset.state == "uploaded", asset.size > 0, asset.size <= Self.maximumBytes,
              let source = URL(string: asset.browser_download_url), Self.allowed(source),
              source.host == "github.com",
              source.path.hasPrefix("/Reloaded-Project/Reloaded-II/releases/download/"),
              source.lastPathComponent == "Setup-Linux.exe" else {
            throw Failure.rejected("Latest stable release has invalid or ambiguous Linux installer metadata")
        }
        let reference: String?
        if let digest = asset.digest {
            let hex = String(digest.dropFirst(7)).lowercased()
            guard digest.hasPrefix("sha256:"), hex.count == 64,
                  hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw Failure.rejected("Invalid upstream SHA-256 metadata")
            }
            reference = hex
        } else { reference = nil }
        let fm = FileManager.default
        let root = try fm.url(for: .cachesDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
        let directory = root.appendingPathComponent("BepisLoader/42A-15/" + UUID().uuidString,
                                                    isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        var completed = false
        defer { if !completed { try? fm.removeItem(at: directory) } }
        let file = directory.appendingPathComponent("Setup-Linux.exe")
        guard fm.createFile(atPath: file.path, contents: nil,
                            attributes: [.posixPermissions: 0o600]) else {
            throw Failure.rejected("Cannot create host cache file")
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        let count = try await stream(source, session: session, limit: asset.size) {
            try handle.write(contentsOf: $0)
            hasher.update(data: $0)
        }
        try handle.synchronize()
        guard count == asset.size else { throw Failure.rejected("Downloaded byte count differs from release metadata") }
        let observed = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if let reference, reference != observed {
            throw Failure.rejected("SHA-256 MISMATCH — downloaded payload discarded")
        }
        let provenance: String
        if discoverProvenance {
            provenance = await discover(release: release, file: file, digest: observed,
                                        session: session, directory: directory)
        } else { provenance = "" }
        let report = """
        42A-15 · HOST-ONLY RELOADED-II RELEASE FETCH
        Retrieved: \(ISO8601DateFormatter().string(from: Date()))
        Repository: \(Self.repository)
        Release: \(release.name ?? release.tag_name) · Tag: \(release.tag_name)
        Release ID: \(release.id) · Asset ID: \(asset.id)
        Published: \(release.published_at ?? "Not supplied")
        Release page: \(release.html_url)
        Asset URL: \(source.absoluteString)
        Host cache: \(file.path)
        Bytes: \(count)
        Computed SHA-256: \(observed)
        GitHub API SHA-256: \(reference ?? "NOT PROVIDED")
        Integrity: \(reference == nil ? "HASH COMPUTED ONLY — no reference comparison" : "MATCH against GitHub API digest")
        Authenticated publisher provenance: NOT VERIFIED
        HTTPS and an official repository URL do not independently authenticate publisher identity or build provenance. No signature or independently trusted digest was verified.
        \(provenance)
        Recovery/snapshot/rollback: NOT VERIFIED
        Safety review attestations: UNCHANGED · No installation authorization
        Payload downloaded to host cache only; never executed, installed, or sent to guest.
        Game files, prefix, and saves untouched by this workflow.
        """
        try metadata.write(to: directory.appendingPathComponent("release.json"), options: .atomic)
        try report.write(to: directory.appendingPathComponent("evidence.txt"), atomically: true, encoding: .utf8)
        completed = true
        return report
    }
    // Presence discovery only. Neither API metadata nor certificate bytes establish trust.
    private func discover(release: Release, file: URL, digest: String,
                          session: URLSession, directory: URL) async -> String {
        let candidates = release.assets.map { $0.name }.filter {
            let name = $0.lowercased()
            return [".asc", ".sig", ".p7s", ".pem", ".crt", ".sigstore", ".intoto.jsonl"].contains {
                name.hasSuffix($0)
            } || name.contains("sha256") || name.contains("checksum") || name.contains("attestation")
        }
        let certificate: String
        do { certificate = try Self.certificateTableStatus(Data(contentsOf: file)) }
        catch { certificate = "INSPECTION FAILED: \(error.localizedDescription)" }
        let endpoint = "https://api.github.com/repos/Reloaded-Project/Reloaded-II/attestations/sha256:" + digest
        var body = Data()
        var code = 0
        let attestation: String
        do {
            _ = try await stream(URL(string: endpoint)!, session: session, limit: 4 * 1024 * 1024,
                                 acceptedStatuses: [200, 401, 403, 404, 429], status: { code = $0 }) {
                body.append($0)
            }
            // Retain the bounded raw response for review, never treat it as an approval.
            try body.write(to: directory.appendingPathComponent("attestation-response.json"), options: .atomic)
            if code == 200 {
                let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                guard let entries = object?["attestations"] as? [Any] else {
                    throw Failure.rejected("Unexpected attestation response schema")
                }
                attestation = entries.isEmpty
                    ? "No entries returned on this page (HTTP 200); provenance remains unverified"
                    : "\(entries.count) candidate(s) returned on first page — signatures, subjects, workflow identity, and trust roots NOT VERIFIED"
            } else {
                attestation = "UNAVAILABLE (HTTP \(code)); absence cannot be established from this response"
            }
        } catch { attestation = "LOOKUP FAILED: \(error.localizedDescription); provenance remains unverified" }
        return """
        42A-16 · PROVENANCE EVIDENCE DISCOVERY (READ-ONLY)
        Scope: this release's asset names, downloaded PE certificate directory, and digest-specific public GitHub attestation API. Not an exhaustive upstream audit.
        Signature/checksum sidecar candidates: \(candidates.isEmpty ? "None found among release assets" : candidates.joined(separator: ", "))
        Candidate sidecars are not downloaded or cryptographically verified.
        Embedded Authenticode certificate table: \(certificate)
        Certificate presence does not verify a signature, certificate chain, publisher identity, revocation, or timestamp.
        Attestation query: \(endpoint)
        Attestation discovery: \(attestation)
        Signed source commits/tags do not authenticate the downloaded binary.
        Publisher trust pin: NOT ESTABLISHED
        Authenticated publisher provenance: NOT VERIFIED · Installation gate remains blocked
        """
    }

    // Bounds-checked PE32/PE32+ security directory parsing; never loads the executable.
    static func certificateTableStatus(_ data: Data) throws -> String {
        func u16(_ offset: Int) throws -> Int {
            guard offset >= 0, offset <= data.count - 2 else { throw Failure.rejected("Truncated PE header") }
            return Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> Int {
            guard offset >= 0, offset <= data.count - 4 else { throw Failure.rejected("Truncated PE header") }
            return (0..<4).reduce(0) { $0 | Int(data[offset + $1]) << (8 * $1) }
        }
        guard try u16(0) == 0x5a4d else { throw Failure.rejected("Not an MZ executable") }
        let pe = try u32(60)
        guard pe >= 64, try u32(pe) == 0x4550 else { throw Failure.rejected("Invalid PE signature") }
        let optional = pe + 24
        let optionalSize = try u16(pe + 20)
        let magic = try u16(optional)
        guard magic == 0x10b || magic == 0x20b else { throw Failure.rejected("Unsupported PE optional header") }
        let base = magic == 0x20b ? 112 : 96
        guard optionalSize >= base, optional <= data.count - optionalSize else {
            throw Failure.rejected("Truncated PE optional header")
        }
        let directories = try u32(optional + base - 4)
        if directories <= 4 { return "ABSENT (no security directory)" }
        guard optionalSize >= base + 40 else { throw Failure.rejected("Truncated security directory") }
        let offset = try u32(optional + base + 32)
        let size = try u32(optional + base + 36)
        if offset == 0 && size == 0 { return "ABSENT (no embedded signature)" }
        guard offset > 0, offset % 8 == 0, size >= 8, offset <= data.count - size else {
            throw Failure.rejected("Invalid certificate table bounds")
        }
        return "PRESENT (\(size) bytes) — signature NOT VERIFIED"
    }

}
