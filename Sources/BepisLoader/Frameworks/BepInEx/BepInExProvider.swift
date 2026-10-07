import Foundation

// ─────────────────────────────────────────────
//  BepInExProvider
//
//  Generic mod-framework facade for the existing
//  BepInEx implementation.
//
//  BepInExInstaller remains responsible for the
//  proven installation pipeline while the rest
//  of BepisLoader can interact with BepInEx via
//  ModFrameworkProvider.
// ─────────────────────────────────────────────

final class BepInExProvider: ModFrameworkProvider {

    static let shared = BepInExProvider()

    let framework: ModFramework = .bepInEx

    private let installer: BepInExInstaller

    private init(installer: BepInExInstaller = .shared) {
        self.installer = installer
    }

    // ── Detection ─────────────────────────────

    func detect(in game: GameInstall) -> FrameworkInstallation {
        let status: FrameworkStatus

        switch game.bepInExStatus {
        case .notInstalled:
            status = .notInstalled

        case .installed(let version):
            status = .installed(version: version)

        case .incompatible(let reason):
            status = .incompatible(reason: reason)
        }

        return FrameworkInstallation(
            framework: framework,
            status: status
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
        try installer.uninstall(from: game)
    }
}
