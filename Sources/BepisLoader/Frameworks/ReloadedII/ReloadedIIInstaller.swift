import Foundation

// ─────────────────────────────────────────────
//  ReloadedIIInstaller
//
//  Installs Reloaded-II using the official
//  Setup-Linux.exe installer under the game's
//  existing Wine compatibility environment.
// ─────────────────────────────────────────────

final class ReloadedIIInstaller {

    static let shared = ReloadedIIInstaller()

    private let fm = FileManager.default
    private let wineEnvironment = WineEnvironment.shared

    private init() {}

    private let installerURL = URL(
        string: "https://github.com/Reloaded-Project/Reloaded-II/releases/latest/download/Setup-Linux.exe"
    )!

    // ── Install ───────────────────────────────

    func install(
        into game: GameInstall,
        progress: @escaping (Double, String) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                self.report(
                    progress,
                    0.05,
                    "Preparing Reloaded-II installation…"
                )

                let bottle = self.effectiveBottle(for: game)

                guard let wineBinary =
                    self.wineEnvironment.findWineBinary(for: bottle)
                else {
                    throw InstallerError.wineBinaryNotFound
                }

                self.report(
                    progress,
                    0.15,
                    "Downloading Reloaded-II Setup-Linux.exe…"
                )

                let setup = try self.downloadInstaller()

                defer {
                    try? self.fm.removeItem(at: setup)
                }

                self.report(
                    progress,
                    0.55,
                    "Launching Reloaded-II installer…"
                )

                let result = try self.runInstaller(
                    setup,
                    wineBinary: wineBinary,
                    bottle: bottle
                )

                guard result.exitCode == 0 else {
                    throw InstallerError.installerFailed(
                        exitCode: result.exitCode,
                        output: result.output
                    )
                }

                self.report(
                    progress,
                    0.90,
                    "Recording Reloaded-II installation…"
                )

                try self.writeInstallationMarker(for: game)

                self.report(
                    progress,
                    1.0,
                    "Reloaded-II setup completed"
                )

                DispatchQueue.main.async {
                    completion(.success(()))
                }

            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // ── Download ──────────────────────────────

    private func downloadInstaller() throws -> URL {
        let destination = fm.temporaryDirectory
            .appendingPathComponent(
                "BepisLoader-ReloadedII-\(UUID().uuidString)"
            )
            .appendingPathExtension("exe")

        var receivedURL: URL?
        var receivedError: Error?

        let semaphore = DispatchSemaphore(value: 0)

        URLSession.shared.downloadTask(
            with: installerURL
        ) { temporaryURL, _, error in

            defer {
                semaphore.signal()
            }

            if let error {
                receivedError = error
                return
            }

            guard let temporaryURL else {
                return
            }

            do {
                try self.fm.moveItem(
                    at: temporaryURL,
                    to: destination
                )

                receivedURL = destination
            } catch {
                receivedError = error
            }

        }.resume()

        semaphore.wait()

        if let receivedError {
            throw InstallerError.downloadFailed(
                receivedError.localizedDescription
            )
        }

        guard let receivedURL else {
            throw InstallerError.downloadFailed(
                "No installer was received"
            )
        }

        return receivedURL
    }

    // ── Wine execution ────────────────────────

    private func runInstaller(
        _ setup: URL,
        wineBinary: String,
        bottle: Bottle
    ) throws -> (
        exitCode: Int32,
        output: String
    ) {
        let process = Process()

        process.executableURL = URL(
            fileURLWithPath: wineBinary
        )

        process.arguments = [
            windowsPath(for: setup)
        ]

        process.environment =
            wineEnvironment.environment(for: bottle)

        let pipe = Pipe()

        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw InstallerError.launchFailed(
                error.localizedDescription
            )
        }

        process.waitUntilExit()

        let data =
            pipe.fileHandleForReading.readDataToEndOfFile()

        let output =
            String(data: data, encoding: .utf8) ?? ""

        return (
            process.terminationStatus,
            output
        )
    }

    // ── Installation marker ───────────────────

    private func writeInstallationMarker(
        for game: GameInstall
    ) throws {
        let paths = ReloadedIIPaths(game: game)

        if !fm.fileExists(atPath: paths.root.path) {
            try fm.createDirectory(
                at: paths.root,
                withIntermediateDirectories: true
            )
        }

        // Version discovery belongs to actual Reloaded-II
        // installation inspection, not the setup launcher.
        try "".write(
            to: paths.installationMarker,
            atomically: true,
            encoding: .utf8
        )
    }

    // ── Bottle handling ───────────────────────

    private func effectiveBottle(
        for game: GameInstall
    ) -> Bottle {
        Bottle(
            name: game.bottle.name,
            path: game.bottle.path,
            layer: game.overrideLayer ?? game.bottle.layer,
            winePID: game.bottle.winePID,
            extraSearchPaths: game.bottle.extraSearchPaths
        )
    }

    // ── Windows path conversion ───────────────

    private func windowsPath(
        for url: URL
    ) -> String {
        "Z:" + url.path.replacingOccurrences(
            of: "/",
            with: "\\"
        )
    }

    // ── Progress ──────────────────────────────

    private func report(
        _ handler: @escaping (Double, String) -> Void,
        _ progress: Double,
        _ message: String
    ) {
        DispatchQueue.main.async {
            handler(progress, message)
        }
    }

    // ── Errors ────────────────────────────────

    enum InstallerError: LocalizedError {
        case wineBinaryNotFound
        case downloadFailed(String)
        case launchFailed(String)
        case installerFailed(
            exitCode: Int32,
            output: String
        )

        var errorDescription: String? {
            switch self {

            case .wineBinaryNotFound:
                return """
                Wine binary not found for this \
                compatibility environment
                """

            case .downloadFailed(let reason):
                return """
                Failed to download Reloaded-II: \
                \(reason)
                """

            case .launchFailed(let reason):
                return """
                Failed to launch Reloaded-II installer: \
                \(reason)
                """

            case .installerFailed(
                let exitCode,
                let output
            ):
                let details =
                    output.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )

                if details.isEmpty {
                    return """
                    Reloaded-II installer exited with \
                    status \(exitCode)
                    """
                }

                return """
                Reloaded-II installer exited with \
                status \(exitCode):

                \(details)
                """
            }
        }
    }
}
