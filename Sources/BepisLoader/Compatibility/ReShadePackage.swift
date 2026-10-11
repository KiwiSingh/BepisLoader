import Foundation
import CryptoKit

/// User-selected files, snapshotted before any guest operation. No shader or addon is bundled.
struct ReShadePackage {
    var files: [String: Data]
    let name: String
    let presets: [String]
    var replaceExistingSettings = false
    static let compilerHash = "e994847e01a6f1e4cbdc5a864616ac262f67ee4f14db194984661a8d927ab7f4"
    var totalBytes: Int { files.values.reduce(0) { $0 + $1.count } }
    var addons: [String] { files.keys.filter { $0.hasSuffix(".addon64") }.sorted() }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "ReShade", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validPath(_ path: String) -> Bool {
        path.utf8.count < 1024 && !path.contains("\\") && !path.contains(":") && !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func allowed(_ path: String) -> Bool {
        guard validPath(path) else { return false }
        if path.hasPrefix("reshade-shaders/") { return true }
        return !path.contains("/") && (path == "dxgi.dll" || path == "d3dcompiler_47.dll" || path.lowercased().hasSuffix(".ini") || path.hasSuffix(".addon64"))
    }
    static func boundedRead(_ file: URL, maximum: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: maximum + 1) ?? Data()
        guard bytes.count <= maximum else { throw failure("File grew beyond its limit while reading.") }
        return bytes
    }
    static func isX64DLL(_ data: Data) -> Bool {
        guard data.count >= 64, data.prefix(2) == Data([77,90]) else { return false }
        let offset = (0..<4).reduce(0) { $0 | Int(data[60 + $1]) << (8 * $1) }
        guard offset <= data.count - 26, data[offset..<offset+4] == Data([80,69,0,0]) else { return false }
        return data[offset+4] == 0x64 && data[offset+5] == 0x86 && data[offset+22] & 0x20 != 0 && data[offset+24] == 0x0b && data[offset+25] == 0x02
    }
    static func inspect(folder: URL) throws -> ReShadePackage {
        let root = folder.standardizedFileURL, fm = FileManager.default
        guard root == root.resolvingSymlinksInPath(), try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw failure("Choose an extracted ReShade mod folder without symbolic links.") }
        var problem: Error?
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [], errorHandler: { _, error in problem = error; return false }) else { throw failure("Cannot read this folder.") }
        var files: [String: Data] = [:], seen = Set<String>(), total = 0, entries = 0
        for case let file as URL in walker {
            entries += 1; guard entries <= 8192 else { throw failure("Too many files in this ReShade package.") }
            let relative = String(file.path.dropFirst(root.path.count + 1))
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw failure("ReShade packages cannot contain symbolic links.") }
            if relative == "__MACOSX" || ["reshade-cache", "reshade-screenshots", ".reshade-cache", ".reshade-screenshots"].contains(relative) { walker.skipDescendants(); continue }
            if values.isDirectory == true { continue }
            if file.lastPathComponent == ".DS_Store" || file.lastPathComponent.hasPrefix("._") || ["ReShade.log", "README.md", "README.txt", "LICENSE", "LICENSE.txt"].contains(file.lastPathComponent) { continue }
            guard values.isRegularFile == true, allowed(relative), seen.insert(relative.lowercased()).inserted else { throw failure("Unsupported or conflicting ReShade file: \(relative)") }
            guard (values.fileSize ?? Int.max) <= 64 * 1024 * 1024 else { throw failure("ReShade files must be at most 64 MiB each.") }
            let data = try Self.boundedRead(file, maximum: 64 * 1024 * 1024)
            total += data.count; guard total <= 256 * 1024 * 1024, files.count < 4096 else { throw failure("ReShade packages must be at most 256 MiB / 4,096 files.") }
            if relative == "dxgi.dll" || relative == "d3dcompiler_47.dll" || relative.hasSuffix(".addon64") {
                guard isX64DLL(data) else { throw failure("\(relative) must be a Windows x64 DLL, matching the game rather than the ARM64 host.") }
            }
            if relative == "dxgi.dll", data.range(of: Data("ReShade".utf8)) == nil { throw failure("dxgi.dll does not identify itself as ReShade.") }
            if relative == "d3dcompiler_47.dll", hash(data) != compilerHash { throw failure("The Microsoft shader compiler does not match the tested version.") }
            files[relative] = data
        }
        if let problem { throw problem }
        let presets = files.keys.filter { key in
            !key.contains("/") && key.lowercased().hasSuffix(".ini") && String(data: files[key]!, encoding: .utf8)?.contains("Techniques=") == true
        }.sorted()
        guard !presets.isEmpty else { throw failure("No ReShade preset was found. Choose the extracted folder containing the preset .ini and its shaders.") }
        return ReShadePackage(files: files, name: folder.lastPathComponent, presets: presets)
    }
    mutating func configure(preset: String, downArrow: Bool) throws {
        guard presets.contains(preset) else { throw Self.failure("Choose a preset from this package.") }
        var text = ""
        if let original = files["ReShade.ini"] {
            guard let decoded = String(data: original, encoding: .utf8), original.count <= 1024 * 1024 else { throw Self.failure("ReShade.ini must be a UTF-8 configuration smaller than 1 MiB.") }
            text = decoded
        }
        // Keep appearance settings, replace machine-specific filesystem settings.
        for (section, key, value) in [
            ("GENERAL", "EffectSearchPaths", ".\\reshade-shaders\\Shaders\\**"),
            ("GENERAL", "TextureSearchPaths", ".\\reshade-shaders\\Textures\\**"),
            ("GENERAL", "IntermediateCachePath", ".\\.reshade-cache"),
            ("GENERAL", "PresetPath", ".\\" + preset), ("GENERAL", "StartupPresetPath", ""),
            ("GENERAL", "PresetShortcutPaths", ""), ("GENERAL", "AddonPath", ".\\"),
            ("SCREENSHOT", "SavePath", ".\\.reshade-screenshots"),
            ("SCREENSHOT", "PostSaveCommand", ""), ("SCREENSHOT", "PostSaveCommandArguments", ""),
            ("SCREENSHOT", "PostSaveCommandWorkingDirectory", ".\\"), ("SCREENSHOT", "SoundPath", ""),
            ("STYLE", "Font", ""), ("STYLE", "LatinFont", ""), ("STYLE", "EditorFont", "")
        ] { text = Self.setting(text, section: section, key: key, value: value) }
        if downArrow { text = Self.setting(text, section: "INPUT", key: "KeyEffects", value: "40,0,0,0") }
        files["ReShade.ini"] = Data(text.utf8)
    }
    static func setting(_ text: String, section: String, key: String, value: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var active = "", sectionStart: Int?, insertAt = lines.count
        var remove: [Int] = []
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                if active == section { insertAt = i }
                active = String(trimmed.dropFirst().dropLast()).uppercased()
                if active == section { sectionStart = i; insertAt = i + 1 }
            } else if active == section {
                insertAt = i + 1
                if trimmed.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() == key.lowercased() { remove.append(i) }
            }
        }
        for i in remove.reversed() { lines.remove(at: i); if i < insertAt { insertAt -= 1 } }
        if sectionStart == nil { lines.append("[\(section)]"); insertAt = lines.count }
        lines.insert("\(key)=\(value)", at: insertAt)
        return lines.joined(separator: "\n")
    }
    func manifest(appId: UInt32, executable: String, executableHash: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schema": 1, "appId": appId, "executable": executable, "executableHash": executableHash, "name": name, "replaceExistingSettings": replaceExistingSettings, "files": files.mapValues(Self.hash)], options: [.sortedKeys])
    }
}
