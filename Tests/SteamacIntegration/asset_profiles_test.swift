import Foundation
@main struct AssetProfileTests {
    static func main() throws {
        let adapter = AssetModAdapter.supported[0]
        let first = AssetModPackage(adapter: adapter, name: "Eyes", files: ["app_0/images/eyes.img": Data([1]), "unique.bin": Data([3])])
        let second = AssetModPackage(adapter: adapter, name: "Costume", files: ["APP_0/images/eyes.img": Data([2]), "costume.img": Data([4])])
        var profile = AssetModProfile(mods: [.init(id: "a", name: "Eyes", root: "", enabled: true), .init(id: "b", name: "Costume", root: "", enabled: true)])
        let packages = ["a": first, "b": second]
        let merged = try AssetModProfiles.merge(profile, packages: packages, adapter: adapter)
        precondition(merged.package.files.count == 3 && merged.package.files["APP_0/images/eyes.img"] == Data([2]))
        precondition(merged.package.files["app_0/images/eyes.img"] == nil)
        precondition(merged.conflicts["app_0/images/eyes.img"] == ["Eyes", "Costume"])
        profile.mods.swapAt(0,1)
        precondition(tryMerge(profile, packages, adapter).package.files["app_0/images/eyes.img"] == Data([1]))
        profile.mods[1].enabled = false
        precondition(tryMerge(profile, packages, adapter).conflicts.isEmpty)
        profile.mods[0].enabled = false
        precondition(tryMerge(profile, packages, adapter).package.files.isEmpty)
        let encoded = try JSONEncoder().encode(profile)
        let restored = try JSONDecoder().decode(AssetModProfile.self, from: encoded)
        precondition(restored.mods == profile.mods)
        profile.mods = []
        precondition(tryMerge(profile, packages, adapter).package.files.isEmpty)
        print("PASS: multi-mod union, exact raw filenames, case-folded conflicts, priority reversal, individual disable, all disabled, removal, persistent state round trip")
    }
    static func tryMerge(_ p: AssetModProfile, _ files: [String: AssetModPackage], _ a: AssetModAdapter) -> AssetProfileMerge {
        try! AssetModProfiles.merge(p, packages: files, adapter: a)
    }
}
