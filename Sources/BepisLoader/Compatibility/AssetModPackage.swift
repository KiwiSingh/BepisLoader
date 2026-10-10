import Foundation
import CryptoKit

/// The UI is game agnostic. Each adapter owns its game ABI and accepted assets.
struct AssetModAdapter {
    let id: String
    let appId: UInt32
    let executable: String
    let executableSHA256: String
    static let supported = [AssetModAdapter(id: "dsts-mvgl-v1", appId: 1984270,
        executable: "Digimon Story Time Stranger.exe",
        executableSHA256: "ff9de825a543bf874cfb7e73ed951256d3ce4e8702957afa3b26ca6487a81688")]
    static func forGame(_ appId: UInt32) -> AssetModAdapter? { supported.first { $0.appId == appId } }
}

struct AssetModPackage {
    let adapter: AssetModAdapter
    let name: String
    /// Snapshot bytes once: upload cannot observe edits after validation.
    let files: [String: Data]
    var totalBytes: Int { files.values.reduce(0) { $0 + $1.count } }
    var manifest: Data {
        get throws {
            try JSONSerialization.data(withJSONObject: ["schema": 1, "adapter": adapter.id,
                "name": name, "files": files.mapValues(Self.hash)], options: [.sortedKeys])
        }
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func inspect(folder: URL, appId: UInt32) throws -> AssetModPackage {
        guard let adapter = AssetModAdapter.forGame(appId) else { throw failure("No asset adapter is available for this game.") }
        let fm = FileManager.default
        let root = folder.standardizedFileURL
        guard root == root.resolvingSymlinksInPath() else { throw failure("Mod folders cannot redirect through symbolic links.") }
        let config = root.appendingPathComponent("ModConfig.json")
        guard try config.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isSymbolicLink != true,
              let info = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any],
              let supported = info["SupportedAppId"] as? [String],
              supported.contains(where: { $0.lowercased() == adapter.executable.lowercased() }) else {
            throw failure("This mod does not declare support for the selected game.")
        }
        for field in ["ModDll", "ModNativeDll32", "ModNativeDll64", "ModR2RManagedDll32", "ModR2RManagedDll64"] {
            if let value = info[field], !(value is String) || !(value as? String ?? "").isEmpty {
                throw failure("This mod contains code and cannot use the asset-only adapter.")
            }
        }
        guard info["ModDependencies"] == nil || info["ModDependencies"] is [String] else { throw failure("Invalid mod dependency metadata.") }
        let dependencies = info["ModDependencies"] as? [String] ?? []
        let assetDependencies: Set<String> = ["DSTS.ModLoader", "MVGL.FileLoader.Reloaded", "Reloaded.Memory.SigScan.ReloadedII", "reloaded.sharedlib.hooks"]
        guard dependencies.allSatisfy({ assetDependencies.contains($0) }), info["IsLibrary"] as? Bool != true else {
            throw failure("This mod requires a dependency that the asset adapter cannot provide.")
        }
        let assets = root.appendingPathComponent("dsts-loader", isDirectory: true)
        guard assets == assets.resolvingSymlinksInPath(),
              let walker = fm.enumerator(at: assets, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey], options: []) else {
            throw failure("No supported asset folder was found.")
        }
        var files: [String: Data] = [:], seen = Set<String>(), total = 0
        for case let file as URL in walker {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw failure("Symbolic links are not allowed in asset mods.") }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, file.path.hasPrefix(assets.path + "/") else { throw failure("Only regular asset files are supported.") }
            let key = String(file.path.dropFirst(assets.path.count + 1))
            guard key.utf8.count < 1024, key.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }),
                  key.hasPrefix("app_0/images/"), key.hasSuffix(".dds"), !key.contains(":"), !key.contains("\\"),
                  key.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  key.split(separator: "/").count <= 32, seen.insert(key.lowercased()).inserted else {
                throw failure("Unsupported or conflicting asset path: \(key)")
            }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size >= 128, size <= 64 * 1024 * 1024, total + size <= 256 * 1024 * 1024, files.count < 4096 else {
                throw failure("This asset mod exceeds the supported size limits.")
            }
            let data = try Data(contentsOf: file)
            guard data.count == size, data.starts(with: [0x44, 0x44, 0x53, 0x20]) else { throw failure("Invalid or changed DDS asset: \(key)") }
            files[key] = data; total += data.count
        }
        guard !files.isEmpty else { throw failure("The mod contains no supported assets.") }
        return AssetModPackage(adapter: adapter, name: info["ModName"] as? String ?? folder.lastPathComponent, files: files)
    }
    static func failure(_ message: String) -> NSError { NSError(domain: "BepisAssetMod", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
