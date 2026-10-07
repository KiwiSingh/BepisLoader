import Foundation

// ─────────────────────────────────────────────
//  ReloadedIIPaths
//
//  Discovers Reloaded-II inside the game's Wine
//  prefix and maps paths between macOS and Wine.
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

    var driveC: URL {
        prefix
            .appendingPathComponent("drive_c")
    }

    var usersRoot: URL {
        driveC
            .appendingPathComponent("users")
    }

    // ── Reloaded-II installation ──────────────

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

    // Reloaded-II's default
    // ApplicationConfigDirectory is "Apps",
    // relative to the Reloaded-II installation.
    var applications: URL? {
        installationRoot?
            .appendingPathComponent("Apps")
    }

    // ── Application config paths ──────────────

    func applicationDirectory(
        appId: String
    ) -> URL? {
        applications?
            .appendingPathComponent(
                appId,
                isDirectory: true
            )
    }

    func applicationConfig(
        appId: String
    ) -> URL? {
        applicationDirectory(
            appId: appId
        )?
        .appendingPathComponent(
            "AppConfig.json"
        )
    }

    // ── Wine path conversion ──────────────────

    func windowsPath(
        for hostURL: URL
    ) -> String? {
        let root = driveC
            .standardizedFileURL
            .path

        let target = hostURL
            .standardizedFileURL
            .path

        guard target == root ||
              target.hasPrefix(root + "/")
        else {
            return nil
        }

        var relative = String(
            target.dropFirst(root.count)
        )

        relative = relative
            .trimmingCharacters(
                in: CharacterSet(
                    charactersIn: "/"
                )
            )

        if relative.isEmpty {
            return "C:\\"
        }

        return "C:\\" + relative
            .replacingOccurrences(
                of: "/",
                with: "\\"
            )
    }

    func requiredWindowsPath(
        for hostURL: URL
    ) throws -> String {
        guard let result =
                windowsPath(
                    for: hostURL
                )
        else {
            throw PathError.outsideDriveC(
                hostURL
            )
        }

        return result
    }

    enum PathError:
        LocalizedError
    {
        case outsideDriveC(URL)

        var errorDescription: String? {
            switch self {

            case .outsideDriveC(
                let url
            ):
                return """
                \(url.path) is outside this \
                Wine prefix's C: drive
                """
            }
        }
    }


    // ── Installation discovery ────────────────

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
