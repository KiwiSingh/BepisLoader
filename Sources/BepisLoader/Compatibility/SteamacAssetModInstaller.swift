import Foundation

/// Shared asset-mod entry point, with game-specific adapters behind it.
struct SteamacAssetModInstaller {
    static let payloadHashes = [
        "bepis-mvgl.asi": "d6e2e91f7bafd4caae6e47806a0d6557af571daaca3a2d2adb203be70e78083b",
        "winmm.dll": "412d410eb6091fb483b150bea1b13f8aeb746be8c62802ea7e081fd15ea64b69"]
    static func install(_ package: AssetModPackage, game: SteamacGame,
                        endpoint: SteamacBridgeEndpoint, bridge: SteamacBridge = .shared, payloadRoot: URL? = nil) throws -> String {
        let root = try publish(package, game: game, endpoint: endpoint, bridge: bridge, payloadRoot: payloadRoot)
        return launchReport(package, game: game, root: root)
    }
    static func publish(_ package: AssetModPackage, game: SteamacGame, endpoint: SteamacBridgeEndpoint,
                        bridge: SteamacBridge = .shared, payloadRoot: URL? = nil, profile: Data? = nil) throws -> String {
        guard game.appId == package.adapter.appId else {
            throw AssetModPackage.failure("This asset adapter does not support the selected game.")
        }
        guard try bridge.handshake(endpoint: endpoint).capabilities.supports(.assetModInstallV1) else {
            throw AssetModPackage.failure("The running SteamOS guest agent lacks assetModInstallV1. Update Steamac to Kiwi Build 5 and restart the VM using its bundled guest layer. If it is already updated, check for an older fx-bepis-agent service override.")
        }
        if profile != nil {
            guard try bridge.handshake(endpoint: endpoint).capabilities.supports(.assetModProfilesV1) else {
                throw AssetModPackage.failure("The running guest does not support combined asset profiles. Update Steamac and restart the VM.")
            }
        }
        guard let install = try bridge.gameInstall(for: game, endpoint: endpoint) else {
            throw AssetModPackage.failure("The selected game's executable could not be found.")
        }
        guard try bridge.peArchitecture(for: install, endpoint: endpoint) == .x64 else {
            throw AssetModPackage.failure("This asset adapter requires a Windows x64 game executable.")
        }
        guard try bridge.protonRuntime(for: game.appId, endpoint: endpoint) != nil else {
            throw AssetModPackage.failure("No Proton runtime is selected for this game. Select one in Steam's Compatibility settings and refresh the library.")
        }
        guard let resources = payloadRoot ?? Bundle.module.url(forResource: package.adapter.id, withExtension: nil, subdirectory: "AssetAdapters") else {
            throw AssetModPackage.failure("The bundled asset adapter is missing.")
        }
        var payloads: [String: Data] = [:]
        for (file, expected) in payloadHashes {
            let data = try Data(contentsOf: resources.appendingPathComponent(file))
            guard AssetModPackage.hash(data) == expected else { throw AssetModPackage.failure("The bundled asset adapter failed its integrity check.") }
            payloads[file] = data
        }
        let identifier = UUID().uuidString.lowercased()
        let stage = game.installPath + "/.bepis-asset-stage-" + identifier
        try bridge.createGuestDirectory(stage, endpoint: endpoint)
        try bridge.createGuestDirectory(stage + "/assets", endpoint: endpoint)
        // Retain failed staging for review; never clean up an unknown guest path.
        for (key, data) in package.files.sorted(by: { $0.key < $1.key }) {
            let destination = stage + "/assets/" + key
            try bridge.createGuestDirectory((destination as NSString).deletingLastPathComponent, endpoint: endpoint)
            try bridge.writeGuestFile(data, to: destination, endpoint: endpoint)
        }
        for (key, data) in payloads { try bridge.writeGuestFile(data, to: stage + "/" + (key == "bepis-mvgl.asi" ? "adapter.payload" : "proxy.payload"), endpoint: endpoint) }
        try bridge.writeGuestFile(try package.manifest, to: stage + "/manifest.json", endpoint: endpoint)
        let root: String
        if let profile {
            try bridge.writeGuestFile(profile, to: stage + "/profile.json", endpoint: endpoint)
            root = try bridge.publishAssetProfile(appId: game.appId, adapter: package.adapter.id, stage: stage, endpoint: endpoint)
        } else {
            root = try bridge.commitAssetMod(appId: game.appId, adapter: package.adapter.id, stage: stage, endpoint: endpoint)
        }
        guard root == (profile == nil ? game.installPath + "/.bepis-asset-mod-" + identifier + "/assets" : game.installPath + "/.bepis-assets-active") else { throw AssetModPackage.failure("Guest publication returned an unexpected asset path; installation retained for review.") }
        return root
    }
    static func launchReport(_ package: AssetModPackage, game: SteamacGame, root: String) -> String {
        let windowsRoot = "Z:" + root
        let quotedRoot = "'" + windowsRoot.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let options = "BEPIS_MVGL_ASSET_ROOT=\(quotedRoot) BEPIS_MVGL_EXE_SHA256=\(package.adapter.executableSHA256) WINEDLLOVERRIDES='winmm=n,b' %command%"
        return "Installed \(package.name) for \(game.name) (\(package.files.count) assets).\n\nOne-time setup: copy this into Steam → Properties → Launch Options, then use Play:\n\(options)\n\nPreserve your existing launch options when combining settings; an existing Wine override may conflict. This path stays the same when managing asset mods. Close the game before applying changes, then restart it."
    }
}
