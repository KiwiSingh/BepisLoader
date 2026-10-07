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
        let paths =
            ReloadedIIPaths(
                game: game
            )

        guard let modsRoot =
                paths.mods
        else {
            throw ReloadedIIModError
                .frameworkNotInstalled
        }

        let application =
            try registry.register(
                game
            )

        var sourceIsDirectory:
            ObjCBool = false

        guard fm.fileExists(
            atPath: source.path,
            isDirectory:
                &sourceIsDirectory
        ) else {
            throw ReloadedIIModError
                .sourceNotFound
        }

        let workspace =
            try PackageWorkspace(
                fileManager: fm
            )

        defer {
            workspace.cleanup()
        }

        let packageRoot =
            try preparePackage(
                source,
                sourceIsDirectory:
                    sourceIsDirectory.boolValue,
                in: workspace
            )

        let packageMods:
            [ReloadedIIDiscoveredMod]

        do {
            packageMods =
                try ReloadedIIModDiscovery
                    .packageMods(
                        under: packageRoot
                    )
        } catch {
            throw ReloadedIIModError
                .invalidPackage(
                    error.localizedDescription
                )
        }

        guard packageMods.count == 1,
              let packageMod =
                packageMods.first
        else {
            throw ReloadedIIModError
                .ambiguousPackage(
                    packageMods.map {
                        $0.config.modId
                    }
                )
        }

        let modConfig =
            packageMod.config

        guard supports(
            modConfig,
            applicationId:
                application.config.appId
        ) else {
            throw ReloadedIIModError
                .unsupportedApplication(
                    modId:
                        modConfig.modId,
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

        let existing =
            ReloadedIIModDiscovery.mods(
                under: modsRoot
            )
            .first {
                $0.config.modId
                    .caseInsensitiveCompare(
                        modConfig.modId
                    ) == .orderedSame
            }

        let destination =
            modsRoot.appendingPathComponent(
                safeDirectoryName(
                    for: modConfig.modId
                ),
                isDirectory: true
            )

        let wasEnabled =
            application.config.enabledMods
                .contains {
                    $0.caseInsensitiveCompare(
                        modConfig.modId
                    ) == .orderedSame
                }

        let previousSortedIndex =
            application.config.sortedMods
                .firstIndex {
                    $0.caseInsensitiveCompare(
                        modConfig.modId
                    ) == .orderedSame
                }

        try validateRequiredDependencies(
            for: modConfig,
            installedMods:
                ReloadedIIModDiscovery.mods(
                    under: modsRoot
                ),
            applicationId:
                application.config.appId
        )

        let transaction =
            try transactionalInstall(
                payload:
                    packageMod.directory,
                destination:
                    destination,
                existingDirectory:
                    existing?.directory,
                workspace:
                    workspace
            )

        do {
            let installedConfig =
                destination
                    .appendingPathComponent(
                        "ModConfig.json"
                    )

            guard let verified =
                    ReloadedIIModDiscovery.read(
                        at: installedConfig
                    ),
                  verified.config.modId
                    .caseInsensitiveCompare(
                        modConfig.modId
                    ) == .orderedSame
            else {
                throw ReloadedIIModError
                    .invalidInstalledMod
            }

            var updated =
                application

            updated.config.enabledMods =
                updated.config.enabledMods
                    .filter {
                        $0.caseInsensitiveCompare(
                            modConfig.modId
                        ) != .orderedSame
                    }

            updated.config.sortedMods =
                updated.config.sortedMods
                    .filter {
                        $0.caseInsensitiveCompare(
                            modConfig.modId
                        ) != .orderedSame
                    }

            // New mods are enabled.
            // Updates preserve disabled state.
            if existing == nil || wasEnabled {
                updated.config.enabledMods
                    .append(
                        modConfig.modId
                    )
            }

            if let previousSortedIndex {
                updated.config.sortedMods
                    .insert(
                        modConfig.modId,
                        at: min(
                            previousSortedIndex,
                            updated.config
                                .sortedMods.count
                        )
                    )
            } else {
                updated.config.sortedMods
                    .append(
                        modConfig.modId
                    )
            }

            try registry.update(
                updated
            )

            transaction.commit()

        } catch {
            do {
                try transaction.rollback()
            } catch {
                throw ReloadedIIModError
                    .rollbackFailed(
                        error.localizedDescription
                    )
            }

            throw error
        }
    }

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

        try guardAgainstBreakingEnabledDependents(
            targetModId:
                target.config.modId,
            installedMods:
                discovered,
            game:
                game
        )

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

        let allInstalledMods =
            ReloadedIIModDiscovery.mods(
                under: modsRoot
            )

        if enabled {
            try validateRequiredDependencies(
                for: discovered.config,
                installedMods:
                    allInstalledMods,
                applicationId:
                    application.config.appId
            )
        } else {
            try guardAgainstBreakingEnabledDependents(
                targetModId:
                    discovered.config.modId,
                installedMods:
                    allInstalledMods,
                application:
                    application
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

    // ── Dependency graph ──────────────────────

    private struct DependencyValidationResult {
        var missing:
            Set<String> = []

        var incompatible:
            Set<String> = []

        var isValid: Bool {
            missing.isEmpty
            && incompatible.isEmpty
        }
    }

    private func normalizedModId(
        _ modId: String
    ) -> String {
        modId
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            .lowercased()
    }

    private func modIndex(
        _ mods: [ReloadedIIDiscoveredMod]
    ) -> [String: ReloadedIIDiscoveredMod] {
        var result:
            [String: ReloadedIIDiscoveredMod] = [:]

        for mod in mods {
            let key =
                normalizedModId(
                    mod.config.modId
                )

            if result[key] == nil {
                result[key] =
                    mod
            }
        }

        return result
    }

    private func validateRequiredDependencies(
        for rootConfig: ReloadedIIModConfig,
        installedMods:
            [ReloadedIIDiscoveredMod],
        applicationId: String
    ) throws {
        let index =
            modIndex(
                installedMods
            )

        var result =
            DependencyValidationResult()

        var visited =
            Set<String>()

        // The root may be an update of an
        // already-installed mod. Mark it visited
        // so a circular graph cannot recurse back
        // through the old copy.
        visited.insert(
            normalizedModId(
                rootConfig.modId
            )
        )

        inspectRequiredDependencies(
            of: rootConfig,
            index: index,
            applicationId:
                applicationId,
            visited:
                &visited,
            result:
                &result
        )

        guard !result.isValid else {
            return
        }

        throw ReloadedIIModError
            .dependencyValidationFailed(
                modId:
                    rootConfig.modId,
                missing:
                    sortedModIds(
                        result.missing
                    ),
                incompatible:
                    sortedModIds(
                        result.incompatible
                    )
            )
    }

    private func inspectRequiredDependencies(
        of config: ReloadedIIModConfig,
        index:
            [String: ReloadedIIDiscoveredMod],
        applicationId: String,
        visited: inout Set<String>,
        result:
            inout DependencyValidationResult
    ) {
        // OptionalDependencies intentionally do
        // not participate in validation.
        for dependencyId
            in config.modDependencies
        {
            let trimmed =
                dependencyId
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )

            guard !trimmed.isEmpty else {
                continue
            }

            let key =
                normalizedModId(
                    trimmed
                )

            // Cycles are legal for traversal
            // purposes: once a node has already
            // been inspected, stop descending.
            if visited.contains(key) {
                continue
            }

            visited.insert(key)

            guard let dependency =
                    index[key]
            else {
                result.missing.insert(
                    trimmed
                )
                continue
            }

            if !supports(
                dependency.config,
                applicationId:
                    applicationId
            ) {
                result.incompatible.insert(
                    dependency.config.modId
                )

                // Still inspect its children so
                // the user receives the complete
                // dependency failure set.
            }

            inspectRequiredDependencies(
                of: dependency.config,
                index: index,
                applicationId:
                    applicationId,
                visited:
                    &visited,
                result:
                    &result
            )
        }
    }

    private func sortedModIds(
        _ ids: Set<String>
    ) -> [String] {
        ids.sorted {
            $0.localizedCaseInsensitiveCompare(
                $1
            ) == .orderedAscending
        }
    }

    private func guardAgainstBreakingEnabledDependents(
        targetModId: String,
        installedMods:
            [ReloadedIIDiscoveredMod],
        game: GameInstall
    ) throws {
        guard let application =
                registry.registeredApplication(
                    for: game
                )
        else {
            return
        }

        try guardAgainstBreakingEnabledDependents(
            targetModId:
                targetModId,
            installedMods:
                installedMods,
            application:
                application
        )
    }

    private func guardAgainstBreakingEnabledDependents(
        targetModId: String,
        installedMods:
            [ReloadedIIDiscoveredMod],
        application:
            ReloadedIIApplication
    ) throws {
        let dependents =
            enabledDependents(
                of: targetModId,
                installedMods:
                    installedMods,
                enabledModIds:
                    application.config
                        .enabledMods
            )

        guard dependents.isEmpty else {
            throw ReloadedIIModError
                .requiredByEnabledMods(
                    modId:
                        targetModId,
                    dependents:
                        dependents
                )
        }
    }

    private func enabledDependents(
        of targetModId: String,
        installedMods:
            [ReloadedIIDiscoveredMod],
        enabledModIds: [String]
    ) -> [String] {
        let index =
            modIndex(
                installedMods
            )

        let target =
            normalizedModId(
                targetModId
            )

        let enabled =
            Set(
                enabledModIds.map {
                    normalizedModId(
                        $0
                    )
                }
            )

        var result:
            [String] = []

        for mod in installedMods {
            let modKey =
                normalizedModId(
                    mod.config.modId
                )

            guard enabled.contains(
                modKey
            ) else {
                continue
            }

            // A mod never blocks disabling or
            // removing itself.
            guard modKey != target else {
                continue
            }

            var visited =
                Set<String>()

            if transitivelyDepends(
                config:
                    mod.config,
                on: target,
                index: index,
                visited:
                    &visited
            ) {
                result.append(
                    mod.config.modId
                )
            }
        }

        return result.sorted {
            $0.localizedCaseInsensitiveCompare(
                $1
            ) == .orderedAscending
        }
    }

    private func transitivelyDepends(
        config: ReloadedIIModConfig,
        on target:
            String,
        index:
            [String: ReloadedIIDiscoveredMod],
        visited: inout Set<String>
    ) -> Bool {
        let current =
            normalizedModId(
                config.modId
            )

        guard visited.insert(
            current
        ).inserted else {
            return false
        }

        for dependencyId
            in config.modDependencies
        {
            let dependency =
                normalizedModId(
                    dependencyId
                )

            guard !dependency.isEmpty else {
                continue
            }

            if dependency == target {
                return true
            }

            guard let discovered =
                    index[dependency]
            else {
                continue
            }

            if transitivelyDepends(
                config:
                    discovered.config,
                on: target,
                index: index,
                visited:
                    &visited
            ) {
                return true
            }
        }

        return false
    }

    // ── Package installation ───────────────────

    private final class PackageWorkspace {

        let root: URL
        let extraction: URL
        let stagedPayload: URL
        let backup: URL

        private let fm:
            FileManager

        init(
            fileManager: FileManager
        ) throws {
            fm = fileManager

            root =
                fileManager
                    .temporaryDirectory
                    .appendingPathComponent(
                        "BepisLoader-ReloadedII-\(UUID().uuidString)",
                        isDirectory: true
                    )

            extraction =
                root.appendingPathComponent(
                    "Extracted",
                    isDirectory: true
                )

            stagedPayload =
                root.appendingPathComponent(
                    "Payload",
                    isDirectory: true
                )

            backup =
                root.appendingPathComponent(
                    "Previous",
                    isDirectory: true
                )

            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
        }

        func cleanup() {
            try? fm.removeItem(
                at: root
            )
        }
    }

    private final class InstallTransaction {

        private let fm:
            FileManager

        private let destination:
            URL

        private let backup:
            URL

        private let previousLocation:
            URL?

        private var finished =
            false

        init(
            fileManager: FileManager,
            destination: URL,
            backup: URL,
            previousLocation: URL?
        ) {
            fm = fileManager
            self.destination = destination
            self.backup = backup
            self.previousLocation =
                previousLocation
        }

        func commit() {
            guard !finished else {
                return
            }

            finished = true

            if fm.fileExists(
                atPath: backup.path
            ) {
                try? fm.removeItem(
                    at: backup
                )
            }
        }

        func rollback() throws {
            guard !finished else {
                return
            }

            finished = true

            if fm.fileExists(
                atPath: destination.path
            ) {
                try fm.removeItem(
                    at: destination
                )
            }

            guard fm.fileExists(
                atPath: backup.path
            ) else {
                return
            }

            let restoreLocation =
                previousLocation
                ?? destination

            if fm.fileExists(
                atPath: restoreLocation.path
            ) {
                try fm.removeItem(
                    at: restoreLocation
                )
            }

            try fm.moveItem(
                at: backup,
                to: restoreLocation
            )
        }
    }

    private func preparePackage(
        _ source: URL,
        sourceIsDirectory: Bool,
        in workspace: PackageWorkspace
    ) throws -> URL {
        if sourceIsDirectory {
            try fm.copyItem(
                at: source,
                to: workspace.extraction
            )

            return workspace.extraction
        }

        guard source.pathExtension
                .caseInsensitiveCompare(
                    "zip"
                ) == .orderedSame
        else {
            throw ReloadedIIModError
                .unsupportedPackageType
        }

        try fm.createDirectory(
            at: workspace.extraction,
            withIntermediateDirectories: true
        )

        try extractZip(
            source,
            to: workspace.extraction
        )

        return workspace.extraction
    }

    private func extractZip(
        _ archive: URL,
        to destination: URL
    ) throws {
        let process =
            Process()

        process.executableURL =
            URL(
                fileURLWithPath:
                    "/usr/bin/ditto"
            )

        process.arguments = [
            "-x",
            "-k",
            "--",
            archive.path,
            destination.path
        ]

        let errorPipe =
            Pipe()

        process.standardError =
            errorPipe

        do {
            try process.run()
        } catch {
            throw ReloadedIIModError
                .archiveExtractionFailed(
                    error.localizedDescription
                )
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0
        else {
            let data =
                errorPipe
                    .fileHandleForReading
                    .readDataToEndOfFile()

            let output =
                String(
                    data: data,
                    encoding: .utf8
                )?
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

            throw ReloadedIIModError
                .archiveExtractionFailed(
                    output?.isEmpty == false
                        ? output!
                        : "ditto exited with status \(process.terminationStatus)"
                )
        }
    }

    private func safeDirectoryName(
        for modId: String
    ) -> String {
        let invalid =
            CharacterSet(
                charactersIn:
                    "/\\:"
            )
            .union(
                .controlCharacters
            )

        let sanitized =
            modId
                .components(
                    separatedBy: invalid
                )
                .filter {
                    !$0.isEmpty
                }
                .joined(
                    separator: "_"
                )
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

        return sanitized.isEmpty
            ? "ReloadedMod"
            : sanitized
    }

    private func transactionalInstall(
        payload: URL,
        destination: URL,
        existingDirectory: URL?,
        workspace: PackageWorkspace
    ) throws -> InstallTransaction {
        try fm.copyItem(
            at: payload,
            to: workspace.stagedPayload
        )

        let stagedConfig =
            workspace.stagedPayload
                .appendingPathComponent(
                    "ModConfig.json"
                )

        guard ReloadedIIModDiscovery.read(
            at: stagedConfig
        ) != nil
        else {
            throw ReloadedIIModError
                .invalidInstalledMod
        }

        let previousLocation:
            URL?

        if let existingDirectory,
           fm.fileExists(
                atPath: existingDirectory.path
           )
        {
            previousLocation =
                existingDirectory

            try fm.moveItem(
                at: existingDirectory,
                to: workspace.backup
            )

        } else if fm.fileExists(
            atPath: destination.path
        ) {
            previousLocation =
                destination

            try fm.moveItem(
                at: destination,
                to: workspace.backup
            )

        } else {
            previousLocation =
                nil
        }

        do {
            if fm.fileExists(
                atPath: destination.path
            ) {
                try fm.removeItem(
                    at: destination
                )
            }

            try fm.moveItem(
                at: workspace.stagedPayload,
                to: destination
            )

        } catch {
            if fm.fileExists(
                atPath: destination.path
            ) {
                try? fm.removeItem(
                    at: destination
                )
            }

            if fm.fileExists(
                atPath: workspace.backup.path
            ) {
                try? fm.moveItem(
                    at: workspace.backup,
                    to:
                        previousLocation
                        ?? destination
                )
            }

            throw ReloadedIIModError
                .transactionFailed(
                    error.localizedDescription
                )
        }

        return InstallTransaction(
            fileManager: fm,
            destination: destination,
            backup: workspace.backup,
            previousLocation:
                previousLocation
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

        case dependencyValidationFailed(
            modId: String,
            missing: [String],
            incompatible: [String]
        )

        case requiredByEnabledMods(
            modId: String,
            dependents: [String]
        )
        case sourceNotFound
        case unsupportedPackageType
        case invalidPackage(String)
        case ambiguousPackage([String])
        case archiveExtractionFailed(String)
        case transactionFailed(String)
        case rollbackFailed(String)
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

            case .sourceNotFound:
                return """
                The selected Reloaded-II mod \
                package could not be found
                """

            case .unsupportedPackageType:
                return """
                Reloaded-II mods must be \
                installed from a folder or \
                ZIP archive
                """

            case .invalidPackage(
                let reason
            ):
                return """
                Invalid Reloaded-II package:

                \(reason)
                """

            case .ambiguousPackage(
                let modIds
            ):
                return """
                The selected package contains \
                multiple Reloaded-II mods:

                \(modIds.joined(separator: ", "))
                """

            case .archiveExtractionFailed(
                let reason
            ):
                return """
                Could not extract Reloaded-II \
                ZIP package:

                \(reason)
                """

            case .transactionFailed(
                let reason
            ):
                return """
                Could not safely install the \
                Reloaded-II mod:

                \(reason)
                """

            case .rollbackFailed(
                let reason
            ):
                return """
                Reloaded-II installation failed \
                and the previous mod could not \
                be restored automatically:

                \(reason)
                """

            case .dependencyValidationFailed(
                let modId,
                let missing,
                let incompatible
            ):
                var sections:
                    [String] = []

                if !missing.isEmpty {
                    sections.append(
                        """
                        Missing required dependencies:
                        \(missing.map { "• \($0)" }.joined(separator: "\n"))
                        """
                    )
                }

                if !incompatible.isEmpty {
                    sections.append(
                        """
                        Dependencies incompatible with this game:
                        \(incompatible.map { "• \($0)" }.joined(separator: "\n"))
                        """
                    )
                }

                return """
                Cannot use \(modId).

                \(sections.joined(separator: "\n\n"))
                """

            case .requiredByEnabledMods(
                let modId,
                let dependents
            ):
                return """
                Cannot disable or remove \(modId).

                Required by enabled mods:
                \(dependents.map { "• \($0)" }.joined(separator: "\n"))
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
