import Foundation

// ─────────────────────────────────────────────
//  ReloadedIIModManager
//
//  Uses real Reloaded-II ModConfig.json metadata
//  and per-application EnabledMods / SortedMods.
// ─────────────────────────────────────────────

final class ReloadedIIModManager:
    ModManaging
{
    static let shared =
        ReloadedIIModManager()

    let framework:
        ModFramework = .reloadedII

    private let fm =
        FileManager.default

    private let registry =
        ReloadedIIApplicationRegistry.shared

    private init() {}

    // ── Discovery ─────────────────────────────

    func installedMods(
        for game: GameInstall
    ) -> [InstalledMod] {
        let paths = ReloadedIIPaths(
            game: game
        )

        guard let modsRoot = paths.mods,
              fm.fileExists(
                atPath: modsRoot.path
              )
        else {
            return []
        }

        guard let application =
                registry.registeredApplication(
                    for: game
                )
        else {
            return []
        }

        let enabledIds = Set(
            application.config.enabledMods
                .map {
                    $0.lowercased()
                }
        )

        let discovered =
            ReloadedIIModDiscovery.mods(
                under: modsRoot
            )
            .filter {
                supports(
                    $0.config,
                    applicationId:
                        application.config.appId
                )
            }

        return discovered
            .map { mod in
                InstalledMod(
                    id: mod.config.modId,
                    name: mod.config.modName,
                    version:
                        emptyToNil(
                            mod.config.modVersion
                        ),
                    author:
                        emptyToNil(
                            mod.config.modAuthor
                        ),
                    description:
                        mod.config.modDescription,
                    framework:
                        framework,
                    path:
                        mod.directory,
                    isEnabled:
                        enabledIds.contains(
                            mod.config.modId
                                .lowercased()
                        )
                )
            }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare(
                    $1.name
                ) == .orderedAscending
            }
    }

    // ── Installation ──────────────────────────

    func installMod(
        from source: URL,
        into game: GameInstall
    ) throws {
        var isDirectory:
            ObjCBool = false

        guard fm.fileExists(
            atPath: source.path,
            isDirectory: &isDirectory
        ),
        isDirectory.boolValue
        else {
            throw ReloadedIIModError
                .expectedDirectory
        }

        let paths = ReloadedIIPaths(
            game: game
        )

        guard let modsRoot = paths.mods else {
            throw ReloadedIIModError
                .frameworkNotInstalled
        }

        let application =
            try registry.register(game)

        guard let sourceMod =
                ReloadedIIModDiscovery.firstMod(
                    under: source
                )
        else {
            throw ReloadedIIModError
                .missingModConfig
        }

        guard supports(
            sourceMod.config,
            applicationId:
                application.config.appId
        ) else {
            throw ReloadedIIModError
                .unsupportedApplication(
                    modId:
                        sourceMod.config.modId,
                    appId:
                        application.config.appId
                )
        }

        if !fm.fileExists(
            atPath: modsRoot.path
        ) {
            try fm.createDirectory(
                at: modsRoot,
                withIntermediateDirectories: true
            )
        }

        // Refuse duplicate ModIds even if their
        // folder names differ.
        let existing =
            ReloadedIIModDiscovery.mods(
                under: modsRoot
            )

        if existing.contains(
            where: {
                $0.config.modId
                    .caseInsensitiveCompare(
                        sourceMod.config.modId
                    ) == .orderedSame
            }
        ) {
            throw ReloadedIIModError
                .duplicateModId(
                    sourceMod.config.modId
                )
        }

        let destination =
            uniqueDestination(
                source.lastPathComponent,
                under: modsRoot
            )

        try fm.copyItem(
            at: source,
            to: destination
        )

        // Validate the copied result before
        // touching AppConfig.json.
        guard let installed =
                ReloadedIIModDiscovery.mods(
                    under: destination
                )
                .first(
                    where: {
                        $0.config.modId
                            .caseInsensitiveCompare(
                                sourceMod.config.modId
                            ) == .orderedSame
                    }
                )
        else {
            try? fm.removeItem(
                at: destination
            )

            throw ReloadedIIModError
                .invalidInstalledMod
        }

        do {
            try setModEnabledById(
                true,
                modId:
                    installed.config.modId,
                game:
                    game
            )
        } catch {
            try? fm.removeItem(
                at: destination
            )

            throw error
        }
    }

    // ── Removal ───────────────────────────────

    func removeMod(
        _ mod: InstalledMod,
        from game: GameInstall
    ) throws {
        guard mod.framework ==
                framework
        else {
            throw ReloadedIIModError
                .wrongFramework
        }

        let paths = ReloadedIIPaths(
            game: game
        )

        guard let modsRoot = paths.mods else {
            throw ReloadedIIModError
                .frameworkNotInstalled
        }

        let discovered =
            ReloadedIIModDiscovery.mods(
                under: modsRoot
            )

        guard let target =
                discovered.first(
                    where: {
                        $0.config.modId
                            .caseInsensitiveCompare(
                                mod.id
                            ) == .orderedSame
                    }
                )
        else {
            throw ReloadedIIModError
                .modNotFound(
                    mod.id
                )
        }

        // Remove references from this game's
        // application config before deleting
        // the globally installed mod.
        try removeModIdFromApplication(
            target.config.modId,
            game: game
        )

        try fm.removeItem(
            at: target.directory
        )
    }

    // ── Enable / disable ──────────────────────

    func setModEnabled(
        _ enabled: Bool,
        mod: InstalledMod,
        in game: GameInstall
    ) throws {
        guard mod.framework ==
                framework
        else {
            throw ReloadedIIModError
                .wrongFramework
        }

        try setModEnabledById(
            enabled,
            modId: mod.id,
            game: game
        )
    }

    private func setModEnabledById(
        _ enabled: Bool,
        modId: String,
        game: GameInstall
    ) throws {
        let paths = ReloadedIIPaths(
            game: game
        )

        guard let modsRoot = paths.mods else {
            throw ReloadedIIModError
                .frameworkNotInstalled
        }

        guard let discovered =
                ReloadedIIModDiscovery.mods(
                    under: modsRoot
                )
                .first(
                    where: {
                        $0.config.modId
                            .caseInsensitiveCompare(
                                modId
                            ) == .orderedSame
                    }
                )
        else {
            throw ReloadedIIModError
                .modNotFound(
                    modId
                )
        }

        var application =
            try registry.register(game)

        guard supports(
            discovered.config,
            applicationId:
                application.config.appId
        ) else {
            throw ReloadedIIModError
                .unsupportedApplication(
                    modId:
                        discovered.config.modId,
                    appId:
                        application.config.appId
                )
        }

        let canonicalId =
            discovered.config.modId

        application.config.enabledMods =
            application.config.enabledMods
                .filter {
                    $0.caseInsensitiveCompare(
                        canonicalId
                    ) != .orderedSame
                }

        if enabled {
            application.config.enabledMods
                .append(
                    canonicalId
                )
        }

        // Modern Reloaded-II keeps disabled mods
        // in SortedMods when disabled-mod ordering
        // is preserved.
        if application.config
            .preserveDisabledModOrder
        {
            let alreadySorted =
                application.config.sortedMods
                    .contains {
                        $0.caseInsensitiveCompare(
                            canonicalId
                        ) == .orderedSame
                    }

            if !alreadySorted {
                application.config.sortedMods
                    .append(
                        canonicalId
                    )
            }
        }

        try registry.update(
            application
        )
    }

    // ── Application config cleanup ────────────

    private func removeModIdFromApplication(
        _ modId: String,
        game: GameInstall
    ) throws {
        guard var application =
                registry.registeredApplication(
                    for: game
                )
        else {
            return
        }

        application.config.enabledMods =
            application.config.enabledMods
                .filter {
                    $0.caseInsensitiveCompare(
                        modId
                    ) != .orderedSame
                }

        application.config.sortedMods =
            application.config.sortedMods
                .filter {
                    $0.caseInsensitiveCompare(
                        modId
                    ) != .orderedSame
                }

        try registry.update(
            application
        )
    }

    // ── Compatibility ─────────────────────────

    private func supports(
        _ mod:
            ReloadedIIModConfig,
        applicationId:
            String
    ) -> Bool {
        if mod.isUniversalMod {
            return true
        }

        return mod.supportedAppId
            .contains {
                $0.caseInsensitiveCompare(
                    applicationId
                ) == .orderedSame
            }
    }

    // ── Filesystem helpers ────────────────────

    private func uniqueDestination(
        _ preferredName: String,
        under root: URL
    ) -> URL {
        let cleanName =
            preferredName.isEmpty
                ? "ReloadedMod"
                : preferredName

        var candidate =
            root.appendingPathComponent(
                cleanName,
                isDirectory: true
            )

        var suffix = 2

        while fm.fileExists(
            atPath: candidate.path
        ) {
            candidate =
                root.appendingPathComponent(
                    "\(cleanName)-\(suffix)",
                    isDirectory: true
                )

            suffix += 1
        }

        return candidate
    }

    private func emptyToNil(
        _ value: String
    ) -> String? {
        let trimmed =
            value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        return trimmed.isEmpty
            ? nil
            : trimmed
    }

    // ── Errors ────────────────────────────────

    enum ReloadedIIModError:
        LocalizedError
    {
        case expectedDirectory
        case frameworkNotInstalled
        case missingModConfig
        case invalidInstalledMod
        case duplicateModId(String)
        case unsupportedApplication(
            modId: String,
            appId: String
        )
        case modNotFound(String)
        case wrongFramework

        var errorDescription: String? {
            switch self {

            case .expectedDirectory:
                return """
                Reloaded-II mods must be \
                installed from a folder
                """

            case .frameworkNotInstalled:
                return """
                Reloaded-II is not installed \
                for this game
                """

            case .missingModConfig:
                return """
                No valid ModConfig.json was \
                found in the selected folder
                """

            case .invalidInstalledMod:
                return """
                The copied Reloaded-II mod \
                could not be validated
                """

            case .duplicateModId(
                let modId
            ):
                return """
                A Reloaded-II mod with ID \
                \(modId) is already installed
                """

            case .unsupportedApplication(
                let modId,
                let appId
            ):
                return """
                Reloaded-II mod \(modId) does \
                not declare support for \
                application \(appId)
                """

            case .modNotFound(
                let modId
            ):
                return """
                Reloaded-II mod \(modId) \
                could not be found
                """

            case .wrongFramework:
                return """
                This mod is not a \
                Reloaded-II mod
                """
            }
        }
    }
}
