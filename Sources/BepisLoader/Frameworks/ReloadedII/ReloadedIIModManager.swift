import Foundation

// ─────────────────────────────────────────────
//  ReloadedIIModManager
//
//  Reloaded-II implementation of the generic
//  ModManaging abstraction.
//
//  Reloaded-II mods are normally directories,
//  rather than loose BepInEx-style plugin DLLs.
// ─────────────────────────────────────────────

final class ReloadedIIModManager: ModManaging {

    static let shared = ReloadedIIModManager()

    let framework: ModFramework = .reloadedII

    private let fm = FileManager.default

    private init() {}

    // ── Installed mods ────────────────────────

    func installedMods(for game: GameInstall) -> [InstalledMod] {
        let paths = ReloadedIIPaths(game: game)

        guard fm.fileExists(atPath: paths.mods.path) else {
            return []
        }

        let contents = (try? fm.contentsOfDirectory(
            at: paths.mods,
            includingPropertiesForKeys: [
                .isDirectoryKey
            ],
            options: .skipsHiddenFiles
        )) ?? []

        return contents.compactMap { url in
            guard isDirectory(url) else {
                return nil
            }

            return InstalledMod(
                id: url.lastPathComponent,
                name: url.lastPathComponent,
                version: nil,
                author: nil,
                description: "",
                framework: framework,
                path: url,
                isEnabled: true
            )
        }
    }

    // ── Install ────────────────────────────────

    func installMod(
        from source: URL,
        into game: GameInstall
    ) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                source.stopAccessingSecurityScopedResource()
            }
        }

        guard isDirectory(source) else {
            throw ReloadedIIModError.expectedDirectory
        }

        let paths = ReloadedIIPaths(game: game)

        if !fm.fileExists(atPath: paths.mods.path) {
            try fm.createDirectory(
                at: paths.mods,
                withIntermediateDirectories: true
            )
        }

        let destination = paths.mods.appendingPathComponent(
            source.lastPathComponent
        )

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }

        try fm.copyItem(
            at: source,
            to: destination
        )
    }

    // ── Remove ────────────────────────────────

    func removeMod(
        _ mod: InstalledMod,
        from game: GameInstall
    ) throws {
        guard mod.framework == framework else {
            throw ReloadedIIModError.wrongFramework
        }

        let target = ReloadedIIPaths(game: game)
            .mods
            .appendingPathComponent(mod.path.lastPathComponent)

        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
    }

    // ── Enable / Disable ──────────────────────
    //
    // Real Reloaded-II enable/disable semantics will be
    // implemented once its configuration format becomes
    // part of the integration. Do not fake it by renaming
    // directories.

    func setModEnabled(
        _ enabled: Bool,
        mod: InstalledMod,
        in game: GameInstall
    ) throws {
        guard mod.framework == framework else {
            throw ReloadedIIModError.wrongFramework
        }

        throw ReloadedIIModError.enableDisableNotImplemented
    }

    // ── Helpers ───────────────────────────────

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false

        guard fm.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) else {
            return false
        }

        return isDirectory.boolValue
    }

    enum ReloadedIIModError: LocalizedError {
        case expectedDirectory
        case wrongFramework
        case enableDisableNotImplemented

        var errorDescription: String? {
            switch self {
            case .expectedDirectory:
                return "Reloaded-II mods must be installed from a directory"

            case .wrongFramework:
                return "This mod does not belong to Reloaded-II"

            case .enableDisableNotImplemented:
                return "Reloaded-II mod enable/disable is not implemented yet"
            }
        }
    }
}
