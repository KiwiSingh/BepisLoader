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

    // 42A-3: validated Reloaded-II download.
    //
    // These are defensive bounds, not a verified statement about
    // the current official installer release.
    private static let minimumInstallerBytes: UInt64 = 64 * 1024
    private static let maximumInstallerBytes: UInt64 = 512 * 1024 * 1024

    // 42A-3-R2: condition-synchronized transfer.
    //
    // The transfer owns its file until URLSession has finished.
    // Timeout closes and removes partial output synchronously.
    private func downloadInstaller() throws -> URL {
        let destination = fm.temporaryDirectory
            .appendingPathComponent(
                "BepisLoader-ReloadedII-\(UUID().uuidString)"
            )
            .appendingPathExtension("exe")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300

        let transfer = ReloadedIITransfer(
            destination: destination,
            maximumBytes: Int64(Self.maximumInstallerBytes)
        )

        let session = URLSession(
            configuration: configuration,
            delegate: transfer,
            delegateQueue: nil
        )

        defer {
            session.invalidateAndCancel()
        }

        let task = session.dataTask(with: installerURL)
        task.resume()

        let downloadedURL: URL

        do {
            downloadedURL = try transfer.wait(
                for: task,
                timeout: 330
            )
        } catch {
            throw InstallerError.downloadFailed(
                error.localizedDescription
            )
        }

        do {
            try validateDownloadedInstaller(at: downloadedURL)
            return downloadedURL
        } catch {
            try? fm.removeItem(at: downloadedURL)
            throw error
        }
    }

    private func validateDownloadedInstaller(
        at url: URL
    ) throws {
        let attributes = try fm.attributesOfItem(
            atPath: url.path
        )

        guard let sizeNumber =
            attributes[.size] as? NSNumber
        else {
            throw InstallerError.downloadFailed(
                "Unable to determine installer size"
            )
        }

        let size = sizeNumber.uint64Value

        guard size >= Self.minimumInstallerBytes else {
            throw InstallerError.downloadFailed(
                "Installer is unexpectedly small (\(size) bytes)"
            )
        }

        guard size <= Self.maximumInstallerBytes else {
            throw InstallerError.downloadFailed(
                "Installer exceeds the 512 MiB safety limit"
            )
        }

        let handle = try FileHandle(
            forReadingFrom: url
        )
        defer { try? handle.close() }

        // DOS header: MZ at offset zero.
        let dosHeader = try handle.read(
            upToCount: 64
        ) ?? Data()

        guard dosHeader.count == 64,
              dosHeader[0] == 0x4D,
              dosHeader[1] == 0x5A
        else {
            throw InstallerError.downloadFailed(
                "Downloaded file has no valid MZ header"
            )
        }

        // e_lfanew: little-endian offset to PE header.
        let peOffset =
            UInt64(dosHeader[0x3C])
            | (UInt64(dosHeader[0x3D]) << 8)
            | (UInt64(dosHeader[0x3E]) << 16)
            | (UInt64(dosHeader[0x3F]) << 24)

        guard peOffset >= 64,
              peOffset <= size - 24
        else {
            throw InstallerError.downloadFailed(
                "Downloaded executable has an invalid PE offset"
            )
        }

        try handle.seek(toOffset: peOffset)

        let peHeader = try handle.read(
            upToCount: 24
        ) ?? Data()

        guard peHeader.count == 24,
              peHeader[0] == 0x50,
              peHeader[1] == 0x45,
              peHeader[2] == 0,
              peHeader[3] == 0
        else {
            throw InstallerError.downloadFailed(
                "Downloaded executable has no valid PE signature"
            )
        }

        // COFF Machine field.
        let machine =
            UInt16(peHeader[4])
            | (UInt16(peHeader[5]) << 8)

        // x86 and x86-64 Windows executables.
        guard machine == 0x014C || machine == 0x8664 else {
            throw InstallerError.downloadFailed(
                "Unsupported Windows executable architecture"
            )
        }

        // COFF Characteristics field, IMAGE_FILE_EXECUTABLE_IMAGE.
        let characteristics =
            UInt16(peHeader[22])
            | (UInt16(peHeader[23]) << 8)

        guard characteristics & 0x0002 != 0 else {
            throw InstallerError.downloadFailed(
                "Downloaded PE file is not marked executable"
            )
        }
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

// MARK: - Reloaded-II bounded transfer

// 42A-3-R2: condition-synchronized transfer.
//
// Every state transition and file operation is protected by the
// same NSCondition. A successful result is published only after
// URLSession finishes and the output file has been closed.
//
// This helper never executes the downloaded installer.
private final class ReloadedIITransfer:
    NSObject,
    URLSessionDataDelegate,
    @unchecked Sendable
{
    private let destination: URL
    private let maximumBytes: Int64

    private let condition = NSCondition()

    private var finished = false
    private var outcome: Result<URL, Error>?
    private var handle: FileHandle?
    private var receivedBytes: Int64 = 0
    private var failureReason: String?
    private var expired = false

    init(destination: URL, maximumBytes: Int64) {
        self.destination = destination
        self.maximumBytes = maximumBytes
        super.init()
    }

    private func failure(_ message: String) -> Error {
        NSError(
            domain: "BepisLoader.ReloadedII.Download",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: message
            ]
        )
    }

    // Requires condition to be locked.
    private func closeAndRemoveLocked() {
        if let handle {
            try? handle.close()
            self.handle = nil
        }

        try? FileManager.default.removeItem(
            at: destination
        )
    }

    // Requires condition to be locked.
    private func finishLocked(
        _ result: Result<URL, Error>
    ) {
        guard !finished else {
            return
        }

        finished = true
        outcome = result
        condition.broadcast()
    }

    func wait(
        for task: URLSessionTask,
        timeout: TimeInterval
    ) throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)

        condition.lock()

        while !finished {
            if !condition.wait(until: deadline) {
                if !finished {
                    expired = true
                    closeAndRemoveLocked()

                    finishLocked(
                        .failure(
                            failure(
                                "Download exceeded \(Int(timeout)) seconds"
                            )
                        )
                    )
                }

                break
            }
        }

        let result = outcome
        let timedOut = expired

        condition.unlock()

        // Terminal timeout state is visible before cancellation.
        if timedOut {
            task.cancel()
        }

        guard let result else {
            throw failure("Download finished without a result")
        }

        return try result.get()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        condition.lock()

        guard !finished else {
            condition.unlock()
            completionHandler(.cancel)
            return
        }

        guard let http = response as? HTTPURLResponse else {
            failureReason = "Server returned a non-HTTP response"
            condition.unlock()
            completionHandler(.cancel)
            return
        }

        guard (200...299).contains(http.statusCode) else {
            failureReason =
                "HTTP \(http.statusCode) from download server"
            condition.unlock()
            completionHandler(.cancel)
            return
        }

        if response.expectedContentLength > maximumBytes {
            failureReason = "Installer exceeds 512 MiB"
            condition.unlock()
            completionHandler(.cancel)
            return
        }

        let created = FileManager.default.createFile(
            atPath: destination.path,
            contents: nil,
            attributes: [
                .posixPermissions: 0o600
            ]
        )

        guard created else {
            failureReason = "Unable to create installer output file"
            condition.unlock()
            completionHandler(.cancel)
            return
        }

        do {
            handle = try FileHandle(
                forWritingTo: destination
            )

            condition.unlock()
            completionHandler(.allow)

        } catch {
            failureReason = error.localizedDescription
            closeAndRemoveLocked()
            condition.unlock()
            completionHandler(.cancel)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        condition.lock()

        guard !finished, failureReason == nil else {
            condition.unlock()
            dataTask.cancel()
            return
        }

        let incoming = Int64(data.count)

        guard incoming <= maximumBytes - receivedBytes else {
            failureReason = "Installer exceeds 512 MiB"
            condition.unlock()
            dataTask.cancel()
            return
        }

        guard let handle else {
            failureReason = "Installer output file unavailable"
            condition.unlock()
            dataTask.cancel()
            return
        }

        do {
            try handle.write(contentsOf: data)
            receivedBytes += incoming
            condition.unlock()

        } catch {
            failureReason = error.localizedDescription
            condition.unlock()
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        condition.lock()
        defer {
            condition.unlock()
        }

        guard !finished else {
            return
        }

        if let failureReason {
            closeAndRemoveLocked()
            finishLocked(.failure(failure(failureReason)))
            return
        }

        if let error {
            closeAndRemoveLocked()
            finishLocked(.failure(error))
            return
        }

        guard let handle else {
            closeAndRemoveLocked()
            finishLocked(
                .failure(
                    failure("Download produced no output file")
                )
            )
            return
        }

        do {
            try handle.close()
            self.handle = nil

            finishLocked(.success(destination))

        } catch {
            closeAndRemoveLocked()
            finishLocked(.failure(error))
        }
    }
}
