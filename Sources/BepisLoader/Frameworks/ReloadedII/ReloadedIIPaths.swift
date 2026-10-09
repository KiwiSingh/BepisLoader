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

    // ── Environment-aware paths ───────────────
    //
    // The URL properties below remain the compatibility API for
    // host-accessible Wine prefixes. These GameEnvironmentPath
    // properties are authoritative when the game lives in a
    // remote/guest environment such as Steamac.

    var environmentPrefix: GameEnvironmentPath? {
        switch game.backing {
        case .localWine(let bottle):
            return .host(
                bottle.path
            )

        case .steamac(
            _,
            _,
            _,
            let protonPrefix
        ):
            guard let protonPrefix,
                  !protonPrefix.isEmpty
            else {
                return nil
            }

            return .guest(
                protonPrefix
            )
        }
    }

    var environmentDriveC: GameEnvironmentPath? {
        environmentPrefix.map {
            Self.appending(
                $0,
                "drive_c"
            )
        }
    }

    var environmentUsersRoot: GameEnvironmentPath? {
        environmentDriveC.map {
            Self.appending(
                $0,
                "users"
            )
        }
    }


    var environmentGameExecutable: GameEnvironmentPath {
        game.environmentExecutablePath
    }

    var environmentGameDirectory: GameEnvironmentPath {
        switch game.environmentExecutablePath {
        case .host(let executable):
            return .host(
                executable
                    .deletingLastPathComponent()
            )

        case .guest(let executable):
            return .guest(
                Self.guestDeletingLastPathComponent(
                    executable
                )
            )
        }
    }

    // Installation discovery is currently authoritative only for
    // host-accessible Wine environments. Steamac guest discovery
    // is introduced by the next Reloaded-II/Steamac patches.
    var environmentInstallationRoot: GameEnvironmentPath? {
        switch game.environment.filesystem {
        case .local:
            return installationRoot.map {
                .host($0)
            }

        case .guest:
            return nil
        }
    }

    var environmentExecutable: GameEnvironmentPath? {
        environmentInstallationRoot.map {
            Self.appending(
                $0,
                "Reloaded-II.exe"
            )
        }
    }

    var environmentMods: GameEnvironmentPath? {
        environmentInstallationRoot.map {
            Self.appending(
                $0,
                "Mods"
            )
        }
    }

    var environmentApplications: GameEnvironmentPath? {
        environmentInstallationRoot.map {
            Self.appending(
                $0,
                "Apps"
            )
        }
    }

    func environmentApplicationDirectory(
        appId: String
    ) -> GameEnvironmentPath? {
        environmentApplications.map {
            Self.appending(
                $0,
                appId
            )
        }
    }

    func environmentApplicationConfig(
        appId: String
    ) -> GameEnvironmentPath? {
        environmentApplicationDirectory(
            appId: appId
        )
        .map {
            Self.appending(
                $0,
                "AppConfig.json"
            )
        }
    }

    static func guestJoin(
        _ base: String,
        _ component: String
    ) -> String {
        let cleanBase =
            base.hasSuffix("/")
                ? String(base.dropLast())
                : base

        let cleanComponent =
            component.hasPrefix("/")
                ? String(component.dropFirst())
                : component

        if cleanBase.isEmpty {
            return "/" + cleanComponent
        }

        if cleanComponent.isEmpty {
            return cleanBase
        }

        return cleanBase
            + "/"
            + cleanComponent
    }

    static func guestDeletingLastPathComponent(
        _ path: String
    ) -> String {
        var normalized = path

        while normalized.count > 1,
              normalized.hasSuffix("/")
        {
            normalized.removeLast()
        }

        guard let slash =
            normalized.lastIndex(of: "/")
        else {
            return "."
        }

        if slash == normalized.startIndex {
            return "/"
        }

        return String(
            normalized[..<slash]
        )
    }


    static func appending(
        _ base: GameEnvironmentPath,
        _ component: String
    ) -> GameEnvironmentPath {
        switch base {
        case .host(let url):
            return .host(
                url.appendingPathComponent(
                    component
                )
            )

        case .guest(let path):
            return .guest(
                guestJoin(
                    path,
                    component
                )
            )
        }
    }

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

    static func resolveEnvironmentInstallationRoot(
        for game: GameInstall,
        endpoint: SteamacBridgeEndpoint? = nil
    ) throws -> GameEnvironmentPath? {
        let paths =
            ReloadedIIPaths(
                game: game
            )

        switch game.environment.filesystem {
        case .local:
            return paths.installationRoot.map {
                .host($0)
            }

        case .guest:
            guard case .steamac(
                let appId,
                _,
                _,
                _
            ) = game.backing
            else {
                return nil
            }

            let resolvedEndpoint:
                SteamacBridgeEndpoint

            if let endpoint {
                resolvedEndpoint = endpoint
            } else {
                guard let discovered =
                    try SteamacBridge.shared
                        .endpoints()
                        .first
                else {
                    return nil
                }

                resolvedEndpoint =
                    discovered
            }

            guard let root =
                try SteamacBridge.shared
                    .reloadedIIInstallationRoot(
                        appId: appId,
                        endpoint: resolvedEndpoint
                    )
            else {
                return nil
            }

            return .guest(root)
        }
    }

    static func resolveEnvironmentExecutable(
        for game: GameInstall,
        endpoint: SteamacBridgeEndpoint? = nil
    ) throws -> GameEnvironmentPath? {
        try resolveEnvironmentInstallationRoot(
            for: game,
            endpoint: endpoint
        )
        .map {
            appending(
                $0,
                "Reloaded-II.exe"
            )
        }
    }

    static func resolveEnvironmentMods(
        for game: GameInstall,
        endpoint: SteamacBridgeEndpoint? = nil
    ) throws -> GameEnvironmentPath? {
        try resolveEnvironmentInstallationRoot(
            for: game,
            endpoint: endpoint
        )
        .map {
            appending(
                $0,
                "Mods"
            )
        }
    }

    static func resolveEnvironmentApplications(
        for game: GameInstall,
        endpoint: SteamacBridgeEndpoint? = nil
    ) throws -> GameEnvironmentPath? {
        try resolveEnvironmentInstallationRoot(
            for: game,
            endpoint: endpoint
        )
        .map {
            appending(
                $0,
                "Apps"
            )
        }
    }

    static func resolveEnvironmentApplicationDirectory(
        for game: GameInstall,
        appId: String,
        endpoint: SteamacBridgeEndpoint? = nil
    ) throws -> GameEnvironmentPath? {
        try resolveEnvironmentApplications(
            for: game,
            endpoint: endpoint
        )
        .map {
            appending(
                $0,
                appId
            )
        }
    }

    static func resolveEnvironmentApplicationConfig(
        for game: GameInstall,
        appId: String,
        endpoint: SteamacBridgeEndpoint? = nil
    ) throws -> GameEnvironmentPath? {
        try resolveEnvironmentApplicationDirectory(
            for: game,
            appId: appId,
            endpoint: endpoint
        )
        .map {
            appending(
                $0,
                "AppConfig.json"
            )
        }
    }

}
