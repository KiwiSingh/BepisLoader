import Foundation

// ─────────────────────────────────────────────
//  GameLauncher
//  Launches a Windows game through its selected
//  compatibility environment and mod framework.
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

        let layerToUse = game.overrideLayer ?? game.bottle.layer
        let tempBottle = Bottle(
            name: game.bottle.name,
            path: game.bottle.path,
            layer: layerToUse,
            winePID: game.bottle.winePID
        )

        let wineEnvironment = WineEnvironment.shared

        guard let wineBin = wineEnvironment.findWineBinary(for: tempBottle) else {
            throw LaunchError.wineBinaryNotFound
        }

        var configuration = GameLaunchConfiguration(
            environment: wineEnvironment.environment(for: tempBottle),
            arguments: [windowsPathForExe(game.executablePath)]
        )

        if requireBepInEx {
            BepInExLaunchProvider.shared.configureLaunch(
                for: game,
                configuration: &configuration
            )
        }

        // Suppress Wine diagnostics unless a framework explicitly changes it.
        configuration.environment["WINEDEBUG"] = "-all"

        let proc = Process()
        proc.executableURL    = URL(fileURLWithPath: wineBin)
        proc.arguments        = configuration.arguments
        proc.environment      = configuration.environment
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
