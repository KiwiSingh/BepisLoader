import Foundation

struct SteamacGuestRecoveryInventory: Codable {
    struct Entry: Codable {
        let path: String
        let kind: String
        let size: Int64
        let mode: UInt32
        let uid: UInt32
        let gid: UInt32
        let device: UInt64
        let inode: UInt64
        let mountID: UInt64?
        let mountCrossing: Bool
        let linkTarget: String?
    }
    let root: String
    let entries: [Entry]
    let issues: [String]
    let complete: Bool
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1024 * 1024 else { throw SteamacBridgeError.responseTooLarge }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard SteamacRecoveryScopePlan.usableGuestPath(value.root), value.entries.count <= 4096,
              value.issues.count <= 10000, !value.complete || value.issues.isEmpty else {
            throw SteamacBridgeError.malformedResponse("Invalid inventory bounds/completeness")
        }
        var paths = Set<String>()
        for entry in value.entries {
            guard !entry.path.isEmpty, !entry.path.hasPrefix("/"), entry.path.utf8.count <= 4096,
                  !entry.path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
                  !entry.path.contains("//"), !entry.path.hasSuffix("/"), paths.insert(entry.path).inserted,
                  ["file", "directory", "symlink", "other"].contains(entry.kind), entry.size >= 0,
                  entry.mode <= 0o7777, entry.linkTarget?.utf8.count ?? 0 <= 4096 else {
                throw SteamacBridgeError.malformedResponse("Invalid inventory entry")
            }
        }
        return value
    }
    func summary(scope: String) -> String {
        let links = entries.filter { $0.kind == "symlink" }
        let crossings = entries.filter { $0.mountCrossing }
        let saves = entries.filter {
            let name = $0.path.lowercased()
            return ["save", "digimon", "timestranger", "time stranger", "1984270"].contains { name.contains($0) }
        }
        let sample = entries.prefix(40).map { "\($0.kind) · \($0.size) bytes · mode \(String($0.mode, radix: 8)) · uid/gid \($0.uid)/\($0.gid) · \($0.path)" }.joined(separator: "\n")
        return """
        Scope: \(scope) · Root: \(root)
        Traversal status: \(complete ? "Completed within configured limits (non-atomic)" : "PARTIAL/TRUNCATED — not a complete inventory")
        Entries: \(entries.count) · symlinks: \(links.count) · device crossings: \(crossings.count)
        Issues: \(issues.isEmpty ? "None reported" : issues.joined(separator: "; "))
        Save/name candidates (heuristic only, first 40):
        \(saves.isEmpty ? "No name matches in returned entries; actual saves remain unresolved" : saves.prefix(40).map { $0.path }.joined(separator: "\n"))
        Link targets (first 20; never followed):
        \(links.isEmpty ? "None in returned entries" : links.prefix(20).map { $0.path + " -> " + ($0.linkTarget ?? "unavailable") }.joined(separator: "\n"))
        Entry sample (first 40; full returned manifest saved on host):
        \(sample)
        """
    }
}
