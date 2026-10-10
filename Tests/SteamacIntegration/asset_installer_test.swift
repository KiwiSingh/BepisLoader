import Foundation
extension Bundle { static var module: Bundle { .main } }
struct SteamacGame { let appId: UInt32; let installPath: String; var name: String { "Fixture" } }
struct SteamacBridgeEndpoint {}
struct GameInstall {}
enum Architecture { case x64, x86 }
enum Capability { case assetModInstallV1, assetModProfilesV1, assetMbeTablesV1 }
struct Capabilities { var enabled: Bool; func supports(_ c: Capability) -> Bool { enabled } }
struct Hello { let capabilities: Capabilities }
final class SteamacBridge {
    static let shared = SteamacBridge()
    var supported = true, installed = true, runtime = true, activationFails = false
    var architecture = Architecture.x64
    var calls: [String] = []; var uploaded: [String: Data] = [:]
    func handshake(endpoint: SteamacBridgeEndpoint) throws -> Hello { calls.append("hello"); return Hello(capabilities: Capabilities(enabled: supported)) }
    func gameInstall(for game: SteamacGame, endpoint: SteamacBridgeEndpoint) throws -> GameInstall? { calls.append("game"); return installed ? GameInstall() : nil }
    func peArchitecture(for install: GameInstall, endpoint: SteamacBridgeEndpoint) throws -> Architecture { calls.append("pe"); return architecture }
    func protonRuntime(for appId: UInt32, endpoint: SteamacBridgeEndpoint) throws -> String? { calls.append("runtime"); return runtime ? "/proton" : nil }
    func createGuestDirectory(_ path: String, endpoint: SteamacBridgeEndpoint) throws { calls.append("mkdir") }
    func writeGuestFile(_ data: Data, to path: String, endpoint: SteamacBridgeEndpoint) throws { calls.append("upload"); uploaded[path] = data }
    func commitAssetMod(appId: UInt32, adapter: String, stage: String, endpoint: SteamacBridgeEndpoint) throws -> String { calls.append("commit"); return stage.replacingOccurrences(of: ".bepis-asset-stage-", with: ".bepis-asset-mod-") + "/assets" }
    func publishAssetProfile(appId: UInt32, adapter: String, stage: String, endpoint: SteamacBridgeEndpoint) throws -> String { calls.append("profile"); return "/game/.bepis-assets-active" }
    func assetProfileState(appId: UInt32, endpoint: SteamacBridgeEndpoint) throws -> Data { return Data("{\"schema\":1,\"baseRoot\":\"\",\"mods\":[]}".utf8) }
    func readGuestFile(at path: String, endpoint: SteamacBridgeEndpoint, maximumSize: UInt64) throws -> Data { return Data() }
    func setAssetModEnabled(appId: UInt32, assetRoot: String?, endpoint: SteamacBridgeEndpoint) throws { calls.append("activate"); if activationFails { throw AssetModPackage.failure("activation blocked") } }
}
@main struct AssetInstallerTests {
    static func main() throws {
        let payload = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BEPIS_TEST_PAYLOADS"]!)
        let package = AssetModPackage(adapter: AssetModAdapter.supported[0], name: "Eyes", files: ["app_0/images/pc002a_b01l_01.img": Data([1,2,3])])
        let game = SteamacGame(appId: 1984270, installPath: "/game"), endpoint = SteamacBridgeEndpoint()
        let good = SteamacBridge()
        let report = try SteamacAssetModInstaller.install(package, game: game, endpoint: endpoint, bridge: good, payloadRoot: payload)
        precondition(report.contains("One-time setup") && good.calls.last == "commit")
        precondition(good.calls.firstIndex(of: "commit")! > good.calls.lastIndex(of: "upload")!)
        precondition(good.uploaded.count == 4)
        precondition(good.uploaded.first(where: { $0.key.hasSuffix("/assets/app_0/images/pc002a_b01l_01.img") })?.value == Data([1,2,3]))
        for failure in 0..<4 {
            let b = SteamacBridge()
            if failure == 0 { b.supported = false }; if failure == 1 { b.installed = false }; if failure == 2 { b.architecture = .x86 }; if failure == 3 { b.runtime = false }
            do { _ = try SteamacAssetModInstaller.install(package, game: game, endpoint: endpoint, bridge: b, payloadRoot: payload); fatalError("Accepted unsupported configuration") } catch {}
            precondition(!b.calls.contains("mkdir") && !b.calls.contains("upload"))
        }
        let profileBridge = SteamacBridge()
        _ = try SteamacAssetModInstaller.publish(package, game: game, endpoint: endpoint, bridge: profileBridge, payloadRoot: payload, profile: Data("{}".utf8))
        precondition(profileBridge.calls.last == "profile")
        precondition(profileBridge.uploaded.keys.contains(where: { $0.hasSuffix("/profile.json") }))
        print("PASS: checked payloads, uploads precede guest commit, manual launch setting returned, capability/game/ABI/runtime rejection before mutation")
    }
}
