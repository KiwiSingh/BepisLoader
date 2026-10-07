import Foundation

// MARK: - Reloaded-II Official Index
//
// Reloaded-II.Index publishes AllDependencies.json.br,
// a compact aggregate intended for dependency lookup.
//
// Transport/decompression is intentionally abstracted.
// The official deployed artifact is Brotli-compressed,
// and acquisition semantics should not care how those
// bytes become decoded JSON.

protocol ReloadedIIIndexLoading {
    func loadIndexData() async throws -> Data
}


// MARK: Decoded index schema

private struct ReloadedIIIndexDependencyDocument:
    Decodable
{
    let packages:
        [ReloadedIIIndexDependencyPackage]

    private enum CodingKeys:
        String,
        CodingKey
    {
        case packages = "Packages"
    }
}

private struct ReloadedIIIndexDependencyPackage:
    Decodable
{
    let name: String?
    let source: String?
    let id: String?
    let fileSize: Int64?
    let downloadURL: String?

    private enum CodingKeys:
        String,
        CodingKey
    {
        case name = "Name"
        case source = "Source"
        case id = "Id"
        case fileSize = "FileSize"
        case downloadURL = "DownloadUrl"
    }
}


// MARK: Provider

final class ReloadedIIIndexAcquisitionProvider:
    ReloadedIIDependencyAcquisitionProvider
{
    let identifier =
        "reloaded-ii-index"

    let priority =
        100

    private let loader:
        any ReloadedIIIndexLoading

    init(
        loader:
            any ReloadedIIIndexLoading
    ) {
        self.loader =
            loader
    }

    func candidates(
        for modId: String
    ) async throws
        -> [ReloadedIIModAcquisitionCandidate]
    {
        let requestedId =
            normalizedModId(
                modId
            )

        guard !requestedId.isEmpty
        else {
            return []
        }

        let data =
            try await loader
                .loadIndexData()

        let document =
            try JSONDecoder()
                .decode(
                    ReloadedIIIndexDependencyDocument.self,
                    from: data
                )

        return document.packages
            .compactMap {
                candidate(
                    from: $0,
                    requestedId:
                        requestedId
                )
            }
            .sorted {
                candidateSortKey(
                    $0
                )
                <
                candidateSortKey(
                    $1
                )
            }
    }

    private func candidate(
        from package:
            ReloadedIIIndexDependencyPackage,
        requestedId: String
    ) -> ReloadedIIModAcquisitionCandidate? {
        guard let packageId =
                package.id?
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
              normalizedModId(
                packageId
              ) == requestedId,
              let rawDownloadURL =
                package.downloadURL?
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
              let downloadURL =
                validatedHTTPSURL(
                    rawDownloadURL
                )
        else {
            return nil
        }

        let sourceName =
            normalizedSourceName(
                package.source
            )

        return ReloadedIIModAcquisitionCandidate(
            modId:
                packageId,
            source:
                acquisitionSource(
                    sourceName:
                        sourceName,
                    downloadURL:
                        downloadURL
                ),
            sourceName:
                sourceName,
            informationURL:
                nil,
            packageURL:
                downloadURL,
            version:
                nil,
            priority:
                priority
        )
    }

    private func acquisitionSource(
        sourceName: String,
        downloadURL: URL
    ) -> ReloadedIIModAcquisitionSource {
        if sourceName
            .caseInsensitiveCompare(
                "GameBanana"
            )
            == .orderedSame,
           let item =
                gameBananaItem(
                    from:
                        downloadURL
                )
        {
            return .gameBanana(
                itemType:
                    item.type,
                itemId:
                    item.id
            )
        }

        // The official index may contain sources
        // other than GameBanana, including NuGet.
        // A verified DownloadUrl is therefore the
        // authoritative package location.
        return .directPackage(
            downloadURL
        )
    }

    private func gameBananaItem(
        from url: URL
    ) -> (
        type: String,
        id: String
    )? {
        guard let host =
                url.host?
                    .lowercased(),
              host == "gamebanana.com"
                || host.hasSuffix(
                    ".gamebanana.com"
                )
        else {
            return nil
        }

        let components =
            url.pathComponents
                .filter {
                    $0 != "/"
                }

        guard components.count
                >= 2
        else {
            return nil
        }

        let type =
            components[
                components.count - 2
            ]

        let id =
            components[
                components.count - 1
            ]

        guard !type.isEmpty,
              !id.isEmpty
        else {
            return nil
        }

        return (
            type,
            id
        )
    }

    private func validatedHTTPSURL(
        _ value: String
    ) -> URL? {
        guard let url =
                URL(
                    string: value
                ),
              url.scheme?
                .lowercased()
                == "https",
              url.host != nil
        else {
            return nil
        }

        return url
    }

    private func normalizedSourceName(
        _ value: String?
    ) -> String {
        let trimmed =
            value?
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            ?? ""

        return trimmed.isEmpty
            ? "Reloaded-II Index"
            : trimmed
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

    private func candidateSortKey(
        _ candidate:
            ReloadedIIModAcquisitionCandidate
    ) -> String {
        candidate.sourceName
            .lowercased()
        + "|"
        + (
            candidate.packageURL?
                .absoluteString
            ?? ""
        )
    }
}


// MARK: In-memory loader
//
// Useful for tests, previews, and callers which
// already possess decoded AllDependencies JSON.

struct ReloadedIIIndexDataLoader:
    ReloadedIIIndexLoading
{
    let data: Data

    func loadIndexData()
        async throws -> Data
    {
        data
    }
}
