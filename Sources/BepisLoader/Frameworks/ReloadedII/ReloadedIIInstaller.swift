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

                switch game.backing {
                case .localWine:
                    try self.installIntoLocalWine(
                        game,
                        progress: progress
                    )

                case .steamac:
                    try self.installIntoSteamac(
                        game,
                        progress: progress
                    )
                }

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


    // ── Environment-specific installation ─────

    private func installIntoLocalWine(
        _ game: GameInstall,
        progress: @escaping (Double, String) -> Void
    ) throws {
        let bottle = effectiveBottle(
            for: game
        )

        guard let wineBinary =
            wineEnvironment.findWineBinary(
                for: bottle
            )
        else {
            throw InstallerError.wineBinaryNotFound
        }

        report(
            progress,
            0.15,
            "Downloading Reloaded-II Setup-Linux.exe…"
        )

        let setup = try downloadInstaller()

        defer {
            try? fm.removeItem(
                at: setup
            )
        }

        report(
            progress,
            0.55,
            "Launching Reloaded-II installer…"
        )

        let result = try runInstaller(
            setup,
            wineBinary: wineBinary,
            bottle: bottle
        )

        guard result.exitCode == 0
        else {
            throw InstallerError.installerFailed(
                exitCode: result.exitCode,
                output: result.output
            )
        }

        report(
            progress,
            0.90,
            "Verifying Reloaded-II installation…"
        )

        try verifyInstallation(
            for: game
        )

        report(
            progress,
            0.95,
            "Registering game with Reloaded-II…"
        )

        try ReloadedIIApplicationRegistry
            .shared
            .register(game)
    }


    private func installIntoSteamac(
        _ game: GameInstall,
        progress: @escaping (Double, String) -> Void
    ) throws {
        guard case .steamac(
            let appId,
            _,
            let libraryPath,
            _
        ) = game.backing
        else {
            throw InstallerError.invalidSteamacGame
        }

        guard libraryPath.hasPrefix("/"),
              !libraryPath.isEmpty
        else {
            throw InstallerError.invalidSteamacGame
        }

        guard let endpoint =
            SteamacBridge.shared.endpoints().first
        else {
            throw SteamacBridgeError.noRunningInstance
        }

        report(
            progress,
            0.15,
            "Downloading Reloaded-II Setup-Linux.exe…"
        )

        let setup = try downloadInstaller()

        defer {
            try? fm.removeItem(
                at: setup
            )
        }

        let compatdata = Self.guestJoin(
            libraryPath,
            "steamapps/compatdata/\(appId)"
        )

        let stagingDirectory = Self.guestJoin(
            compatdata,
            "bepisloader/reloadedii"
        )

        let guestSetup = Self.guestJoin(
            stagingDirectory,
            "Setup-Linux.exe"
        )

        report(
            progress,
            0.35,
            "Staging Reloaded-II inside Steamac…"
        )

        try SteamacBridge.shared.createGuestDirectory(
            stagingDirectory,
            endpoint: endpoint
        )

        // Always remove the staged installer.
        defer {
            try? SteamacBridge.shared.removeGuestItem(
                at: guestSetup,
                endpoint: endpoint
            )
        }

        try SteamacBridge.shared.uploadGuestFile(
            from: setup,
            to: guestSetup,
            endpoint: endpoint
        )

        report(
            progress,
            0.55,
            "Launching Reloaded-II through Proton…"
        )

        let exitCode =
            try SteamacBridge.shared.runReloadedIISetup(
                appId: appId,
                setupPath: guestSetup,
                endpoint: endpoint
            )

        guard exitCode == 0
        else {
            throw InstallerError.installerFailed(
                exitCode: exitCode,
                output: ""
            )
        }

        report(
            progress,
            0.88,
            "Verifying Reloaded-II inside Steamac…"
        )

        try verifySteamacInstallation(
            for: game,
            endpoint: endpoint
        )

        report(
            progress,
            0.94,
            "Registering game with Reloaded-II…"
        )

        _ = try ReloadedIIApplicationRegistry
            .shared
            .register(
                game,
                endpoint: endpoint
            )

        report(
            progress,
            0.98,
            "Reloaded-II game registration completed"
        )
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

        // Wine accepts a host Unix path for the
        // executable. Avoid assuming every compatibility
        // layer exposes the Unix filesystem through Z:.
        process.arguments = [
            setup.path
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

    // ── Installation verification ─────────────

    private func verifyInstallation(
        for game: GameInstall
    ) throws {
        let paths = ReloadedIIPaths(
            game: game
        )

        guard let executable = paths.executable else {
            throw InstallerError.installationNotFound
        }

        guard fm.fileExists(
            atPath: executable.path
        ) else {
            throw InstallerError.installationNotFound
        }
    }

    private func verifySteamacInstallation(
        for game: GameInstall,
        endpoint: SteamacBridgeEndpoint
    ) throws {
        guard let executable =
            try ReloadedIIPaths.resolveEnvironmentExecutable(
                for: game,
                endpoint: endpoint
            )
        else {
            throw InstallerError.installationNotFound
        }

        guard case .guest(let executablePath) =
            executable
        else {
            throw InstallerError.installationNotFound
        }

        let info =
            try SteamacBridge.shared.guestFileInfo(
                at: executablePath,
                endpoint: endpoint
            )

        guard info.kind == .file
        else {
            throw InstallerError.installationNotFound
        }
    }


    private static func guestJoin(
        _ base: String,
        _ component: String
    ) -> String {
        ReloadedIIPaths.guestJoin(
            base,
            component
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
        case invalidSteamacGame
        case wineBinaryNotFound
        case installationNotFound
        case downloadFailed(String)
        case launchFailed(String)
        case installerFailed(
            exitCode: Int32,
            output: String
        )

        var errorDescription: String? {
            switch self {

            case .invalidSteamacGame:
                return """
                This Steamac game does not expose the                 AppID and Steam library information                 required to install Reloaded-II
                """

            case .wineBinaryNotFound:
                return """
                Wine binary not found for this \
                compatibility environment
                """

            case .installationNotFound:
                return """
                Reloaded-II setup completed, but \
                Reloaded-II.exe could not be found \
                in the Wine user's Desktop folder
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
