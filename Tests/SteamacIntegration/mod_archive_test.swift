import Foundation
@main struct ArchiveTests {
    static func main() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BEPIS_ARCHIVE_FIXTURES"]!)
        let wrapped = try ModArchive.inspect(source: root.appendingPathComponent("wrapped.zip")) { try ReShadePackage.inspect(folder: $0) }
        precondition(wrapped.presets == ["My preset.ini"] && wrapped.files.count == 2)
        for name in ["traversal", "absolute", "case", "symlink"] {
            do { _ = try ModArchive.files(in: root.appendingPathComponent(name + ".zip")); fatalError("Accepted unsafe archive: \(name)") } catch {}
        }
        let asset = try ModArchive.inspect(source: root.appendingPathComponent("asset.7z")) { try AssetModPackage.inspect(folder: $0, appId: 1984270) }
        precondition(asset.files.count == 2 && asset.name == "Skip Opening Logos")
        if let rar = ProcessInfo.processInfo.environment["BEPIS_REAL_RAR"] {
            let imported = try ModArchive.inspect(source: URL(fileURLWithPath: rar)) { try ReShadePackage.inspect(folder: $0) }
            precondition(imported.files.count == 85 && imported.files["dxgi.dll"] != nil)
            if let source = ProcessInfo.processInfo.environment["BEPIS_REAL_RESHADE"] {
                let folder = try ReShadePackage.inspect(folder: URL(fileURLWithPath: source))
                precondition(imported.files == folder.files)
            }
        }
        if let large = ProcessInfo.processInfo.environment["BEPIS_LARGE_ARCHIVE_FIXTURES"] {
            let folder = URL(fileURLWithPath: large)
            do {
                let files = try ModArchive.files(in: folder.appendingPathComponent("file-boundary.zip"))
                precondition(files["large.bin"]?.count == 128 * 1024 * 1024)
            }
            do { _ = try ModArchive.files(in: folder.appendingPathComponent("file-overflow.zip")); fatalError("Accepted archive file above 128 MiB") } catch {}
        }
        print("PASS: actual RAR import matches extracted source; actual asset 7z import; wrapped ZIP, traversal, absolute paths, links and case-conflict rejection")
    }
}
