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

    private let fm = FileManager.default
    private let installer = ReloadedIIInstaller.shared

    private init() {}

    // ── Detection ─────────────────────────────

    func detect(in game: GameInstall) -> FrameworkInstallation {
        let paths = ReloadedIIPaths(game: game)

        guard fm.fileExists(atPath: paths.installationMarker.path) else {
            return FrameworkInstallation(
                framework: framework,
                status: .notInstalled
            )
        }

        let version = try? String(
            contentsOf: paths.installationMarker,
            encoding: .utf8
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        return FrameworkInstallation(
            framework: framework,
            status: .installed(
                version: version?.isEmpty == false ? version : nil
            )
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

        var errorDescription: String? {
            switch self {
            case .uninstallationNotImplemented:
                return "Reloaded-II uninstallation is not implemented yet"
            }
        }
    }
}
