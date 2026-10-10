import Foundation
struct BepInExPluginSnapshot {
    let filename: String
    let data: Data
    var digest: String { AssetModPackage.hash(data) }
}
enum BepInExPluginBatch {
    static func inspect(_ urls: [URL]) throws -> [BepInExPluginSnapshot] {
        guard !urls.isEmpty, urls.count <= 128 else { throw AssetModPackage.failure("Select between 1 and 128 plugins.") }
        var seen = Set<String>(), total = 0
        return try urls.map { url in
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            guard name.count > 4, name.lowercased().hasSuffix(".dll"), !name.contains("\\"), !name.contains("\n"), !name.contains("\r"),
                  seen.insert(name.lowercased()).inserted else { throw AssetModPackage.failure("Duplicate or invalid plugin filename: \(name)") }
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { throw AssetModPackage.failure("Plugin sources must be regular files.") }
            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
            let bytes = try file.read(upToCount: 64 * 1024 * 1024 + 1) ?? Data(); total += bytes.count
            guard !bytes.isEmpty, bytes.count <= 64 * 1024 * 1024, total <= 256 * 1024 * 1024 else {
                throw AssetModPackage.failure("Plugins must be nonempty, at most 64 MiB each, and at most 256 MiB combined.")
            }
            return BepInExPluginSnapshot(filename: name, data: bytes)
        }
    }
}
