import Foundation
import CryptoKit

// 42A-17: Synthetic host fixtures only. No caller-supplied paths, guest, or installer access.
enum SteamacRecoveryRehearsal {
    struct Entry: Codable, Equatable {
        let kind: String
        let sha256: String?
        let bytes: Int?
        let mode: Int
    }
    enum Failure: LocalizedError {
        case rejected(String)
        var errorDescription: String? {
            switch self { case .rejected(let reason): return reason }
        }
    }
    // Refuse symlinks and special files rather than following them into unrelated data.
    static func manifest(_ root: URL) throws -> [String: Entry] {
        let fm = FileManager.default
        var result: [String: Entry] = [:]
        func visit(_ url: URL, relative: String) throws {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
            guard mode >= 0 else { throw Failure.rejected("Missing fixture permissions") }
            if type == .typeDirectory {
                result[relative] = Entry(kind: "directory", sha256: nil, bytes: nil, mode: mode)
                for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try visit(child, relative: relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent)
                }
            } else if type == .typeRegular {
                let data = try Data(contentsOf: url)
                guard data.count <= 1024 * 1024 else { throw Failure.rejected("Fixture size limit exceeded") }
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                result[relative] = Entry(kind: "file", sha256: hash, bytes: data.count, mode: mode)
            } else { throw Failure.rejected("Symlink or special file rejected in fixture") }
        }
        try visit(root, relative: "")
        return result
    }
    static func requireMatch(_ observed: [String: Entry], _ expected: [String: Entry]) throws {
        guard observed == expected else { throw Failure.rejected("Recovery manifest mismatch — rehearsal failed") }
    }
    static func run() throws -> String {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("BepisLoader-42A-17-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        let fixture = scratch.appendingPathComponent("fixture", isDirectory: true)
        let snapshot = scratch.appendingPathComponent("snapshot", isDirectory: true)
        let staged = scratch.appendingPathComponent("restore-stage", isDirectory: true)
        try fm.createDirectory(at: fixture.appendingPathComponent("config"), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: fixture.appendingPathComponent("empty"), withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        let files: [(String, Data)] = [
            ("config/settings.json", Data("{\"fixtureOnly\":true,\"enabled\":false}\n".utf8)),
            ("synthetic-save.bin", Data((0..<4096).map { UInt8($0 % 256) })),
            ("empty-file", Data())
        ]
        for (path, data) in files {
            guard fm.createFile(atPath: fixture.appendingPathComponent(path).path, contents: data,
                                attributes: [.posixPermissions: 0o600]) else {
                throw Failure.rejected("Could not create disposable fixture")
            }
        }
        let baseline = try manifest(fixture)
        try fm.copyItem(at: fixture, to: snapshot)
        try requireMatch(manifest(snapshot), baseline)
        // Simulate modified bytes, deleted file/empty directory, added file, and changed permissions.
        try Data("synthetic mutation\n".utf8).write(to: fixture.appendingPathComponent("config/settings.json"))
        try fm.removeItem(at: fixture.appendingPathComponent("synthetic-save.bin"))
        try fm.removeItem(at: fixture.appendingPathComponent("empty"))
        try Data("new fixture file".utf8).write(to: fixture.appendingPathComponent("added.txt"))
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.appendingPathComponent("empty-file").path)
        let changed = try manifest(fixture)
        guard changed != baseline else { throw Failure.rejected("Mutation was not detected") }
        // Check snapshot before restoring; stage and verify the copy before replacing fixture.
        try requireMatch(manifest(snapshot), baseline)
        try fm.copyItem(at: snapshot, to: staged)
        try requireMatch(manifest(staged), baseline)
        try fm.removeItem(at: fixture)
        try fm.moveItem(at: staged, to: fixture)
        let restored = try manifest(fixture)
        try requireMatch(restored, baseline)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let root = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let evidence = root.appendingPathComponent("BepisLoader/42A-17/" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: evidence, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var saved = false
        defer { if !saved { try? fm.removeItem(at: evidence) } }
        for (name, value) in [("baseline", baseline), ("mutated", changed), ("restored", restored)] {
            try encoder.encode(value).write(to: evidence.appendingPathComponent(name + ".json"), options: .atomic)
        }
        // Explicit cleanup must succeed before reporting a pass.
        try fm.removeItem(at: scratch)
        let hashes = baseline.keys.sorted().compactMap { path -> String? in
            guard let hash = baseline[path]?.sha256 else { return nil }
            return "\(path): \(hash)"
        }.joined(separator: "\n")
        let report = """
        42A-17 · HOST-ONLY SYNTHETIC RECOVERY REHEARSAL
        Completed: \(ISO8601DateFormatter().string(from: Date()))
        Result: PASS (disposable fixture only)
        Snapshot copy: MATCH against baseline
        Simulated changes: modified bytes, deleted file/directory, added file, changed permissions
        Mutation detection: PASS
        Snapshot recheck and staged restore: MATCH
        Restored paths/types, file sizes/SHA-256, POSIX permissions: EXACT MATCH
        Empty file and empty directory restoration: PASS
        Disposable fixture/snapshot: REMOVED
        Evidence manifests: \(evidence.path)
        Baseline/restored SHA-256:
        \(hashes)
        Scope: ordinary synthetic host files/directories only. ACLs, extended attributes, symlinks, live files, crash recovery, and guest filesystem semantics are not validated.
        Real Steamac snapshot restorability: NOT VERIFIED
        Real Steamac rollback restorability: NOT VERIFIED
        Publisher provenance: NOT VERIFIED
        Verification criteria: NOT APPROVED
        Safety review attestations: UNCHANGED · No installation authorization
        No payload executed or installed. No guest calls or game/prefix/save changes.
        """
        try report.write(to: evidence.appendingPathComponent("evidence.txt"), atomically: true, encoding: .utf8)
        saved = true
        return report
    }
}
