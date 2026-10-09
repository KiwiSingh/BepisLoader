import Foundation

// ─────────────────────────────────────────────
//  BepInExPaths
//
//  Framework-owned filesystem layout for a
//  BepInEx installation associated with a game.
// ─────────────────────────────────────────────

struct BepInExPaths {

    let game: GameInstall

    var root: URL {
        game.gameDirectory.appendingPathComponent("BepInEx")
    }


    /// Authoritative BepInEx root in the game's runtime.
    ///
    /// Existing URL properties remain for local-Wine consumers.
    var environmentRoot: GameEnvironmentPath {
        switch game.backing {
        case .localWine:
            return .host(root)

        case .steamac(_, let installPath, _, _):
            return .guest(
                Self.guestJoin(
                    installPath,
                    "BepInEx"
                )
            )
        }
    }

    var environmentPlugins: GameEnvironmentPath {
        appending(
            "plugins",
            to: environmentRoot
        )
    }

    var environmentConfig: GameEnvironmentPath {
        appending(
            "config",
            to: environmentRoot
        )
    }

    var environmentPatchers: GameEnvironmentPath {
        appending(
            "patchers",
            to: environmentRoot
        )
    }

    var environmentVersionFile: GameEnvironmentPath {
        appending(
            "BepInEx.version",
            to: environmentRoot
        )
    }

    var environmentLog: GameEnvironmentPath {
        appending(
            "LogOutput.log",
            to: environmentRoot
        )
    }

    var environmentDoorstopConfig: GameEnvironmentPath {
        switch game.backing {
        case .localWine:
            return .host(doorstopConfig)

        case .steamac(_, let installPath, _, _):
            return .guest(
                Self.guestJoin(
                    installPath,
                    "doorstop_config.ini"
                )
            )
        }
    }

    var environmentDoorstopProxy: GameEnvironmentPath {
        switch game.backing {
        case .localWine:
            return .host(doorstopProxy)

        case .steamac(_, let installPath, _, _):
            return .guest(
                Self.guestJoin(
                    installPath,
                    "winhttp.dll"
                )
            )
        }
    }

    private func appending(
        _ component: String,
        to base: GameEnvironmentPath
    ) -> GameEnvironmentPath {
        switch base {
        case .host(let url):
            return .host(
                url.appendingPathComponent(component)
            )

        case .guest(let path):
            return .guest(
                Self.guestJoin(
                    path,
                    component
                )
            )
        }
    }

    static func guestJoin(
        _ base: String,
        _ component: String
    ) -> String {
        let trimmed = base.hasSuffix("/")
            ? String(base.dropLast())
            : base

        return trimmed + "/" + component
    }

    var plugins: URL {
        root.appendingPathComponent("plugins")
    }

    var config: URL {
        root.appendingPathComponent("config")
    }

    var patchers: URL {
        root.appendingPathComponent("patchers")
    }

    var versionFile: URL {
        root.appendingPathComponent("BepInEx.version")
    }

    var log: URL {
        root.appendingPathComponent("LogOutput.log")
    }

    var doorstopConfig: URL {
        game.gameDirectory.appendingPathComponent("doorstop_config.ini")
    }

    var doorstopProxy: URL {
        game.gameDirectory.appendingPathComponent("winhttp.dll")
    }
}
