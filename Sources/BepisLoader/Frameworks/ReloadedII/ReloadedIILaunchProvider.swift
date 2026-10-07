import Foundation

// ─────────────────────────────────────────────
//  Reloaded-II Launch Provider
//
//  Reloaded-II owns its injection lifecycle.
//
//  BepisLoader launches:
//
//      Reloaded-II.exe --launch <game.exe>
//
//  in the same Wine prefix.
//
//  No ASI deployment or custom injection occurs
//  here.
// ─────────────────────────────────────────────

final class ReloadedIILaunchProvider:
    GameLaunchProvider
{
    static let shared =
        ReloadedIILaunchProvider()

    let framework:
        ModFramework = .reloadedII

    private init() {}

    func configureLaunch(
        for game: GameInstall,
        configuration:
            inout GameLaunchConfiguration
    ) {
        let paths =
            ReloadedIIPaths(
                game: game
            )

        guard let reloadedExecutable =
                paths.executable
        else {
            return
        }

        configuration.executable =
            reloadedExecutable

        configuration.arguments = [
            "--launch",
            windowsPath(
                for: game.executablePath,
                in: game.bottle
            )
        ]

        // Prevent host .NET configuration from
        // leaking into Reloaded-II under Wine.
        configuration.environment[
            "DOTNET_ROOT"
        ] = ""
    }

    private func windowsPath(
        for url: URL,
        in bottle: Bottle
    ) -> String {
        let path =
            url.standardizedFileURL.path

        let driveC =
            bottle.path
                .appendingPathComponent(
                    "drive_c",
                    isDirectory: true
                )
                .standardizedFileURL.path

        let driveCPrefix =
            driveC.hasSuffix("/")
                ? driveC
                : driveC + "/"

        if path.hasPrefix(
            driveCPrefix
        ) {
            let relative =
                String(
                    path.dropFirst(
                        driveCPrefix.count
                    )
                )

            return "C:\\\\" +
                relative.replacingOccurrences(
                    of: "/",
                    with: "\\"
                )
        }

        return "Z:" +
            path.replacingOccurrences(
                of: "/",
                with: "\\"
            )
    }
}
