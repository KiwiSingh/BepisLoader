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

/// A Unity game that lives inside a bottle
struct GameInstall: Identifiable, Hashable, Codable {
    enum UnityType: String, Codable {
        case mono    = "Mono"
        case il2cpp  = "IL2CPP"
        case unknown = "Unknown"
    }
    
    let id:             UUID
    let name:           String
    let executablePath: URL
    let bottle:         Bottle
    var overrideLayer:  CompatibilityLayer?
    var unityType:      UnityType = .unknown
    init(name: String, executablePath: URL, bottle: Bottle) {
        self.id              = UUID()
        self.name            = name
        self.executablePath  = executablePath
        self.bottle          = bottle
    }

    /// Directory that contains the game .exe
    var gameDirectory: URL { executablePath.deletingLastPathComponent() }


}

