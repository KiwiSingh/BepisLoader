import Foundation

// ─────────────────────────────────────────────
//  ReloadedIIPaths
//
//  Framework-owned filesystem layout for a
//  Reloaded-II installation associated with a
//  game.
//
//  Reloaded-II itself may live outside the game
//  directory. These paths describe only the
//  game-local state BepisLoader owns/manages.
// ─────────────────────────────────────────────

struct ReloadedIIPaths {

    let game: GameInstall

    /// BepisLoader-managed Reloaded-II state for this game.
    var root: URL {
        game.gameDirectory.appendingPathComponent("Reloaded-II")
    }

    /// Game-local mod directory managed by BepisLoader.
    var mods: URL {
        root.appendingPathComponent("Mods")
    }

    /// Marker written after a successful Reloaded-II setup.
    ///
    /// Keeping detection behind a marker lets the provider own
    /// framework state without polluting GameInstall.
    var installationMarker: URL {
        root.appendingPathComponent(".bepisloader-installed")
    }
}
