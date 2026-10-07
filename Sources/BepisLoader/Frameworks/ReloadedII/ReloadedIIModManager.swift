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

    // MARK: - Dependency Inspector

    func installMissingDependencies(
        for mod: InstalledMod,
        in game: GameInstall
    ) async throws -> [String] {
        guard mod.framework
                == .reloadedII
        else {
            throw ReloadedIIModError
                .wrongFramework
        }

        let paths =
            ReloadedIIPaths(
                game: game
            )

        guard let modsRoot =
                paths.mods,
              fm.fileExists(
                atPath:
                    modsRoot.path
              )
        else {
            throw ReloadedIIModError
                .frameworkNotInstalled
        }

        let application =
            try registry.register(
                game
            )

        let installedMods =
            ReloadedIIModDiscovery
                .mods(
                    under: modsRoot
                )

        let installedIndex =
            modIndex(
                installedMods
            )

        guard let target =
                installedIndex[
                    normalizedModId(
                        mod.id
                    )
                ]
        else {
            throw ReloadedIIModError
                .modNotFound(
                    mod.id
                )
        }

        let rootPlan =
            ReloadedIIDependencyResolver
                .shared
                .plan(
                    for:
                        target.config.modId,
                    installedMods:
                        installedMods,
                    enabledModIds:
                        application.config
                            .enabledMods,
                    applicationId:
                        application.config
                            .appId
                )

        guard rootPlan
                .incompatibleRequired
                .isEmpty
        else {
            throw ReloadedIIDependencyInstallError
                .incompatibleDependencies(
                    rootPlan
                        .incompatibleRequired
                        .map {
                            $0.modId
                        }
                )
        }

        guard !rootPlan
                .missingRequired
                .isEmpty
        else {
            return []
        }

        // Resolve and verify the complete recursively
        // discovered graph before installing anything.
        var staged:
            [String: RecursiveDependencyPackage]
                = [:]

        var visiting:
            [String] = []

        var visitSet =
            Set<String>()

        var orderedIds:
            [String] = []

        var orderedSet =
            Set<String>()

        defer {
            for package
                in staged.values
            {
                try? fm.removeItem(
                    at:
                        package.localURL
                )
            }
        }

        func acquire(
            _ requestedModId: String
        ) async throws {
            let normalized =
                normalizedModId(
                    requestedModId
                )

            // Existing compatible installs satisfy
            // this node without downloading anything.
            if let installed =
                    installedIndex[
                        normalized
                    ]
            {
                guard supports(
                    installed.config,
                    applicationId:
                        application.config
                            .appId
                )
                else {
                    throw ReloadedIIDependencyInstallError
                        .incompatibleDependencies(
                            [
                                requestedModId
                            ]
                        )
                }

                return
            }

            if staged[
                normalized
            ] != nil {
                return
            }

            // DFS recursion-stack cycle detection.
            if visitSet.contains(
                normalized
            ) {
                let cycleStart =
                    visiting.firstIndex(
                        of:
                            normalized
                    )
                    ?? 0

                let cycle =
                    Array(
                        visiting[
                            cycleStart...
                        ]
                    )
                    + [
                        normalized
                    ]

                throw ReloadedIIDependencyInstallError
                    .recursiveDependencyCycle(
                        cycle
                    )
            }

            visitSet.insert(
                normalized
            )

            visiting.append(
                normalized
            )

            defer {
                _ = visitSet.remove(
                    normalized
                )

                if visiting.last
                    == normalized
                {
                    visiting.removeLast()
                } else if let index =
                            visiting.firstIndex(
                                of:
                                    normalized
                            )
                {
                    visiting.remove(
                        at:
                            index
                    )
                }
            }

            // Represent this recursively discovered
            // missing ModId as a one-node acquisition
            // plan so Patch 29's existing provider
            // ordering/filtering remains authoritative.
            let dependency =
                ReloadedIIDependencyResolution(
                    modId:
                        requestedModId,
                    requestedBy:
                        visiting.dropLast()
                            .last
                        ?? target.config
                            .modId,
                    kind:
                        .required,
                    state:
                        .missing,
                    depth:
                        visiting.count
                )

            let syntheticPlan =
                ReloadedIIDependencyPlan(
                    rootModId:
                        target.config.modId,
                    resolutions: [
                        dependency
                    ],
                    cycles: []
                )

            let acquisitionPlan =
                await ReloadedIIDependencyAcquisitionService
                    .shared
                    .plan(
                        for:
                            syntheticPlan
                    )

            guard let resolution =
                    acquisitionPlan
                        .dependencies
                        .first
            else {
                throw ReloadedIIDependencyInstallError
                    .unresolvedDependencies(
                        [
                            requestedModId
                        ]
                    )
            }

            guard let candidate =
                    resolution
                        .candidates
                        .first(
                            where: {
                                $0.packageURL
                                    != nil
                            }
                        )
            else {
                throw ReloadedIIDependencyInstallError
                    .noDownloadableCandidate(
                        requestedModId
                    )
            }

            let downloaded =
                try await ReloadedIIDependencyPackageDownloader
                    .shared
                    .download(
                        candidate:
                            candidate
                    )

            var retainedDownload =
                false

            defer {
                if !retainedDownload {
                    try? fm.removeItem(
                        at:
                            downloaded.localURL
                    )
                }
            }

            let verificationWorkspace =
                try PackageWorkspace(
                    fileManager:
                        fm
                )

            defer {
                verificationWorkspace
                    .cleanup()
            }

            let packageRoot =
                try preparePackage(
                    downloaded.localURL,
                    sourceIsDirectory:
                        false,
                    in:
                        verificationWorkspace
                )

            try validatePackageTree(
                packageRoot
            )

            let packageMods:
                [ReloadedIIDiscoveredMod]

            do {
                packageMods =
                    try ReloadedIIModDiscovery
                        .packageMods(
                            under:
                                packageRoot
                        )
            } catch {
                throw ReloadedIIDependencyInstallError
                    .invalidDownloadedPackage(
                        modId:
                            requestedModId,
                        reason:
                            error.localizedDescription
                    )
            }

            guard packageMods.count
                    == 1,
                  let downloadedMod =
                    packageMods.first
            else {
                throw ReloadedIIDependencyInstallError
                    .ambiguousDownloadedPackage(
                        requestedModId
                    )
            }

            guard downloadedMod
                    .config
                    .modId
                    .caseInsensitiveCompare(
                        requestedModId
                    )
                    == .orderedSame
            else {
                throw ReloadedIIDependencyInstallError
                    .modIdMismatch(
                        expected:
                            requestedModId,
                        actual:
                            downloadedMod
                                .config
                                .modId
                    )
            }

            guard supports(
                downloadedMod.config,
                applicationId:
                    application.config
                        .appId
            )
            else {
                throw ReloadedIIDependencyInstallError
                    .incompatibleDependencies(
                        [
                            downloadedMod
                                .config
                                .modId
                        ]
                    )
            }

            var dependencyIds:
                [String] = []

            var dependencyKeys =
                Set<String>()

            for dependencyId
                in downloadedMod
                    .config
                    .modDependencies
            {
                let trimmed =
                    dependencyId
                        .trimmingCharacters(
                            in:
                                .whitespacesAndNewlines
                        )

                guard !trimmed.isEmpty
                else {
                    continue
                }

                let key =
                    normalizedModId(
                        trimmed
                    )

                guard dependencyKeys
                        .insert(
                            key
                        )
                        .inserted
                else {
                    continue
                }

                dependencyIds.append(
                    trimmed
                )
            }

            staged[
                normalized
            ] =
                RecursiveDependencyPackage(
                    modId:
                        downloadedMod
                            .config
                            .modId,
                    localURL:
                        downloaded
                            .localURL,
                    requiredDependencies:
                        dependencyIds
                )

            retainedDownload =
                true

            // Discover dependencies from the verified
            // downloaded ModConfig.json and recurse.
            for dependencyId
                in dependencyIds
            {
                try await acquire(
                    dependencyId
                )
            }

            // DFS post-order naturally places every
            // acquired dependency before its parent.
            if orderedSet.insert(
                    normalized
                  ).inserted
            {
                orderedIds.append(
                    normalized
                )
            }
        }

        for resolution
            in rootPlan
                .missingRequired
        {
            try await acquire(
                resolution.modId
            )
        }

        // ─────────────────────────────────────
        // COMMIT PHASE
        //
        // The complete recursive graph has resolved
        // and every downloaded package has already
        // passed identity/tree/compatibility checks.
        // ─────────────────────────────────────

        var installed:
            [String] = []

        for normalized
            in orderedIds
        {
            guard let package =
                    staged[
                        normalized
                    ]
            else {
                throw ReloadedIIDependencyInstallError
                    .preflightStateLost(
                        normalized
                    )
            }

            try installMod(
                from:
                    package.localURL,
                into:
                    game
            )

            let installedNow =
                ReloadedIIModDiscovery
                    .mods(
                        under:
                            modsRoot
                    )

            guard installedNow
                    .contains(
                        where: {
                            $0.config.modId
                                .caseInsensitiveCompare(
                                    package.modId
                                )
                                == .orderedSame
                        }
                    )
            else {
                throw ReloadedIIDependencyInstallError
                    .postInstallVerificationFailed(
                        package.modId
                    )
            }

            installed.append(
                package.modId
            )
        }

        return installed
    }

    private struct RecursiveDependencyPackage {
        let modId: String
        let localURL: URL
        let requiredDependencies: [String]
    }

    func dependencyAcquisitionSummary(
        for mod: InstalledMod,
        in game: GameInstall
    ) async throws -> String {
        guard mod.framework == .reloadedII
        else {
            return
                "Dependency acquisition is only available for Reloaded-II mods."
        }

        let paths =
            ReloadedIIPaths(
                game: game
            )

        guard let modsRoot =
                paths.mods,
              fm.fileExists(
                atPath:
                    modsRoot.path
              )
        else {
            return
                "Reloaded-II is not installed for this game."
        }

        let application =
            try registry.register(
                game
            )

        let discovered =
            ReloadedIIModDiscovery
                .mods(
                    under: modsRoot
                )

        let index =
            modIndex(
                discovered
            )

        guard let target =
                index[
                    normalizedModId(
                        mod.id
                    )
                ]
        else {
            return
                "The selected Reloaded-II mod could not be found."
        }

        let dependencyPlan =
            ReloadedIIDependencyResolver
                .shared
                .plan(
                    for:
                        target.config.modId,
                    installedMods:
                        discovered,
                    enabledModIds:
                        application.config
                            .enabledMods,
                    applicationId:
                        application.config
                            .appId
                )

        guard !dependencyPlan
                .missingRequired
                .isEmpty
        else {
            return
                "No required dependencies are missing."
        }

        let acquisitionPlan =
            await ReloadedIIDependencyAcquisitionService
                .shared
                .plan(
                    for:
                        dependencyPlan
                )

        var lines: [String] = [
            "Official Index Lookup",
            ""
        ]

        for resolution
            in acquisitionPlan.dependencies
        {
            let modId =
                resolution
                    .dependency
                    .modId

            guard !resolution
                    .candidates
                    .isEmpty
            else {
                lines.append(
                    "❌ \(modId)"
                )

                lines.append(
                    "   No acquisition source found."
                )

                continue
            }

            lines.append(
                "📦 \(modId)"
            )

            for candidate
                in resolution.candidates
            {
                var detail =
                    "   • \(candidate.sourceName)"

                if let version =
                        candidate.version,
                   !version.isEmpty
                {
                    detail +=
                        " — \(version)"
                }

                lines.append(
                    detail
                )

                if let packageURL =
                        candidate.packageURL
                {
                    lines.append(
                        "     \(packageURL.absoluteString)"
                    )
                }
            }
        }

        lines.append(
            ""
        )

        if acquisitionPlan
            .isFullyResolvable
        {
            lines.append(
                "🟢 All missing required dependencies were found in configured acquisition sources."
            )
        } else {
            lines.append(
                "🔴 Some required dependencies could not be resolved."
            )
        }

        lines.append(
            ""
        )

        lines.append(
            "Nothing has been downloaded or installed."
        )

        return lines.joined(
            separator: "\n"
        )
    }

    func dependencySummary(
        for mod: InstalledMod,
        in game: GameInstall
    ) throws -> String {
        guard mod.framework
                == .reloadedII
        else {
            throw ReloadedIIModError
                .wrongFramework
        }

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

        let discovered =
            ReloadedIIModDiscovery
                .mods(
                    under: modsRoot
                )

        let index =
            modIndex(
                discovered
            )

        let targetKey =
            normalizedModId(
                mod.id
            )

        guard let target =
                index[targetKey]
        else {
            throw ReloadedIIModError
                .modNotFound(
                    mod.id
                )
        }

        let plan =
            ReloadedIIDependencyResolver
                .shared
                .plan(
                    for:
                        target.config.modId,
                    installedMods:
                        discovered,
                    enabledModIds:
                        application.config
                            .enabledMods,
                    applicationId:
                        application.config.appId
                )

        var sections:
            [String] = []

        let required =
            plan.resolutions
                .filter {
                    $0.kind == .required
                }

        if required.isEmpty {
            sections.append(
                "Required dependency graph: None"
            )
        } else {
            sections.append(
                """
                Required dependency graph:
                \(dependencyResolutionLines(required))
                """
            )
        }

        let optional =
            plan.resolutions
                .filter {
                    $0.kind == .optional
                }

        if !optional.isEmpty {
            sections.append(
                """
                Optional dependency graph:
                \(dependencyResolutionLines(optional))
                """
            )
        }

        var resolutionLines:
            [String] = []

        if plan.isSatisfiableFromInstalledMods {
            if plan.disabledRequired.isEmpty {
                resolutionLines.append(
                    "🟢 All required dependencies are satisfied."
                )
            } else {
                resolutionLines.append(
                    "🟡 All required dependencies are installed, but \(plan.disabledRequired.count) must be enabled."
                )
            }
        } else {
            resolutionLines.append(
                "🔴 Cannot currently satisfy all required dependencies from installed mods."
            )
        }

        if !plan.missingRequired.isEmpty {
            resolutionLines.append(
                "• Missing required: \(plan.missingRequired.count)"
            )
        }

        if !plan.incompatibleRequired.isEmpty {
            resolutionLines.append(
                "• Incompatible required: \(plan.incompatibleRequired.count)"
            )
        }

        if !plan.disabledRequired.isEmpty {
            resolutionLines.append(
                "• Installed but disabled: \(plan.disabledRequired.count)"
            )
        }

        sections.append(
            """
            Resolution:
            \(resolutionLines.joined(separator: "\n"))
            """
        )

        if plan.cycles.isEmpty {
            sections.append(
                "Dependency cycles: None"
            )
        } else {
            let cycleLines =
                plan.cycles.map {
                    "⚠️ "
                    + $0.modIds.joined(
                        separator: " → "
                    )
                }

            sections.append(
                """
                Dependency cycles:
                \(cycleLines.joined(separator: "\n"))
                """
            )
        }

        let dependents =
            enabledDependents(
                of:
                    target.config.modId,
                installedMods:
                    discovered,
                enabledModIds:
                    application.config
                        .enabledMods
            )

        if dependents.isEmpty {
            sections.append(
                "Enabled dependents: None"
            )
        } else {
            sections.append(
                """
                Enabled mods that depend on this mod:
                \(dependents.map { "• \($0)" }.joined(separator: "\n"))
                """
            )
        }

        return """
        \(target.config.modName.isEmpty ? target.config.modId : target.config.modName)
        Mod ID: \(target.config.modId)

        \(sections.joined(separator: "\n\n"))
        """
    }

    private func dependencyResolutionLines(
        _ resolutions:
            [ReloadedIIDependencyResolution]
    ) -> String {
        resolutions
            .map { resolution in
                let indentation =
                    String(
                        repeating: "  ",
                        count: max(
                            0,
                            resolution.depth - 1
                        )
                    )

                let stateText: String

                switch resolution.state {
                case .installedEnabled:
                    stateText =
                        "🟢 installed, enabled"

                case .installedDisabled:
                    stateText =
                        "🟡 installed, disabled"

                case .incompatible:
                    stateText =
                        resolution.kind == .required
                        ? "🔴 installed, incompatible"
                        : "⚠️ installed, incompatible"

                case .missing:
                    stateText =
                        resolution.kind == .required
                        ? "🔴 missing"
                        : "⚪ not installed"
                }

                return "\(indentation)• \(resolution.modId) — \(stateText)"
            }
            .joined(
                separator: "\n"
            )
    }

    func moveModUp(
        _ mod: InstalledMod,
        in game: GameInstall
    ) throws {
        try moveReloadedIIMod(
            mod,
            direction: -1,
            in: game
        )
    }

    func moveModDown(
        _ mod: InstalledMod,
        in game: GameInstall
    ) throws {
        try moveReloadedIIMod(
            mod,
            direction: 1,
            in: game
        )
    }

    private func moveReloadedIIMod(
        _ mod: InstalledMod,
        direction: Int,
        in game: GameInstall
    ) throws {
        guard mod.framework
                == .reloadedII
        else {
            throw ReloadedIIModError
                .wrongFramework
        }

        guard direction == -1
                || direction == 1
        else {
            return
        }

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

        let discovered =
            ReloadedIIModDiscovery
                .mods(
                    under: modsRoot
                )

        guard let target =
                discovered.first(
                    where: {
                        normalizedModId(
                            $0.config.modId
                        )
                        ==
                        normalizedModId(
                            mod.id
                        )
                    }
                )
        else {
            throw ReloadedIIModError
                .modNotFound(
                    mod.id
                )
        }

        let orderedIds =
            canonicalSortedModIds(
                discoveredMods:
                    discovered,
                configuredOrder:
                    application
                        .config
                        .sortedMods
            )

        guard let currentIndex =
                orderedIds.firstIndex(
                    where: {
                        normalizedModId($0)
                        ==
                        normalizedModId(
                            target.config.modId
                        )
                    }
                )
        else {
            throw ReloadedIIModError
                .modNotFound(
                    mod.id
                )
        }

        let destinationIndex =
            currentIndex
            + direction

        guard orderedIds.indices
                .contains(
                    destinationIndex
                )
        else {
            return
        }

        var reordered =
            orderedIds

        reordered.swapAt(
            currentIndex,
            destinationIndex
        )

        var updated =
            application.config

        updated.sortedMods =
            reordered

        var updatedApplication = application
        updatedApplication.config = updated
        try registry.update(updatedApplication)
    }

    private func canonicalSortedModIds(
        discoveredMods:
            [ReloadedIIDiscoveredMod],
        configuredOrder:
            [String]
    ) -> [String] {
        let canonicalByNormalizedId =
            Dictionary(
                uniqueKeysWithValues:
                    discoveredMods.map {
                        (
                            normalizedModId(
                                $0.config.modId
                            ),
                            $0.config.modId
                        )
                    }
            )

        var result:
            [String] = []

        var seen =
            Set<String>()

        for configuredId
            in configuredOrder
        {
            let normalized =
                normalizedModId(
                    configuredId
                )

            guard let canonical =
                    canonicalByNormalizedId[
                        normalized
                    ],
                  seen.insert(
                    normalized
                  ).inserted
            else {
                continue
            }

            result.append(
                canonical
            )
        }

        let remaining =
            discoveredMods
                .map {
                    $0.config.modId
                }
                .filter {
                    !seen.contains(
                        normalizedModId($0)
                    )
                }
                .sorted {
                    $0.localizedCaseInsensitiveCompare(
                        $1
                    ) == .orderedAscending
                }

        result.append(
            contentsOf:
                remaining
        )

        return result
    }

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

        // Treat package contents as untrusted.
        // Validate the copied/extracted tree
        // before reading ModConfig.json or
        // touching the real Mods directory.
        try validatePackageTree(
            packageRoot
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

        guard isContained(
            packageMod.directory,
            within: packageRoot
        ),
        isContained(
            packageMod.configURL,
            within: packageRoot
        ) else {
            throw ReloadedIIModError
                .unsafePackageEntry(
                    packageMod.directory.path
                )
        }

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

        let destinationName =
            try validatedModDirectoryName(
                for: modConfig.modId
            )

        let destination =
            modsRoot.appendingPathComponent(
                destinationName,
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

        let allInstalledMods =
            ReloadedIIModDiscovery.mods(
                under: modsRoot
            )

        guard let discovered =
                allInstalledMods.first(
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

        if enabled {
            let plan =
                try dependencyActivationPlan(
                    for: discovered.config,
                    installedMods:
                        allInstalledMods,
                    applicationId:
                        application.config.appId
                )

            applyDependencyActivationPlan(
                plan,
                to: &application
            )
        } else {
            try guardAgainstBreakingEnabledDependents(
                targetModId:
                    canonicalId,
                installedMods:
                    allInstalledMods,
                application:
                    application
            )

            application.config.enabledMods =
                application.config.enabledMods
                    .filter {
                        $0.caseInsensitiveCompare(
                            canonicalId
                        ) != .orderedSame
                    }

            // Modern Reloaded-II keeps disabled
            // mods in SortedMods when disabled-mod
            // ordering is preserved.
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
        }

        // Activation planning mutates only the
        // in-memory application object. Persist
        // the complete plan atomically with one
        // registry update.
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

    private struct DependencyActivationPlan {
        // Dependency-first canonical ModIds.
        // The requested root mod is always last
        // unless a cycle has already visited it.
        let orderedModIds: [String]
    }

    private func dependencyActivationPlan(
        for rootConfig: ReloadedIIModConfig,
        installedMods:
            [ReloadedIIDiscoveredMod],
        applicationId: String
    ) throws -> DependencyActivationPlan {
        // Preserve Patch 18's complete error
        // reporting for missing/incompatible
        // dependencies before building a plan.
        try validateRequiredDependencies(
            for: rootConfig,
            installedMods:
                installedMods,
            applicationId:
                applicationId
        )

        let index =
            modIndex(
                installedMods
            )

        var visited =
            Set<String>()

        var ordered:
            [String] = []

        appendDependencyActivation(
            config: rootConfig,
            index: index,
            visited: &visited,
            ordered: &ordered
        )

        return DependencyActivationPlan(
            orderedModIds:
                ordered
        )
    }

    private func appendDependencyActivation(
        config: ReloadedIIModConfig,
        index:
            [String: ReloadedIIDiscoveredMod],
        visited: inout Set<String>,
        ordered: inout [String]
    ) {
        let current =
            normalizedModId(
                config.modId
            )

        guard visited.insert(
            current
        ).inserted else {
            return
        }

        // DFS post-order gives us dependencies
        // before the mod that requires them.
        //
        // OptionalDependencies intentionally do
        // not participate in automatic activation.
        for dependencyId
            in config.modDependencies
        {
            let dependencyKey =
                normalizedModId(
                    dependencyId
                )

            guard !dependencyKey.isEmpty,
                  let dependency =
                    index[dependencyKey]
            else {
                // Missing dependencies have
                // already been rejected by the
                // validation pass above.
                continue
            }

            appendDependencyActivation(
                config:
                    dependency.config,
                index: index,
                visited: &visited,
                ordered: &ordered
            )
        }

        ordered.append(
            config.modId
        )
    }

    private func applyDependencyActivationPlan(
        _ plan: DependencyActivationPlan,
        to application:
            inout ReloadedIIApplication
    ) {
        // Preserve unrelated EnabledMods and
        // SortedMods. For every planned ModId,
        // remove case-insensitive duplicates,
        // then append it in dependency-first
        // order.
        //
        // This also canonicalizes casing using
        // the installed ModConfig.json value.
        for modId
            in plan.orderedModIds
        {
            application.config.enabledMods =
                application.config.enabledMods
                    .filter {
                        $0.caseInsensitiveCompare(
                            modId
                        ) != .orderedSame
                    }

            application.config.enabledMods
                .append(
                    modId
                )
        }

        // SortedMods is the explicit load-order
        // list. Planned mods are rewritten there
        // dependency-first as one contiguous
        // ordered sequence.
        let plannedKeys =
            Set(
                plan.orderedModIds.map {
                    normalizedModId(
                        $0
                    )
                }
            )

        application.config.sortedMods =
            application.config.sortedMods
                .filter {
                    !plannedKeys.contains(
                        normalizedModId(
                            $0
                        )
                    )
                }

        application.config.sortedMods
            .append(
                contentsOf:
                    plan.orderedModIds
            )
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

    private func validatedModDirectoryName(
        for modId: String
    ) throws -> String {
        let trimmed =
            modId.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !trimmed.isEmpty,
              trimmed == modId,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains(":"),
              !trimmed.unicodeScalars.contains(
                where: {
                    CharacterSet
                        .controlCharacters
                        .contains($0)
                }
              )
        else {
            // Reject instead of sanitizing.
            // Distinct ModIds must never collapse
            // onto the same physical directory.
            throw ReloadedIIModError
                .unsafeModId(
                    modId
                )
        }

        return trimmed
    }

    private func validatePackageTree(
        _ root: URL
    ) throws {
        let rootURL =
            root.standardizedFileURL

        var rootIsDirectory:
            ObjCBool = false

        guard fm.fileExists(
            atPath: rootURL.path,
            isDirectory:
                &rootIsDirectory
        ),
        rootIsDirectory.boolValue else {
            throw ReloadedIIModError
                .invalidPackage(
                    "Package root is not a directory."
                )
        }

        let keys:
            Set<URLResourceKey> = [
                .isSymbolicLinkKey
            ]

        var enumerationError:
            Error?

        guard let enumerator =
                fm.enumerator(
                    at: rootURL,
                    includingPropertiesForKeys:
                        Array(keys),
                    options: [],
                    errorHandler: {
                        _, error in

                        enumerationError =
                            error

                        return false
                    }
                )
        else {
            throw ReloadedIIModError
                .invalidPackage(
                    "Could not enumerate package contents."
                )
        }

        while let entry =
                enumerator.nextObject()
                    as? URL
        {
            if let error =
                    enumerationError
            {
                throw ReloadedIIModError
                    .invalidPackage(
                        error.localizedDescription
                    )
            }

            let standardized =
                entry.standardizedFileURL

            guard isContained(
                standardized,
                within: rootURL
            ) else {
                throw ReloadedIIModError
                    .unsafePackageEntry(
                        entry.path
                    )
            }

            let values:
                URLResourceValues

            do {
                values =
                    try entry.resourceValues(
                        forKeys: keys
                    )
            } catch {
                throw ReloadedIIModError
                    .unsafePackageEntry(
                        entry.path
                    )
            }

            guard values.isSymbolicLink
                    == true
            else {
                continue
            }

            let destination:
                String

            do {
                destination =
                    try fm.destinationOfSymbolicLink(
                        atPath:
                            entry.path
                    )
            } catch {
                throw ReloadedIIModError
                    .unsafePackageEntry(
                        entry.path
                    )
            }

            let resolved:
                URL

            if destination.hasPrefix("/") {
                resolved =
                    URL(
                        fileURLWithPath:
                            destination
                    )
                    .standardizedFileURL
            } else {
                resolved =
                    entry
                        .deletingLastPathComponent()
                        .appendingPathComponent(
                            destination
                        )
                        .standardizedFileURL
            }

            // Links must resolve to an existing
            // target inside this package tree.
            // This rejects absolute escapes,
            // relative ".." escapes and broken
            // links before installation begins.
            guard isContained(
                resolved,
                within: rootURL
            ),
            fm.fileExists(
                atPath:
                    resolved.path
            ) else {
                throw ReloadedIIModError
                    .unsafePackageEntry(
                        entry.path
                    )
            }
        }

        if let error =
                enumerationError
        {
            throw ReloadedIIModError
                .invalidPackage(
                    error.localizedDescription
                )
        }
    }

    private func isContained(
        _ candidate: URL,
        within root: URL
    ) -> Bool {
        let rootPath =
            root.standardizedFileURL
                .path

        let candidatePath =
            candidate.standardizedFileURL
                .path

        if candidatePath == rootPath {
            return true
        }

        let prefix =
            rootPath.hasSuffix("/")
            ? rootPath
            : rootPath + "/"

        return candidatePath.hasPrefix(
            prefix
        )
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

    enum ReloadedIIDependencyInstallError:
        LocalizedError
    {
        case unresolvedDependencies([String])
        case incompatibleDependencies([String])
        case noDownloadableCandidate(String)
        case invalidDownloadedPackage(
            modId: String,
            reason: String
        )
        case ambiguousDownloadedPackage(String)
        case modIdMismatch(
            expected: String,
            actual: String
        )
        case postInstallVerificationFailed(String)
        case recursiveDependencyCycle([String])
        case preflightStateLost(String)

        var errorDescription: String? {
            switch self {
            case .unresolvedDependencies(
                let modIds
            ):
                return """
                Some required Reloaded-II dependencies \
                could not be found in the configured \
                acquisition sources:

                \(modIds.joined(separator: ", "))
                """

            case .incompatibleDependencies(
                let modIds
            ):
                return """
                Some required Reloaded-II dependencies \
                are installed but incompatible with \
                this application:

                \(modIds.joined(separator: ", "))
                """

            case .noDownloadableCandidate(
                let modId
            ):
                return """
                No downloadable package candidate \
                is available for:

                \(modId)
                """

            case .invalidDownloadedPackage(
                let modId,
                let reason
            ):
                return """
                The downloaded package for \(modId) \
                is not a valid Reloaded-II package:

                \(reason)
                """

            case .ambiguousDownloadedPackage(
                let modId
            ):
                return """
                The downloaded package for \(modId) \
                contains zero or multiple Reloaded-II \
                mods and cannot be installed safely.
                """

            case .modIdMismatch(
                let expected,
                let actual
            ):
                return """
                Dependency package identity mismatch.

                Requested:
                \(expected)

                Downloaded package:
                \(actual)

                Nothing from this package was installed.
                """

            case .postInstallVerificationFailed(
                let modId
            ):
                return """
                Reloaded-II reported a successful \
                dependency installation, but \(modId) \
                could not be verified afterward.
                """

            case .recursiveDependencyCycle(
                let modIds
            ):
                return """
                A required Reloaded-II dependency \
                cycle was discovered while inspecting \
                acquired packages:

                \(modIds.joined(separator: " → "))

                Nothing from this recursive acquisition \
                plan was installed.
                """

            case .preflightStateLost(
                let modId
            ):
                return """
                The verified dependency package for \
                \(modId) disappeared from the recursive \
                acquisition plan before installation.
                """
            }
        }
    }

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
        case unsafePackageEntry(String)
        case unsafeModId(String)
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

            case .unsafePackageEntry(
                let path
            ):
                return """
                Reloaded-II package contains an \
                unsafe or broken filesystem entry:

                \(path)
                """

            case .unsafeModId(
                let modId
            ):
                return """
                Reloaded-II ModId cannot safely \
                be used as a single Mods \
                directory name:

                \(modId)
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
