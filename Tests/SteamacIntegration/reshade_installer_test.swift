import Foundation
struct SteamacGame { let appId: UInt32; let installPath: String; let name: String }
struct SteamacBridgeEndpoint {}
enum Architecture { case x64, x86 }
enum GameEnvironmentPath { case guest(String), local(URL) }
struct GameInstall { let environmentExecutablePath: GameEnvironmentPath }
enum Capability { case reShadeInstallV1 }
struct Capabilities { var enabled: Bool; func supports(_ c: Capability) -> Bool { enabled } }
struct Hello { let capabilities: Capabilities }
struct AssetModAdapter { let executableSHA256: String; static func forGame(_ id: UInt32) -> AssetModAdapter? { id == 1984270 ? AssetModAdapter(executableSHA256: "abc") : nil } }
struct AssetModProfiles { let baseRoot: String; static func load(game: SteamacGame, endpoint: SteamacBridgeEndpoint, bridge: SteamacBridge) throws -> AssetModProfiles { AssetModProfiles(baseRoot: bridge.active ? "/profile" : "") } }
final class SteamacBridge {
    static let shared = SteamacBridge()
    var supported = true, installed = true, runtime = true, active = true, failCommit = false
    var runtimeHash: String? = "existing-runtime-hash"
    var architecture = Architecture.x64
    var calls: [String] = []; var uploaded: [String: Data] = [:]
    func handshake(endpoint: SteamacBridgeEndpoint) throws -> Hello { calls.append("hello"); return Hello(capabilities: Capabilities(enabled: supported)) }
    func gameInstall(for game: SteamacGame, endpoint: SteamacBridgeEndpoint) throws -> GameInstall? { calls.append("game"); return installed ? GameInstall(environmentExecutablePath: .guest(game.installPath + "/game.exe")) : nil }
    func peArchitecture(for install: GameInstall, endpoint: SteamacBridgeEndpoint) throws -> Architecture { architecture }
    func protonRuntime(for appId: UInt32, endpoint: SteamacBridgeEndpoint) throws -> String? { runtime ? "/proton" : nil }
    func existingReShadeRuntime(appId: UInt32, executable: String, endpoint: SteamacBridgeEndpoint) throws -> String? { runtimeHash }
    func reShadeTarget(appId: UInt32, executable: String, endpoint: SteamacBridgeEndpoint) throws -> (directory: String, executableHash: String) { calls.append("target"); return ((executable as NSString).deletingLastPathComponent, String(repeating: "a", count: 64)) }
    func createGuestDirectory(_ path: String, endpoint: SteamacBridgeEndpoint) throws { calls.append("mkdir") }
    func writeGuestFile(_ data: Data, to path: String, endpoint: SteamacBridgeEndpoint) throws { calls.append("write"); uploaded[path] = data }
    func commitReShade(appId: UInt32, stage: String, endpoint: SteamacBridgeEndpoint) throws { calls.append("commit"); if failCommit { throw ReShadePackage.failure("game-running-close-it-first") } }
}
@main struct InstallerTests {
    static func main() throws {
        var package = ReShadePackage(files: ["ReShade.ini": Data("[GENERAL]".utf8), "preset.ini": Data("Techniques=A".utf8), "d3dcompiler_47.dll": Data("fixture".utf8)], name: "Preset", presets: ["preset.ini"])
        let game = SteamacGame(appId: 1984270, installPath: "/games/Game", name: "Game"), endpoint = SteamacBridgeEndpoint()
        let bridge = SteamacBridge()
        let report = try SteamacReShadeInstaller.install(package, game: game, endpoint: endpoint, bridge: bridge, existingOverrides: "dinput8=n,b")
        precondition(report.contains("winmm=n,b;dxgi=n,b;d3dcompiler_47=n,b"))
        precondition(report.contains("dinput8=n,b") && report.contains(".bepis-assets-active"))
        precondition(bridge.calls.last == "commit" && bridge.uploaded.keys.allSatisfy { $0.contains("/.bepis-reshade-stage-") })
        let manifest = bridge.uploaded.first { $0.key.hasSuffix("manifest.json") }!.value
        let json = try JSONSerialization.jsonObject(with: manifest) as! [String: Any]
        precondition(json["appId"] as! Int == 1984270 && json["executable"] as! String == "/games/Game/game.exe")
        for change in 0..<4 {
            let b = SteamacBridge()
            switch change { case 0: b.supported = false; case 1: b.installed = false; case 2: b.architecture = .x86; default: b.runtime = false }
            do { _ = try SteamacReShadeInstaller.install(package, game: game, endpoint: endpoint, bridge: b); fatalError("accepted failed preflight") } catch {}
            precondition(!b.calls.contains("mkdir") && !b.calls.contains("write"))
        }
        let malformed = SteamacBridge()
        do { _ = try SteamacReShadeInstaller.install(package, game: game, endpoint: endpoint, bridge: malformed, existingOverrides: "bad=value"); fatalError("accepted malformed override") } catch {}
        precondition(!malformed.calls.contains("write"))
        let failing = SteamacBridge(); failing.failCommit = true
        do { _ = try SteamacReShadeInstaller.install(package, game: game, endpoint: endpoint, bridge: failing); fatalError("accepted failed commit") } catch { precondition(error.localizedDescription.contains("game-running")) }
        let standalone = SteamacBridge(); standalone.active = false
        package.files["extra.ini"] = Data("other preset".utf8)
        let plain = try SteamacReShadeInstaller.install(package, game: SteamacGame(appId: 7, installPath: "/games/Other", name: "Other"), endpoint: endpoint, bridge: standalone)
        precondition(!plain.contains("winmm=n,b") && !plain.contains("BEPIS_MVGL"))
        if ProcessInfo.processInfo.environment["BEPIS_TEST_DOWNLOAD_COMPILER"] == "1" {
            let compiler = try SteamacReShadeInstaller.shaderCompiler()
            precondition(ReShadePackage.hash(compiler) == ReShadePackage.compilerHash && ReShadePackage.isX64DLL(compiler))
            let automatic = SteamacBridge(); automatic.runtimeHash = nil; automatic.active = false
            let setup = try SteamacReShadeInstaller.setupPackage()
            _ = try SteamacReShadeInstaller.install(setup, game: SteamacGame(appId: 7, installPath: "/games/Other", name: "Other"), endpoint: endpoint, bridge: automatic)
            let uploadedRuntime = automatic.uploaded.first { $0.key.hasSuffix("/dxgi.dll") }!.value
            precondition(ReShadePackage.hash(uploadedRuntime) == SteamacReShadeInstaller.runtimeHashes[false])
            precondition(automatic.uploaded.keys.contains { $0.hasSuffix("/d3dcompiler_47.dll") })
            print("PASS: fresh-game automatic setup supplies official x64 runtime, compiler and default configuration")
            for addons in [false, true] {
                let runtime = try SteamacReShadeInstaller.officialRuntime(addons: addons)
                precondition(ReShadePackage.hash(runtime) == SteamacReShadeInstaller.runtimeHashes[addons])
            }
            print("PASS: pinned official ReShade standard/addon downloads and embedded x64 runtime extraction")
            print("PASS: pinned Microsoft SDK download, CAB extraction and native x64 shader compiler integrity")
        }
        print("PASS: capability/architecture/Proton preflight, staged-only upload, checked commit, combined launch options, guest rejection and game-agnostic preset installation")
    }
}
