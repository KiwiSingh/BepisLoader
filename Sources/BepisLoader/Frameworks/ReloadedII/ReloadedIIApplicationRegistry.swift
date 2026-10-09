import Foundation

// ─────────────────────────────────────────────
//  ReloadedIIApplicationRegistry
//
//  Persists Reloaded-II AppConfig.json files
//  using the current upstream application schema.
//
//  Registration remains separate from framework
//  installation: Reloaded-II may be installed in
//  a prefix without this particular game having
//  been registered.
// ─────────────────────────────────────────────

final class ReloadedIIApplicationRegistry {

    static let shared =
        ReloadedIIApplicationRegistry()

    private let fm =
        FileManager.default

    private init() {}


    // ── Public API ────────────────────────────

    /// Legacy synchronous query.
    ///
    /// Guest-backed environments deliberately do not perform
    /// hidden bridge I/O here. Call the endpoint-aware overload
    /// when working with Steamac.
    func isRegistered(
        _ game: GameInstall
    ) -> Bool {
        switch game.environment.filesystem {
        case .local:
            return registeredLocalApplication(
                for: game
            ) != nil

        case .guest:
            return false
        }
    }


    func isRegistered(
        _ game: GameInstall,
        endpoint: SteamacBridgeEndpoint
    ) throws -> Bool {
        switch game.environment.filesystem {
        case .local:
            return registeredLocalApplication(
                for: game
            ) != nil

        case .guest:
            return try registeredSteamacApplication(
                for: game,
                endpoint: endpoint
            ) != nil
        }
    }


    @discardableResult
    func register(
        _ game: GameInstall
    ) throws -> ReloadedIIApplication {
        switch game.environment.filesystem {
        case .local:
            return try registerLocal(
                game
            )

        case .guest:
            guard let endpoint =
                    SteamacBridge.shared
                        .endpoints()
                        .first
            else {
                throw SteamacBridgeError
                    .noRunningInstance
            }

            return try registerSteamac(
                game,
                endpoint: endpoint
            )
        }
    }


    @discardableResult
    func register(
        _ game: GameInstall,
        endpoint: SteamacBridgeEndpoint
    ) throws -> ReloadedIIApplication {
        switch game.environment.filesystem {
        case .local:
            return try registerLocal(
                game
            )

        case .guest:
            return try registerSteamac(
                game,
                endpoint: endpoint
            )
        }
    }


    func registeredApplication(
        for game: GameInstall
    ) -> ReloadedIIApplication? {
        switch game.environment.filesystem {
        case .local:
            return registeredLocalApplication(
                for: game
            )

        case .guest:
            // Preserve the old synchronous API without hiding
            // bridge I/O behind an optional-returning getter.
            return nil
        }
    }


    func registeredApplication(
        for game: GameInstall,
        endpoint: SteamacBridgeEndpoint
    ) throws -> ReloadedIIApplication? {
        switch game.environment.filesystem {
        case .local:
            return registeredLocalApplication(
                for: game
            )

        case .guest:
            return try registeredSteamacApplication(
                for: game,
                endpoint: endpoint
            )
        }
    }


    // ── Local Wine registration ───────────────

    private func registerLocal(
        _ game: GameInstall
    ) throws -> ReloadedIIApplication {
        let paths =
            ReloadedIIPaths(
                game: game
            )

        guard fm.fileExists(
            atPath:
                game.executablePath.path
        )
        else {
            throw RegistryError
                .gameExecutableNotFound
        }

        let canonicalLocation =
            try paths.requiredWindowsPath(
                for: game.executablePath
            )

        if let existing =
                registeredLocalApplication(
                    for: game
                )
        {
            guard normalizeWindowsPath(
                existing.config.appLocation
            ) == normalizeWindowsPath(
                canonicalLocation
            )
            else {
                throw RegistryError
                    .registrationMismatch
            }

            return existing
        }

        guard paths.executable != nil,
              let applications =
                paths.applications
        else {
            throw RegistryError
                .frameworkNotInstalled
        }

        let windowsWorkingDirectory =
            try paths.requiredWindowsPath(
                for: game.gameDirectory
            )

        try fm.createDirectory(
            at: applications,
            withIntermediateDirectories: true
        )

        let baseId =
            game.executablePath
                .lastPathComponent
                .lowercased()

        guard !baseId.isEmpty
        else {
            throw RegistryError
                .invalidExecutable
        }

        let appId =
            uniqueLocalAppId(
                base: baseId,
                applications: applications
            )

        guard let directory =
                paths.applicationDirectory(
                    appId: appId
                ),
              let configURL =
                paths.applicationConfig(
                    appId: appId
                )
        else {
            throw RegistryError
                .frameworkNotInstalled
        }

        let config =
            makeConfig(
                appId: appId,
                game: game,
                windowsExecutable:
                    canonicalLocation,
                windowsWorkingDirectory:
                    windowsWorkingDirectory
            )

        try fm.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let data =
            try encodedConfig(
                config
            )

        try data.write(
            to: configURL,
            options: .atomic
        )

        return ReloadedIIApplication(
            config: config,
            configPath: .host(
                configURL
            )
        )
    }


    private func registeredLocalApplication(
        for game: GameInstall
    ) -> ReloadedIIApplication? {
        let paths =
            ReloadedIIPaths(
                game: game
            )

        guard let applications =
                paths.applications,
              let expectedLocation =
                try? paths.requiredWindowsPath(
                    for: game.executablePath
                ),
              let directories =
                try? fm.contentsOfDirectory(
                    at: applications,
                    includingPropertiesForKeys: [
                        .isDirectoryKey
                    ],
                    options: [
                        .skipsHiddenFiles
                    ]
                )
        else {
            return nil
        }

        for directory in directories {
            let configURL =
                directory
                    .appendingPathComponent(
                        "AppConfig.json"
                    )

            guard let application =
                    readLocalApplication(
                        at: configURL
                    )
            else {
                continue
            }

            if normalizeWindowsPath(
                application.config.appLocation
            ) == normalizeWindowsPath(
                expectedLocation
            ) {
                return application
            }
        }

        return nil
    }


    // ── Steamac registration ──────────────────

    private func registerSteamac(
        _ game: GameInstall,
        endpoint: SteamacBridgeEndpoint
    ) throws -> ReloadedIIApplication {
        guard case .steamac =
                game.backing,
              case .guest(
                let executablePath
              ) = game.environmentExecutablePath
        else {
            throw RegistryError
                .invalidEnvironment
        }

        let executableInfo =
            try SteamacBridge.shared
                .guestFileInfo(
                    at: executablePath,
                    endpoint: endpoint
                )

        guard executableInfo.kind
                == .file
        else {
            throw RegistryError
                .gameExecutableNotFound
        }

        guard let applicationsPath =
                try ReloadedIIPaths
                    .resolveEnvironmentApplications(
                        for: game,
                        endpoint: endpoint
                    ),
              case .guest(
                let applications
              ) = applicationsPath
        else {
            throw RegistryError
                .frameworkNotInstalled
        }

        let windowsExecutable =
            try steamacWindowsPath(
                executablePath
            )

        let workingDirectory =
            ReloadedIIPaths
                .guestDeletingLastPathComponent(
                    executablePath
                )

        let windowsWorkingDirectory =
            try steamacWindowsPath(
                workingDirectory
            )

        if let existing =
                try registeredSteamacApplication(
                    for: game,
                    endpoint: endpoint
                )
        {
            guard normalizeWindowsPath(
                existing.config.appLocation
            ) == normalizeWindowsPath(
                windowsExecutable
            )
            else {
                throw RegistryError
                    .registrationMismatch
            }

            return existing
        }

        let basename =
            (executablePath as NSString)
                .lastPathComponent
                .lowercased()

        guard !basename.isEmpty
        else {
            throw RegistryError
                .invalidExecutable
        }

        // Each Steam AppID has its own Proton prefix. A stable
        // basename-derived ID therefore avoids requiring broad
        // guest directory enumeration merely to generate "_dup".
        let appId =
            sanitizedGuestAppId(
                basename
            )

        guard !appId.isEmpty
        else {
            throw RegistryError
                .invalidExecutable
        }

        let directory =
            ReloadedIIPaths.guestJoin(
                applications,
                appId
            )

        let configPath =
            ReloadedIIPaths.guestJoin(
                directory,
                "AppConfig.json"
            )

        let config =
            makeConfig(
                appId: appId,
                game: game,
                windowsExecutable:
                    windowsExecutable,
                windowsWorkingDirectory:
                    windowsWorkingDirectory
            )

        try SteamacBridge.shared
            .createGuestDirectory(
                applications,
                endpoint: endpoint
            )

        try SteamacBridge.shared
            .createGuestDirectory(
                directory,
                endpoint: endpoint
            )

        try SteamacBridge.shared
            .writeGuestFile(
                try encodedConfig(
                    config
                ),
                to: configPath,
                endpoint: endpoint
            )

        return ReloadedIIApplication(
            config: config,
            configPath: .guest(
                configPath
            )
        )
    }


    private func registeredSteamacApplication(
        for game: GameInstall,
        endpoint: SteamacBridgeEndpoint
    ) throws -> ReloadedIIApplication? {
        guard case .steamac =
                game.backing,
              case .guest(
                let executablePath
              ) = game.environmentExecutablePath
        else {
            throw RegistryError
                .invalidEnvironment
        }

        guard let applicationsPath =
                try ReloadedIIPaths
                    .resolveEnvironmentApplications(
                        for: game,
                        endpoint: endpoint
                    ),
              case .guest(
                let applications
              ) = applicationsPath
        else {
            return nil
        }

        let basename =
            (executablePath as NSString)
                .lastPathComponent
                .lowercased()

        let appId =
            sanitizedGuestAppId(
                basename
            )

        guard !appId.isEmpty
        else {
            return nil
        }

        let configPath =
            ReloadedIIPaths.guestJoin(
                ReloadedIIPaths.guestJoin(
                    applications,
                    appId
                ),
                "AppConfig.json"
            )

        let info =
            try SteamacBridge.shared
                .guestFileInfo(
                    at: configPath,
                    endpoint: endpoint
                )

        if info.kind == .missing {
            return nil
        }

        guard info.kind == .file
        else {
            throw RegistryError
                .invalidRegistration
        }

        let data =
            try SteamacBridge.shared
                .readGuestFile(
                    at: configPath,
                    endpoint: endpoint
                )

        let config: ReloadedIIApplicationConfig

        do {
            config =
                try JSONDecoder()
                    .decode(
                        ReloadedIIApplicationConfig.self,
                        from: data
                    )
        } catch {
            throw RegistryError
                .invalidRegistration
        }

        let expectedLocation =
            try steamacWindowsPath(
                executablePath
            )

        guard normalizeWindowsPath(
            config.appLocation
        ) == normalizeWindowsPath(
            expectedLocation
        )
        else {
            throw RegistryError
                .registrationMismatch
        }

        return ReloadedIIApplication(
            config: config,
            configPath: .guest(
                configPath
            )
        )
    }


    // ── Config mutation ───────────────────────

    func update(
        _ application: ReloadedIIApplication
    ) throws {
        guard case .host(let url) =
                application.configPath
        else {
            throw RegistryError
                .guestEndpointRequired
        }

        try encodedConfig(
            application.config
        )
        .write(
            to: url,
            options: .atomic
        )
    }


    func update(
        _ application: ReloadedIIApplication,
        endpoint: SteamacBridgeEndpoint
    ) throws {
        let data =
            try encodedConfig(
                application.config
            )

        switch application.configPath {
        case .host(let url):
            try data.write(
                to: url,
                options: .atomic
            )

        case .guest(let path):
            try SteamacBridge.shared
                .writeGuestFile(
                    data,
                    to: path,
                    endpoint: endpoint
                )
        }
    }


    // ── Shared helpers ────────────────────────

    private func makeConfig(
        appId: String,
        game: GameInstall,
        windowsExecutable: String,
        windowsWorkingDirectory: String
    ) -> ReloadedIIApplicationConfig {
        ReloadedIIApplicationConfig(
            appId: appId,
            appName: game.name,
            appLocation: windowsExecutable,
            appArguments: "",
            appIcon: "Icon.png",
            autoInject: false,
            enabledMods: [],
            workingDirectory:
                windowsWorkingDirectory,
            pluginData: [:],
            sortedMods: [],
            preserveDisabledModOrder: true,
            dontInject: false,
            isMsStore: false
        )
    }


    private func encodedConfig(
        _ config: ReloadedIIApplicationConfig
    ) throws -> Data {
        let encoder =
            JSONEncoder()

        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys
        ]

        return try encoder.encode(
            config
        )
    }


    private func readLocalApplication(
        at url: URL
    ) -> ReloadedIIApplication? {
        guard let data =
                try? Data(
                    contentsOf: url
                )
        else {
            return nil
        }

        guard let config =
                try? JSONDecoder()
                    .decode(
                        ReloadedIIApplicationConfig.self,
                        from: data
                    )
        else {
            return nil
        }

        return ReloadedIIApplication(
            config: config,
            configPath: .host(
                url
            )
        )
    }


    private func uniqueLocalAppId(
        base: String,
        applications: URL
    ) -> String {
        var candidate =
            base

        while fm.fileExists(
            atPath:
                applications
                    .appendingPathComponent(
                        candidate
                    )
                    .path
        ) {
            candidate +=
                "_dup"
        }

        return candidate
    }


    /// Proton exposes the Linux filesystem through Wine's Z: drive.
    ///
    /// Steam game installations live outside drive_c, under the
    /// Steam library's steamapps/common tree, so mapping them to
    /// C: would be incorrect.
    private func steamacWindowsPath(
        _ guestPath: String
    ) throws -> String {
        guard guestPath.hasPrefix("/")
        else {
            throw RegistryError
                .executableOutsidePrefix
        }

        let relative =
            guestPath
                .dropFirst()
                .replacingOccurrences(
                    of: "/",
                    with: "\\"
                )

        return "Z:\\"
            + relative
    }


    private func sanitizedGuestAppId(
        _ value: String
    ) -> String {
        let allowed =
            CharacterSet
                .alphanumerics
                .union(
                    CharacterSet(
                        charactersIn: "._-"
                    )
                )

        var result =
            ""

        for scalar in value.unicodeScalars {
            if allowed.contains(
                scalar
            ) {
                result.append(
                    Character(
                        String(
                            scalar
                        )
                    )
                )
            } else {
                result.append(
                    "_"
                )
            }
        }

        return result
    }


    private func normalizeWindowsPath(
        _ path: String
    ) -> String {
        path
            .replacingOccurrences(
                of: "/",
                with: "\\"
            )
            .trimmingCharacters(
                in: CharacterSet(
                    charactersIn: "\\"
                )
            )
            .lowercased()
    }


    // ── Errors ────────────────────────────────

    enum RegistryError: LocalizedError {
        case frameworkNotInstalled
        case executableOutsidePrefix
        case gameExecutableNotFound
        case registrationMismatch
        case invalidExecutable
        case invalidEnvironment
        case invalidRegistration
        case guestEndpointRequired

        var errorDescription: String? {
            switch self {

            case .frameworkNotInstalled:
                return """
                Reloaded-II is not installed \
                in this game's compatibility environment
                """

            case .executableOutsidePrefix:
                return """
                The game executable could not \
                be mapped to a Windows path
                """

            case .gameExecutableNotFound:
                return """
                The game's executable could not \
                be found
                """

            case .registrationMismatch:
                return """
                Reloaded-II's registered AppLocation \
                does not match this game's canonical \
                executable path
                """

            case .invalidExecutable:
                return """
                The game executable does not \
                have a valid filename
                """

            case .invalidEnvironment:
                return """
                Reloaded-II registration received an \
                incompatible game environment
                """

            case .invalidRegistration:
                return """
                Reloaded-II's AppConfig.json is not \
                a valid application registration
                """

            case .guestEndpointRequired:
                return """
                Updating a Steamac Reloaded-II \
                registration requires its active bridge
                """
            }
        }
    }
}


// ─────────────────────────────────────────────
//  Application wrapper
// ─────────────────────────────────────────────

struct ReloadedIIApplication: Hashable {

    var config:
        ReloadedIIApplicationConfig

    let configPath:
        GameEnvironmentPath

    /// Host-only compatibility accessor.
    var configURL: URL? {
        guard case .host(let url) =
                configPath
        else {
            return nil
        }

        return url
    }
}

// ─────────────────────────────────────────────
//  Current Reloaded-II application schema
// ─────────────────────────────────────────────

struct ReloadedIIApplicationConfig:
    Codable,
    Hashable
{
    var appId: String
    var appName: String
    var appLocation: String
    var appArguments: String
    var appIcon: String
    var autoInject: Bool
    var enabledMods: [String]
    var workingDirectory: String
    var pluginData: [String: String]
    var sortedMods: [String]
    var preserveDisabledModOrder: Bool
    var dontInject: Bool
    var isMsStore: Bool

    enum CodingKeys:
        String,
        CodingKey
    {
        case appId =
            "AppId"

        case appName =
            "AppName"

        case appLocation =
            "AppLocation"

        case appArguments =
            "AppArguments"

        case appIcon =
            "AppIcon"

        case autoInject =
            "AutoInject"

        case enabledMods =
            "EnabledMods"

        case workingDirectory =
            "WorkingDirectory"

        case pluginData =
            "PluginData"

        case sortedMods =
            "SortedMods"

        case preserveDisabledModOrder =
            "PreserveDisabledModOrder"

        case dontInject =
            "DontInject"

        case isMsStore =
            "IsMsStore"
    }

    init(
        appId: String,
        appName: String,
        appLocation: String,
        appArguments: String,
        appIcon: String,
        autoInject: Bool,
        enabledMods: [String],
        workingDirectory: String,
        pluginData: [String: String],
        sortedMods: [String],
        preserveDisabledModOrder: Bool,
        dontInject: Bool,
        isMsStore: Bool
    ) {
        self.appId = appId
        self.appName = appName
        self.appLocation = appLocation
        self.appArguments = appArguments
        self.appIcon = appIcon
        self.autoInject = autoInject
        self.enabledMods = enabledMods
        self.workingDirectory =
            workingDirectory
        self.pluginData = pluginData
        self.sortedMods = sortedMods
        self.preserveDisabledModOrder =
            preserveDisabledModOrder
        self.dontInject = dontInject
        self.isMsStore = isMsStore
    }

    // Be tolerant of configs written by older
    // Reloaded-II versions that may omit newer
    // launcher-only properties.
    init(
        from decoder: Decoder
    ) throws {
        let c = try decoder.container(
            keyedBy: CodingKeys.self
        )

        appId = try c.decode(
            String.self,
            forKey: .appId
        )

        appName = try c.decodeIfPresent(
            String.self,
            forKey: .appName
        ) ?? appId

        appLocation = try c.decode(
            String.self,
            forKey: .appLocation
        )

        appArguments =
            try c.decodeIfPresent(
                String.self,
                forKey: .appArguments
            ) ?? ""

        appIcon =
            try c.decodeIfPresent(
                String.self,
                forKey: .appIcon
            ) ?? "Icon.png"

        autoInject =
            try c.decodeIfPresent(
                Bool.self,
                forKey: .autoInject
            ) ?? false

        enabledMods =
            try c.decodeIfPresent(
                [String].self,
                forKey: .enabledMods
            ) ?? []

        workingDirectory =
            try c.decodeIfPresent(
                String.self,
                forKey: .workingDirectory
            ) ?? ""

        pluginData =
            try c.decodeIfPresent(
                [String: String].self,
                forKey: .pluginData
            ) ?? [:]

        sortedMods =
            try c.decodeIfPresent(
                [String].self,
                forKey: .sortedMods
            ) ?? []

        preserveDisabledModOrder =
            try c.decodeIfPresent(
                Bool.self,
                forKey:
                    .preserveDisabledModOrder
            ) ?? true

        dontInject =
            try c.decodeIfPresent(
                Bool.self,
                forKey: .dontInject
            ) ?? false

        isMsStore =
            try c.decodeIfPresent(
                Bool.self,
                forKey: .isMsStore
            ) ?? false
    }
}
