import Foundation

/// Shared asset-mod entry point, with game-specific adapters behind it.
struct SteamacAssetModInstaller {
    static let payloadHashes = [
        "bepis-mvgl.asi": "06c996ce4b0072aea2b21eda90e1991265a7b3728f069f7d6a1090774060bcaf",
        "winmm.dll": "412d410eb6091fb483b150bea1b13f8aeb746be8c62802ea7e081fd15ea64b69"]
    static func install(_ package: AssetModPackage, game: SteamacGame,
                        endpoint: SteamacBridgeEndpoint, bridge: SteamacBridge = .shared, payloadRoot: URL? = nil) throws -> String {
        guard game.appId == package.adapter.appId,
              try bridge.handshake(endpoint: endpoint).capabilities.supports(.assetModInstallV1),
              let install = try bridge.gameInstall(for: game, endpoint: endpoint),
              try bridge.peArchitecture(for: install, endpoint: endpoint) == .x64,
              try bridge.protonRuntime(for: game.appId, endpoint: endpoint) != nil else {
            throw AssetModPackage.failure("This Steamac version or game does not support checked asset-mod installation.")
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
        let stage = game.installPath + "/.bepis-asset-stage-" + UUID().uuidString.lowercased()
        try bridge.createGuestDirectory(stage, endpoint: endpoint)
        // Retain failed staging for review; never clean up an unknown guest path.
        for (key, data) in package.files.sorted(by: { $0.key < $1.key }) {
            let destination = stage + "/assets/" + key
            try bridge.createGuestDirectory((destination as NSString).deletingLastPathComponent, endpoint: endpoint)
            try bridge.writeGuestFile(data, to: destination, endpoint: endpoint)
        }
        for (key, data) in payloads { try bridge.writeGuestFile(data, to: stage + "/" + (key == "bepis-mvgl.asi" ? "adapter.payload" : "proxy.payload"), endpoint: endpoint) }
        try bridge.writeGuestFile(try package.manifest, to: stage + "/manifest.json", endpoint: endpoint)
        let root = try bridge.commitAssetMod(appId: game.appId, adapter: package.adapter.id, stage: stage, endpoint: endpoint)
        let windowsRoot = "Z:" + root
        let quotedRoot = "'" + windowsRoot.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let options = "BEPIS_MVGL_ASSET_ROOT=\(quotedRoot) BEPIS_MVGL_EXE_SHA256=\(package.adapter.executableSHA256) WINEDLLOVERRIDES='winmm=n,b' %command%"
        return "Installed \(package.name) (\(package.files.count) assets).\n\nOne-time setup: copy this into Steam → Properties → Launch Options, then use Play:\n\(options)\n\nPreserve your existing launch options when combining settings; an existing Wine override may conflict. Disable asset mods to stop loading this adapter."
    }
}
