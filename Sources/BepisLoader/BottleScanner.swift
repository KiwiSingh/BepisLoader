import Foundation

// ─────────────────────────────────────────────
//  BottleScanner
//  Finds Wine bottles created by various layers
//  and Unity games within each bottle.
// ─────────────────────────────────────────────

class BottleScanner {

    static let shared = BottleScanner()
    private init() {}

    private let fm = FileManager.default

    // ── Public API ─────────────────────────────

    /// Scans all known compatibility layers and returns every discovered bottle.
    func scanAll() -> [Bottle] {
        var bottles: [Bottle] = []
        for layer in CompatibilityLayer.allCases {
            bottles.append(contentsOf: scan(layer: layer))
        }
        return bottles
    }

    /// Scans a single compatibility layer.
    func scan(layer: CompatibilityLayer) -> [Bottle] {
        switch layer {
        case .crossOver, .crossOverPreview: return scanCrossOver(layer: layer)
        case .gameMac:                      return scanGameMac()
        case .wine:                         return scanStandaloneWine()
        case .wineskin:                     return scanWineskin()
        case .porting:                      return scanPortingKit()
        case .whisky:                       return scanWhisky()
        case .other:                        return scanOtherLocations()
        }
    }

    /// Finds Unity games inside the given bottles.
    func findGames(in bottles: [Bottle]) -> [GameInstall] {
        var games: [GameInstall] = []
        for bottle in bottles {
            games.append(contentsOf: findGames(in: bottle))
        }
        return games
    }

    // ── CrossOver ──────────────────────────────

    private func scanCrossOver(layer: CompatibilityLayer) -> [Bottle] {
        // CrossOver bottles live at ~/Library/Application Support/CrossOver/Bottles/<name>/
        let crossOverAppSupport: URL
        switch layer {
        case .crossOverPreview:
            crossOverAppSupport = homeDir()
                .appendingPathComponent("Library/Application Support/CrossOver-Preview/Bottles")
        default:
            crossOverAppSupport = homeDir()
                .appendingPathComponent("Library/Application Support/CrossOver/Bottles")
        }
        
        var bottles = bottlesIn(directory: crossOverAppSupport, layer: layer)
        
        // Also check for Steam-specific bottles in CrossOver
        let steamBottle = crossOverAppSupport.appendingPathComponent("Steam")
        if isWineBottle(steamBottle) && !bottles.contains(where: { $0.path == steamBottle }) {
            bottles.append(Bottle(name: "Steam (CrossOver)", path: steamBottle, layer: layer))
        }
        
        return bottles
    }

    // ── GameMac — see scanGameMac() below ─────────────────────────────────────

        // ── Standalone Wine ────────────────────────

    private func scanStandaloneWine() -> [Bottle] {
        // ~/.wine is the default prefix; also check WINEPREFIX env
        var paths: [URL] = [homeDir().appendingPathComponent(".wine")]
        if let envPrefix = ProcessInfo.processInfo.environment["WINEPREFIX"] {
            paths.append(URL(fileURLWithPath: envPrefix))
        }
        var bottles: [Bottle] = []
        for path in paths where isWineBottle(path) {
            bottles.append(Bottle(name: path.lastPathComponent, path: path, layer: .wine))
        }
        return bottles
    }

    // ── Wineskin ───────────────────────────────

    private func scanWineskin() -> [Bottle] {
        let wineskinDir = homeDir().appendingPathComponent("Applications/Wineskin")
        guard let entries = try? fm.contentsOfDirectory(
            at: wineskinDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }

        return entries.compactMap { url -> Bottle? in
            // Each .app bundle wraps a Wine prefix at Contents/SharedSupport/prefix
            let prefixPath = url
                .appendingPathComponent("Contents/SharedSupport/prefix")
            guard isWineBottle(prefixPath) else { return nil }
            return Bottle(name: url.deletingPathExtension().lastPathComponent,
                         path: prefixPath, layer: .wineskin)
        }
    }

    // ── Porting Kit ────────────────────────────

    private func scanPortingKit() -> [Bottle] {
        let portingDir = homeDir().appendingPathComponent("Library/Application Support/PortingKit")
        return bottlesIn(directory: portingDir, layer: .porting)
    }

    // ── Whisky ─────────────────────────────────

    private func scanWhisky() -> [Bottle] {
        let whiskyDir = homeDir().appendingPathComponent("Library/Containers/com.isaacmarovitz.Whisky/Bottles")
        return bottlesIn(directory: whiskyDir, layer: .whisky)
    }

    private func scanOtherLocations() -> [Bottle] {
        var bottles: [Bottle] = []

        // ── Whisky-managed Steam bottles (alternate path) ─────────────────────
        let whiskySteam = homeDir()
            .appendingPathComponent("Library/Application Support/Whisky/Bottles/Steam")
        if isWineBottle(whiskySteam) {
            bottles.append(Bottle(name: "Steam (Whisky)", path: whiskySteam, layer: .other))
        }

        return bottles
    }

    // ── GameMac ────────────────────────────────────────────────────────────────

    private func scanGameMac() -> [Bottle] {
        let home = homeDir()
        let bundleIds = ["com.gamemac.www", "com.www.gamemac"]
        
        var allBottles: [Bottle] = []
        
        for bid in bundleIds {
            let possibleRoots = [
                home.appendingPathComponent("Library/Application Support/\(bid)"),
                home.appendingPathComponent("Library/Containers/\(bid)/Data/Library/Application Support/\(bid)")
            ]
            
            for supportDir in possibleRoots {
                let storeURL = supportDir.appendingPathComponent("gamehub/game_container_store.json")
                let containersRoot = supportDir.appendingPathComponent("wine-engine/containers/virtual_containers")
                
                guard fm.fileExists(atPath: storeURL.path),
                      let data = try? Data(contentsOf: storeURL),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let bindings = json["bindings"] as? [[String: Any]]
                else {
                    // JSON not found or unreadable — skip this root
                    if fm.fileExists(atPath: containersRoot.path) {
                        allBottles.append(contentsOf: bottlesIn(directory: containersRoot, layer: .gameMac))
                    }
                    continue
                }


        for binding in bindings {
            guard
                let gameName    = binding["game_name"]            as? String,
                let containerID = binding["virtual_container_id"] as? String
            else { continue }

            // The Wine prefix is the virtual container directory
            let prefixURL = containersRoot.appendingPathComponent(containerID)
            guard isWineBottle(prefixURL) else { continue }

            var bottle = Bottle(name: gameName, path: prefixURL, layer: .gameMac)

            // game_path in game_container_store.json is the Steam library root
            // (e.g. /Volumes/Zweidrive/Games) — not a per-game directory.
            // Steam always installs games at <library>/steamapps/common/<installdir>.
            //
            // Strategy (tried in order):
            //   1. Read steamapps/appmanifest_<appId>.acf to get the exact installdir name
            //   2. Scan steamapps/common/ for a directory whose name matches game_name
            //   3. Fall back to steamapps/common/ as a whole (finds all games but works)
            if let gamePathStr = binding["game_path"] as? String,
               let appId       = binding["platform_app_id"] as? String {
                let libraryRoot  = URL(fileURLWithPath: gamePathStr)
                let steamapps    = libraryRoot.appendingPathComponent("steamapps")
                let commonDir    = steamapps.appendingPathComponent("common")

                if let specificDir = resolveGameInstallDir(
                    appId: appId, gameName: gameName,
                    steamapps: steamapps, common: commonDir
                ), fm.fileExists(atPath: specificDir.path) {
                    // Best case: we know exactly which subdirectory this game is in
                    bottle.extraSearchPaths = [specificDir]
                } else if fm.fileExists(atPath: commonDir.path) {
                    // Fallback: scan all of steamapps/common — still much narrower
                    // than the library root since it skips steamapps/workshop etc.
                    bottle.extraSearchPaths = [commonDir]
                } else if fm.fileExists(atPath: libraryRoot.path) {
                    bottle.extraSearchPaths = [libraryRoot]
                }
            }

            allBottles.append(bottle)
        }
            }
        }
        
        // Deduplicate bottles by path
        var seenPaths = Set<String>()
        return allBottles.filter { seenPaths.insert($0.path.path).inserted }
    }

    /// Resolves the exact game install directory from a Steam library.
    ///
    /// Tries, in order:
    ///   1. Parse `steamapps/appmanifest_<appId>.acf` for the `installdir` field
    ///   2. Direct match: `steamapps/common/<gameName>`
    ///   3. Case-insensitive match against entries in `steamapps/common/`
    private func resolveGameInstallDir(
        appId: String, gameName: String,
        steamapps: URL, common: URL
    ) -> URL? {
        // 1. ACF manifest — most reliable, gives exact installdir
        let acf = steamapps.appendingPathComponent("appmanifest_\(appId).acf")
        if fm.fileExists(atPath: acf.path),
           let acfText = try? String(contentsOf: acf, encoding: .utf8) {
            // ACF format: "installdir"		"<name>"
            for line in acfText.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().hasPrefix("\"installdir\"") {
                    // Extract the value between the second pair of quotes
                    let parts = trimmed.components(separatedBy: "\"")
                    if parts.count >= 4 {
                        let installDir = parts[3]
                        let candidate = common.appendingPathComponent(installDir)
                        if fm.fileExists(atPath: candidate.path) { return candidate }
                    }
                }
            }
        }

        // 2. Direct name match
        let direct = common.appendingPathComponent(gameName)
        if fm.fileExists(atPath: direct.path) { return direct }

        // 3. Case-insensitive match
        guard let entries = try? fm.contentsOfDirectory(
            at: common, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return nil }

        let lowerName = gameName.lowercased()
        return entries.first {
            $0.lastPathComponent.lowercased() == lowerName
                || $0.lastPathComponent.lowercased().contains(lowerName)
                || lowerName.contains($0.lastPathComponent.lowercased())
        }
    }

    // ── Unity game detection ───────────────────

    func findGames(in bottle: Bottle) -> [GameInstall] {
        var games: [GameInstall] = []
        let driveC = bottle.driveCRoot

        // Walk the drive_c/Program Files and drive_c/users/… tree
        var searchRoots: [URL] = [
            driveC.appendingPathComponent("Program Files"),
            driveC.appendingPathComponent("Program Files (x86)"),
            driveC.appendingPathComponent("Games"),
            driveC,   // some games install at root
        ]

        // For GameMac bottles, game files live at game_path on the external drive —
        // NOT inside drive_c. extraSearchPaths carries game_path from
        // game_container_store.json and is prepended below. We clear the drive_c
        // search roots entirely for GameMac because they would just find
        // Windows system files inside the virtual container, not game exes.
        if bottle.layer == .gameMac {
            searchRoots = []
        }

        // Also check other mapped drives in dosdevices (for external SSDs and
        // GameMac/GameHub symlinked game paths)
        let dosdevices = bottle.path.appendingPathComponent("dosdevices")
        if let drives = try? fm.contentsOfDirectory(at: dosdevices, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for drive in drives {
                let name = drive.lastPathComponent.lowercased()
                // Skip c: (already handled) and z: (usually maps to macOS root /)
                if name.count == 2 && name.hasSuffix(":") && name != "c:" && name != "z:" {
                    // Resolve the symlink so we scan the real host path
                    if let dest = try? fm.destinationOfSymbolicLink(atPath: drive.path) {
                        let resolved = dest.hasPrefix("/")
                            ? URL(fileURLWithPath: dest)
                            : URL(fileURLWithPath: dest, relativeTo: drive.deletingLastPathComponent()).standardized
                        if fm.fileExists(atPath: resolved.path) {
                            searchRoots.append(resolved)
                        }
                    } else {
                        searchRoots.append(drive)
                    }
                }
            }
        }

        // Extra search paths set by the scanner (e.g. GameMac's game_path pointing
        // to an external drive). Prepend them so they take priority over drive_c.
        searchRoots = bottle.extraSearchPaths + searchRoots

        // Deduplicate by canonical path so we never scan the same directory twice
        var seen = Set<String>()
        let uniqueRoots = searchRoots.filter { url in
            let canonical = url.standardized.path
            return seen.insert(canonical).inserted
        }

        for root in uniqueRoots where fm.fileExists(atPath: root.path) {
            enumerateForUnity(root: root, bottle: bottle, results: &games)
        }
        return games
    }

    // ── Helpers ────────────────────────────────

    private func bottlesIn(directory: URL, layer: CompatibilityLayer) -> [Bottle] {
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return entries.compactMap { url -> Bottle? in
            guard isWineBottle(url) else { return nil }
            return Bottle(name: url.lastPathComponent, path: url, layer: layer)
        }
    }

    /// Returns true if the directory looks like a valid Wine prefix
    private func isWineBottle(_ url: URL) -> Bool {
        let driveC = url.appendingPathComponent("drive_c")
        let system32 = driveC.appendingPathComponent("windows/system32")
        return fm.fileExists(atPath: driveC.path) &&
               fm.fileExists(atPath: system32.path)
    }

    /// Recursively finds Unity game executables within a directory tree.
    /// A Unity game directory contains a `<GameName>_Data` folder alongside the exe.
    private func enumerateForUnity(root: URL, bottle: Bottle, results: inout [GameInstall], depth: Int = 0) {
        guard depth < 5 else { return }
        guard let contents = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: .skipsHiddenFiles
        ) else { return }

        // Look for *_Data sibling of a .exe
        let exeFiles = contents.filter { $0.pathExtension.lowercased() == "exe" }
        for exe in exeFiles {
            let gameName = exe.deletingPathExtension().lastPathComponent
            let dataDir = root.appendingPathComponent("\(gameName)_Data")
            if fm.fileExists(atPath: dataDir.path) {
                var game = GameInstall(name: gameName, executablePath: exe, bottle: bottle)
                game.unityType = detectUnityType(for: game)
                game.bepInExStatus = detectBepInExStatus(gameDir: root)
                results.append(game)
            }
        }

        // Recurse into subdirectories
        for entry in contents {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: entry.path, isDirectory: &isDir)
            if isDir.boolValue {
                enumerateForUnity(root: entry, bottle: bottle, results: &results, depth: depth + 1)
            }
        }
    }

    func detectUnityType(for game: GameInstall) -> GameInstall.UnityType {
        let fm = FileManager.default
        let gameDir = game.executablePath.deletingLastPathComponent()
        
        // Find any directory ending in _Data in the same folder as the exe
        guard let contents = try? fm.contentsOfDirectory(at: gameDir, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else {
            return .unknown
        }
        
        let dataDirs = contents.filter { $0.lastPathComponent.hasSuffix("_Data") }
        for dataDir in dataDirs {
            let dataContents = (try? fm.subpathsOfDirectory(atPath: dataDir.path)) ?? []
            
            if dataContents.contains(where: { $0.contains("Assembly-CSharp.dll") }) {
                return .mono
            } else if dataContents.contains(where: { $0.contains("libil2cpp.dll") }) || 
                      dataContents.contains(where: { $0.contains("GameAssembly.dll") }) ||
                      dataContents.contains(where: { $0.contains("il2cpp_data") }) {
                return .il2cpp
            }
        }
        return .unknown
    }

    func detectBepInExStatus(gameDir: URL) -> GameInstall.BepInExStatus {
        let bepInExDir = gameDir.appendingPathComponent("BepInEx")
        guard fm.fileExists(atPath: bepInExDir.path) else { return .notInstalled }

        // 1. Try BepInEx.version file (most reliable for our installer)
        let versionFile = bepInExDir.appendingPathComponent("BepInEx.version")
        if let version = try? String(contentsOf: versionFile, encoding: .utf8) {
            return .installed(version: version.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // 2. Try to read version from Core DLL (BepInEx 5 or 6)
        let coreDll5 = bepInExDir.appendingPathComponent("core/BepInEx.dll")
        let coreDll6 = bepInExDir.appendingPathComponent("core/BepInEx.Core.dll")
        let coreDllIL2CPP = bepInExDir.appendingPathComponent("core/BepInEx.Unity.IL2CPP.dll")
        
        let coreDll: URL
        if fm.fileExists(atPath: coreDllIL2CPP.path) {
            coreDll = coreDllIL2CPP
        } else if fm.fileExists(atPath: coreDll6.path) {
            coreDll = coreDll6
        } else {
            coreDll = coreDll5
        }

        if fm.fileExists(atPath: coreDll.path) {
            if let version = readVersionFromAssembly(coreDll) {
                return .installed(version: version)
            }
        }

        // Fallback: check LogOutput.log
        let logFile = bepInExDir.appendingPathComponent("LogOutput.log")
        if let logText = try? String(contentsOf: logFile, encoding: .utf8) {
            let pattern = "BepInEx\\s+([0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+(-[a-zA-Z0-9.]+)?)"
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: logText, range: NSRange(logText.startIndex..., in: logText)) {
                if let range = Range(match.range(at: 1), in: logText) {
                    return .installed(version: String(logText[range]))
                }
            }
        }

        if fm.fileExists(atPath: coreDll.path) {
            return .installed(version: "unknown")
        }
        return .installed(version: "unknown")
    }

    private func readVersionFromAssembly(_ url: URL) -> String? {
        // Real implementation would parse the PE header / managed assembly manifest.
        // Here we check for a VERSION file that BepInEx installs.
        let rootDir = url.deletingLastPathComponent().deletingLastPathComponent()
        let rootVersionFile = rootDir.appendingPathComponent("BepInEx.version")
        if let text = try? String(contentsOf: rootVersionFile, encoding: .utf8) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let coreVersionFile = url.deletingLastPathComponent().appendingPathComponent("BepInEx.version")
        return try? String(contentsOf: coreVersionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func homeDir() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
    }
}
