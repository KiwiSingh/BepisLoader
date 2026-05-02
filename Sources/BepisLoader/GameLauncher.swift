import Foundation

// ─────────────────────────────────────────────
//  GameLauncher
//  Launches a Windows game via the correct Wine
//  binary with BepInEx environment variables set.
// ─────────────────────────────────────────────

class GameLauncher {

    static let shared = GameLauncher()
    private init() {}

    enum LaunchError: LocalizedError {
        case wineBinaryNotFound
        case gameExecutableNotFound
        case bepInExNotInstalled
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .wineBinaryNotFound:      return "Wine binary not found for this compatibility layer"
            case .gameExecutableNotFound:  return "Game executable not found"
            case .bepInExNotInstalled:     return "BepInEx is not installed for this game"
            case .launchFailed(let r):     return "Launch failed: \(r)"
            }
        }
    }

    // ── Launch ─────────────────────────────────

    @discardableResult
    func launch(game: GameInstall, requireBepInEx: Bool = true) throws -> Process {
        guard FileManager.default.fileExists(atPath: game.executablePath.path) else {
            throw LaunchError.gameExecutableNotFound
        }
        if requireBepInEx && !game.isBepInExInstalled {
            throw LaunchError.bepInExNotInstalled
        }

        let installer = BepInExInstaller.shared
        let layerToUse = game.overrideLayer ?? game.bottle.layer
        let tempBottle = Bottle(name: game.bottle.name, path: game.bottle.path, layer: layerToUse, winePID: game.bottle.winePID)
        guard let wineBin = installer.findWineBinary(for: tempBottle) else {
            throw LaunchError.wineBinaryNotFound
        }

        var env = installer.environmentForBottle(tempBottle)

        // BepInEx / Doorstop environment variables
        env["DOORSTOP_ENABLE"]           = "TRUE"
        env["WINEDLLOVERRIDES"]          = "winhttp,version=n,b"
        
        let targetDll = game.unityType == .il2cpp ? "core/BepInEx.Unity.IL2CPP.dll" : "core/BepInEx.Preloader.dll"
        env["DOORSTOP_INVOKE_DLL_PATH"]  = windowsPath(
            for: game.bepInExRoot.appendingPathComponent(targetDll),
            in: game.bottle
        )
        env["DOORSTOP_CORLIB_OVERRIDE"]  = "FALSE"
        
        if game.unityType == .il2cpp {
            // IL2CPP requires pointing to the included Mono runtime
            env["DOORSTOP_MONO_RUNTIME_LIB"] = windowsPath(
                for: game.gameDirectory.appendingPathComponent("mono/MonoBleedingEdge/EmbedRuntime/mono-2.0-sgen.dll"),
                in: game.bottle
            )
            env["DOORSTOP_MONO_CONFIG_DIR"]  = windowsPath(
                for: game.gameDirectory.appendingPathComponent("mono/MonoBleedingEdge/etc"),
                in: game.bottle
            )
        }
        
        // Mono / IL2CPP path hint (needed for BepInEx 6)
        env["BEPINEX_ENABLED"]           = "1"

        // Make Wine not show error dialogs and hide wine spam
        env["WINEDEBUG"]                 = "-all"
        // Ensure overrides are in the correct format for Wine (comma separated)
        env["WINEDLLOVERRIDES"]          = "winhttp=n,b,version=n,b"

        let proc = Process()
        proc.executableURL    = URL(fileURLWithPath: wineBin)
        proc.arguments        = [windowsPathForExe(game.executablePath)]
        proc.environment      = env
        proc.currentDirectoryURL = game.gameDirectory

        // Pipe logs so we can surface them in the UI
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError  = errPipe

        // Stream log output
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .gameLogOutput,
                    object: nil,
                    userInfo: ["text": text, "stream": "stdout"]
                )
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .gameLogOutput,
                    object: nil,
                    userInfo: ["text": text, "stream": "stderr"]
                )
            }
        }

        do {
            try proc.run()
        } catch {
            throw LaunchError.launchFailed(error.localizedDescription)
        }

        return proc
    }

    // ── Path translation ───────────────────────

    /// Convert a macOS host path inside a bottle to a Windows Z:\ path for Wine.
    private func windowsPath(for url: URL, in bottle: Bottle) -> String {
        let path = url.path
        let dosdevices = bottle.path.appendingPathComponent("dosdevices")
        
        if let drives = try? FileManager.default.contentsOfDirectory(at: dosdevices, includingPropertiesForKeys: nil) {
            for drive in drives {
                let driveName = drive.lastPathComponent
                if driveName == "c:" || driveName == "z:" { continue }
                if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: drive.path) {
                    let absoluteDest = URL(fileURLWithPath: dest, relativeTo: dosdevices).standardized.path
                    if path.hasPrefix(absoluteDest) {
                        var relative = String(path.dropFirst(absoluteDest.count))
                        if relative.hasPrefix("/") { relative = String(relative.dropFirst()) }
                        return "\(driveName.uppercased())\\\(relative.replacingOccurrences(of: "/", with: "\\"))"
                    }
                }
            }
        }
        return "Z:\(path.replacingOccurrences(of: "/", with: "\\"))"
    }

    /// Return the exe path in whatever form Wine wants it.
    private func windowsPathForExe(_ url: URL) -> String {
        // If the exe is inside drive_c, use C:\ notation; otherwise Z:\
        let path = url.path
        if let range = path.range(of: "/drive_c/") {
            let afterDriveC = String(path[range.upperBound...])
            return "C:\\" + afterDriveC.replacingOccurrences(of: "/", with: "\\")
        }
        return "Z:" + path.replacingOccurrences(of: "/", with: "\\")
    }
}

// ── Notifications ──────────────────────────────────────────────────────────

extension Notification.Name {
    static let gameLogOutput = Notification.Name("BepInExMac.GameLogOutput")
}
