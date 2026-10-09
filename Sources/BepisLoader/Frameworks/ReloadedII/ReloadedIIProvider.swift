import Foundation

// ─────────────────────────────────────────────
//  ReloadedIIProvider
//
//  Reloaded-II implementation of the generic
//  ModFrameworkProvider abstraction.
//
//  Installation/uninstallation are intentionally
//  placeholders until the actual Wine/Proton
//  installation pipeline lands.
// ─────────────────────────────────────────────

final class ReloadedIIProvider: ModFrameworkProvider {

    static let shared = ReloadedIIProvider()

    let framework: ModFramework = .reloadedII

    private let installer = ReloadedIIInstaller.shared

    private init() {}

    // ── Detection ─────────────────────────────

    /// Synchronous provider-protocol detection.
    ///
    /// Local Wine installs can be inspected directly. Guest-backed
    /// environments deliberately do not perform hidden bridge I/O.
    /// Steamac callers should use the endpoint-aware overload.
    func detect(
        in game: GameInstall
    ) -> FrameworkInstallation {
        switch game.environment.filesystem {

        case .local:
            return detectLocal(
                in: game
            )

        case .guest:
            return notInstalled()
        }
    }


    /// Authoritative environment-aware detection.
    ///
    /// Steamac detection is explicit because resolving and checking
    /// the guest Reloaded-II installation requires bridge IPC.
    func detect(
        in game: GameInstall,
        endpoint: SteamacBridgeEndpoint
    ) throws -> FrameworkInstallation {
        switch game.environment.filesystem {

        case .local:
            return detectLocal(
                in: game
            )

        case .guest:
            return try detectSteamac(
                in: game,
                endpoint: endpoint
            )
        }
    }


    private func detectLocal(
        in game: GameInstall
    ) -> FrameworkInstallation {
        let paths =
            ReloadedIIPaths(
                game: game
            )

        guard let executable =
                paths.executable
        else {
            return notInstalled()
        }

        let version =
            WindowsExecutableMetadata
                .fileVersion(
                    at: executable
                )

        return installed(
            version: version
        )
    }


    private func detectSteamac(
        in game: GameInstall,
        endpoint: SteamacBridgeEndpoint
    ) throws -> FrameworkInstallation {
        guard case .steamac =
                game.backing
        else {
            throw ReloadedIIError
                .invalidSteamacGame
        }

        guard let executable =
                try ReloadedIIPaths
                    .resolveEnvironmentExecutable(
                        for: game,
                        endpoint: endpoint
                    )
        else {
            return notInstalled()
        }

        guard case .guest(
            let executablePath
        ) = executable
        else {
            throw ReloadedIIError
                .invalidSteamacGame
        }

        let info =
            try SteamacBridge.shared
                .guestFileInfo(
                    at: executablePath,
                    endpoint: endpoint
                )

        guard info.kind == .file
        else {
            return notInstalled()
        }

        // WindowsExecutableMetadata requires a host URL.
        // Guest PE version-resource inspection has not landed yet,
        // so do not manufacture a version string here.
        return installed(
            version: nil
        )
    }


    private func installed(
        version: String?
    ) -> FrameworkInstallation {
        FrameworkInstallation(
            framework: framework,
            status: .installed(
                version: version
            )
        )
    }


    private func notInstalled()
        -> FrameworkInstallation
    {
        FrameworkInstallation(
            framework: framework,
            status: .notInstalled
        )
    }

    // ── Installation ──────────────────────────

    func install(
        into game: GameInstall,
        progress: @escaping (Double, String) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        installer.install(
            into: game,
            progress: progress,
            completion: completion
        )
    }

    // ── Uninstallation ────────────────────────

    func uninstall(from game: GameInstall) throws {
        throw ReloadedIIError.uninstallationNotImplemented
    }

    enum ReloadedIIError: LocalizedError {
        case uninstallationNotImplemented
        case invalidSteamacGame

        var errorDescription: String? {
            switch self {

            case .uninstallationNotImplemented:
                return """
                Reloaded-II uninstallation is not implemented yet
                """

            case .invalidSteamacGame:
                return """
                Reloaded-II Steamac detection received an                 incompatible game environment
                """
            }
        }
    }
}
