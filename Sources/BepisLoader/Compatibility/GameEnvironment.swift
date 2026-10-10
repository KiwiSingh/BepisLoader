import Foundation

// ─────────────────────────────────────────────
//  Game Environment
//
//  A game environment describes WHERE a Windows
//  game lives independently from WHICH modding
//  framework is installed.
//
//  Existing Wine-style environments are directly
//  accessible from the macOS host.
//
//  VM-backed environments such as Steamac may
//  expose paths that exist only inside a guest.
// ─────────────────────────────────────────────

enum GameEnvironmentKind:
    String,
    Codable,
    CaseIterable,
    Hashable
{
    case localWine =
        "Local Wine"

    case steamac =
        "Steamac"
}


/// Describes how BepisLoader can access a game's
/// files.
///
/// Patch 36 intentionally implements only the local
/// case. `guest` establishes the model boundary that
/// the Steamac bridge will implement in later patches.
enum GameFilesystemAccess:
    Hashable,
    Codable
{
    case local
    case guest(
        environmentId: String
    )

    var isHostAccessible:
        Bool
    {
        switch self {
        case .local:
            return true

        case .guest:
            return false
        }
    }
}


/// A path whose namespace is explicit.
///
/// Do NOT turn `.guest` into a file URL. Guest paths
/// are opaque to FileManager on macOS and must later
/// be accessed through the environment bridge.
enum GameEnvironmentPath:
    Hashable,
    Codable
{
    case host(URL)
    case guest(String)

    var hostURL:
        URL?
    {
        guard case .host(
            let url
        ) = self
        else {
            return nil
        }

        return url
    }

    var guestPath:
        String?
    {
        guard case .guest(
            let path
        ) = self
        else {
            return nil
        }

        return path
    }
}


/// Stable description of the runtime containing a
/// game.
///
/// `identifier` is deliberately implementation-neutral.
/// For Steamac it can later identify a particular VM
/// installation without coupling BepisLoader's core
/// model to fxgl/steamac or KiwiSingh/steamac.
struct GameEnvironment:
    Hashable,
    Codable
{
    let kind:
        GameEnvironmentKind

    let identifier:
        String

    let filesystem:
        GameFilesystemAccess

    static func localWine(
        bottle: Bottle
    ) -> GameEnvironment {
        GameEnvironment(
            kind:
                .localWine,
            identifier:
                bottle.id.uuidString,
            filesystem:
                .local
        )
    }

    static func steamac(
        identifier: String
    ) -> GameEnvironment {
        GameEnvironment(
            kind:
                .steamac,
            identifier:
                identifier,
            filesystem:
                .guest(
                    environmentId:
                        identifier
                )
        )
    }

    var isHostAccessible:
        Bool
    {
        filesystem.isHostAccessible
    }
}


// ─────────────────────────────────────────────
//  Environment capabilities
//
//  Steamac integration will negotiate these rather
//  than checking which fork happens to be running.
//  KiwiSingh/steamac and upstream Steamac can
//  therefore implement the same bridge contract.
// ─────────────────────────────────────────────

enum GameEnvironmentCapability:
    String,
    Codable,
    CaseIterable,
    Hashable
{
    case recoveryInventoryV1
    case guestFileAccess
    case guestCommandExecution
    case steamLibraryDiscovery
    case protonRuntimeResolution
    case protonPrefixResolution
    case protonEnvironmentInspection
    case protonRuntimeAttestationV1
    case assetModProfilesV1
    case assetAudioBanksV1
    case assetMbeTablesV1
    case assetModInstallV1
    case bepInExInstallationInventoryV1
    case reloadedIIModInventoryV1
    case reloadedIIModMetadataV1
}


struct GameEnvironmentCapabilities:
    Hashable,
    Codable
{
    var protocolVersion:
        Int

    var capabilities:
        Set<GameEnvironmentCapability>

    init(
        protocolVersion: Int,
        capabilities:
            Set<GameEnvironmentCapability>
    ) {
        self.protocolVersion =
            protocolVersion

        self.capabilities =
            capabilities
    }

    func supports(
        _ capability:
            GameEnvironmentCapability
    ) -> Bool {
        capabilities.contains(
            capability
        )
    }
}
