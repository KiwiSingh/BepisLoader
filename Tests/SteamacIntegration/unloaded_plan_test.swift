import Foundation

// Minimal bridge double for the read-only integration. The app build separately
// type-checks against the real bridge; this verifies policy and call ordering.
struct SteamacGame { let appId: UInt32 }
struct SteamacBridgeEndpoint {}
struct GameInstall {}
enum SteamacPEArchitecture { case x64, x86, unknown }
enum SteamacBridgeError: Error { case requestFailed(String) }
final class SteamacBridge {
    static let shared = SteamacBridge()
    var calls: [String] = []
    var connected = true
    var detected = true
    var architecture = SteamacPEArchitecture.x64
    var runtime: String? = "/proton"
    enum State { case installed, absent }
    struct Inventory { let installation: State }
    func handshake(endpoint: SteamacBridgeEndpoint) throws {
        calls.append("hello")
        if !connected { throw SteamacBridgeError.requestFailed("bad handshake") }
    }
    func gameInstall(for game: SteamacGame, endpoint: SteamacBridgeEndpoint) throws -> GameInstall? {
        calls.append("game"); return detected ? GameInstall() : nil
    }
    func peArchitecture(for game: GameInstall, endpoint: SteamacBridgeEndpoint) throws -> SteamacPEArchitecture {
        calls.append("pe"); return architecture
    }
    func protonRuntime(for appId: UInt32, endpoint: SteamacBridgeEndpoint) throws -> String? {
        calls.append("proton"); return runtime
    }
    func reloadedIIInventory(appId: UInt32, endpoint: SteamacBridgeEndpoint) throws -> Inventory {
        calls.append("inventory"); return Inventory(installation: .installed)
    }
}

@main struct UnloadedPlanTests {
    static func main() throws {
        let game = SteamacGame(appId: 1984270), endpoint = SteamacBridgeEndpoint()
        let valid = SteamacBridge()
        let plan = try SteamacUnloadedIIPlan.inspect(game: game, endpoint: endpoint, bridge: valid)
        precondition(plan.payloadRID == "win-x64" && plan.coordinatorRID == "linux-arm64")
        precondition(plan.installed && !plan.canLaunchModded)
        precondition(valid.calls == ["hello", "game", "pe", "proton", "inventory"])
        for failure in 0..<4 {
            let bridge = SteamacBridge()
            switch failure {
            case 0: bridge.connected = false
            case 1: bridge.detected = false
            case 2: bridge.architecture = .unknown
            default: bridge.runtime = nil
            }
            do {
                _ = try SteamacUnloadedIIPlan.inspect(game: game, endpoint: endpoint, bridge: bridge)
                fatalError("Invalid preflight accepted")
            } catch { precondition(!bridge.calls.contains("inventory")) }
        }
        let unsupported = SteamacBridge()
        do {
            _ = try SteamacUnloadedIIPlan.inspect(game: SteamacGame(appId: 1), endpoint: endpoint, bridge: unsupported)
            fatalError("Unsupported game accepted")
        } catch { precondition(unsupported.calls.isEmpty) }
        print("6 Unloaded-II policy cases passed; no launch API used")
    }
}
