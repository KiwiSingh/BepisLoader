import Foundation

// ─────────────────────────────────────────────
//  Generic Mod Management
//
//  Framework-neutral representation of an
//  installed mod.
//
//  Framework-specific managers such as
//  BepInExModManager and ReloadedIIModManager
//  adapt their native mod formats to this API.
// ─────────────────────────────────────────────

struct InstalledMod: Identifiable, Hashable {

    let id: String

    var name: String
    var version: String?
    var author: String?
    var description: String

    let framework: ModFramework
    let path: URL

    var isEnabled: Bool

    init(
        id: String,
        name: String,
        version: String? = nil,
        author: String? = nil,
        description: String = "",
        framework: ModFramework,
        path: URL,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.description = description
        self.framework = framework
        self.path = path
        self.isEnabled = isEnabled
    }
}

// ─────────────────────────────────────────────
//  Framework-neutral mod manager
// ─────────────────────────────────────────────

protocol ModManaging {

    var framework: ModFramework { get }

    /// Returns mods currently installed for a game.
    func installedMods(for game: GameInstall) -> [InstalledMod]

    /// Installs a mod from a local file or directory.
    func installMod(from source: URL, into game: GameInstall) throws

    /// Removes an installed mod.
    func removeMod(_ mod: InstalledMod, from game: GameInstall) throws

    /// Enables or disables an installed mod.
    func setModEnabled(
        _ enabled: Bool,
        mod: InstalledMod,
        in game: GameInstall
    ) throws
}
