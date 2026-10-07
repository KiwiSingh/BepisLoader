import Foundation

// MARK: - Reloaded-II Dependency Resolution

/// Describes how BepisLoader can currently satisfy
/// a Reloaded-II dependency.
///
/// Patch 27 is deliberately read-only: `.missing`
/// means no trustworthy acquisition source is known.
/// Future acquisition providers can extend resolution
/// without weakening the install transaction.
enum ReloadedIIDependencyState: Hashable {
    case installedEnabled
    case installedDisabled
    case incompatible
    case missing
}

enum ReloadedIIDependencyKind: Hashable {
    case required
    case optional
}

struct ReloadedIIDependencyResolution: Hashable {
    let modId: String
    let requestedBy: String
    let kind: ReloadedIIDependencyKind
    let state: ReloadedIIDependencyState
    let depth: Int
}

struct ReloadedIIDependencyCycle: Hashable {
    let modIds: [String]
}

struct ReloadedIIDependencyPlan {
    let rootModId: String
    let resolutions: [ReloadedIIDependencyResolution]
    let cycles: [ReloadedIIDependencyCycle]

    var missingRequired:
        [ReloadedIIDependencyResolution]
    {
        resolutions.filter {
            $0.kind == .required
                && $0.state == .missing
        }
    }

    var incompatibleRequired:
        [ReloadedIIDependencyResolution]
    {
        resolutions.filter {
            $0.kind == .required
                && $0.state == .incompatible
        }
    }

    var disabledRequired:
        [ReloadedIIDependencyResolution]
    {
        resolutions.filter {
            $0.kind == .required
                && $0.state == .installedDisabled
        }
    }

    var isSatisfiableFromInstalledMods: Bool {
        missingRequired.isEmpty
            && incompatibleRequired.isEmpty
    }
}

/// Produces deterministic, read-only dependency plans
/// from the mods already installed in Reloaded-II.
///
/// It performs no downloads, registry writes, file
/// operations, or enable/disable mutations.
final class ReloadedIIDependencyResolver {

    static let shared =
        ReloadedIIDependencyResolver()

    private init() {}

    func plan(
        for rootModId: String,
        installedMods: [ReloadedIIDiscoveredMod],
        enabledModIds: [String],
        applicationId: String
    ) -> ReloadedIIDependencyPlan {

        let index =
            Dictionary(
                uniqueKeysWithValues:
                    installedMods.map {
                        (
                            normalizedModId(
                                $0.config.modId
                            ),
                            $0
                        )
                    }
            )

        let enabled =
            Set(
                enabledModIds.map {
                    normalizedModId($0)
                }
            )

        let rootKey =
            normalizedModId(
                rootModId
            )

        var resolutions:
            [ReloadedIIDependencyResolution] = []

        var cycles:
            [ReloadedIIDependencyCycle] = []

        var visitedRequired =
            Set<String>()

        var visitedOptional =
            Set<String>()

        var activeStack:
            [String] = []

        var activeSet =
            Set<String>()

        if let root =
                index[rootKey]
        {
            walk(
                mod: root,
                kind: .required,
                depth: 0,
                index: index,
                enabled: enabled,
                applicationId:
                    applicationId,
                resolutions:
                    &resolutions,
                cycles:
                    &cycles,
                visitedRequired:
                    &visitedRequired,
                visitedOptional:
                    &visitedOptional,
                activeStack:
                    &activeStack,
                activeSet:
                    &activeSet
            )
        }

        return ReloadedIIDependencyPlan(
            rootModId: rootModId,
            resolutions: resolutions,
            cycles: cycles
        )
    }

    private func walk(
        mod: ReloadedIIDiscoveredMod,
        kind: ReloadedIIDependencyKind,
        depth: Int,
        index: [String: ReloadedIIDiscoveredMod],
        enabled: Set<String>,
        applicationId: String,
        resolutions:
            inout [ReloadedIIDependencyResolution],
        cycles:
            inout [ReloadedIIDependencyCycle],
        visitedRequired:
            inout Set<String>,
        visitedOptional:
            inout Set<String>,
        activeStack:
            inout [String],
        activeSet:
            inout Set<String>
    ) {
        let modKey =
            normalizedModId(
                mod.config.modId
            )

        if activeSet.contains(
            modKey
        ) {
            if let start =
                    activeStack.firstIndex(
                        of: modKey
                    )
            {
                let cycle =
                    Array(
                        activeStack[start...]
                    )
                    + [modKey]

                let candidate =
                    ReloadedIIDependencyCycle(
                        modIds: cycle
                    )

                if !cycles.contains(
                    candidate
                ) {
                    cycles.append(
                        candidate
                    )
                }
            }

            return
        }

        let visited =
            kind == .required
            ? visitedRequired
            : visitedOptional

        if visited.contains(
            modKey
        ) {
            return
        }

        if kind == .required {
            visitedRequired.insert(
                modKey
            )
        } else {
            visitedOptional.insert(
                modKey
            )
        }

        activeStack.append(
            modKey
        )

        activeSet.insert(
            modKey
        )

        for dependencyId
            in requiredDependencyIds(
                of: mod
            )
        {
            inspect(
                dependencyId:
                    dependencyId,
                requestedBy:
                    mod.config.modId,
                kind:
                    .required,
                depth:
                    depth + 1,
                index:
                    index,
                enabled:
                    enabled,
                applicationId:
                    applicationId,
                resolutions:
                    &resolutions,
                cycles:
                    &cycles,
                visitedRequired:
                    &visitedRequired,
                visitedOptional:
                    &visitedOptional,
                activeStack:
                    &activeStack,
                activeSet:
                    &activeSet
            )
        }

        for dependencyId
            in optionalDependencyIds(of: mod)
        {
            inspect(
                dependencyId:
                    dependencyId,
                requestedBy:
                    mod.config.modId,
                kind:
                    .optional,
                depth:
                    depth + 1,
                index:
                    index,
                enabled:
                    enabled,
                applicationId:
                    applicationId,
                resolutions:
                    &resolutions,
                cycles:
                    &cycles,
                visitedRequired:
                    &visitedRequired,
                visitedOptional:
                    &visitedOptional,
                activeStack:
                    &activeStack,
                activeSet:
                    &activeSet
            )
        }

        _ = activeStack.popLast()

        activeSet.remove(
            modKey
        )
    }

    private func inspect(
        dependencyId: String,
        requestedBy: String,
        kind: ReloadedIIDependencyKind,
        depth: Int,
        index: [String: ReloadedIIDiscoveredMod],
        enabled: Set<String>,
        applicationId: String,
        resolutions:
            inout [ReloadedIIDependencyResolution],
        cycles:
            inout [ReloadedIIDependencyCycle],
        visitedRequired:
            inout Set<String>,
        visitedOptional:
            inout Set<String>,
        activeStack:
            inout [String],
        activeSet:
            inout Set<String>
    ) {
        let key =
            normalizedModId(
                dependencyId
            )

        guard let dependency =
                index[key]
        else {
            appendResolution(
                ReloadedIIDependencyResolution(
                    modId: dependencyId,
                    requestedBy:
                        requestedBy,
                    kind: kind,
                    state: .missing,
                    depth: depth
                ),
                to: &resolutions
            )

            return
        }

        let compatible =
            supports(
                dependency.config,
                applicationId:
                    applicationId
            )

        let state:
            ReloadedIIDependencyState

        if !compatible {
            state = .incompatible
        } else if enabled.contains(
            key
        ) {
            state = .installedEnabled
        } else {
            state = .installedDisabled
        }

        appendResolution(
            ReloadedIIDependencyResolution(
                modId:
                    dependency.config.modId,
                requestedBy:
                    requestedBy,
                kind: kind,
                state: state,
                depth: depth
            ),
            to: &resolutions
        )

        // An incompatible dependency is present but
        // cannot satisfy this application's graph.
        // Do not recurse through it.
        guard compatible else {
            return
        }

        walk(
            mod: dependency,
            kind: kind,
            depth: depth,
            index: index,
            enabled: enabled,
            applicationId:
                applicationId,
            resolutions:
                &resolutions,
            cycles:
                &cycles,
            visitedRequired:
                &visitedRequired,
            visitedOptional:
                &visitedOptional,
            activeStack:
                &activeStack,
            activeSet:
                &activeSet
        )
    }

    private func appendResolution(
        _ resolution:
            ReloadedIIDependencyResolution,
        to resolutions:
            inout [ReloadedIIDependencyResolution]
    ) {
        let id =
            normalizedModId(
                resolution.modId
            )

        let requester =
            normalizedModId(
                resolution.requestedBy
            )

        let duplicate =
            resolutions.contains {
                normalizedModId(
                    $0.modId
                ) == id
                && normalizedModId(
                    $0.requestedBy
                ) == requester
                && $0.kind
                    == resolution.kind
            }

        if !duplicate {
            resolutions.append(
                resolution
            )
        }
    }

    private func requiredDependencyIds(
        of mod: ReloadedIIDiscoveredMod
    ) -> [String] {
        normalizedDependencyList(
            mod.config.modDependencies
        )
    }

    private func optionalDependencyIds(
        of mod: ReloadedIIDiscoveredMod
    ) -> [String] {
        normalizedDependencyList(
            mod.config.optionalDependencies
        )
    }

    private func normalizedDependencyList(
        _ values: [String]
    ) -> [String] {
        var seen =
            Set<String>()

        var result:
            [String] = []

        for raw
            in values
        {
            let value =
                raw.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

            guard !value.isEmpty else {
                continue
            }

            let key =
                normalizedModId(
                    value
                )

            guard seen.insert(
                    key
                  ).inserted
            else {
                continue
            }

            result.append(
                value
            )
        }

        return result
    }

    private func normalizedModId(
        _ value: String
    ) -> String {
        value
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            .lowercased()
    }

    private func supports(
        _ config: ReloadedIIModConfig,
        applicationId: String
    ) -> Bool {
        if config.isUniversalMod {
            return true
        }

        let appId =
            normalizedModId(
                applicationId
            )

        return config.supportedAppId
            .contains {
                normalizedModId($0)
                    == appId
            }
    }
}
