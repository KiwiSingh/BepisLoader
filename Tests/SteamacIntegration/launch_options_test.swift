import Foundation
@main struct LaunchOptionsTests {
    static func main() throws {
        let combined = try SteamacLaunchOptions.make(assetRoot: "/game's/.bepis-assets-active", executableHash: "abc", reshade: true, existingOverrides: "dinput8=n,b;winmm=b;dxgi=b;version=n,b")
        precondition(combined.contains("winmm=n,b;dxgi=n,b;d3dcompiler_47=n,b"))
        precondition(combined.contains("dinput8=n,b") && combined.contains("version=n,b"))
        precondition(combined.components(separatedBy: "WINEDLLOVERRIDES=").count == 2)
        precondition(combined.hasSuffix("%command%"))
        precondition(combined.contains("game'\"'\"'s"))
        let standalone = try SteamacLaunchOptions.make(reshade: true)
        precondition(standalone == "WINEDLLOVERRIDES='dxgi=n,b;d3dcompiler_47=n,b' %command%")
        let assetOnly = try SteamacLaunchOptions.make(assetRoot: "/game/assets", executableHash: "abc")
        precondition(!assetOnly.contains("dxgi=") && assetOnly.contains("winmm=n,b"))
        let grouped = try SteamacLaunchOptions.make(reshade: true, existingOverrides: "dxgi,dinput8=b;dinput8=n,b")
        precondition(grouped.contains("dinput8=n,b;dxgi=n,b"))
        for invalid in ["WINEDLLOVERRIDES='dxgi=n,b'", "dxgi=n,b %command%", "dxgi=n,b;$(bad)=n", "dxgi=x", "=n"] {
            do { _ = try SteamacLaunchOptions.make(existingOverrides: invalid); fatalError("Accepted malformed input") } catch {}
        }
        print("PASS: ReShade plus loaders, single assignment, compiler override, grouped overrides, shell quoting, malformed input rejected")
    }
}
