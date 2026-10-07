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

    func isRegistered(
        _ game: GameInstall
    ) -> Bool {
        registeredApplication(
            for: game
        ) != nil
    }

    @discardableResult
    func register(
        _ game: GameInstall
    ) throws -> ReloadedIIApplication {
        if let existing = registeredApplication(
            for: game
        ) {
            return existing
        }

        let paths = ReloadedIIPaths(
            game: game
        )

        guard paths.executable != nil,
              let applications = paths.applications
        else {
            throw RegistryError.frameworkNotInstalled
        }

        guard let windowsExecutable =
                paths.windowsPath(
                    for: game.executablePath
                )
        else {
            throw RegistryError.executableOutsidePrefix
        }

        guard let windowsWorkingDirectory =
                paths.windowsPath(
                    for: game.gameDirectory
                )
        else {
            throw RegistryError.executableOutsidePrefix
        }

        try fm.createDirectory(
            at: applications,
            withIntermediateDirectories: true
        )

        let baseId = game.executablePath
            .lastPathComponent
            .lowercased()

        guard !baseId.isEmpty else {
            throw RegistryError.invalidExecutable
        }

        let appId = uniqueAppId(
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
            throw RegistryError.frameworkNotInstalled
        }

        let config = ReloadedIIApplicationConfig(
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

        try fm.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()

        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys
        ]

        let data = try encoder.encode(
            config
        )

        try data.write(
            to: configURL,
            options: .atomic
        )

        return ReloadedIIApplication(
            config: config,
            configURL: configURL
        )
    }

    func registeredApplication(
        for game: GameInstall
    ) -> ReloadedIIApplication? {
        let paths = ReloadedIIPaths(
            game: game
        )

        guard let applications =
                paths.applications,
              let expectedLocation =
                paths.windowsPath(
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
            let configURL = directory
                .appendingPathComponent(
                    "AppConfig.json"
                )

            guard let application =
                    readApplication(
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

    // ── Config mutation ───────────────────────

    func update(
        _ application: ReloadedIIApplication
    ) throws {
        let encoder = JSONEncoder()

        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys
        ]

        let data = try encoder.encode(
            application.config
        )

        try data.write(
            to: application.configURL,
            options: .atomic
        )
    }

    // ── Discovery ─────────────────────────────

    private func readApplication(
        at url: URL
    ) -> ReloadedIIApplication? {
        guard let data = try? Data(
            contentsOf: url
        ) else {
            return nil
        }

        let decoder = JSONDecoder()

        guard let config = try? decoder.decode(
            ReloadedIIApplicationConfig.self,
            from: data
        ) else {
            return nil
        }

        return ReloadedIIApplication(
            config: config,
            configURL: url
        )
    }

    private func uniqueAppId(
        base: String,
        applications: URL
    ) -> String {
        var candidate = base

        while fm.fileExists(
            atPath: applications
                .appendingPathComponent(
                    candidate
                )
                .path
        ) {
            candidate += "_dup"
        }

        return candidate
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
        case invalidExecutable

        var errorDescription: String? {
            switch self {

            case .frameworkNotInstalled:
                return """
                Reloaded-II is not installed \
                in this game's Wine prefix
                """

            case .executableOutsidePrefix:
                return """
                The game executable could not \
                be mapped into the Wine C: drive
                """

            case .invalidExecutable:
                return """
                The game executable does not \
                have a valid filename
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

    let configURL: URL
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
