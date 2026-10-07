import Foundation

// ─────────────────────────────────────────────
//  ReloadedIIReleaseService
//
//  Read-only update awareness for Reloaded-II.
//
//  Local framework detection remains entirely
//  separate in ReloadedIIProvider. This service
//  performs the optional network lookup for the
//  latest stable upstream release.
// ─────────────────────────────────────────────

enum ReloadedIIUpdateStatus:
    Equatable
{
    case upToDate(
        installed: String,
        latest: String
    )

    case updateAvailable(
        installed: String,
        latest: String
    )

    case newerThanLatest(
        installed: String,
        latest: String
    )

    case unknown
}

final class ReloadedIIReleaseService {

    static let shared =
        ReloadedIIReleaseService()

    private struct GitHubRelease:
        Decodable
    {
        let tagName: String

        enum CodingKeys:
            String,
            CodingKey
        {
            case tagName = "tag_name"
        }
    }

    private struct CachedRelease {
        let version: String
        let fetchedAt: Date
    }

    private struct SemanticVersion:
        Comparable
    {
        let components: [Int]

        static func < (
            lhs: SemanticVersion,
            rhs: SemanticVersion
        ) -> Bool {
            let count =
                max(
                    lhs.components.count,
                    rhs.components.count
                )

            for index in 0..<count {
                let left =
                    index < lhs.components.count
                    ? lhs.components[index]
                    : 0

                let right =
                    index < rhs.components.count
                    ? rhs.components[index]
                    : 0

                if left != right {
                    return left < right
                }
            }

            return false
        }
    }

    private let endpoint =
        URL(
            string:
                "https://api.github.com/repos/Reloaded-Project/Reloaded-II/releases/latest"
        )!

    private let cacheLifetime:
        TimeInterval = 60 * 60

    private let queue =
        DispatchQueue(
            label:
                "BepisLoader.ReloadedIIReleaseService"
        )

    private var cache:
        CachedRelease?

    private var pending:
        [(String?) -> Void] = []

    private var requestInFlight =
        false

    private init() {}

    func invalidateCache() {
        queue.async {
            self.cache = nil
        }
    }

    func updateStatus(
        installedVersion: String,
        completion:
            @escaping (ReloadedIIUpdateStatus) -> Void
    ) {
        latestVersion {
            latest in

            let status =
                Self.compare(
                    installed:
                        installedVersion,
                    latest:
                        latest
                )

            DispatchQueue.main.async {
                completion(
                    status
                )
            }
        }
    }

    func latestVersion(
        completion:
            @escaping (String?) -> Void
    ) {
        queue.async {
            if let cache =
                    self.cache,
               Date()
                    .timeIntervalSince(
                        cache.fetchedAt
                    )
                    < self.cacheLifetime
            {
                let version =
                    cache.version

                DispatchQueue.main.async {
                    completion(
                        version
                    )
                }

                return
            }

            self.pending.append(
                completion
            )

            guard !self.requestInFlight else {
                return
            }

            self.requestInFlight =
                true

            self.fetchLatestVersion()
        }
    }

    private func fetchLatestVersion() {
        var request =
            URLRequest(
                url: endpoint
            )

        request.httpMethod =
            "GET"

        request.timeoutInterval =
            15

        request.setValue(
            "application/vnd.github+json",
            forHTTPHeaderField:
                "Accept"
        )

        request.setValue(
            "2022-11-28",
            forHTTPHeaderField:
                "X-GitHub-Api-Version"
        )

        request.setValue(
            "BepisLoader",
            forHTTPHeaderField:
                "User-Agent"
        )

        URLSession.shared.dataTask(
            with: request
        ) {
            [weak self]
            data,
            response,
            error in

            guard let self else {
                return
            }

            var latest:
                String?

            if error == nil,
               let http =
                    response
                        as? HTTPURLResponse,
               (200..<300)
                    .contains(
                        http.statusCode
                    ),
               let data,
               let release =
                    try? JSONDecoder()
                        .decode(
                            GitHubRelease.self,
                            from: data
                        )
            {
                latest =
                    Self.normalizedVersionString(
                        release.tagName
                    )
            }

            self.queue.async {
                if let latest {
                    self.cache =
                        CachedRelease(
                            version: latest,
                            fetchedAt: Date()
                        )
                }

                let callbacks =
                    self.pending

                self.pending.removeAll()

                self.requestInFlight =
                    false

                for callback in callbacks {
                    DispatchQueue.main.async {
                        callback(
                            latest
                        )
                    }
                }
            }
        }
        .resume()
    }

    private static func compare(
        installed: String,
        latest: String?
    ) -> ReloadedIIUpdateStatus {
        guard let latest,
              let installedSemantic =
                semanticVersion(
                    installed
                ),
              let latestSemantic =
                semanticVersion(
                    latest
                )
        else {
            return .unknown
        }

        if installedSemantic
            < latestSemantic
        {
            return .updateAvailable(
                installed:
                    installed,
                latest:
                    latest
            )
        }

        if latestSemantic
            < installedSemantic
        {
            return .newerThanLatest(
                installed:
                    installed,
                latest:
                    latest
            )
        }

        return .upToDate(
            installed:
                installed,
            latest:
                latest
        )
    }

    private static func semanticVersion(
        _ value: String
    ) -> SemanticVersion? {
        guard let normalized =
                normalizedVersionString(
                    value
                )
        else {
            return nil
        }

        let parts =
            normalized.split(
                separator: ".",
                omittingEmptySubsequences:
                    false
            )

        guard !parts.isEmpty else {
            return nil
        }

        var components:
            [Int] = []

        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({
                      $0.isNumber
                  }),
                  let number =
                    Int(part)
            else {
                return nil
            }

            components.append(
                number
            )
        }

        return SemanticVersion(
            components:
                components
        )
    }

    private static func normalizedVersionString(
        _ value: String
    ) -> String? {
        var trimmed =
            value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        if trimmed.first == "v"
            || trimmed.first == "V"
        {
            trimmed.removeFirst()
        }

        guard !trimmed.isEmpty else {
            return nil
        }

        let parts =
            trimmed.split(
                separator: ".",
                omittingEmptySubsequences:
                    false
            )

        guard !parts.isEmpty,
              parts.allSatisfy({
                  !$0.isEmpty
                  && $0.allSatisfy {
                      $0.isNumber
                  }
              })
        else {
            return nil
        }

        return trimmed
    }
}
