import Foundation

// 42A-19: Bounded metadata probes only; never read contents, enumerate, or mutate.
enum SteamacRecoveryScopeDiscovery {
    struct Candidate: Equatable {
        let path: String
        let purpose: String
    }
    static func candidates(install: String, prefix: String?) -> [Candidate] {
        var result: [Candidate] = []
        if SteamacRecoveryScopePlan.usableGuestPath(install) {
            result += [Candidate(path: install, purpose: "observed install root")]
            for name in ["winmm.dll", "version.dll", "dinput8.dll", "Reloaded-II", "BepInEx", "doorstop_config.ini"] {
                result.append(Candidate(path: (install.hasSuffix("/") ? String(install.dropLast()) : install) + "/" + name,
                                        purpose: "loader/config candidate; presence does not establish ownership or injection"))
            }
        }
        if let prefix, SteamacRecoveryScopePlan.usableGuestPath(prefix) {
            let base = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
            result.append(Candidate(path: base, purpose: "resolved prefix root"))
            for name in ["system.reg", "user.reg", "drive_c", "dosdevices", "drive_c/users",
                         "drive_c/users/steamuser/AppData/Local", "drive_c/users/steamuser/AppData/Roaming",
                         "drive_c/users/steamuser/Documents"] {
                result.append(Candidate(path: base + "/" + name,
                                        purpose: "prefix/save-container candidate; steamuser is a hypothesis, actual saves unresolved"))
            }
        }
        return result
    }
    static func report(appID: UInt32, name: String, install: String, prefix: String?,
                       prefixEvidence: String, probe: (String) throws -> (kind: String, size: UInt64)) -> String {
        let started = ISO8601DateFormatter().string(from: Date())
        let paths = candidates(install: install, prefix: prefix)
        var errors = 0
        let rows = paths.map { candidate -> String in
            do {
                let result = try probe(candidate.path)
                return "\(candidate.path)\n  Guest-reported kind: \(result.kind) · reported bytes: \(result.size)\n  Scope: \(candidate.purpose)"
            } catch {
                errors += 1
                return "\(candidate.path)\n  UNAVAILABLE: \(error.localizedDescription)\n  Scope: \(candidate.purpose)"
            }
        }.joined(separator: "\n")
        return """
        42A-19 · READ-ONLY GUEST RECOVERY SCOPE DISCOVERY
        Game: \(name) · AppID \(appID)
        Collection started: \(started)
        Collection completed: \(ISO8601DateFormatter().string(from: Date()))
        Status: PARTIAL / INCOMPLETE (\(paths.count) bounded candidate probes; \(errors) unavailable)
        Prefix resolution: \(prefixEvidence)
        Metadata observations are non-atomic and may change during collection. Missing means only the probed path was reported missing; errors never mean absence.

        COLLECTED METADATA
        \(rows.isEmpty ? "No valid candidate roots; collection blocked" : rows)

        PROTOCOL LIMITATIONS / UNRESOLVED SCOPE
        Generic directory enumeration: UNAVAILABLE in current host bridge
        Actual save filenames/locations and Steam account userdata: UNRESOLVED; container presence is not save discovery
        Symlink targets and no-follow semantics for ancestor components: NOT VERIFIED; no recursive traversal or link-target follow-up is performed
        Mount boundaries/device IDs: NOT COLLECTED (no supported query)
        Ownership/permissions/ACLs/extended attributes/hashes: NOT COLLECTED by fs-stat
        Full prefix/game inventory and external/shared installer writes: NOT ESTABLISHED
        Process quiescence, Steam Cloud consistency, backup capacity/destination: NOT CHECKED
        Requires an AppID-scoped, bounded, no-follow guest inventory API to complete discovery; no shell or mutation fallback attempted.

        Snapshot/rollback restorability in guest: NOT VERIFIED
        Publisher provenance: NOT VERIFIED
        Verification criteria: NOT APPROVED
        Transaction preflight: NOT RE-RUN
        Safety review attestations: UNCHANGED · Installation/injection authorization: NONE
        Only existing proton-prefix and fs-stat read-only queries used. No snapshot/restore, payload execution, installation, or game/prefix/save modification.
        """
    }
}
