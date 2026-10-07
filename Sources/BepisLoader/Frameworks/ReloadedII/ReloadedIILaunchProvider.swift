import Foundation

// ─────────────────────────────────────────────
//  Reloaded-II Launch Provider
//
//  Reloaded-II owns injection.
//
//  BepisLoader launches:
//
//      Reloaded-II.exe
//          --launch <AppConfig.AppLocation>
//
//  The --launch value is taken directly from the
//  registered AppConfig rather than independently
//  recomputing a Windows path.
//
//  This guarantees registration and launch agree
//  on the executable identity Reloaded-II uses.
// ─────────────────────────────────────────────

final class ReloadedIILaunchProvider:
    GameLaunchProvider
{
    static let shared =
        ReloadedIILaunchProvider()

    let framework:
        ModFramework = .reloadedII

    private let registry =
        ReloadedIIApplicationRegistry.shared

    private init() {}

    func configureLaunch(
        for game: GameInstall,
        configuration:
            inout GameLaunchConfiguration
    ) throws {
        let paths =
            ReloadedIIPaths(
                game: game
            )

        guard let reloadedExecutable =
                paths.executable
        else {
            throw LaunchConfigurationError
                .frameworkNotInstalled
        }

        let application =
            try registry.register(
                game
            )

        let canonicalLocation =
            try paths.requiredWindowsPath(
                for: game.executablePath
            )

        guard normalizeWindowsPath(
            application.config.appLocation
        ) == normalizeWindowsPath(
            canonicalLocation
        ) else {
            throw LaunchConfigurationError
                .registrationMismatch(
                    expected:
                        canonicalLocation,
                    registered:
                        application.config
                            .appLocation
                )
        }

        let registeredAppLocation =
            application.config.appLocation

        guard !registeredAppLocation
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                .isEmpty
        else {
            throw LaunchConfigurationError
                .emptyAppLocation
        }

        configuration.executable =
            reloadedExecutable

        configuration.arguments = [
            "--launch",
            registeredAppLocation
        ]

        // Avoid host .NET state leaking into the
        // Wine-hosted Reloaded-II process.
        configuration.environment[
            "DOTNET_ROOT"
        ] = ""
    }

    private func normalizeWindowsPath(
        _ path: String
    ) -> String {
        path
            .replacingOccurrences(
                of: "/",
                with: "\\"
            )
            .trimmingCharacters(
                in: CharacterSet(
                    charactersIn: "\\"
                )
            )
            .lowercased()
    }

    enum LaunchConfigurationError:
        LocalizedError
    {
        case frameworkNotInstalled

        case registrationMismatch(
            expected: String,
            registered: String
        )

        case emptyAppLocation

        var errorDescription: String? {
            switch self {

            case .frameworkNotInstalled:
                return """
                Reloaded-II is not installed \
                in this game's Wine prefix
                """

            case .registrationMismatch(
                let expected,
                let registered
            ):
                return """
                Reloaded-II registration does \
                not match this game.

                Expected:
                \(expected)

                Registered:
                \(registered)
                """

            case .emptyAppLocation:
                return """
                Reloaded-II's AppConfig has an \
                empty AppLocation
                """
            }
        }
    }
}
