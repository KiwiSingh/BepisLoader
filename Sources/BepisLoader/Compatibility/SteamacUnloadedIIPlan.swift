import Foundation

/// Unloaded-II is a Windows x64 in-process loader, even when SteamOS is ARM64.
/// This read-only integration uses the existing bepis.sock protocol and never
/// equates installed files, a runtime path, or a prepared CLI plan with launch proof.
struct SteamacUnloadedIIPlan {
    let payloadRID: String
    let coordinatorRID: String
    let installed: Bool
    let canLaunchModded: Bool
    let reason: String

    static func inspect(game: SteamacGame, endpoint: SteamacBridgeEndpoint,
                        bridge: SteamacBridge = .shared) throws -> SteamacUnloadedIIPlan {
        guard game.appId == 1984270 else {
            throw SteamacBridgeError.requestFailed("This Unloaded-II integration currently targets Digimon Story Time Stranger.")
        }
        _ = try bridge.handshake(endpoint: endpoint)
        guard let install = try bridge.gameInstall(for: game, endpoint: endpoint),
              try bridge.peArchitecture(for: install, endpoint: endpoint) == .x64 else {
            throw SteamacBridgeError.requestFailed("Unloaded-II requires a detected Windows x64 game executable.")
        }
        guard try bridge.protonRuntime(for: game.appId, endpoint: endpoint) != nil else {
            throw SteamacBridgeError.requestFailed("No selected Proton runtime was resolved for this game.")
        }
        let inventory = try bridge.reloadedIIInventory(appId: game.appId, endpoint: endpoint)
        return SteamacUnloadedIIPlan(payloadRID: "win-x64", coordinatorRID: "linux-arm64",
            installed: inventory.installation == .installed, canLaunchModded: false,
            reason: "Unloaded-II preparation uses an ARM64 Linux coordinator and Windows x64 game loaders. An asset-only native ASI is also being tested to bypass .NET for loose MVGL assets. The current bridge does not attest .NET hosting or native asset injection. Modded launch remains blocked; installation inventory is not runtime proof.")
    }

    var report: String {
        "Digimon Unloaded-II: host tool \(coordinatorRID), game payload \(payloadRID). Reloaded inventory: \(installed ? "installed" : "absent").\n\(reason)"
    }
}
