import Foundation

// ─────────────────────────────────────────────
//  BepInExModManager
//  Manages BepInEx plugin DLLs and folders in the game's
//  BepInEx/plugins directory.
// ─────────────────────────────────────────────

final class BepInExModManager: ModManaging {

    static let shared = BepInExModManager()
    private init() {}

    let framework: ModFramework = .bepInEx

    private let fm = FileManager.default

    // ── Installed mod list ─────────────────────

    func installedMods(for game: GameInstall) -> [InstalledMod] {
        guard fm.fileExists(atPath: BepInExPaths(game: game).plugins.path) else { return [] }

        let contents = (try? fm.contentsOfDirectory(
            at: BepInExPaths(game: game).plugins,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []

        return contents
            .filter { $0.pathExtension.lowercased() == "dll" || isModFolder($0) }
            .compactMap { installedMod(from: $0) }
    }

    // ── Install ────────────────────────────────

    /// Installs a mod DLL (or a mod folder) into the game's plugins directory.
    func installMod(from dllURL: URL, into game: GameInstall) throws {
        let isScoped = dllURL.startAccessingSecurityScopedResource()
        defer { if isScoped { dllURL.stopAccessingSecurityScopedResource() } }

        if !fm.fileExists(atPath: BepInExPaths(game: game).plugins.path) {
            try fm.createDirectory(at: BepInExPaths(game: game).plugins, withIntermediateDirectories: true)
        }

        let dest = BepInExPaths(game: game).plugins.appendingPathComponent(dllURL.lastPathComponent)

        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        
        try fm.copyItem(at: dllURL, to: dest)
        print("[BepisLoader] Successfully installed mod to: \(dest.path)")
    }

    // ── Remove ─────────────────────────────────

    func removeMod(_ mod: InstalledMod, from game: GameInstall) throws {
        let target = BepInExPaths(game: game).plugins.appendingPathComponent(mod.path.lastPathComponent)
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        // Also remove any associated .config file
        let config = target.deletingPathExtension().appendingPathExtension("cfg")
        if fm.fileExists(atPath: config.path) {
            try fm.removeItem(at: config)
        }
    }

    // ── Enable / Disable ───────────────────────
    // BepInEx respects the .disabled extension convention used by some loaders.
    // More reliably: we move the DLL to/from a "disabled" subfolder.

    func setModEnabled(_ enabled: Bool, mod: InstalledMod, in game: GameInstall) throws {
        let activePath   = BepInExPaths(game: game).plugins.appendingPathComponent(mod.path.lastPathComponent)
        let disabledDir  = BepInExPaths(game: game).plugins.appendingPathComponent(".disabled")
        let disabledPath = disabledDir.appendingPathComponent(mod.path.lastPathComponent)

        if enabled {
            // Move from disabled → active
            if fm.fileExists(atPath: disabledPath.path) {
                if !fm.fileExists(atPath: BepInExPaths(game: game).plugins.path) {
                    try fm.createDirectory(at: BepInExPaths(game: game).plugins, withIntermediateDirectories: true)
                }
                try fm.moveItem(at: disabledPath, to: activePath)
            }
        } else {
            // Move from active → disabled
            if fm.fileExists(atPath: activePath.path) {
                if !fm.fileExists(atPath: disabledDir.path) {
                    try fm.createDirectory(at: disabledDir, withIntermediateDirectories: true)
                }
                try fm.moveItem(at: activePath, to: disabledPath)
            }
        }
    }

    // ── Read BepInEx metadata from DLL ─────────

    /// Parses basic BepInEx plugin metadata from a managed assembly.
    /// Full implementation would use a Mono.Cecil-style reader;
    /// here we do a fast string scan for the [BepInPlugin] attribute literal.
    func readMetadata(from dllURL: URL) -> (guid: String, name: String, version: String)? {
        guard let data = try? Data(contentsOf: dllURL) else { return nil }

        // BepInPlugin stores GUID, Name, Version as UTF-8 string literals
        // right before the attribute class reference in the PE .text section.
        // We look for the pattern: <GUID>\0<Name>\0<Version>
        // This is a heuristic — works for most BepInEx 5.x plugins.
        guard let text = String(data: data, encoding: .isoLatin1) else { return nil }

        // Scan for BepInPlugin marker
        let marker = "BepInPlugin"
        if text.contains(marker) {
            // Try to extract printable ASCII strings near it
            let strings = extractStrings(from: data, minLen: 3)
            // Heuristic: find a version-looking string and walk backwards
            if let vIdx = strings.firstIndex(where: { isVersionString($0) }) {
                let version = strings[vIdx]
                let name    = vIdx > 0 ? strings[vIdx - 1] : dllURL.deletingPathExtension().lastPathComponent
                let guid    = vIdx > 1 ? strings[vIdx - 2] : name
                return (guid: guid, name: name, version: version)
            }
        }
        return nil
    }

    // ── Helpers ────────────────────────────────

    private func installedMod(from url: URL) -> InstalledMod? {
        let name = url.deletingPathExtension().lastPathComponent
        let meta = readMetadata(from: url)

        var finalName = meta?.name ?? name
        if finalName.lowercased() == "release" || finalName.lowercased() == "debug" {
            finalName = name
        }

        return InstalledMod(
            id: meta?.guid ?? url.path,
            name: finalName,
            version: meta?.version,
            author: nil,
            description: "",
            framework: framework,
            path: url,
            isEnabled: true
        )
    }

    private func isModFolder(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if !isDir.boolValue { return false }
        // A mod folder typically contains exactly one .dll
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return contents.contains { $0.hasSuffix(".dll") }
    }

    private func isVersionString(_ s: String) -> Bool {
        // Simple x.y or x.y.z check
        let parts = s.split(separator: ".")
        return parts.count >= 2 && parts.allSatisfy { Int($0) != nil }
    }

    private func extractStrings(from data: Data, minLen: Int) -> [String] {
        var strings: [String] = []
        var current = ""
        for byte in data {
            if byte >= 0x20 && byte < 0x7F {
                current.append(Character(UnicodeScalar(byte)))
            } else {
                if current.count >= minLen { strings.append(current) }
                current = ""
            }
        }
        if current.count >= minLen { strings.append(current) }
        return strings
    }
}
