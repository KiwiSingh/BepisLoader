import Compression
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum ReloadedIIIndexTransportError:
    LocalizedError
{
    case invalidResponse
    case unexpectedStatusCode(Int)
    case compressedPayloadTooLarge(Int)
    case emptyCompressedPayload
    case decompressionFailed
    case decompressedPayloadTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return
                "Reloaded-II Index returned an invalid HTTP response."

        case .unexpectedStatusCode(let code):
            return
                "Reloaded-II Index returned HTTP \(code)."

        case .compressedPayloadTooLarge(let size):
            return
                "Reloaded-II Index compressed payload is too large (\(size) bytes)."

        case .emptyCompressedPayload:
            return
                "Reloaded-II Index returned an empty compressed payload."

        case .decompressionFailed:
            return
                "Could not decompress the Reloaded-II dependency index."

        case .decompressedPayloadTooLarge(let size):
            return
                "Reloaded-II dependency index exceeded the decompressed size limit (\(size) bytes)."
        }
    }
}


// MARK: - Brotli decoder

private enum ReloadedIIBrotliDecoder {
    static func decode(
        _ compressed: Data,
        maximumOutputSize: Int
    ) throws -> Data {
        guard !compressed.isEmpty
        else {
            throw ReloadedIIIndexTransportError
                .emptyCompressedPayload
        }

        guard maximumOutputSize > 0
        else {
            throw ReloadedIIIndexTransportError
                .decompressionFailed
        }

        // The current official aggregate is only around
        // half a megabyte decoded. Start small and grow
        // until the stream fits, while enforcing a hard
        // upper bound.
        var capacity =
            min(
                max(
                    compressed.count * 4,
                    256 * 1024
                ),
                maximumOutputSize
            )

        while capacity <= maximumOutputSize {
            var output =
                Data(
                    count: capacity
                )

            let decodedSize:
                Int =
                output.withUnsafeMutableBytes {
                    destinationBytes in

                    compressed.withUnsafeBytes {
                        sourceBytes in

                        guard let destination =
                                destinationBytes
                                    .bindMemory(
                                        to: UInt8.self
                                    )
                                    .baseAddress,
                              let source =
                                sourceBytes
                                    .bindMemory(
                                        to: UInt8.self
                                    )
                                    .baseAddress
                        else {
                            return 0
                        }

                        return compression_decode_buffer(
                            destination,
                            capacity,
                            source,
                            compressed.count,
                            nil,
                            COMPRESSION_BROTLI
                        )
                    }
                }

            if decodedSize > 0 {
                output.removeSubrange(
                    decodedSize..<output.count
                )

                return output
            }

            if capacity == maximumOutputSize {
                break
            }

            let nextCapacity =
                min(
                    capacity * 2,
                    maximumOutputSize
                )

            guard nextCapacity > capacity
            else {
                break
            }

            capacity =
                nextCapacity
        }

        throw ReloadedIIIndexTransportError
            .decompressionFailed
    }
}


// MARK: - Production loader

actor ReloadedIIIndexNetworkLoader:
    ReloadedIIIndexLoading
{
    static let shared =
        ReloadedIIIndexNetworkLoader()

    static let officialIndexURL =
        URL(
            string:
                "https://reloaded-project.github.io/Reloaded-II.Index/AllDependencies.json.br"
        )!

    private let session:
        URLSession

    private let indexURL:
        URL

    private let maximumCompressedSize:
        Int

    private let maximumDecompressedSize:
        Int

    private var cachedData:
        Data?

    init(
        session: URLSession = .shared,
        indexURL: URL =
            ReloadedIIIndexNetworkLoader
                .officialIndexURL,
        maximumCompressedSize: Int =
            4 * 1024 * 1024,
        maximumDecompressedSize: Int =
            32 * 1024 * 1024
    ) {
        self.session =
            session

        self.indexURL =
            indexURL

        self.maximumCompressedSize =
            maximumCompressedSize

        self.maximumDecompressedSize =
            maximumDecompressedSize
    }

    func loadIndexData()
        async throws -> Data
    {
        if let cachedData {
            return cachedData
        }

        var request =
            URLRequest(
                url: indexURL
            )

        request.httpMethod =
            "GET"

        request.cachePolicy =
            .reloadRevalidatingCacheData

        request.timeoutInterval =
            30

        request.setValue(
            "application/octet-stream",
            forHTTPHeaderField:
                "Accept"
        )

        let (
            compressed,
            response
        ) =
            try await session.data(
                for: request
            )

        guard let httpResponse =
                response as? HTTPURLResponse
        else {
            throw ReloadedIIIndexTransportError
                .invalidResponse
        }

        guard (200...299)
                .contains(
                    httpResponse.statusCode
                )
        else {
            throw ReloadedIIIndexTransportError
                .unexpectedStatusCode(
                    httpResponse.statusCode
                )
        }

        guard compressed.count
                <= maximumCompressedSize
        else {
            throw ReloadedIIIndexTransportError
                .compressedPayloadTooLarge(
                    compressed.count
                )
        }

        let decoded =
            try ReloadedIIBrotliDecoder
                .decode(
                    compressed,
                    maximumOutputSize:
                        maximumDecompressedSize
                )

        guard decoded.count
                <= maximumDecompressedSize
        else {
            throw ReloadedIIIndexTransportError
                .decompressedPayloadTooLarge(
                    decoded.count
                )
        }

        // Validate that the decoded payload is at least
        // syntactically JSON before caching it. Schema
        // validation remains the Patch 30 provider's job.
        _ =
            try JSONSerialization
                .jsonObject(
                    with: decoded
                )

        cachedData =
            decoded

        return decoded
    }

    func invalidateCache() {
        cachedData =
            nil
    }
}
