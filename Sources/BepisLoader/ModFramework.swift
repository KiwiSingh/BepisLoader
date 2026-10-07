import Foundation

// ─────────────────────────────────────────────
//  Mod Framework Abstraction
//
//  Modding frameworks such as BepInEx and
//  Reloaded-II implement this common interface.
// ─────────────────────────────────────────────

enum ModFramework: String, Codable, CaseIterable, Hashable {
    case bepInEx    = "BepInEx"
    case reloadedII = "Reloaded-II"
}

enum FrameworkStatus: Hashable, Codable {
    case notInstalled
    case installed(version: String?)
    case incompatible(reason: String)
}

struct FrameworkInstallation: Hashable, Codable {
    let framework: ModFramework
    var status: FrameworkStatus

    var isInstalled: Bool {
        if case .installed = status {
            return true
        }
        return false
    }

    var version: String? {
        guard case .installed(let version) = status else {
            return nil
        }
        return version
    }
}

protocol ModFrameworkProvider {
    var framework: ModFramework { get }

    /// Detect this framework for a particular game.
    func detect(in game: GameInstall) -> FrameworkInstallation

    /// Install the framework into the game.
    func install(
        into game: GameInstall,
        progress: @escaping (Double, String) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    )

    /// Remove the framework from the game.
    func uninstall(from game: GameInstall) throws
}
