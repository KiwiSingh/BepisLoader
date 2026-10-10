import Foundation
@main struct AssetPackageTests {
    static func main() throws {
        let parent = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!)
        let root = parent.appendingPathComponent("asset-package-tests-" + UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("dsts-loader/app_0/images"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var config: [String: Any] = ["ModName": "Eyes", "ModDll": "", "ModDependencies": ["DSTS.ModLoader"], "SupportedAppId": ["digimon story time stranger.exe"]]
        func save() throws { try JSONSerialization.data(withJSONObject: config).write(to: root.appendingPathComponent("ModConfig.json")) }
        func reject(_ appId: UInt32 = 1984270) { do { _ = try AssetModPackage.inspect(folder: root, appId: appId); fatalError("Accepted unsafe package") } catch {} }
        try save()
        let asset = root.appendingPathComponent("dsts-loader/app_0/images/eyes.dds")
        var bytes = Data([0x44,0x44,0x53,0x20]); bytes.append(Data(repeating: 0, count: 124)); try bytes.write(to: asset)
        let package = try AssetModPackage.inspect(folder: root, appId: 1984270)
        precondition(package.files.count == 1 && package.totalBytes == 128)
        let manifestObject = try JSONSerialization.jsonObject(with: package.manifest)
        precondition(manifestObject is [String: Any])
        let img = root.appendingPathComponent("dsts-loader/app_0/images/pc002a_b01l_01.img")
        try bytes.write(to: img)
        let imgPackage = try AssetModPackage.inspect(folder: root, appId: 1984270)
        precondition(imgPackage.files["app_0/images/pc002a_b01l_01.img"] == bytes)
        let collision = root.appendingPathComponent("dsts-loader/app_0/images/pc002a_b01l_01.dds")
        try bytes.write(to: collision); let distinct = try AssetModPackage.inspect(folder: root, appId: 1984270); precondition(distinct.files.count == 3); try fm.removeItem(at: collision)
        try Data([1,2,3]).write(to: img); let raw = try AssetModPackage.inspect(folder: root, appId: 1984270); precondition(raw.files["app_0/images/pc002a_b01l_01.img"] == Data([1,2,3]))
        try fm.removeItem(at: img)
        reject(1)
        config["ModDll"] = "injected.dll"; try save(); reject()
        config["ModDll"] = ""; config["ModDependencies"] = ["unknown-code-loader"]; try save(); reject()
        config["ModDependencies"] = ["DSTS.ModLoader"]; config["SupportedAppId"] = ["other.exe"]; try save(); reject()
        config["SupportedAppId"] = ["digimon story time stranger.exe"]; try save()
        try fm.createSymbolicLink(at: root.appendingPathComponent("dsts-loader/app_0/images/link.dds"), withDestinationURL: asset); reject()
        try fm.removeItem(at: root.appendingPathComponent("dsts-loader/app_0/images/link.dds"))
        try bytes.write(to: root.appendingPathComponent("dsts-loader/app_0/images/plugin.dll")); let named = try AssetModPackage.inspect(folder: root, appId: 1984270); precondition(named.files["app_0/images/plugin.dll"] == bytes)
        try fm.removeItem(at: root.appendingPathComponent("dsts-loader/app_0/images/plugin.dll"))
        try Data().write(to: asset); reject()
        precondition(package.files["app_0/images/eyes.dds"] == bytes, "Snapshot changed after source edit")
        print("PASS: exact IMG filenames, distinct IMG/DDS filenames, raw IMG bytes, valid DDS, manifest, unsupported game, code payload, unknown dependency, wrong game, symlink, arbitrary extensions, empty asset rejection, immutable snapshot")
    }
}
