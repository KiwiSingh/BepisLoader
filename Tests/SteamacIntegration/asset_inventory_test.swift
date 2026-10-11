import Foundation
@main struct AssetInventoryTests {
    static func main() throws {
        let bridge = SteamacBridge()
        let game = SteamacGame(appId: 1984270, installPath: "/game")
        let root = "/game/.bepis-asset-mod-abcd/assets"
        let profile = AssetModProfile(mods: [.init(id: "abcd", name: "Fixture", root: root, enabled: true)])
        let payload = Data([1, 2, 3])
        let keys = (0..<2000).map { "images/asset\($0).img" }
        bridge.fixtures[String(root.dropLast(7)) + "/manifest.json"] = try JSONSerialization.data(withJSONObject: ["adapter": "dsts-mvgl-v1", "schema": 1, "files": Dictionary(uniqueKeysWithValues: keys.map { ($0, AssetModPackage.hash(payload)) })])
        let inventory = try AssetModProfiles.packages(profile, game: game, endpoint: SteamacBridgeEndpoint(), bridge: bridge, metadataOnly: true)
        precondition(bridge.reads.count == 1 && bridge.reads[0].hasSuffix("/manifest.json"))
        precondition(inventory["abcd"]!.files.count == 2000)
        bridge.reads = []
        _ = try AssetModProfiles.packagesForApply(profile, game: game, endpoint: SteamacBridgeEndpoint(), bridge: bridge)
        precondition(bridge.reads.count == 1 && bridge.reads[0].hasSuffix("/manifest.json"))
        for key in keys { bridge.fixtures[root + "/" + key] = payload }
        bridge.reads = []
        let verified = try AssetModProfiles.packages(profile, game: game, endpoint: SteamacBridgeEndpoint(), bridge: bridge)
        precondition(bridge.reads.count == 2001 && verified["abcd"]!.totalBytes == 6000)
        bridge.reads = []; bridge.reuseSupported = false
        _ = try AssetModProfiles.packagesForApply(profile, game: game, endpoint: SteamacBridgeEndpoint(), bridge: bridge)
        precondition(bridge.reads.count == 2001)
        bridge.fixtures[root + "/" + keys[0]] = Data([9])
        do {
            _ = try AssetModProfiles.packages(profile, game: game, endpoint: SteamacBridgeEndpoint(), bridge: bridge)
            fatalError("Tampered payload accepted")
        } catch {}
        bridge.fixtures[String(root.dropLast(7)) + "/manifest.json"] = Data("broken json".utf8)
        do {
            _ = try AssetModProfiles.packages(profile, game: game, endpoint: SteamacBridgeEndpoint(), bridge: bridge, metadataOnly: true)
            fatalError("Corrupt manifest accepted")
        } catch {}
        print("PASS: 2000 assets require one inventory/apply manifest read with reuse; older guest fallback fetches payloads; tampering/corrupt JSON rejected")
    }
}
