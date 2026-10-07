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
