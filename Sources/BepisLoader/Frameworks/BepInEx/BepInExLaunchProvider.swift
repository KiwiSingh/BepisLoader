import Foundation

// ─────────────────────────────────────────────
//  BepInEx Launch Provider
//
//  Supplies the Doorstop/BepInEx environment
//  required when launching through Wine.
// ─────────────────────────────────────────────

final class BepInExLaunchProvider: GameLaunchProvider {

    static let shared = BepInExLaunchProvider()

    let framework: ModFramework = .bepInEx

    private init() {}

    func configureLaunch(
        for game: GameInstall,
        configuration: inout GameLaunchConfiguration
    ) {
        configuration.environment["DOORSTOP_ENABLE"] = "TRUE"
        configuration.environment["WINEDLLOVERRIDES"] = "winhttp=n,b;version=n,b"

        let targetDLL = game.unityType == .il2cpp
            ? "core/BepInEx.Unity.IL2CPP.dll"
            : "core/BepInEx.Preloader.dll"

        configuration.environment["DOORSTOP_INVOKE_DLL_PATH"] = windowsPath(
            for: game.bepInExRoot.appendingPathComponent(targetDLL),
            in: game.bottle
        )

        configuration.environment["DOORSTOP_CORLIB_OVERRIDE"] = "FALSE"

        if game.unityType == .il2cpp {
            configuration.environment["DOORSTOP_MONO_RUNTIME_LIB"] = windowsPath(
                for: game.gameDirectory.appendingPathComponent(
                    "mono/MonoBleedingEdge/EmbedRuntime/mono-2.0-sgen.dll"
                ),
                in: game.bottle
            )

            configuration.environment["DOORSTOP_MONO_CONFIG_DIR"] = windowsPath(
                for: game.gameDirectory.appendingPathComponent(
                    "mono/MonoBleedingEdge/etc"
                ),
                in: game.bottle
            )
        }

        configuration.environment["BEPINEX_ENABLED"] = "1"
    }

    private func windowsPath(for url: URL, in bottle: Bottle) -> String {
        let path = url.path
        let dosdevices = bottle.path.appendingPathComponent("dosdevices")

        if let drives = try? FileManager.default.contentsOfDirectory(
            at: dosdevices,
            includingPropertiesForKeys: nil
        ) {
            for drive in drives {
                let driveName = drive.lastPathComponent

                if driveName == "c:" || driveName == "z:" {
                    continue
                }

                if let dest = try? FileManager.default.destinationOfSymbolicLink(
                    atPath: drive.path
                ) {
                    let absoluteDest = URL(
                        fileURLWithPath: dest,
                        relativeTo: dosdevices
                    ).standardized.path

                    if path.hasPrefix(absoluteDest) {
                        var relative = String(
                            path.dropFirst(absoluteDest.count)
                        )

                        if relative.hasPrefix("/") {
                            relative = String(relative.dropFirst())
                        }

                        return "\(driveName.uppercased())\\\(relative.replacingOccurrences(of: "/", with: "\\"))"
                    }
                }
            }
        }

        return "Z:\(path.replacingOccurrences(of: "/", with: "\\"))"
    }
}
