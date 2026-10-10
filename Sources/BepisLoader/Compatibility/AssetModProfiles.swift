import Foundation

struct AssetProfileMod: Codable, Equatable {
    let id: String
    let name: String
    let root: String
    var enabled: Bool
}
struct AssetModProfile: Codable {
    var schema = 1
    var baseRoot = ""
    var mods: [AssetProfileMod] = []
}
struct AssetProfileMerge {
    let package: AssetModPackage
    let conflicts: [String: [String]]
}
enum AssetModProfiles {
    static func load(game: SteamacGame, endpoint: SteamacBridgeEndpoint, bridge: SteamacBridge = .shared) throws -> AssetModProfile {
        let data = try bridge.assetProfileState(appId: game.appId, endpoint: endpoint)
        let profile = try JSONDecoder().decode(AssetModProfile.self, from: data)
        guard profile.schema == 1, profile.mods.count <= 64, Set(profile.mods.map(\.id)).count == profile.mods.count else {
            throw AssetModPackage.failure("Invalid asset profile returned by the guest.")
        }
        for mod in profile.mods { try checkedRoot(mod.root, game: game) }
        return profile
    }
    private static func checkedRoot(_ root: String, game: SteamacGame) throws {
        let prefix = game.installPath + "/.bepis-asset-mod-"
        guard root.hasPrefix(prefix), root.hasSuffix("/assets") else { throw AssetModPackage.failure("Invalid stored asset location.") }
        let id = root.dropFirst(prefix.count).dropLast(7)
        guard !id.isEmpty, id.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { throw AssetModPackage.failure("Invalid stored asset location.") }
    }
    static func add(_ packages: [AssetModPackage], to profile: AssetModProfile,
                    game: SteamacGame, endpoint: SteamacBridgeEndpoint, bridge: SteamacBridge = .shared) throws -> AssetModProfile {
        guard profile.mods.count + packages.count <= 64 else { throw AssetModPackage.failure("An asset profile supports up to 64 mods.") }
        var result = profile
        for package in packages {
            let root = try SteamacAssetModInstaller.publish(package, game: game, endpoint: endpoint, bridge: bridge)
            result.mods.append(AssetProfileMod(id: UUID().uuidString.lowercased(), name: package.name, root: root, enabled: true))
        }
        return result
    }
    static func merge(_ profile: AssetModProfile, packages: [String: AssetModPackage], adapter: AssetModAdapter) throws -> AssetProfileMerge {
        var files: [String: Data] = [:], canonical: [String: String] = [:], owners: [String: [String]] = [:]
        let duplicateNames = Set(Dictionary(grouping: profile.mods, by: \.name).filter { $0.value.count > 1 }.keys)
        for mod in profile.mods where mod.enabled {
            guard let package = packages[mod.id], package.adapter.id == adapter.id else { throw AssetModPackage.failure("Stored asset package is missing or uses a different adapter.") }
            for (key, data) in package.files {
                let normalized = key.lowercased()
                if let oldKey = canonical[normalized] { files.removeValue(forKey: oldKey) }
                canonical[normalized] = key; files[key] = data
                owners[normalized, default: []].append(duplicateNames.contains(mod.name) ? "\(mod.name) (\(mod.id.prefix(8)))" : mod.name)
            }
        }
        guard files.count <= 4096, files.values.reduce(0, { $0 + $1.count }) <= 256 * 1024 * 1024 else {
            throw AssetModPackage.failure("The combined active assets exceed the supported limits.")
        }
        return AssetProfileMerge(package: AssetModPackage(adapter: adapter, name: "Active asset mods", files: files),
            conflicts: owners.filter { $0.value.count > 1 })
    }
    static func packages(_ profile: AssetModProfile, game: SteamacGame, endpoint: SteamacBridgeEndpoint,
                         bridge: SteamacBridge = .shared) throws -> [String: AssetModPackage] {
        guard let adapter = AssetModAdapter.forGame(game.appId) else { throw AssetModPackage.failure("Unsupported asset adapter.") }
        var result: [String: AssetModPackage] = [:], total = 0
        for mod in profile.mods {
            try checkedRoot(mod.root, game: game)
            let bundle = String(mod.root.dropLast(7))
            let manifest = try bridge.readGuestFile(at: bundle + "/manifest.json", endpoint: endpoint, maximumSize: 1024 * 1024)
            guard let json = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
                  json["adapter"] as? String == adapter.id,
                  let hashes = json["files"] as? [String: String], hashes.count <= 4096 else { throw AssetModPackage.failure("Invalid stored asset manifest.") }
            var files: [String: Data] = [:]
            for (key, hash) in hashes {
                guard !key.hasPrefix("/"), !key.contains(":"), !key.contains("\\"),
                      key.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                    throw AssetModPackage.failure("Invalid stored asset path.")
                }
                let bytes = try bridge.readGuestFile(at: mod.root + "/" + key, endpoint: endpoint, maximumSize: 64 * 1024 * 1024)
                total += bytes.count
                guard total <= 256 * 1024 * 1024, AssetModPackage.hash(bytes) == hash else {
                    throw AssetModPackage.failure("Stored assets changed or the profile exceeds the supported snapshot limit.")
                }
                files[key] = bytes
            }
            result[mod.id] = AssetModPackage(adapter: adapter, name: mod.name, files: files)
        }
        return result
    }
    static func apply(_ profile: AssetModProfile, merge: AssetProfileMerge, game: SteamacGame,
                      endpoint: SteamacBridgeEndpoint, bridge: SteamacBridge = .shared) throws -> String {
        let root = try SteamacAssetModInstaller.publish(merge.package, game: game, endpoint: endpoint,
            bridge: bridge, profile: JSONEncoder().encode(profile))
        return "Applied \(profile.mods.filter(\.enabled).count) enabled asset mods.\n\n" + SteamacAssetModInstaller.launchReport(merge.package, game: game, root: root)
    }
}
