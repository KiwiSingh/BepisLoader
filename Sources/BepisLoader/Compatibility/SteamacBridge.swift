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



struct SteamacGame:
    Identifiable,
    Hashable
{
    let appId:
        UInt32

    let name:
        String

    /// Absolute Linux path inside the Steamac guest.
    let installPath:
        String

    /// Absolute Linux Steam library root inside the guest.
    let libraryPath:
        String

    let environment:
        GameEnvironment

    var id:
        String
    {
        "\(environment.identifier):\(appId)"
    }

    var gameDirectory:
        GameEnvironmentPath
    {
        .guest(
            installPath
        )
    }
}


enum SteamacPEArchitecture:
    String,
    Hashable
{
    case x86
    case x64
    case unknown
}


enum SteamacGuestFileKind:
    String,
    Hashable
{
    case file
    case directory
    case symlink
    case other
    case missing
}


struct SteamacGuestFileInfo:
    Hashable
{
    let kind:
        SteamacGuestFileKind

    let size:
        UInt64

    var exists:
        Bool
    {
        kind != .missing
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



// 41F-19B: Read-only Proton environment diagnostics.
enum SteamacProtonComponentStatus: String, Hashable {
    case present
    case missing
    case invalid
    case inaccessible
}

struct SteamacProtonInspection: Hashable {
    let appId: UInt32
    let prefixPath: String
    let prefix: SteamacProtonComponentStatus
    let driveC: SteamacProtonComponentStatus
    let dosdevices: SteamacProtonComponentStatus
    let systemRegistry: SteamacProtonComponentStatus
    let userRegistry: SteamacProtonComponentStatus

    var isStructurallyReady: Bool {
        prefix == .present &&
        driveC == .present &&
        dosdevices == .present &&
        systemRegistry == .present &&
        userRegistry == .present
    }
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

        guard parts.count >= 3,
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
            case "recoveryInventoryV1":
                capabilities.insert(.recoveryInventoryV1)
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

            case "protonEnvironmentInspection":
                capabilities.insert(.protonEnvironmentInspection)

            case "assetModInstallV1":
                capabilities.insert(.assetModInstallV1)
            case "bepInExInstallationInventoryV1":
                capabilities.insert(.bepInExInstallationInventoryV1)

            case "reloadedIIModInventoryV1":
                capabilities.insert(.reloadedIIModInventoryV1)

            case "reloadedIIModMetadataV1":
                capabilities.insert(.reloadedIIModMetadataV1)

            case "protonRuntimeAttestationV1":
                capabilities.insert(.protonRuntimeAttestationV1)

            case "protonRuntimeResolution":
                capabilities.insert(.protonRuntimeResolution)

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


    // MARK: - Steam guest discovery

    func steamGames(
        endpoint:
            SteamacBridgeEndpoint
    ) throws -> [SteamacGame] {
        let handshake =
            try handshake(
                endpoint:
                    endpoint
            )

        guard handshake
                .capabilities
                .supports(
                    .steamLibraryDiscovery
                )
        else {
            throw SteamacBridgeError
                .requestFailed(
                    "Steamac does not advertise Steam library discovery."
                )
        }

        let lines =
            try requestLines(
                "steam-games",
                endpoint:
                    endpoint,
                terminator:
                    "steam-games-end"
            )

        guard let header =
                lines.first
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    "<empty steam-games response>"
                )
        }

        let headerParts =
            header.split(
                separator:
                    " ",
                omittingEmptySubsequences:
                    true
            )

        guard headerParts.count == 2,
              headerParts[0] == "steam-games",
              let expectedCount =
                Int(headerParts[1]),
              expectedCount >= 0
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    header
                )
        }

        let environment =
            GameEnvironment.steamac(
                identifier:
                    "steamac-\(endpoint.processId)"
            )

        var games:
            [SteamacGame] = []

        for line
            in lines.dropFirst()
        {
            if line == "steam-games-end" {
                break
            }

            let parts =
                line.split(
                    separator:
                        " ",
                    omittingEmptySubsequences:
                        true
                )

            guard parts.count == 5,
                  parts[0] == "game",
                  let appId =
                    UInt32(parts[1]),
                  let name =
                    decodeProtocolField(
                        String(parts[2])
                    ),
                  let installPath =
                    decodeProtocolField(
                        String(parts[3])
                    ),
                  let libraryPath =
                    decodeProtocolField(
                        String(parts[4])
                    )
            else {
                throw SteamacBridgeError
                    .malformedResponse(
                        line
                    )
            }

            guard installPath.hasPrefix("/"),
                  libraryPath.hasPrefix("/")
            else {
                throw SteamacBridgeError
                    .malformedResponse(
                        line
                    )
            }

            games.append(
                SteamacGame(
                    appId:
                        appId,
                    name:
                        name,
                    installPath:
                        installPath,
                    libraryPath:
                        libraryPath,
                    environment:
                        environment
                )
            )
        }

        guard games.count
                == expectedCount
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    "steam-games expected \(expectedCount) records, received \(games.count)"
                )
        }

        return games
    }


    func steamGames()
        throws -> [SteamacGame]
    {
        guard let endpoint =
                endpoints().first
        else {
            throw SteamacBridgeError
                .noRunningInstance
        }

        return try steamGames(
            endpoint:
                endpoint
        )
    }



    // MARK: - Proton environment inspection (41F-19B)

    func protonRuntime(
        for appId: UInt32,
        endpoint: SteamacBridgeEndpoint
    ) throws -> String? {
        let handshake = try handshake(endpoint: endpoint)

        guard handshake.capabilities.supports(.protonRuntimeResolution) else {
            throw SteamacBridgeError.requestFailed(
                "Steamac does not advertise Proton runtime resolution."
            )
        }

        let response = try request(
            "proton-runtime \(appId)",
            endpoint: endpoint
        )

        let parts = response.split(separator: " ")

        guard parts.count == 3,
              parts[0] == "proton-runtime",
              UInt32(parts[1]) == appId else {
            throw SteamacBridgeError.malformedResponse(response)
        }

        if parts[2] == "none" {
            return nil
        }

        guard let path = decodeProtocolField(String(parts[2])),
              path.hasPrefix("/") else {
            throw SteamacBridgeError.malformedResponse(response)
        }

        return path
    }

    // 41F-21C.9C: Static Proton layout attestation (never launch proof).
    enum ProtonRuntimeAttestationState: String {
        case verified
        case missing
        case incomplete
        case unknown
    }

    struct ProtonRuntimeAttestation {
        let appId: UInt32
        let state: ProtonRuntimeAttestationState
        let evidence: String

        var isStaticallyVerified: Bool {
            state == .verified &&
                evidence == "static-layout-only-not-launch-verified"
        }
    }

    func protonRuntimeAttestation(
        for appId: UInt32,
        endpoint: SteamacBridgeEndpoint
    ) throws -> ProtonRuntimeAttestation {
        let hello = try handshake(endpoint: endpoint)
        guard hello.capabilities.supports(.protonRuntimeAttestationV1) else {
            throw SteamacBridgeError.requestFailed(
                "Steamac does not advertise Proton runtime attestation."
            )
        }

        let response = try request("proton-attest \(appId)", endpoint: endpoint)
        let fields = response.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 4,
              fields[0] == "proton-attest",
              UInt32(fields[1]) == appId,
              let state = ProtonRuntimeAttestationState(rawValue: String(fields[2])),
              !fields[3].isEmpty,
              fields[3].utf8.count <= 512,
              fields[3].utf8.allSatisfy({ (45...57).contains($0) || (65...90).contains($0) || (95...95).contains($0) || (97...122).contains($0) })
        else {
            throw SteamacBridgeError.malformedResponse(response)
        }
        return ProtonRuntimeAttestation(
            appId: appId,
            state: state,
            evidence: String(fields[3])
        )
    }

    func protonInspection(
        for appId: UInt32,
        endpoint: SteamacBridgeEndpoint
    ) throws -> SteamacProtonInspection {
        let handshake = try handshake(endpoint: endpoint)

        guard handshake.capabilities.supports(.protonEnvironmentInspection) else {
            throw SteamacBridgeError.requestFailed(
                "Steamac does not advertise Proton environment inspection."
            )
        }

        let response = try request(
            "proton-inspect \(appId)",
            endpoint: endpoint
        )

        let parts = response.split(separator: " ")

        guard parts.count == 8,
              parts[0] == "proton-inspect",
              UInt32(parts[1]) == appId,
              let prefixPath = decodeProtocolField(String(parts[2])),
              prefixPath.hasPrefix("/"),
              let prefix = SteamacProtonComponentStatus(rawValue: String(parts[3])),
              let driveC = SteamacProtonComponentStatus(rawValue: String(parts[4])),
              let dosdevices = SteamacProtonComponentStatus(rawValue: String(parts[5])),
              let systemRegistry = SteamacProtonComponentStatus(rawValue: String(parts[6])),
              let userRegistry = SteamacProtonComponentStatus(rawValue: String(parts[7])) else {
            throw SteamacBridgeError.malformedResponse(response)
        }

        return SteamacProtonInspection(
            appId: appId,
            prefixPath: prefixPath,
            prefix: prefix,
            driveC: driveC,
            dosdevices: dosdevices,
            systemRegistry: systemRegistry,
            userRegistry: userRegistry
        )
    }

    func protonPrefix(
        for appId:
            UInt32,
        endpoint:
            SteamacBridgeEndpoint
    ) throws -> GameEnvironmentPath? {
        let handshake =
            try handshake(
                endpoint:
                    endpoint
            )

        guard handshake
                .capabilities
                .supports(
                    .protonPrefixResolution
                )
        else {
            throw SteamacBridgeError
                .requestFailed(
                    "Steamac does not advertise Proton prefix resolution."
                )
        }

        let response =
            try request(
                "proton-prefix \(appId)",
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

        guard parts.count == 3,
              parts[0] == "proton-prefix",
              UInt32(parts[1]) == appId
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    response
                )
        }

        if parts[2] == "none" {
            return nil
        }

        guard let path =
                decodeProtocolField(
                    String(parts[2])
                ),
              path.hasPrefix("/")
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    response
                )
        }

        return .guest(
            path
        )
    }


    func gameExecutables(
        for game:
            SteamacGame,
        endpoint:
            SteamacBridgeEndpoint
    ) throws -> [GameEnvironmentPath] {
        try requireGuestFileAccess(
            endpoint:
                endpoint
        )

        let lines =
            try requestLines(
                "game-executables \(encodeProtocolField(game.installPath))",
                endpoint:
                    endpoint,
                terminator:
                    "game-executables-end"
            )

        guard let header =
                lines.first
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    "<empty game-executables response>"
                )
        }

        let headerParts =
            header.split(
                separator:
                    " ",
                omittingEmptySubsequences:
                    true
            )

        guard headerParts.count == 2,
              headerParts[0] == "game-executables",
              let expectedCount =
                Int(headerParts[1]),
              expectedCount >= 0
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    header
                )
        }

        var executables:
            [GameEnvironmentPath] = []

        for line
            in lines.dropFirst()
        {
            if line
                == "game-executables-end"
            {
                break
            }

            let parts =
                line.split(
                    separator:
                        " ",
                    omittingEmptySubsequences:
                        true
                )

            guard parts.count == 2,
                  parts[0] == "executable",
                  let path =
                    decodeProtocolField(
                        String(parts[1])
                    ),
                  path.hasPrefix(
                    game.installPath + "/"
                  )
                    || path
                        == game.installPath
            else {
                throw SteamacBridgeError
                    .malformedResponse(
                        line
                    )
            }

            executables.append(
                .guest(
                    path
                )
            )
        }

        guard executables.count
                == expectedCount
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    "game-executables expected \(expectedCount) records, received \(executables.count)"
                )
        }

        return executables
    }


    /// Picks a conservative executable candidate.
    ///
    /// We intentionally do not pretend Steam manifests tell us the
    /// launch executable. Prefer a root-level EXE whose basename
    /// resembles the Steam game name; otherwise return nil when
    /// discovery is ambiguous.
    func preferredExecutable(
        for game:
            SteamacGame,
        endpoint:
            SteamacBridgeEndpoint
    ) throws -> GameEnvironmentPath? {
        let candidates =
            try gameExecutables(
                for:
                    game,
                endpoint:
                    endpoint
            )

        if candidates.count == 1 {
            return candidates[0]
        }

        let normalizedName =
            normalizeExecutableName(
                game.name
            )

        let rootCandidates =
            candidates.filter {
                guard case .guest(let path) =
                        $0
                else {
                    return false
                }

                let parent =
                    (path as NSString)
                        .deletingLastPathComponent

                return parent
                    == game.installPath
            }

        let nameMatches =
            rootCandidates.filter {
                guard case .guest(let path) =
                        $0
                else {
                    return false
                }

                let basename =
                    ((path as NSString)
                        .lastPathComponent
                        as NSString)
                        .deletingPathExtension

                return normalizeExecutableName(
                    basename
                ) == normalizedName
            }

        if nameMatches.count == 1 {
            return nameMatches[0]
        }

        if rootCandidates.count == 1 {
            return rootCandidates[0]
        }

        // Ambiguity is safer than silently installing a framework
        // beside a launcher/configuration/helper executable.
        return nil
    }


    private func normalizeExecutableName(
        _ value:
            String
    ) -> String {
        value
            .lowercased()
            .unicodeScalars
            .filter {
                CharacterSet
                    .alphanumerics
                    .contains(
                        $0
                    )
            }
            .map(
                String.init
            )
            .joined()
    }


    // MARK: - Steamac GameInstall conversion

    /// Resolves the guest executable and Proton prefix without
    /// manufacturing host filesystem paths.
    ///
    /// Returns nil when executable discovery remains ambiguous.
    func gameInstall(
        for game: SteamacGame,
        endpoint: SteamacBridgeEndpoint
    ) throws -> GameInstall? {
        guard let executable = try preferredExecutable(
            for: game,
            endpoint: endpoint
        ) else {
            return nil
        }

        guard case .guest(let executablePath) = executable else {
            throw SteamacBridgeError.malformedResponse(
                "Steamac executable unexpectedly resolved to a host path."
            )
        }

        let resolvedPrefix = try protonPrefix(
            for: game.appId,
            endpoint: endpoint
        )

        let protonPrefixPath: String?

        switch resolvedPrefix {
        case .guest(let path):
            protonPrefixPath = path

        case .host:
            throw SteamacBridgeError.malformedResponse(
                "Steamac Proton prefix unexpectedly resolved to a host path."
            )

        case nil:
            protonPrefixPath = nil
        }

        return GameInstall(
            steamacGame: game,
            executablePath: executablePath,
            protonPrefix: protonPrefixPath
        )
    }


    /// Returns only Steamac games whose Windows executable can be
    /// resolved without guessing.
    func gameInstalls(
        endpoint: SteamacBridgeEndpoint
    ) throws -> [GameInstall] {
        let games = try steamGames(
            endpoint: endpoint
        )

        return try games.compactMap { game in
            try gameInstall(
                for: game,
                endpoint: endpoint
            )
        }
    }


    // MARK: - Guest PE metadata

    func peArchitecture(
        at path: String,
        endpoint: SteamacBridgeEndpoint
    ) throws -> SteamacPEArchitecture {
        try requireGuestFileAccess(
            endpoint: endpoint
        )

        let response = try request(
            "pe-info \(encodeProtocolField(path))",
            endpoint: endpoint
        )

        let parts = response.split(
            separator: " ",
            omittingEmptySubsequences: true
        )

        guard parts.count == 2,
              parts[0] == "pe-info",
              let architecture =
                SteamacPEArchitecture(
                    rawValue: String(parts[1])
                )
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    response
                )
        }

        return architecture
    }


    func peArchitecture(
        for game: GameInstall,
        endpoint: SteamacBridgeEndpoint
    ) throws -> SteamacPEArchitecture {
        guard case .guest(let path) =
                game.environmentExecutablePath
        else {
            throw SteamacBridgeError
                .requestFailed(
                    "The requested game executable is not guest-backed."
                )
        }

        return try peArchitecture(
            at: path,
            endpoint: endpoint
        )
    }


    // 42A-20: AppID-scoped no-follow inventory. No arbitrary path argument.
    func recoveryInventory(appID: UInt32, scope: String,
                           endpoint: SteamacBridgeEndpoint) throws -> SteamacGuestRecoveryInventory {
        guard ["game", "prefix", "users", "userdata"].contains(scope),
              try handshake(endpoint: endpoint).capabilities.supports(.recoveryInventoryV1) else {
            throw SteamacBridgeError.requestFailed("Read-only recovery inventory capability unavailable")
        }
        let lines = try requestLines("recovery-inventory \(appID) \(scope)", endpoint: endpoint,
                                     terminator: "recovery-inventory-end")
        guard lines.first == "recovery-inventory-begin", lines.last == "recovery-inventory-end",
              lines.count <= 500 else { throw SteamacBridgeError.malformedResponse("Invalid inventory framing") }
        var data = Data()
        for line in lines.dropFirst().dropLast() {
            let prefix = "recovery-inventory-chunk "
            guard line.hasPrefix(prefix), let chunk = Self.decodeHexData(String(line.dropFirst(prefix.count))) else {
                throw SteamacBridgeError.malformedResponse("Invalid inventory chunk")
            }
            data.append(chunk)
            guard data.count <= 1024 * 1024 else { throw SteamacBridgeError.responseTooLarge }
        }
        return try SteamacGuestRecoveryInventory.decode(data)
    }

    // MARK: - Guest filesystem

    /// Guest-enforced atomic publication of a staged BepInEx DLL.
    /// Requires pluginCommitV1 on the guest; no fs-rename fallback.
    /// Dedicated checked publication; never falls back to generic filesystem rename.
    func commitAssetMod(appId: UInt32, adapter: String, stage: String,
                        endpoint: SteamacBridgeEndpoint) throws -> String {
        let hello = try handshake(endpoint: endpoint)
        guard hello.capabilities.supports(.assetModInstallV1) else {
            throw SteamacBridgeError.requestFailed("Update Steamac to enable checked asset-mod installation.")
        }
        let response = try request("asset-mod-install \(appId) \(encodeProtocolField(adapter)) \(encodeProtocolField(stage))", endpoint: endpoint)
        let fields = response.split(separator: " ")
        guard fields.count == 2, fields[0] == "asset-mod-installed" else {
            throw SteamacBridgeError.malformedResponse(response)
        }
        guard let root = decodeProtocolField(String(fields[1])) else { throw SteamacBridgeError.malformedResponse(response) }
        return root
    }

    func disableAssetMods(appId: UInt32, endpoint: SteamacBridgeEndpoint) throws {
        guard try handshake(endpoint: endpoint).capabilities.supports(.assetModInstallV1) else {
            throw SteamacBridgeError.requestFailed("Update Steamac to manage asset mods.")
        }
        let response = try request("asset-mod-disable \(appId)", endpoint: endpoint)
        guard response == "asset-mod-disabled" else { throw SteamacBridgeError.malformedResponse(response) }
    }

    func commitGuestPlugin(appId: UInt32, stage: String, filename: String,
                           endpoint: SteamacBridgeEndpoint) throws {
        try requireGuestFileAccess(endpoint: endpoint)
        let response = try request(
            "plugin-commit \(appId) \(encodeProtocolField(stage)) \(encodeProtocolField(filename))",
            endpoint: endpoint)
        guard response == "plugin-committed" else {
            throw SteamacBridgeError.malformedResponse(response)
        }
    }

    func guestFileInfo(
        at path:
            String,
        endpoint:
            SteamacBridgeEndpoint
    ) throws -> SteamacGuestFileInfo {
        try requireGuestFileAccess(
            endpoint:
                endpoint
        )

        let response =
            try request(
                "fs-stat \(encodeProtocolField(path))",
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

        guard parts.count == 3,
              parts[0] == "fs-stat",
              let kind =
                SteamacGuestFileKind(
                    rawValue:
                        String(parts[1])
                ),
              let size =
                UInt64(parts[2])
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    response
                )
        }

        return SteamacGuestFileInfo(
            kind:
                kind,
            size:
                size
        )
    }


    /// Reads a regular file from the Steamac guest using the
    /// bounded fs-read protocol added in 41D-1.
    ///
    /// The file is stat'ed first so the client never performs an
    /// unbounded read. Individual protocol frames remain <= 6 KiB.
    func readGuestFile(
        at path: String,
        endpoint: SteamacBridgeEndpoint,
        maximumSize: UInt64 = 1024 * 1024
    ) throws -> Data {
        try requireGuestFileAccess(
            endpoint: endpoint
        )

        let info =
            try guestFileInfo(
                at: path,
                endpoint: endpoint
            )

        guard info.kind == .file
        else {
            throw SteamacBridgeError
                .requestFailed(
                    "Guest path is not a regular file."
                )
        }

        guard info.size <= maximumSize
        else {
            throw SteamacBridgeError
                .requestFailed(
                    "Guest file exceeds the permitted read size."
                )
        }

        if info.size == 0 {
            return Data()
        }

        let chunkSize: UInt64 =
            6 * 1024

        var offset: UInt64 =
            0

        var result =
            Data()

        result.reserveCapacity(
            Int(info.size)
        )

        while offset < info.size {
            let requested =
                min(
                    chunkSize,
                    info.size - offset
                )

            let response =
                try request(
                    "fs-read \(encodeProtocolField(path)) \(offset) \(requested)",
                    endpoint: endpoint
                )

            // EOF may arrive as either:
            //
            //   fs-read 0
            //
            // or a line whose trailing empty payload was removed
            // by the socket line reader.
            let parts =
                response.split(
                    separator: " ",
                    omittingEmptySubsequences: true
                )

            guard parts.count == 2
                    || parts.count == 3,
                  parts[0] == "fs-read",
                  let received =
                    UInt64(parts[1]),
                  received <= requested
            else {
                throw SteamacBridgeError
                    .malformedResponse(
                        response
                    )
            }

            if received == 0 {
                // The stat size promised more data. Treat an early
                // EOF as a concurrent/truncated-file failure rather
                // than silently returning partial JSON.
                throw SteamacBridgeError
                    .requestFailed(
                        "Guest file ended before its reported size."
                    )
            }

            guard parts.count == 3,
                  let chunk =
                    Self.decodeHexData(
                        String(parts[2])
                    ),
                  UInt64(chunk.count) == received
            else {
                throw SteamacBridgeError
                    .malformedResponse(
                        response
                    )
            }

            result.append(
                chunk
            )

            offset +=
                received
        }

        guard UInt64(result.count) == info.size
        else {
            throw SteamacBridgeError
                .requestFailed(
                    "Guest file changed while it was being read."
                )
        }

        return result
    }


    func createGuestDirectory(
        _ path:
            String,
        endpoint:
            SteamacBridgeEndpoint
    ) throws {
        try requireGuestFileAccess(
            endpoint:
                endpoint
        )

        let response =
            try request(
                "fs-mkdir \(encodeProtocolField(path))",
                endpoint:
                    endpoint
            )

        guard response == "ok"
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    response
                )
        }
    }


    /// Atomically renames/moves one validated guest item.
    ///
    /// The guest agent independently validates both paths,
    /// refuses destination overwrite, and constrains the move
    /// to one permitted Steam filesystem root.
    func renameGuestItem(
        from source: String,
        to destination: String,
        endpoint: SteamacBridgeEndpoint
    ) throws {
        guard source.hasPrefix("/"),
              destination.hasPrefix("/"),
              !source
                .split(separator: "/")
                .contains(".."),
              !destination
                .split(separator: "/")
                .contains("..")
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    "Invalid guest rename path."
                )
        }

        guard source != destination
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    "Guest rename source and destination are identical."
                )
        }

        let encodedSource =
            encodeProtocolField(
                source
            )

        let encodedDestination =
            encodeProtocolField(
                destination
            )

        let response =
            try request(
                "fs-rename "
                    + encodedSource
                    + " "
                    + encodedDestination,
                endpoint: endpoint
            )

        guard response == "ok"
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    response
                )
        }
    }


    func removeGuestItem(
        at path:
            String,
        endpoint:
            SteamacBridgeEndpoint
    ) throws {
        try requireGuestFileAccess(
            endpoint:
                endpoint
        )

        let response =
            try request(
                "fs-remove \(encodeProtocolField(path))",
                endpoint:
                    endpoint
            )

        guard response == "ok"
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    response
                )
        }
    }


    /// Uploads a complete file into the Steamac guest.
    ///
    /// The guest protocol deliberately has no arbitrary command
    /// execution. Files are transferred in bounded binary chunks:
    /// the first frame truncates/creates, subsequent frames append.
    func writeGuestFile(
        _ data:
            Data,
        to path:
            String,
        endpoint:
            SteamacBridgeEndpoint
    ) throws {
        try requireGuestFileAccess(
            endpoint:
                endpoint
        )

        // Patch 40A permits <= 6 KiB per frame.
        let chunkSize =
            6 * 1024

        if data.isEmpty {
            let response =
                try request(
                    "fs-write \(encodeProtocolField(path)) ",
                    endpoint:
                        endpoint
                )

            guard response == "ok"
            else {
                throw SteamacBridgeError
                    .malformedResponse(
                        response
                    )
            }

            return
        }

        var offset =
            0

        var first =
            true

        while offset
                < data.count
        {
            let end =
                min(
                    offset + chunkSize,
                    data.count
                )

            let chunk =
                data[
                    offset..<end
                ]

            let verb =
                first
                ? "fs-write"
                : "fs-append"

            let response =
                try request(
                    "\(verb) \(encodeProtocolField(path)) \(hexEncode(chunk))",
                    endpoint:
                        endpoint
                )

            guard response == "ok"
            else {
                throw SteamacBridgeError
                    .malformedResponse(
                        response
                    )
            }

            first =
                false

            offset =
                end
        }
    }


    /// Recursively uploads an already-validated host
    /// directory into an allowed Steamac guest destination.
    ///
    /// This is transport, not package validation:
    /// Reloaded-II's installer validates package semantics before
    /// calling this helper.
    ///
    /// Symlinks and non-regular filesystem objects are rejected.
    func uploadGuestDirectoryTree(
        from sourceRoot: URL,
        to guestRoot: String,
        endpoint: SteamacBridgeEndpoint
    ) throws {
        let fm =
            FileManager.default

        let sourceValues =
            try sourceRoot.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey
                ]
            )

        guard sourceValues.isDirectory == true,
              sourceValues.isSymbolicLink != true
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    sourceRoot.path
                )
        }

        let canonicalRoot =
            sourceRoot
                .resolvingSymlinksInPath()
                .standardizedFileURL

        guard canonicalRoot == sourceRoot
                .standardizedFileURL
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    sourceRoot.path
                )
        }

        guard guestRoot.hasPrefix("/"),
              !guestRoot
                .split(separator: "/")
                .contains("..")
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    guestRoot
                )
        }

        try createGuestDirectory(
            guestRoot,
            endpoint: endpoint
        )

        guard let enumerator =
                fm.enumerator(
                    at: canonicalRoot,
                    includingPropertiesForKeys: [
                        .isDirectoryKey,
                        .isRegularFileKey,
                        .isSymbolicLinkKey
                    ],
                    options: [
                        .skipsHiddenFiles
                    ]
                )
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    canonicalRoot.path
                )
        }

        for case let entry as URL
            in enumerator
        {
            let values =
                try entry.resourceValues(
                    forKeys: [
                        .isDirectoryKey,
                        .isRegularFileKey,
                        .isSymbolicLinkKey
                    ]
                )

            guard values.isSymbolicLink != true
            else {
                throw SteamacBridgeError
                    .malformedResponse(
                        entry.path
                    )
            }

            let canonicalEntry =
                entry
                    .resolvingSymlinksInPath()
                    .standardizedFileURL

            guard Self.hostPath(
                canonicalEntry,
                isWithin: canonicalRoot
            )
            else {
                throw SteamacBridgeError
                    .malformedResponse(
                        entry.path
                    )
            }

            let relative =
                String(
                    canonicalEntry.path
                        .dropFirst(
                            canonicalRoot.path.count
                        )
                )
                .trimmingCharacters(
                    in: CharacterSet(
                        charactersIn: "/"
                    )
                )

            guard !relative.isEmpty
            else {
                continue
            }

            let guestPath =
                Self.joinGuestPath(
                    guestRoot,
                    relative
                )

            if values.isDirectory == true {
                try createGuestDirectory(
                    guestPath,
                    endpoint: endpoint
                )

                continue
            }

            guard values.isRegularFile == true
            else {
                throw SteamacBridgeError
                    .malformedResponse(
                        entry.path
                    )
            }

            try uploadGuestFile(
                from: canonicalEntry,
                to: guestPath,
                endpoint: endpoint
            )
        }
    }


    private static func hostPath(
        _ candidate: URL,
        isWithin root: URL
    ) -> Bool {
        let rootPath =
            root.standardizedFileURL.path

        let candidatePath =
            candidate.standardizedFileURL.path

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


    private static func joinGuestPath(
        _ root: String,
        _ relative: String
    ) -> String {
        let cleanRoot =
            root.hasSuffix("/")
            ? String(root.dropLast())
            : root

        let cleanRelative =
            relative.hasPrefix("/")
            ? String(relative.dropFirst())
            : relative

        return cleanRoot
            + "/"
            + cleanRelative
    }


    func uploadGuestFile(
        from source:
            URL,
        to guestPath:
            String,
        endpoint:
            SteamacBridgeEndpoint
    ) throws {
        let data =
            try Data(
                contentsOf:
                    source,
                options:
                    .mappedIfSafe
            )

        try writeGuestFile(
            data,
            to:
                guestPath,
            endpoint:
                endpoint
        )
    }


    private func requireGuestFileAccess(
        endpoint:
            SteamacBridgeEndpoint
    ) throws {
        let handshake =
            try handshake(
                endpoint:
                    endpoint
            )

        guard handshake
                .capabilities
                .supports(
                    .guestFileAccess
                )
        else {
            throw SteamacBridgeError
                .requestFailed(
                    "Steamac does not advertise guest file access."
                )
        }
    }


    private func encodeProtocolField(
        _ value:
            String
    ) -> String {
        var result =
            ""

        for byte
            in value.utf8
        {
            let allowed =
                (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2D
                || byte == 0x5F
                || byte == 0x2E
                || byte == 0x2F
                || byte == 0x3A

            if allowed {
                result.append(
                    Character(
                        UnicodeScalar(byte)
                    )
                )
            } else {
                result +=
                    String(
                        format:
                            "%%%02X",
                        byte
                    )
            }
        }

        return result
    }


    private func decodeProtocolField(
        _ value:
            String
    ) -> String? {
        let bytes =
            Array(
                value.utf8
            )

        var decoded:
            [UInt8] = []

        decoded.reserveCapacity(
            bytes.count
        )

        var index =
            0

        while index
                < bytes.count
        {
            if bytes[index] == 0x25 {
                guard index + 2
                        < bytes.count,
                      let high =
                        hexNibble(
                            bytes[index + 1]
                        ),
                      let low =
                        hexNibble(
                            bytes[index + 2]
                        )
                else {
                    return nil
                }

                decoded.append(
                    (high << 4) | low
                )

                index +=
                    3
            } else {
                decoded.append(
                    bytes[index]
                )

                index +=
                    1
            }
        }

        return String(
            bytes:
                decoded,
            encoding:
                .utf8
        )
    }


    private func hexNibble(
        _ byte:
            UInt8
    ) -> UInt8? {
        switch byte {
        case 0x30...0x39:
            return byte - 0x30

        case 0x41...0x46:
            return byte - 0x41 + 10

        case 0x61...0x66:
            return byte - 0x61 + 10

        default:
            return nil
        }
    }


    private static func decodeHexData(
        _ value: String
    ) -> Data? {
        let bytes =
            Array(
                value.utf8
            )

        guard bytes.count % 2 == 0
        else {
            return nil
        }

        var output =
            Data()

        output.reserveCapacity(
            bytes.count / 2
        )

        var index =
            0

        while index < bytes.count {
            guard let high =
                    hexValue(
                        bytes[index]
                    ),
                  let low =
                    hexValue(
                        bytes[index + 1]
                    )
            else {
                return nil
            }

            output.append(
                (high << 4) | low
            )

            index +=
                2
        }

        return output
    }


    private static func hexValue(
        _ byte: UInt8
    ) -> UInt8? {
        switch byte {
        case 0x30...0x39:
            return byte - 0x30

        case 0x41...0x46:
            return byte - 0x41 + 10

        case 0x61...0x66:
            return byte - 0x61 + 10

        default:
            return nil
        }
    }


    private func hexEncode(
        _ data:
            Data.SubSequence
    ) -> String {
        let alphabet =
            Array(
                "0123456789abcdef".utf8
            )

        var output =
            [UInt8]()

        output.reserveCapacity(
            data.count * 2
        )

        for byte
            in data
        {
            output.append(
                alphabet[
                    Int(byte >> 4)
                ]
            )

            output.append(
                alphabet[
                    Int(byte & 0x0F)
                ]
            )
        }

        return String(
            bytes:
                output,
            encoding:
                .ascii
        )!
    }


    /// Multi-line sibling of request().
    ///
    /// Used only by protocol commands with an explicit terminal frame,
    /// currently steam-games ... steam-games-end.
    private func requestLines(
        _ requestText:
            String,
        endpoint:
            SteamacBridgeEndpoint,
        terminator:
            String
    ) throws -> [String] {
        guard requestText.utf8.count
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
            Darwin.close(
                fd
            )
        }

        var timeout =
            timeval(
                tv_sec:
                    5,
                tv_usec:
                    0
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

        let socketBytes =
            Array(
                endpoint
                    .socketURL
                    .path
                    .utf8
            ) + [0]

        guard socketBytes.count
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

            socketBytes.withUnsafeBytes {
                source in

                destination.copyBytes(
                    from:
                        source.prefix(
                            destination.count
                        )
                )
            }
        }

        let connectionResult =
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

        guard connectionResult == 0
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
                (requestText + "\n")
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

        // Bound the entire discovery response independently from
        // the per-frame 16 KiB protocol ceiling.
        let maximumResponse =
            4 * 1024 * 1024

        var lines:
            [String] = []

        var current =
            Data()

        var totalBytes =
            0

        var byte:
            UInt8 = 0

        while totalBytes
                <= maximumResponse
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

            totalBytes +=
                count

            if totalBytes
                    > maximumResponse
            {
                throw SteamacBridgeError
                    .responseTooLarge
            }

            if byte == 0x0A {
                guard let line =
                        String(
                            data:
                                current,
                            encoding:
                                .utf8
                        )
                else {
                    throw SteamacBridgeError
                        .malformedResponse(
                            "<non-UTF8>"
                        )
                }

                if line.hasPrefix(
                    "error "
                ) {
                    throw SteamacBridgeError
                        .requestFailed(
                            String(
                                line.dropFirst(
                                    6
                                )
                            )
                        )
                }

                lines.append(
                    line
                )

                if line
                    == terminator
                {
                    return lines
                }

                current.removeAll(
                    keepingCapacity:
                        true
                )

                continue
            }

            guard current.count
                    < 16 * 1024
            else {
                throw SteamacBridgeError
                    .responseTooLarge
            }

            current.append(
                byte
            )
        }

        throw SteamacBridgeError
            .responseTooLarge
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

        // 42A-1: Reloaded-II setup can take several minutes
        // under Proton. Ordinary bridge requests retain their
        // existing five-second receive timeout.
        let receiveTimeoutSeconds: Int =
            request.hasPrefix("reloadedii-setup ")
                ? 600
                : 5

        var timeout =
            timeval(
                tv_sec: receiveTimeoutSeconds,
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

    // 41F-21B.6: Read-only guest inventory. Partial/unknown never means absent.
    enum BepInExInstallationState: String {
        case absent
        case installed
        case partial
        case unknown
    }

    struct BepInExInventory {
        let appId: UInt32
        let installation: BepInExInstallationState
        let evidence: String
    }

    func bepInExInventory(
        appId: UInt32,
        endpoint: SteamacBridgeEndpoint
    ) throws -> BepInExInventory {
        let hello = try handshake(endpoint: endpoint)
        guard hello.capabilities.supports(.bepInExInstallationInventoryV1) else {
            throw SteamacBridgeError.requestFailed(
                "Steamac does not advertise BepInEx installation inventory."
            )
        }
        let response = try request("bepinex-inventory \(appId)", endpoint: endpoint)
        let parts = response.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 4,
              parts[0] == "bepinex-inventory",
              UInt32(parts[1]) == appId,
              let state = BepInExInstallationState(rawValue: String(parts[2])),
              let evidence = decodeProtocolField(String(parts[3])),
              !evidence.isEmpty,
              evidence.utf8.count <= 512 else {
            throw SteamacBridgeError.malformedResponse(response)
        }
        return BepInExInventory(appId: appId, installation: state, evidence: evidence)
    }

    func activateBepInEx(
        appId: UInt32,
        endpoint: SteamacBridgeEndpoint
    ) throws {
        try requireGuestFileAccess(
            endpoint: endpoint
        )

        let response = try request(
            "bepinex-activate \(appId)",
            endpoint: endpoint
        )

        let parts = response.split(
            separator: " ",
            omittingEmptySubsequences: true
        )

        guard parts.count == 3,
              parts[0] == "bepinex-activated",
              parts[1] == Substring(String(appId)),
              UInt(parts[2]) != nil
        else {
            throw SteamacBridgeError.malformedResponse(
                response
            )
        }
    }

    func deactivateBepInEx(
        appId: UInt32,
        endpoint: SteamacBridgeEndpoint
    ) throws {
        try requireGuestFileAccess(
            endpoint: endpoint
        )

        let response = try request(
            "bepinex-deactivate \(appId)",
            endpoint: endpoint
        )

        let parts = response.split(
            separator: " ",
            omittingEmptySubsequences: true
        )

        guard parts.count == 3,
              parts[0] == "bepinex-deactivated",
              parts[1] == Substring(String(appId)),
              UInt(parts[2]) != nil
        else {
            throw SteamacBridgeError.malformedResponse(
                response
            )
        }
    }


    /// Executes the official Reloaded-II Setup-Linux.exe
    /// using Steamac's constrained AppID-scoped operation.
    func runReloadedIISetup(
        appId: UInt32,
        setupPath: String,
        endpoint: SteamacBridgeEndpoint
    ) throws -> Int32 {
        try requireGuestFileAccess(
            endpoint: endpoint
        )

        guard setupPath.hasPrefix("/")
        else {
            throw SteamacBridgeError.requestFailed(
                "Reloaded-II setup path is not absolute."
            )
        }

        let response = try request(
            "reloadedii-setup \(appId) \(encodeProtocolField(setupPath))",
            endpoint: endpoint
        )

        let parts = response.split(
            separator: " ",
            omittingEmptySubsequences: true
        )

        guard parts.count == 3,
              parts[0] == "reloadedii-setup-result",
              UInt32(parts[1]) == appId,
              let exitCode = Int32(parts[2])
        else {
            throw SteamacBridgeError.malformedResponse(
                response
            )
        }

        return exitCode
    }


    /// Returns only Reloaded-II ModConfig.json paths
    /// discovered by the AppID-scoped guest agent.
    ///
    /// The guest owns directory traversal and confinement.
    /// BepisLoader receives no generic directory-listing primitive.


    // MARK: - Reloaded-II metadata (41F-20C.3)

    struct ReloadedIIMetadata: Hashable {
        let modId: String
        let modName: String
        let modAuthor: String
        let modVersion: String
        let modDescription: String
        let supportedAppIds: [String]
        let isUniversalMod: Bool
    }

    enum ReloadedIIMetadataResult: Hashable {
        case parsed(ReloadedIIMetadata)
        case invalid(String)
    }

    struct ReloadedIIMetadataEntry: Hashable {
        let configPath: String
        let result: ReloadedIIMetadataResult
    }

    struct ReloadedIIMetadataInventory: Hashable {
        let appId: UInt32
        let entries: [ReloadedIIMetadataEntry]
    }

    private func decodeReloadedIIMetadata(
        _ encoded: String
    ) throws -> ReloadedIIMetadata {
        guard encoded.utf8.count <= 12 * 1024,
              let jsonText = decodeProtocolField(encoded),
              let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let modId = dictionary["ModId"] as? String,
              !modId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              modId.utf8.count <= 2048,
              let modName = dictionary["ModName"] as? String,
              let author = dictionary["ModAuthor"] as? String,
              let version = dictionary["ModVersion"] as? String,
              let description = dictionary["ModDescription"] as? String,
              let supported = dictionary["SupportedAppId"] as? [String],
              supported.count <= 128,
              let universal = dictionary["IsUniversalMod"] as? Bool
        else {
            throw SteamacBridgeError.malformedResponse(
                "invalid Reloaded-II metadata JSON"
            )
        }

        guard modName.utf8.count <= 2048,
              author.utf8.count <= 2048,
              version.utf8.count <= 2048,
              description.utf8.count <= 2048,
              supported.allSatisfy({ $0.utf8.count <= 2048 })
        else {
            throw SteamacBridgeError.malformedResponse(
                "oversized Reloaded-II metadata field"
            )
        }

        return ReloadedIIMetadata(
            modId: modId,
            modName: modName,
            modAuthor: author,
            modVersion: version,
            modDescription: description,
            supportedAppIds: supported,
            isUniversalMod: universal
        )
    }

    func reloadedIIMetadataInventory(
        appId: UInt32,
        endpoint: SteamacBridgeEndpoint
    ) throws -> ReloadedIIMetadataInventory {
        let hello = try handshake(endpoint: endpoint)

        guard hello.capabilities.supports(.reloadedIIModMetadataV1) else {
            throw SteamacBridgeError.requestFailed(
                "Steamac does not advertise Reloaded-II metadata support."
            )
        }

        let footer = "reloadedii-metadata-end \(appId)"

        let lines = try requestLines(
            "reloadedii-metadata \(appId)",
            endpoint: endpoint,
            terminator: footer
        )

        guard lines.count >= 2,
              let header = lines.first,
              lines.last == footer
        else {
            throw SteamacBridgeError.malformedResponse(
                "incomplete Reloaded-II metadata response"
            )
        }

        let headerFields = header.split(separator: " ")

        guard headerFields.count == 3,
              headerFields[0] == "reloadedii-metadata",
              headerFields[1] == Substring(String(appId)),
              let expectedCount = Int(headerFields[2]),
              (0...4096).contains(expectedCount)
        else {
            throw SteamacBridgeError.malformedResponse(header)
        }

        let payload = Array(lines.dropFirst().dropLast())

        guard payload.count == expectedCount else {
            throw SteamacBridgeError.malformedResponse(
                "Reloaded-II metadata record count mismatch"
            )
        }

        var entries: [ReloadedIIMetadataEntry] = []
        entries.reserveCapacity(expectedCount)

        var seen = Set<String>()

        for line in payload {
            guard line.utf8.count <= 16 * 1024 else {
                throw SteamacBridgeError.malformedResponse(
                    "oversized Reloaded-II metadata record"
                )
            }

            let fields = line.split(
                separator: " ",
                omittingEmptySubsequences: true
            )

            guard fields.count == 4,
                  fields[0] == "reloadedii-metadata-item",
                  let path = decodeProtocolField(String(fields[1])),
                  path.hasPrefix("/"),
                  (path as NSString).lastPathComponent
                    .caseInsensitiveCompare("ModConfig.json") == .orderedSame,
                  seen.insert(path).inserted
            else {
                throw SteamacBridgeError.malformedResponse(line)
            }

            let result: ReloadedIIMetadataResult

            switch fields[2] {
            case "parsed":
                result = .parsed(
                    try decodeReloadedIIMetadata(String(fields[3]))
                )

            case "invalid":
                guard let error = decodeProtocolField(String(fields[3])),
                      !error.isEmpty,
                      error.utf8.count <= 2048
                else {
                    throw SteamacBridgeError.malformedResponse(line)
                }

                result = .invalid(error)

            default:
                throw SteamacBridgeError.malformedResponse(line)
            }

            entries.append(
                ReloadedIIMetadataEntry(
                    configPath: path,
                    result: result
                )
            )
        }

        return ReloadedIIMetadataInventory(
            appId: appId,
            entries: entries
        )
    }

    // 41F-20B: Typed Reloaded-II inventory.
    enum ReloadedIIInstallationState: String {
        case installed
        case absent
    }

    struct ReloadedIIInventory {
        let installation: ReloadedIIInstallationState
        let modConfigPaths: [String]
    }

    func reloadedIIInventory(
        appId: UInt32,
        endpoint: SteamacBridgeEndpoint
    ) throws -> ReloadedIIInventory {
        let hello = try handshake(endpoint: endpoint)

        guard hello.capabilities.supports(.reloadedIIModInventoryV1) else {
            // Backward compatibility with older guest agents.
            let installation = try reloadedIIInstallationRoot(
                appId: appId,
                endpoint: endpoint
            )

            let paths = try reloadedIIModConfigPaths(
                appId: appId,
                endpoint: endpoint
            )

            guard installation != nil || paths.isEmpty else {
                throw SteamacBridgeError.malformedResponse(
                    "Reloaded-II mods found without installation"
                )
            }

            return ReloadedIIInventory(
                installation: installation == nil ? .absent : .installed,
                modConfigPaths: paths
            )
        }

        let lines = try requestLines(
            "reloadedii-inventory \(appId)",
            endpoint: endpoint,
            terminator: "reloadedii-inventory-end \(appId)"
        )

        guard let header = lines.first,
              let footer = lines.last,
              footer == "reloadedii-inventory-end \(appId)" else {
            throw SteamacBridgeError.malformedResponse(
                "incomplete Reloaded-II inventory"
            )
        }

        let fields = header.split(separator: " ")

        guard fields.count == 4,
              fields[0] == "reloadedii-inventory",
              fields[1] == Substring(String(appId)),
              let state = ReloadedIIInstallationState(
                  rawValue: String(fields[2])
              ),
              let count = Int(fields[3]),
              (0...4096).contains(count) else {
            throw SteamacBridgeError.malformedResponse(header)
        }

        let payload = Array(lines.dropFirst().dropLast())

        guard payload.count == count,
              state != .absent || count == 0 else {
            throw SteamacBridgeError.malformedResponse(
                "Reloaded-II inventory count/state mismatch"
            )
        }

        var paths: [String] = []
        var seen = Set<String>()

        for line in payload {
            let fields = line.split(
                separator: " ",
                maxSplits: 1
            )

            guard fields.count == 2,
                  fields[0] == "reloadedii-inventory-item",
                  let path = decodeProtocolField(String(fields[1])),
                  path.hasPrefix("/"),
                  (path as NSString).lastPathComponent
                    .caseInsensitiveCompare("ModConfig.json") == .orderedSame,
                  seen.insert(path).inserted else {
                throw SteamacBridgeError.malformedResponse(line)
            }

            paths.append(path)
        }

        return ReloadedIIInventory(
            installation: state,
            modConfigPaths: paths
        )
    }

    func reloadedIIModConfigPaths(
        appId: UInt32,
        endpoint: SteamacBridgeEndpoint
    ) throws -> [String] {
        let lines =
            try requestLines(
                "reloadedii-mods \(appId)",
                endpoint: endpoint,
                terminator:
                    "reloadedii-mods-end \(appId)"
            )

        guard let header =
                lines.first
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    "empty reloadedii-mods response"
                )
        }

        let headerParts =
            header.split(
                separator: " ",
                omittingEmptySubsequences: true
            )

        guard headerParts.count == 3,
              headerParts[0] == "reloadedii-mods",
              headerParts[1] == Substring(
                String(appId)
              ),
              let expectedCount =
                Int(headerParts[2]),
              expectedCount >= 0,
              expectedCount <= 4096
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    header
                )
        }

        guard let footer =
                lines.last,
              footer ==
                "reloadedii-mods-end \(appId)"
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    lines.last
                        ?? "missing reloadedii-mods footer"
                )
        }

        let payload =
            lines.dropFirst().dropLast()

        guard payload.count ==
                expectedCount
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    "reloadedii-mods count mismatch"
                )
        }

        var result:
            [String] = []

        result.reserveCapacity(
            expectedCount
        )

        var seen =
            Set<String>()

        for line in payload {
            let parts =
                line.split(
                    separator: " ",
                    maxSplits: 1,
                    omittingEmptySubsequences: true
                )

            guard parts.count == 2,
                  parts[0] == "reloadedii-mod",
                  let path =
                    decodeProtocolField(
                        String(parts[1])
                    ),
                  path.hasPrefix("/"),
                  (path as NSString)
                    .lastPathComponent
                    .caseInsensitiveCompare(
                        "ModConfig.json"
                    ) == .orderedSame
            else {
                throw SteamacBridgeError
                    .malformedResponse(
                        line
                    )
            }

            guard seen.insert(
                path
            ).inserted
            else {
                throw SteamacBridgeError
                    .malformedResponse(
                        "duplicate Reloaded-II mod config path"
                    )
            }

            result.append(
                path
            )
        }

        return result
    }


    func reloadedIIInstallationRoot(
        appId: UInt32,
        endpoint: SteamacBridgeEndpoint
    ) throws -> String? {
        try requireGuestFileAccess(
            endpoint: endpoint
        )

        let response =
            try request(
                "reloadedii-paths \(appId)",
                endpoint: endpoint
            )

        let parts =
            response.split(
                separator: " ",
                omittingEmptySubsequences: true
            )

        guard parts.count == 3,
              parts[0] == "reloadedii-paths",
              parts[1] == Substring(String(appId))
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    response
                )
        }

        if parts[2] == "none" {
            return nil
        }

        guard let root =
            decodeProtocolField(
                String(parts[2])
            ),
              !root.isEmpty,
              root.hasPrefix("/")
        else {
            throw SteamacBridgeError
                .malformedResponse(
                    response
                )
        }

        return root
    }


    // 41F-15: explicit fail-closed guest launch reservation/status API.
    // `blockedUnverified` is NOT a successful launch or injection attestation.
    enum ModLaunchProtocolState: String {
        case notRequested = "not-requested"
        case blockedUnverified = "blocked-unverified"
    }

    func modLaunchState(
        appId: UInt32,
        requestID: UUID,
        endpoint: SteamacBridgeEndpoint
    ) throws -> ModLaunchProtocolState {
        try modLaunchCommand(
            "mod-launch-status", appId: appId,
            requestID: requestID, endpoint: endpoint
        )
    }

    func reserveModLaunch(
        appId: UInt32,
        requestID: UUID,
        endpoint: SteamacBridgeEndpoint
    ) throws -> ModLaunchProtocolState {
        try modLaunchCommand(
            "mod-launch-request", appId: appId,
            requestID: requestID, endpoint: endpoint
        )
    }

    private func modLaunchCommand(
        _ command: String,
        appId: UInt32,
        requestID: UUID,
        endpoint: SteamacBridgeEndpoint
    ) throws -> ModLaunchProtocolState {
        let token = requestID.uuidString.lowercased()
        let response = try request(
            "\(command) \(appId) \(token)", endpoint: endpoint
        )
        let fields = response.split(separator: " ")
        guard fields.count == 4,
              fields[0] == Substring(command),
              fields[1] == Substring(String(appId)),
              fields[2] == Substring(token),
              let state = ModLaunchProtocolState(rawValue: String(fields[3]))
        else {
            throw SteamacBridgeError.malformedResponse(response)
        }
        return state
    }

}
