import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Reloaded-II Dependency Package Transport
//
// Patch 33 crosses the acquisition/install boundary.
//
// This object ONLY downloads a package into a
// temporary ZIP. Package interpretation, filesystem
// validation and installation remain the
// responsibility of ReloadedIIModManager.

enum ReloadedIIDependencyDownloadError:
    LocalizedError
{
    case missingPackageURL(String)
    case insecureURL(URL)
    case invalidResponse
    case unexpectedStatusCode(Int)
    case packageTooLarge(Int)
    case emptyPackage

    var errorDescription: String? {
        switch self {
        case .missingPackageURL(let modId):
            return
                "No downloadable package URL was found for \(modId)."

        case .insecureURL(let url):
            return
                "Refusing to download a Reloaded-II dependency over an insecure URL:\n\n\(url.absoluteString)"

        case .invalidResponse:
            return
                "The dependency server returned an invalid HTTP response."

        case .unexpectedStatusCode(let code):
            return
                "The dependency server returned HTTP \(code)."

        case .packageTooLarge(let size):
            return
                "The Reloaded-II dependency package exceeded the download limit (\(size) bytes)."

        case .emptyPackage:
            return
                "The dependency server returned an empty package."
        }
    }
}


struct ReloadedIIDownloadedDependency {
    let modId: String
    let packageURL: URL
    let localURL: URL
}


final class ReloadedIIDependencyPackageDownloader {

    static let shared =
        ReloadedIIDependencyPackageDownloader()

    // Large enough for real mod packages while still
    // preventing an acquisition source from causing
    // unbounded memory/disk use.
    private let maximumPackageSize =
        512 * 1024 * 1024

    private let session:
        URLSession

    init(
        session: URLSession = .shared
    ) {
        self.session = session
    }

    func download(
        candidate:
            ReloadedIIModAcquisitionCandidate
    ) async throws
        -> ReloadedIIDownloadedDependency
    {
        guard let packageURL =
                candidate.packageURL
        else {
            throw ReloadedIIDependencyDownloadError
                .missingPackageURL(
                    candidate.modId
                )
        }

        guard packageURL.scheme?
                .lowercased()
                == "https"
        else {
            throw ReloadedIIDependencyDownloadError
                .insecureURL(
                    packageURL
                )
        }

        var request =
            URLRequest(
                url: packageURL
            )

        request.httpMethod =
            "GET"

        request.timeoutInterval =
            120

        request.cachePolicy =
            .reloadIgnoringLocalCacheData

        let (
            temporaryDownload,
            response
        ) =
            try await session.download(
                for: request
            )

        guard let http =
                response as? HTTPURLResponse
        else {
            throw ReloadedIIDependencyDownloadError
                .invalidResponse
        }

        guard (200...299)
                .contains(
                    http.statusCode
                )
        else {
            throw ReloadedIIDependencyDownloadError
                .unexpectedStatusCode(
                    http.statusCode
                )
        }

        let fm =
            FileManager.default

        let values =
            try temporaryDownload
                .resourceValues(
                    forKeys: [
                        .fileSizeKey
                    ]
                )

        let size =
            values.fileSize
            ?? 0

        guard size > 0
        else {
            throw ReloadedIIDependencyDownloadError
                .emptyPackage
        }

        guard size
                <= maximumPackageSize
        else {
            throw ReloadedIIDependencyDownloadError
                .packageTooLarge(
                    size
                )
        }

        let destination =
            fm.temporaryDirectory
                .appendingPathComponent(
                    "BepisLoader-Dependency-\(UUID().uuidString)"
                )
                .appendingPathExtension(
                    "zip"
                )

        do {
            try fm.moveItem(
                at: temporaryDownload,
                to: destination
            )
        } catch {
            try? fm.removeItem(
                at: destination
            )

            throw error
        }

        return ReloadedIIDownloadedDependency(
            modId:
                candidate.modId,
            packageURL:
                packageURL,
            localURL:
                destination
        )
    }
}
