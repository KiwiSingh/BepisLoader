import Foundation
@main struct ReShadePackageTests {
    static func main() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BEPIS_TEST_ROOT"]!).appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default; try fm.createDirectory(at: root.appendingPathComponent("reshade-shaders/Shaders"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("Techniques=Example\n".utf8).write(to: root.appendingPathComponent("My Preset.ini"))
        try Data("shader".utf8).write(to: root.appendingPathComponent("reshade-shaders/Shaders/Example.fx"))
        try Data("finder".utf8).write(to: root.appendingPathComponent(".DS_Store"))
        try Data("[GENERAL]\nPresetPath=C:\\author\\old.ini\nEffectSearchPaths=C:\\author\\shaders\n[INPUT]\nKeyEffects=34,0,0,0\n[SCREENSHOT]\nSavePath=H:\\author\nPostSaveCommand=bad.exe\n".utf8).write(to: root.appendingPathComponent("ReShade.ini"))
        var package = try ReShadePackage.inspect(folder: root)
        precondition(package.presets == ["My Preset.ini"] && package.files.count == 3)
        try package.configure(preset: "My Preset.ini", downArrow: true)
        let ini = String(data: package.files["ReShade.ini"]!, encoding: .utf8)!
        precondition(ini.contains("PresetPath=.\\My Preset.ini") && ini.contains("KeyEffects=40,0,0,0"))
        precondition(!ini.contains("C:\\author") && !ini.contains("H:\\author") && !ini.contains("bad.exe"))
        precondition(ini.contains("EffectSearchPaths=.\\reshade-shaders\\Shaders\\**"))
        let duplicate = ReShadePackage.setting("[GENERAL]\nPresetPath=one\nPresetPath=two\n", section: "GENERAL", key: "PresetPath", value: "three")
        precondition(duplicate.components(separatedBy: "PresetPath=").count == 2)
        do { try package.configure(preset: "../outside.ini", downArrow: true); fatalError("accepted outside preset") } catch {}
        for path in ["../dxgi.dll", "/dxgi.dll", "reshade-shaders/../winmm.dll", "winmm.dll", "bepis-mvgl.asi", "C:/bad.ini"] { precondition(!ReShadePackage.allowed(path)) }
        try fm.createSymbolicLink(at: root.appendingPathComponent("evil.ini"), withDestinationURL: root.appendingPathComponent("My Preset.ini"))
        do { _ = try ReShadePackage.inspect(folder: root); fatalError("accepted symlink") } catch {}
        try fm.removeItem(at: root.appendingPathComponent("evil.ini"))
        try Data("MZ".utf8).write(to: root.appendingPathComponent("dxgi.dll"))
        do { _ = try ReShadePackage.inspect(folder: root); fatalError("accepted invalid DLL") } catch {}
        try fm.removeItem(at: root.appendingPathComponent("dxgi.dll"))
        try Data("Techniques=Other".utf8).write(to: root.appendingPathComponent("my preset.ini"))
        // APFS may collapse aliases; exercise the two-file collision only on a case-sensitive volume.
        if try fm.contentsOfDirectory(atPath: root.path).filter({ $0.lowercased() == "my preset.ini" }).count == 2 {
            do { _ = try ReShadePackage.inspect(folder: root); fatalError("accepted case alias") } catch {}
        }
        if let actual = ProcessInfo.processInfo.environment["BEPIS_REAL_RESHADE"] {
            var real = try ReShadePackage.inspect(folder: URL(fileURLWithPath: actual))
            precondition(real.files["dxgi.dll"] != nil && real.addons == ["ShaderToggler.addon64"])
            try real.configure(preset: "Digimon reshade.ini", downArrow: true)
            precondition(String(data: real.files["ReShade.ini"]!, encoding: .utf8)!.contains("KeyEffects=40,0,0,0"))
            print("PASS: actual Digimon ReShade package (\(real.files.count) files) validates and configures without modifying its source")
        }
        print("PASS: preset selection, game-local configuration, Down-arrow toggle, duplicate settings, metadata exclusion, traversal, symlink, architecture and case-conflict checks")
    }
}
