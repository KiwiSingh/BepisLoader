import Foundation

// MARK: - Reloaded-II Dependency Acquisition
//
// Patch 29 introduces the boundary between
// dependency resolution ("what is missing?")
// and acquisition ("where could it come from?").
//
// This layer is deliberately planning-only.
// Providers describe trustworthy candidates;
// they do not download, install, or mutate state.

// MARK: Source

enum ReloadedIIModAcquisitionSource:
    Hashable,
    Codable
{
    case github(
        owner: String,
        repository: String
    )

    case gameBanana(
        itemType: String,
        itemId: String
    )

    case directPackage(
        URL
    )

    case custom(
        identifier: String
    )
}


// MARK: Candidate

struct ReloadedIIModAcquisitionCandidate:
    Hashable
{
    let modId: String
    let source:
        ReloadedIIModAcquisitionSource

    /// Human-readable provider/source name.
    let sourceName: String

    /// URL for a human to inspect.
    ///
    /// This is not necessarily a downloadable
    /// package URL.
    let informationURL: URL?

    /// A provider may expose a deterministic
    /// package URL only when it actually knows
    /// that URL represents an installable
    /// Reloaded-II package.
    let packageURL: URL?

    /// Optional version advertised by the source.
    let version: String?

    /// Lower values win when otherwise-equivalent
    /// candidates are produced by one provider.
    let priority: Int
}


// MARK: Provider

protocol ReloadedIIDependencyAcquisitionProvider {

    /// Stable identifier used for deterministic
    /// provider ordering and diagnostics.
    var identifier: String { get }

    /// Lower values are queried first.
    var priority: Int { get }

    /// Returns acquisition candidates for a ModId.
    ///
    /// Implementations must not install the mod or
    /// mutate Reloaded-II state. Network-capable
    /// providers may be introduced later behind
    /// this boundary.
    func candidates(
        for modId: String
    ) async throws
        -> [ReloadedIIModAcquisitionCandidate]
}


// MARK: Resolution result

struct ReloadedIIDependencyAcquisitionResolution {
    let dependency:
        ReloadedIIDependencyResolution

    let candidates:
        [ReloadedIIModAcquisitionCandidate]

    var isResolved: Bool {
        !candidates.isEmpty
    }
}

struct ReloadedIIDependencyAcquisitionPlan {
    let dependencies:
        [ReloadedIIDependencyAcquisitionResolution]

    var unresolved:
        [ReloadedIIDependencyAcquisitionResolution]
    {
        dependencies.filter {
            !$0.isResolved
        }
    }

    var resolved:
        [ReloadedIIDependencyAcquisitionResolution]
    {
        dependencies.filter {
            $0.isResolved
        }
    }

    var isFullyResolvable: Bool {
        unresolved.isEmpty
    }
}


// MARK: Service

final class ReloadedIIDependencyAcquisitionService {

    static let shared =
        ReloadedIIDependencyAcquisitionService(
            providers: [
                ReloadedIIIndexAcquisitionProvider(
                    loader:
                        ReloadedIIIndexNetworkLoader
                            .shared
                )
            ]
        )

    private var providers:
        [any ReloadedIIDependencyAcquisitionProvider]

    init(
        providers:
            [any ReloadedIIDependencyAcquisitionProvider]
                = []
    ) {
        self.providers =
            Self.sortedProviders(
                providers
            )
    }

    /// Replaces the provider set.
    ///
    /// Primarily useful when concrete acquisition
    /// providers are introduced in later patches.
    func setProviders(
        _ providers:
            [any ReloadedIIDependencyAcquisitionProvider]
    ) {
        self.providers =
            Self.sortedProviders(
                providers
            )
    }

    /// Builds an acquisition plan for required
    /// dependencies which Patch 27 determined are
    /// missing.
    ///
    /// Installed, disabled, incompatible, and
    /// optional dependencies are deliberately not
    /// acquisition targets here.
    func plan(
        for dependencyPlan:
            ReloadedIIDependencyPlan
    ) async
        -> ReloadedIIDependencyAcquisitionPlan
    {
        let missing =
            uniqueMissingRequired(
                dependencyPlan
                    .missingRequired
            )

        var results:
            [ReloadedIIDependencyAcquisitionResolution]
                = []

        for dependency
            in missing
        {
            let candidates =
                await candidates(
                    for:
                        dependency.modId
                )

            results.append(
                ReloadedIIDependencyAcquisitionResolution(
                    dependency:
                        dependency,
                    candidates:
                        candidates
                )
            )
        }

        return ReloadedIIDependencyAcquisitionPlan(
            dependencies:
                results
        )
    }

    private func candidates(
        for modId: String
    ) async
        -> [ReloadedIIModAcquisitionCandidate]
    {
        var collected:
            [ReloadedIIModAcquisitionCandidate]
                = []

        for provider
            in providers
        {
            do {
                let values =
                    try await provider
                        .candidates(
                            for: modId
                        )

                collected.append(
                    contentsOf:
                        values.filter {
                            normalizedModId(
                                $0.modId
                            )
                            ==
                            normalizedModId(
                                modId
                            )
                        }
                )
            } catch {
                // One acquisition source failing must
                // not erase candidates from another.
                // Provider diagnostics can be added
                // when real network providers exist.
                continue
            }
        }

        return deduplicatedCandidates(
            collected
        )
    }

    private func uniqueMissingRequired(
        _ dependencies:
            [ReloadedIIDependencyResolution]
    ) -> [ReloadedIIDependencyResolution] {
        var seen =
            Set<String>()

        var result:
            [ReloadedIIDependencyResolution]
                = []

        for dependency
            in dependencies
        {
            let key =
                normalizedModId(
                    dependency.modId
                )

            guard seen.insert(
                    key
                  ).inserted
            else {
                continue
            }

            result.append(
                dependency
            )
        }

        return result
    }

    private func deduplicatedCandidates(
        _ candidates:
            [ReloadedIIModAcquisitionCandidate]
    ) -> [ReloadedIIModAcquisitionCandidate] {
        let ordered =
            candidates.sorted {
                if $0.priority != $1.priority {
                    return $0.priority
                        < $1.priority
                }

                let sourceOrder =
                    $0.sourceName
                        .localizedCaseInsensitiveCompare(
                            $1.sourceName
                        )

                if sourceOrder
                    != .orderedSame
                {
                    return sourceOrder
                        == .orderedAscending
                }

                return candidateIdentity(
                    $0
                )
                <
                candidateIdentity(
                    $1
                )
            }

        var seen =
            Set<String>()

        var result:
            [ReloadedIIModAcquisitionCandidate]
                = []

        for candidate
            in ordered
        {
            let identity =
                candidateIdentity(
                    candidate
                )

            guard seen.insert(
                    identity
                  ).inserted
            else {
                continue
            }

            result.append(
                candidate
            )
        }

        return result
    }

    private func candidateIdentity(
        _ candidate:
            ReloadedIIModAcquisitionCandidate
    ) -> String {
        let sourceIdentity: String

        switch candidate.source {
        case .github(
            let owner,
            let repository
        ):
            sourceIdentity =
                "github:"
                + owner.lowercased()
                + "/"
                + repository.lowercased()

        case .gameBanana(
            let itemType,
            let itemId
        ):
            sourceIdentity =
                "gamebanana:"
                + itemType.lowercased()
                + ":"
                + itemId.lowercased()

        case .directPackage(
            let url
        ):
            sourceIdentity =
                "direct:"
                + url.absoluteString

        case .custom(
            let identifier
        ):
            sourceIdentity =
                "custom:"
                + identifier.lowercased()
        }

        return normalizedModId(
            candidate.modId
        )
        + "|"
        + sourceIdentity
        + "|"
        + (
            candidate.version?
                .lowercased()
            ?? ""
        )
    }

    private static func sortedProviders(
        _ providers:
            [any ReloadedIIDependencyAcquisitionProvider]
    ) -> [any ReloadedIIDependencyAcquisitionProvider] {
        providers.sorted {
            if $0.priority
                != $1.priority
            {
                return $0.priority
                    < $1.priority
            }

            return $0.identifier
                .localizedCaseInsensitiveCompare(
                    $1.identifier
                )
                == .orderedAscending
        }
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
}
