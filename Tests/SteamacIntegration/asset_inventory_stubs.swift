import Foundation
extension Bundle { static var module: Bundle { .main } }
struct SteamacGame { let appId: UInt32; let installPath: String; var name: String { "Fixture" } }
struct SteamacBridgeEndpoint {}
struct GameInstall {}
enum Architecture { case x64, x86 }
enum Capability { case assetModInstallV1, assetModProfilesV1, assetMbeTablesV1, assetAudioBanksV1 }
struct Capabilities { var enabled: Bool; func supports(_ c: Capability) -> Bool { enabled } }
struct Hello { let capabilities: Capabilities }
final class SteamacBridge {
    static let shared = SteamacBridge()
    var reads: [String] = []; var fixtures: [String: Data] = [:]
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
    func readGuestFile(at path: String, endpoint: SteamacBridgeEndpoint, maximumSize: UInt64) throws -> Data { reads.append(path); guard let data = fixtures[path], data.count <= maximumSize else { throw AssetModPackage.failure("missing fixture") }; return data }
    func setAssetModEnabled(appId: UInt32, assetRoot: String?, endpoint: SteamacBridgeEndpoint) throws { calls.append("activate"); if activationFails { throw AssetModPackage.failure("activation blocked") } }
}
