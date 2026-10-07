import Foundation

// ─────────────────────────────────────────────
//  Framework Launch Customization
//
//  Mod frameworks can modify the environment
//  and arguments used to launch a game without
//  GameLauncher knowing framework details.
// ─────────────────────────────────────────────

struct GameLaunchConfiguration {
    /// Windows executable Wine should start.
    ///
    /// Normally this is the game's executable.
    /// A framework may replace it with its own
    /// launcher executable.
    var executable: URL

    /// Arguments passed after `executable`.
    var arguments: [String]

    /// Environment supplied to Wine.
    var environment: [String: String]
}

protocol GameLaunchProvider {
    var framework: ModFramework { get }

    func configureLaunch(
        for game: GameInstall,
        configuration: inout GameLaunchConfiguration
    ) throws
}
