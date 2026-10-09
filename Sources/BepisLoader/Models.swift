import Foundation

// ─────────────────────────────────────────────
//  Models
// ─────────────────────────────────────────────

/// Known compatibility layers on macOS
enum CompatibilityLayer: String, CaseIterable, Codable {
    case crossOver        = "CrossOver"
    case crossOverPreview = "CrossOver Preview"
    case gameMac          = "GameMac"
    case wine             = "Wine (standalone)"
    case wineskin         = "Wineskin"
    case porting          = "Porting Kit"
    case whisky           = "Whisky"
    case other            = "Other"

    /// Bundle identifiers used to locate running instances
    var bundleIdentifiers: [String] {
        switch self {
        case .crossOver:        return ["com.codeweavers.CrossOver"]
        case .crossOverPreview: return ["com.codeweavers.CrossOver-Preview", "com.codeweavers.CrossOverPreview"]
        case .gameMac:          return ["com.gamemac.www", "com.www.gamemac"]
        case .wine:             return []   // detected by process name
        case .wineskin:         return ["com.wineskin.wineskinserver"]
        case .porting:          return ["com.paulthe.portingkit"]
        case .whisky:           return ["com.isaacmarovitz.Whisky"]
        case .other:            return []
        }
    }

    /// Typical Wine/Mono binary names spawned by this layer
    var wineProcessNames: [String] {
        switch self {
        case .crossOver, .crossOverPreview: return ["wine64", "wine", "wineloader", "wineserver"]
        case .gameMac:                      return ["wine64", "wine", "wineserver"]
        case .wine:                         return ["wine64", "wine", "wineserver"]
        case .wineskin:                     return ["wineskin", "wine64", "wine"]
        case .porting:                      return ["wine64", "wine"]
        case .whisky:                       return ["wine64", "wine", "wineserver"]
        case .other:                        return ["wine64", "wine", "wineserver"]
        }
    }
}

/// A detected Wine / compatibility-layer bottle
struct Bottle: Identifiable, Hashable, Codable {
    let id: UUID
    let name: String
    let path: URL             // path to the C: drive root or bottle directory
    let layer: CompatibilityLayer
    var winePID: pid_t?       // PID of wineserver managing this bottle, if running
    /// Extra host-side paths the scanner wants findGames() to search.
    /// Used by GameMac to carry game_path (which may be on an external drive)
    /// into the game-finding phase without needing dosdevices symlink resolution.
    var extraSearchPaths: [URL]

    init(name: String, path: URL, layer: CompatibilityLayer,
         winePID: pid_t? = nil, extraSearchPaths: [URL] = []) {
        self.id               = UUID()
        self.name             = name
        self.path             = path
        self.layer            = layer
        self.winePID          = winePID
        self.extraSearchPaths = extraSearchPaths
    }

    /// Best guess at the Windows drive C root
    var driveCRoot: URL {
        let candidate = path.appendingPathComponent("drive_c")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        return path
    }
}

enum GameInstallBacking: Hashable, Codable {
    case localWine(Bottle)

    case steamac(
        appId: UInt32,
        installPath: String,
        libraryPath: String,
        protonPrefix: String?
    )

    var bottle: Bottle? {
        guard case .localWine(let bottle) = self else {
            return nil
        }

        return bottle
    }

    var steamAppId: UInt32? {
        guard case .steamac(let appId, _, _, _) = self else {
            return nil
        }

        return appId
    }

    var guestInstallPath: String? {
        guard case .steamac(_, let installPath, _, _) = self else {
            return nil
        }

        return installPath
    }

    var guestLibraryPath: String? {
        guard case .steamac(_, _, let libraryPath, _) = self else {
            return nil
        }

        return libraryPath
    }

    var guestProtonPrefix: String? {
        guard case .steamac(_, _, _, let protonPrefix) = self else {
            return nil
        }

        return protonPrefix
    }
}


/// A Unity game that lives inside a bottle
struct GameInstall: Identifiable, Hashable, Codable {
    enum UnityType: String, Codable {
        case mono    = "Mono"
        case il2cpp  = "IL2CPP"
        case unknown = "Unknown"
    }
    
    let id:             UUID
    let name:           String
    /// Legacy host-side executable URL.
    ///
    /// For local Wine games this is the real executable.
    /// For guest-backed games this remains a compatibility value only;
    /// environmentExecutablePath is authoritative.
    let executablePath: URL

    let bottle:         Bottle


    /// Authoritative environment-specific backing.
    let backing: GameInstallBacking
    /// Authoritative executable location in the game's runtime
    /// environment.
    let environmentExecutablePath:
        GameEnvironmentPath

    /// Runtime/filesystem environment containing
    /// this game.
    ///
    /// Existing discovered games use `.localWine`.
    /// VM-backed games such as Steamac will provide
    /// an explicit guest environment.
    let environment:    GameEnvironment

    var overrideLayer:  CompatibilityLayer?
    var unityType:      UnityType = .unknown
    init(
        name: String,
        executablePath: URL,
        bottle: Bottle,
        environment: GameEnvironment? = nil,
        environmentExecutablePath: GameEnvironmentPath? = nil
    ) {
        self.id =
            UUID()

        self.name =
            name

        self.executablePath =
            executablePath

        self.bottle =
            bottle

        self.backing = .localWine(bottle)
        self.environment =
            environment
            ?? .localWine(
                bottle: bottle
            )

        self.environmentExecutablePath =
            environmentExecutablePath
            ?? .host(
                executablePath
            )
    }

    /// Directory that contains the game .exe.
    ///
    /// This remains host-only for compatibility with
    /// the existing Wine providers. Steamac games will
    /// use environment paths/bridge access instead.
    init(
        steamacGame: SteamacGame,
        executablePath: String,
        protonPrefix: String?
    ) {
        self.id = UUID()
        self.name = steamacGame.name

        // Legacy compatibility sentinels only.
        //
        // These are deliberately NOT guest paths. Remote consumers
        // must use environmentExecutablePath/backing instead.
        self.executablePath = URL(
            fileURLWithPath: "/dev/null"
        )

        self.bottle = Bottle(
            name: "Steamac",
            path: URL(
                fileURLWithPath: "/dev/null"
            ),
            layer: .other
        )

        self.backing = .steamac(
            appId: steamacGame.appId,
            installPath: steamacGame.installPath,
            libraryPath: steamacGame.libraryPath,
            protonPrefix: protonPrefix
        )

        self.environment = steamacGame.environment

        self.environmentExecutablePath = .guest(
            executablePath
        )

        self.overrideLayer = nil
        self.unityType = .unknown
    }


    var gameDirectory: URL {
        executablePath
            .deletingLastPathComponent()
    }

    /// True when ordinary macOS FileManager operations
    /// are valid for this game's paths.
    var isHostAccessible:
        Bool
    {
        environment
            .isHostAccessible
    }

    /// Explicit host-side executable path.
    ///
    /// Callers being migrated for Steamac should use
    /// this instead of assuming every GameInstall has
    /// a locally accessible executable.
    var hostExecutablePath:
        URL?
    {
        guard isHostAccessible
        else {
            return nil
        }

        return executablePath
    }

    var hostGameDirectory:
        URL?
    {
        hostExecutablePath?
            .deletingLastPathComponent()
    }
}

