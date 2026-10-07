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
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .wineBinaryNotFound:      return "Wine binary not found for this compatibility layer"
            case .gameExecutableNotFound:  return "Game executable not found"
            case .launchFailed(let r):     return "Launch failed: \(r)"
            }
        }
    }

    // ── Launch ─────────────────────────────────

    @discardableResult
    func launch(
        game: GameInstall,
        providers: [any GameLaunchProvider] = []
    ) throws -> Process {
        guard FileManager.default.fileExists(atPath: game.executablePath.path) else {
            throw LaunchError.gameExecutableNotFound
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
            executable: game.executablePath,
            arguments: [],
            environment: wineEnvironment.environment(
                for: tempBottle
            )
        )

        for provider in providers {
            try provider.configureLaunch(
                for: game,
                configuration: &configuration
            )
        }

        // Suppress Wine diagnostics unless a framework explicitly changes it.
        configuration.environment["WINEDEBUG"] = "-all"

        guard FileManager.default.fileExists(
            atPath: configuration.executable.path
        ) else {
            throw LaunchError.gameExecutableNotFound
        }

        let proc = Process()

        proc.executableURL = URL(
            fileURLWithPath: wineBin
        )

        proc.arguments = [
            windowsPathForExe(
                configuration.executable
            )
        ] + configuration.arguments

        proc.environment =
            configuration.environment

        proc.currentDirectoryURL =
            configuration.executable
                .deletingLastPathComponent()

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
