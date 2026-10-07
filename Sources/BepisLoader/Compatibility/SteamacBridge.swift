import Darwin
import Foundation


enum SteamacBridgeError:
    LocalizedError
{
    case noRunningInstance
    case invalidRuntimeDirectory(URL)
    case connectionFailed(URL, String)
    case requestFailed(String)
    case connectionClosed
    case responseTooLarge
    case malformedResponse(String)
    case unsupportedProtocol(Int)

    var errorDescription:
        String?
    {
        switch self {
        case .noRunningInstance:
            return "No running Steamac Bepis bridge was found."

        case .invalidRuntimeDirectory(let url):
            return "Invalid Steamac runtime directory: \(url.path)"

        case .connectionFailed(let url, let reason):
            return "Could not connect to Steamac bridge at \(url.path): \(reason)"

        case .requestFailed(let reason):
            return "Steamac bridge request failed: \(reason)"

        case .connectionClosed:
            return "The Steamac bridge closed the connection."

        case .responseTooLarge:
            return "The Steamac bridge response exceeded the protocol limit."

        case .malformedResponse(let response):
            return "Malformed Steamac bridge response: \(response)"

        case .unsupportedProtocol(let version):
            return "Unsupported Steamac bridge protocol version \(version)."
        }
    }
}


struct SteamacBridgeHandshake:
    Hashable
{
    let protocolVersion:
        Int

    let implementation:
        String

    let capabilities:
        GameEnvironmentCapabilities

    var isKiwiSinghSteamac:
        Bool
    {
        implementation
            .caseInsensitiveCompare(
                "KiwiSingh/steamac"
            )
            == .orderedSame
    }
}


struct SteamacBridgeEndpoint:
    Hashable
{
    let runtimeDirectory:
        URL

    let socketURL:
        URL

    let processId:
        pid_t
}


final class SteamacBridge {

    static let shared =
        SteamacBridge()

    static let socketName =
        "bepis.sock"

    static let protocolVersion =
        1

    private let fm:
        FileManager

    private init(
        fileManager:
            FileManager = .default
    ) {
        fm =
            fileManager
    }


    // MARK: - Discovery

    func endpoints()
        -> [SteamacBridgeEndpoint]
    {
        guard let names =
                try? fm.contentsOfDirectory(
                    atPath:
                        "/tmp"
                )
        else {
            return []
        }

        return names
            .compactMap {
                endpoint(
                    runtimeDirectoryName:
                        $0
                )
            }
            .sorted {
                $0.processId
                    > $1.processId
            }
    }


    private func endpoint(
        runtimeDirectoryName:
            String
    ) -> SteamacBridgeEndpoint? {
        let prefix =
            "steamac-"

        guard runtimeDirectoryName
                .hasPrefix(prefix)
        else {
            return nil
        }

        let pidString =
            String(
                runtimeDirectoryName
                    .dropFirst(
                        prefix.count
                    )
            )

        guard let pid =
                Int32(pidString),
              pid > 0
        else {
            return nil
        }

        // kill(pid, 0) performs no signalling; it only verifies that
        // the process exists / is visible to us.
        guard kill(pid, 0) == 0
                || errno == EPERM
        else {
            return nil
        }

        let runtime =
            URL(
                fileURLWithPath:
                    "/tmp"
            )
            .appendingPathComponent(
                runtimeDirectoryName,
                isDirectory: true
            )

        guard validateRuntimeDirectory(
            runtime
        )
        else {
            return nil
        }

        let socket =
            runtime
                .appendingPathComponent(
                    Self.socketName
                )

        var info =
            stat()

        guard lstat(
            socket.path,
            &info
        ) == 0
        else {
            return nil
        }

        guard (info.st_mode & S_IFMT)
                == S_IFSOCK
        else {
            return nil
        }

        guard info.st_uid
                == getuid()
        else {
            return nil
        }

        return SteamacBridgeEndpoint(
            runtimeDirectory:
                runtime,
            socketURL:
                socket,
            processId:
                pid
        )
    }


    private func validateRuntimeDirectory(
        _ url:
            URL
    ) -> Bool {
        var info =
            stat()

        guard lstat(
            url.path,
            &info
        ) == 0
        else {
            return false
        }

        guard (info.st_mode & S_IFMT)
                == S_IFDIR
        else {
            return false
        }

        guard info.st_uid
                == getuid()
        else {
            return false
        }

        // Steamac creates this as a private 0700 runtime directory.
        let permissions =
            info.st_mode & 0o777

        guard permissions
                & 0o077
                == 0
        else {
            return false
        }

        return true
    }


    // MARK: - Handshake

    func handshake()
        throws -> SteamacBridgeHandshake
    {
        guard let endpoint =
                endpoints().first
        else {
            throw SteamacBridgeError
                .noRunningInstance
        }

        return try handshake(
            endpoint:
                endpoint
        )
    }


    func handshake(
        endpoint:
            SteamacBridgeEndpoint
    ) throws -> SteamacBridgeHandshake {
        let response =
            try request(
                "hello",
                endpoint:
                    endpoint
            )

        let parts =
            response.split(
                separator:
                    " ",
                omittingEmptySubsequences:
                    true
            )

        guard parts.count >= 4,
              parts[0] == "hello",
              let version =
                Int(parts[1])
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    response
                )
        }

        guard version
                == Self.protocolVersion
        else {
            throw SteamacBridgeError
                .unsupportedProtocol(
                    version
                )
        }

        let implementation =
            String(parts[2])

        var capabilities =
            Set<GameEnvironmentCapability>()

        for raw
            in parts.dropFirst(3)
        {
            switch raw {
            case "guestFileAccess":
                capabilities.insert(
                    .guestFileAccess
                )

            case "guestCommandExecution":
                capabilities.insert(
                    .guestCommandExecution
                )

            case "steamLibraryDiscovery":
                capabilities.insert(
                    .steamLibraryDiscovery
                )

            case "protonPrefixResolution":
                capabilities.insert(
                    .protonPrefixResolution
                )

            default:
                // Forward compatibility: older BepisLoader builds
                // ignore capabilities they do not understand.
                continue
            }
        }

        return SteamacBridgeHandshake(
            protocolVersion:
                version,
            implementation:
                implementation,
            capabilities:
                GameEnvironmentCapabilities(
                    protocolVersion:
                        version,
                    capabilities:
                        capabilities
                )
        )
    }


    func ping(
        endpoint:
            SteamacBridgeEndpoint
    ) throws -> Bool {
        let token =
            UUID()
                .uuidString
                .lowercased()

        return try request(
            "ping \(token)",
            endpoint:
                endpoint
        ) == "pong \(token)"
    }


    // MARK: - Unix socket transport

    private func request(
        _ request:
            String,
        endpoint:
            SteamacBridgeEndpoint
    ) throws -> String {
        guard request.utf8.count
                <= 16 * 1024
        else {
            throw SteamacBridgeError
                .requestFailed(
                    "request too large"
                )
        }

        let fd =
            socket(
                AF_UNIX,
                SOCK_STREAM,
                0
            )

        guard fd >= 0
        else {
            throw SteamacBridgeError
                .connectionFailed(
                    endpoint.socketURL,
                    String(
                        cString:
                            strerror(errno)
                    )
                )
        }

        defer {
            Darwin.close(fd)
        }

        var timeout =
            timeval(
                tv_sec: 5,
                tv_usec: 0
            )

        _ = withUnsafePointer(
            to:
                &timeout
        ) {
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(
                    MemoryLayout<timeval>
                        .size
                )
            )
        }

        var address =
            sockaddr_un()

        address.sun_family =
            sa_family_t(
                AF_UNIX
            )

        let bytes =
            Array(
                endpoint
                    .socketURL
                    .path
                    .utf8
            ) + [0]

        guard bytes.count
                <= MemoryLayout.size(
                    ofValue:
                        address.sun_path
                )
        else {
            throw SteamacBridgeError
                .connectionFailed(
                    endpoint.socketURL,
                    "socket path too long"
                )
        }

        withUnsafeMutableBytes(
            of:
                &address.sun_path
        ) {
            destination in

            destination.initializeMemory(
                as:
                    UInt8.self,
                repeating:
                    0
            )

            bytes.withUnsafeBytes {
                source in

                destination.copyBytes(
                    from:
                        source.prefix(
                            destination.count
                        )
                )
            }
        }

        let result =
            withUnsafePointer(
                to:
                    &address
            ) {
                pointer in

                pointer.withMemoryRebound(
                    to:
                        sockaddr.self,
                    capacity:
                        1
                ) {
                    Darwin.connect(
                        fd,
                        $0,
                        socklen_t(
                            MemoryLayout<sockaddr_un>
                                .size
                        )
                    )
                }
            }

        guard result == 0
        else {
            throw SteamacBridgeError
                .connectionFailed(
                    endpoint.socketURL,
                    String(
                        cString:
                            strerror(errno)
                    )
                )
        }

        let payload =
            Data(
                (request + "\n")
                    .utf8
            )

        guard writeAll(
            fd,
            payload
        )
        else {
            throw SteamacBridgeError
                .requestFailed(
                    "write failed"
                )
        }

        var response =
            Data()

        var byte:
            UInt8 = 0

        while response.count
                <= 16 * 1024
        {
            let count =
                Darwin.read(
                    fd,
                    &byte,
                    1
                )

            if count == 0 {
                throw SteamacBridgeError
                    .connectionClosed
            }

            if count < 0 {
                if errno == EINTR {
                    continue
                }

                throw SteamacBridgeError
                    .requestFailed(
                        String(
                            cString:
                                strerror(errno)
                        )
                    )
            }

            if byte == 0x0A {
                guard let string =
                        String(
                            data:
                                response,
                            encoding:
                                .utf8
                        )
                else {
                    throw SteamacBridgeError
                        .malformedResponse(
                            "<non-UTF8>"
                        )
                }

                if string.hasPrefix(
                    "error "
                ) {
                    throw SteamacBridgeError
                        .requestFailed(
                            String(
                                string.dropFirst(
                                    6
                                )
                            )
                        )
                }

                return string
            }

            response.append(
                byte
            )
        }

        throw SteamacBridgeError
            .responseTooLarge
    }


    private func writeAll(
        _ fd:
            Int32,
        _ data:
            Data
    ) -> Bool {
        data.withUnsafeBytes {
            raw in

            guard let base =
                    raw.baseAddress
            else {
                return true
            }

            var offset =
                0

            while offset
                    < raw.count
            {
                let count =
                    Darwin.write(
                        fd,
                        base.advanced(
                            by:
                                offset
                        ),
                        raw.count
                            - offset
                    )

                if count < 0 {
                    if errno == EINTR {
                        continue
                    }

                    return false
                }

                if count == 0 {
                    return false
                }

                offset +=
                    count
            }

            return true
        }
    }
}
