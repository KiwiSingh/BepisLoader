import Foundation

// ─────────────────────────────────────────────
//  Framework Launch Customization
//
//  Mod frameworks can modify the environment
//  and arguments used to launch a game without
//  GameLauncher knowing framework details.
// ─────────────────────────────────────────────

struct GameLaunchConfiguration {
    var environment: [String: String]
    var arguments: [String]
}

protocol GameLaunchProvider {
    var framework: ModFramework { get }

    func configureLaunch(
        for game: GameInstall,
        configuration: inout GameLaunchConfiguration
    )
}
