import Foundation

// 42A-18: Descriptive plan only. No file access, bridge calls, or review mutations.
enum SteamacRecoveryScopePlan {
    static func usableGuestPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" &&
        !path.split(separator: "/").contains("..") &&
        !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func report(appID: UInt32, name: String, installPath: String,
                       libraryPath: String, prefix: String, runtime: String,
                       collectedAt: Date = Date()) -> String {
        func shown(_ path: String) -> String {
            usableGuestPath(path) ? path : "UNRESOLVED/INVALID — scope blocker"
        }
        return """
        42A-18 · READ-ONLY RECOVERY SCOPE PLAN
        Game: \(name) · AppID \(appID)
        Existing inspection collected: \(ISO8601DateFormatter().string(from: collectedAt))
        Evidence is a point-in-time observation. Refresh connection/library and reselect the game to recheck.
        Plan status: DRAFT / INCOMPLETE · Not a backup or restoration proof

        OBSERVED PATH CANDIDATES (GUEST PATHS; NEVER OPENED ON HOST)
        Game install: \(shown(installPath))
        Steam library: \(shown(libraryPath))
        Resolved Proton prefix: \(shown(prefix))
        Runtime observation: \(runtime)
        These paths are candidates, not an authenticated or exhaustive installer write inventory.
        Do not snapshot an entire Steam library by default; establish AppID-specific boundaries first.

        REQUIRED SCOPE DISCOVERY — NOT YET PERFORMED
        • Inventory the entire relevant prefix, including registry, drive_c, dosdevices links, ownership, permissions, ACLs, extended attributes, and link targets.
        • Identify game-directory loader DLLs/configuration and any pre-existing framework or mod files that may be replaced.
        • Locate actual saves/configuration both inside and outside the prefix. Steam userdata/<account>/\(appID) is only a candidate; account, library/home roots, and external saves remain unresolved.
        • Identify Reloaded-II installer/dependency write locations, shortcuts, AppData, desktop paths, caches, and any shared/system locations. Payload write scope remains unknown.
        • Resolve symlinks and mount boundaries without silently following them; record exclusions and external targets requiring separate protection.
        • Establish Steam Cloud policy, running-process/quiescence checks, and conflicts with concurrent game, Steam, or Wine activity.
        • Determine backup destination, independent failure domain, available capacity, retention, confidentiality, and recovery-tool availability. None selected or measured.

        SNAPSHOT ACCEPTANCE CRITERIA — PROPOSED, NOT APPROVED
        • Bind evidence to guest identity, AppID, canonical scope, exact payload digest/version, and collection time; reject stale or changed evidence.
        • Capture a consistent manifest of paths/types, regular-file sizes/SHA-256, links, permissions/ownership, ACLs and extended attributes; record unreadable files and exclusions as blockers.
        • Verify copied data and metadata against the baseline and demonstrate backup availability independently of the installation target.
        • Restore a representative guest snapshot into an isolated disposable guest environment; verify files, deletions, empty directories, metadata and links without overwriting live data.

        ROLLBACK AND POST-INSTALL CRITERIA — PROPOSED, NOT APPROVED
        • Define exact added/replaced/deleted paths, failure triggers and a reviewed restore procedure; preserve pre-existing mods and dependencies.
        • Recheck snapshot integrity before restore; demonstrate interrupted/partial-operation recovery and fail-closed handling of corrupt or missing backup data.
        • Compare restored guest manifests and separately review game/save usability. Host fixture success does not prove these properties.
        • Define framework inventory/configuration checks separately from authorized launch/injection verification. Neither is performed here.

        UNRESOLVED GATES
        Publisher provenance: NOT VERIFIED (integrity matching alone is insufficient)
        Exhaustive installer write scope / actual saves: NOT VERIFIED
        Snapshot restorability in guest: NOT VERIFIED
        Rollback restorability in guest: NOT VERIFIED
        Verification criteria: NOT APPROVED
        Transaction preflight: NOT RE-RUN by this plan; no passing result established here
        Safety review attestations: UNCHANGED
        Installation/injection authorization: NONE
        42A-17 synthetic host rehearsal is limited evidence only; this plan does not import it as a safety approval.

        No snapshot, restore, payload execution, installation, injection, guest mutation, or game/prefix/save modification is performed by this report.
        """
    }
}
