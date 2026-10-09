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
        switch game.backing {
        case .localWine:
            return detectLocal(
                in: game
            )

        case .steamac:
            return detectSteamac(
                in: game
            )
        }
    }

    private func detectLocal(
        in game: GameInstall
    ) -> FrameworkInstallation {
        let paths = BepInExPaths(
            game: game
        )

        guard FileManager.default.fileExists(
            atPath: paths.root.path
        ) else {
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
            FileManager.default.fileExists(
                atPath: $0.path
            )
        }) {
            return FrameworkInstallation(
                framework: framework,
                status: .installed(
                    version: "unknown"
                )
            )
        }

        if let logText = try? String(
            contentsOf: paths.log,
            encoding: .utf8
        ) {
            let pattern =
                #"BepInEx\s+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?)"#

            if let regex = try? NSRegularExpression(
                pattern: pattern
            ),
               let match = regex.firstMatch(
                    in: logText,
                    range: NSRange(
                        logText.startIndex...,
                        in: logText
                    )
               ),
               let range = Range(
                    match.range(at: 1),
                    in: logText
               ) {
                return FrameworkInstallation(
                    framework: framework,
                    status: .installed(
                        version: String(
                            logText[range]
                        )
                    )
                )
            }
        }

        return FrameworkInstallation(
            framework: framework,
            status: .installed(
                version: "unknown"
            )
        )
    }

    private func detectSteamac(
        in game: GameInstall
    ) -> FrameworkInstallation {
        guard let endpoint =
                SteamacBridge.shared
                    .endpoints()
                    .first
        else {
            return FrameworkInstallation(
                framework: framework,
                status: .incompatible(
                    reason:
                        "Steamac is not running."
                )
            )
        }

        let paths =
            BepInExPaths(
                game: game
            )

        guard case .guest(let root) =
                paths.environmentRoot
        else {
            return FrameworkInstallation(
                framework: framework,
                status: .incompatible(
                    reason:
                        "Steamac game has no guest BepInEx path."
                )
            )
        }

        do {
            let rootInfo =
                try SteamacBridge.shared
                    .guestFileInfo(
                        at: root,
                        endpoint: endpoint
                    )

            guard rootInfo.exists
            else {
                return FrameworkInstallation(
                    framework: framework,
                    status: .notInstalled
                )
            }

            let candidates = [
                BepInExPaths.guestJoin(
                    root,
                    "core/BepInEx.Unity.IL2CPP.dll"
                ),
                BepInExPaths.guestJoin(
                    root,
                    "core/BepInEx.Core.dll"
                ),
                BepInExPaths.guestJoin(
                    root,
                    "core/BepInEx.dll"
                )
            ]

            for candidate in candidates {
                let info =
                    try SteamacBridge.shared
                        .guestFileInfo(
                            at: candidate,
                            endpoint: endpoint
                        )

                if info.exists {
                    return FrameworkInstallation(
                        framework: framework,
                        status: .installed(
                            version: "unknown"
                        )
                    )
                }
            }

            // Directory existence is enough to report an installation,
            // matching the existing local fallback semantics.
            return FrameworkInstallation(
                framework: framework,
                status: .installed(
                    version: "unknown"
                )
            )
        } catch {
            return FrameworkInstallation(
                framework: framework,
                status: .incompatible(
                    reason:
                        error.localizedDescription
                )
            )
        }
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
