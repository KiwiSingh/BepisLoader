import Foundation

// ─────────────────────────────────────────────
//  ReloadedIIPaths
//
//  Discovers Reloaded-II inside the game's Wine
//  prefix.
//
//  Setup-Linux.exe installs Reloaded-II onto the
//  Wine user's Desktop. Wine user names differ
//  between compatibility layers, so never assume
//  "steamuser" or the macOS account name.
// ─────────────────────────────────────────────

struct ReloadedIIPaths {

    let game: GameInstall

    private let fm = FileManager.default

    // ── Prefix ────────────────────────────────

    var prefix: URL {
        game.bottle.path
    }

    var usersRoot: URL {
        prefix
            .appendingPathComponent("drive_c")
            .appendingPathComponent("users")
    }

    // ── Installation discovery ────────────────

    var installationRoot: URL? {
        discoverInstallationRoot()
    }

    var executable: URL? {
        guard let root = installationRoot else {
            return nil
        }

        let executable = root
            .appendingPathComponent("Reloaded-II.exe")

        guard fm.fileExists(
            atPath: executable.path
        ) else {
            return nil
        }

        return executable
    }

    var mods: URL? {
        installationRoot?
            .appendingPathComponent("Mods")
    }

    // ── Discovery ─────────────────────────────

    private func discoverInstallationRoot() -> URL? {
        guard let users = try? fm.contentsOfDirectory(
            at: usersRoot,
            includingPropertiesForKeys: [
                .isDirectoryKey
            ],
            options: [
                .skipsHiddenFiles
            ]
        ) else {
            return nil
        }

        for user in users {
            guard isDirectory(user) else {
                continue
            }

            let candidate = user
                .appendingPathComponent("Desktop")
                .appendingPathComponent("Reloaded-II")

            let executable = candidate
                .appendingPathComponent("Reloaded-II.exe")

            if fm.fileExists(
                atPath: executable.path
            ) {
                return candidate
            }
        }

        return nil
    }

    private func isDirectory(
        _ url: URL
    ) -> Bool {
        var isDirectory: ObjCBool = false

        guard fm.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) else {
            return false
        }

        return isDirectory.boolValue
    }
}
