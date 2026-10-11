import Foundation
@main struct PackageSizeTests {
    static func main() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BEPIS_TEST_ROOT"]!).appendingPathComponent("size-" + UUID().uuidString)
        let fm = FileManager.default
        let assets = root.appendingPathComponent("dsts-loader")
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("{\"ModName\":\"Size test\",\"SupportedAppId\":[\"digimon story time stranger.exe\"],\"ModDependencies\":[\"DSTS.ModLoader\"]}".utf8).write(to: root.appendingPathComponent("ModConfig.json"))
        func sparse(_ index: Int, _ size: UInt64) throws {
            let path = assets.appendingPathComponent("chunk\(index).bin")
            fm.createFile(atPath: path.path, contents: nil)
            let file = try FileHandle(forWritingTo: path); defer { try? file.close() }
            try file.truncate(atOffset: size)
        }
        for i in 0..<5 { try sparse(i, 128 * 1024 * 1024) }
        do {
            let package = try AssetModPackage.inspect(folder: root, appId: 1984270)
            precondition(package.files.count == 5 && package.totalBytes == 640 * 1024 * 1024)
        }
        try sparse(0, 128 * 1024 * 1024 + 1)
        do { _ = try AssetModPackage.inspect(folder: root, appId: 1984270); fatalError("Accepted file above 128 MiB") } catch {}
        try sparse(0, 128 * 1024 * 1024)
        for i in 5..<8 { try sparse(i, 128 * 1024 * 1024) }
        do {
            let package = try AssetModPackage.inspect(folder: root, appId: 1984270)
            precondition(package.totalBytes == 1024 * 1024 * 1024)
        }
        try sparse(8, 1)
        do { _ = try AssetModPackage.inspect(folder: root, appId: 1984270); fatalError("Accepted package above 1 GiB") } catch {}
        print("PASS: 128 MiB files and exactly 1 GiB package accepted; file/package limit plus one rejected")
    }
}
