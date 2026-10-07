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
        let paths = BepInExPaths(game: game)

        guard FileManager.default.fileExists(atPath: paths.root.path) else {
            return FrameworkInstallation(
                framework: framework,
                status: .notInstalled
            )
        }

        if let version = try? String(
            contentsOf: paths.versionFile,
            encoding: .utf8
        ) {
            return FrameworkInstallation(
                framework: framework,
                status: .installed(
                    version: version.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                )
            )
        }

        let coreCandidates = [
            paths.root.appendingPathComponent(
                "core/BepInEx.Unity.IL2CPP.dll"
            ),
            paths.root.appendingPathComponent(
                "core/BepInEx.Core.dll"
            ),
            paths.root.appendingPathComponent(
                "core/BepInEx.dll"
            )
        ]

        if coreCandidates.contains(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) {
            return FrameworkInstallation(
                framework: framework,
                status: .installed(version: "unknown")
            )
        }

        if let logText = try? String(
            contentsOf: paths.log,
            encoding: .utf8
        ) {
            let pattern =
                #"BepInEx\s+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?)"#

            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(
                    in: logText,
                    range: NSRange(logText.startIndex..., in: logText)
               ),
               let range = Range(match.range(at: 1), in: logText) {

                return FrameworkInstallation(
                    framework: framework,
                    status: .installed(
                        version: String(logText[range])
                    )
                )
            }
        }

        // A BepInEx directory exists even if its exact version
        // cannot be determined.
        return FrameworkInstallation(
            framework: framework,
            status: .installed(version: "unknown")
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
