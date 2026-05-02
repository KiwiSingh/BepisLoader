import Foundation
import AppKit
import CommonCrypto

// ─────────────────────────────────────────────
//  BepInExInstaller  v1.0.1
//  Downloads BepInEx, extracts it, then patches
//  every supported compatibility layer so mods
//  load automatically when the user hits Play
//  inside CrossOver / Whisky / GameMac / Porting Kit.
// ─────────────────────────────────────────────

class BepInExInstaller {

    static let shared = BepInExInstaller()
    private init() {}

    // ── Release assets ─────────────────────────

    struct ReleaseAsset {
        let version: String
        let downloadURL: URL
        let sha256: String?
    }

    static func latestStable(is64Bit: Bool, isIL2CPP: Bool) -> ReleaseAsset {
        if isIL2CPP {
            return ReleaseAsset(
                version: "6.0.0-be.755",
                downloadURL: URL(string:
                    "https://builds.bepinex.dev/projects/bepinex_be/755/BepInEx-Unity.IL2CPP-win-x64-6.0.0-be.755%2B3fab71a.zip"
                )!,
                sha256: nil
            )
        } else {
            let arch = is64Bit ? "x64" : "x86"
            return ReleaseAsset(
                version: "5.4.23.2",
                downloadURL: URL(string:
                    "https://github.com/BepInEx/BepInEx/releases/download/v5.4.23.2/BepInEx_win_\(arch)_5.4.23.2.zip"
                )!,
                sha256: nil
            )
        }
    }

    // ── Errors ─────────────────────────────────

    typealias ProgressHandler   = (Double, String) -> Void
    typealias CompletionHandler = (Result<Void, Error>) -> Void

    enum InstallerError: LocalizedError {
        case downloadFailed(String)
        case extractionFailed(String)
        case configWriteFailed(String)
        case gameDirectoryNotFound
        case alreadyInstalled

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let r):    return "Download failed: \(r)"
            case .extractionFailed(let r):  return "Extraction failed: \(r)"
            case .configWriteFailed(let r): return "Config write failed: \(r)"
            case .gameDirectoryNotFound:    return "Game directory not found"
            case .alreadyInstalled:         return "BepInEx is already installed"
            }
        }
    }

    // ── Installation pipeline ──────────────────

    func install(
        into game: GameInstall,
        asset: ReleaseAsset? = nil,
        progress: @escaping ProgressHandler,
        completion: @escaping CompletionHandler
    ) {
        let is64Bit  = detectIs64Bit(game.executablePath)
        let isIL2CPP = game.unityType == .il2cpp
        let release  = asset ?? BepInExInstaller.latestStable(is64Bit: is64Bit, isIL2CPP: isIL2CPP)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                progress(0.00, "Preparing…")
                guard FileManager.default.fileExists(atPath: game.gameDirectory.path) else {
                    throw InstallerError.gameDirectoryNotFound
                }

                // 1. Download
                progress(0.05, "Downloading BepInEx \(release.version)…")
                let zipURL = try self.downloadRelease(release) { p in
                    progress(0.05 + p * 0.45, "Downloading… \(Int(p * 100))%")
                }

                // 2. Clean stale files
                progress(0.50, "Cleaning old installation…")
                for f in [
                    game.gameDirectory.appendingPathComponent("winhttp.dll"),
                    game.gameDirectory.appendingPathComponent("version.dll"),
                    game.gameDirectory.appendingPathComponent("doorstop_config.ini"),
                    game.gameDirectory.appendingPathComponent(".doorstop_version"),
                    game.bepInExRoot.appendingPathComponent("BepInEx.version")
                ] where FileManager.default.fileExists(atPath: f.path) {
                    try? FileManager.default.removeItem(at: f)
                }

                // 3. Extract
                progress(0.55, "Extracting…")
                try self.extract(zipURL, into: game.gameDirectory)

                // 4. version.dll mirror (belt-and-suspenders DLL override)
                let winhttp    = game.gameDirectory.appendingPathComponent("winhttp.dll")
                let versionDll = game.gameDirectory.appendingPathComponent("version.dll")
                if FileManager.default.fileExists(atPath: winhttp.path) {
                    try? FileManager.default.copyItem(at: winhttp, to: versionDll)
                }

                // 5. Strip macOS quarantine so Wine can load the DLLs
                progress(0.62, "Removing quarantine attributes…")
                self.removeQuarantine(winhttp)
                self.removeQuarantine(versionDll)
                self.removeQuarantineRecursive(game.bepInExRoot)

                // 6. Doorstop config — always written, format depends on Mono vs IL2CPP
                progress(0.68, "Writing Doorstop configuration…")
                try self.writeDoorstopConfig(for: game, isIL2CPP: isIL2CPP)

                // 7. Wine registry DLL override (user.reg — works for all layers)
                progress(0.75, "Patching Wine registry…")
                self.injectWineDllOverride(for: game)

                // 8. Per-layer config patching
                progress(0.82, "Patching compatibility layer config…")
                self.patchLayerConfig(for: game)

                // 9. Folder structure + BepInEx.cfg
                progress(0.90, "Finalising…")
                try self.createFolderStructure(for: game)
                try self.writeVersionFile(for: game, version: release.version)
                try? self.enableBepInExConsole(for: game)

                progress(1.00, "Done ✓")
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func uninstall(from game: GameInstall) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: game.bepInExRoot.path) {
            try fm.removeItem(at: game.bepInExRoot)
        }
        for f in [
            game.gameDirectory.appendingPathComponent("winhttp.dll"),
            game.gameDirectory.appendingPathComponent("version.dll"),
            game.gameDirectory.appendingPathComponent("doorstop_config.ini"),
            game.gameDirectory.appendingPathComponent(".doorstop_version"),
        ] where fm.fileExists(atPath: f.path) {
            try fm.removeItem(at: f)
        }
    }

    // ── Download ───────────────────────────────

    private func downloadRelease(_ asset: ReleaseAsset, progressHandler: (Double) -> Void) throws -> URL {
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bepinex_\(asset.version).zip")

        if FileManager.default.fileExists(atPath: dest.path) {
            progressHandler(1.0)
            return dest
        }

        var downloadError: Error?
        var localURL: URL?
        let sem = DispatchSemaphore(value: 0)

        URLSession.shared.downloadTask(with: asset.downloadURL) { url, _, error in
            downloadError = error
            if let url = url {
                try? FileManager.default.moveItem(at: url, to: dest)
                localURL = dest
            }
            sem.signal()
        }.resume()
        sem.wait()

        if let err = downloadError { throw InstallerError.downloadFailed(err.localizedDescription) }
        guard let url = localURL   else { throw InstallerError.downloadFailed("No file received") }
        return url
    }

    private func extract(_ zipURL: URL, into targetDir: URL) throws {
        let result = shell("/usr/bin/unzip", "-o", zipURL.path, "-d", targetDir.path)
        if result.exitCode != 0 { throw InstallerError.extractionFailed(result.output) }
    }

    // ── Quarantine removal ─────────────────────

    private func removeQuarantine(_ url: URL) {
        shell("/usr/bin/xattr", "-d", "com.apple.quarantine", url.path)
    }

    private func removeQuarantineRecursive(_ url: URL) {
        shell("/usr/bin/xattr", "-rs", "com.apple.quarantine", url.path)
    }

    // ── Doorstop config ────────────────────────
    //
    //  For CrossOver / Whisky / standalone Wine, a relative path works because
    //  the game exe and BepInEx folder are in the same directory.
    //
    //  For GameMac, the Wine prefix is a separate virtual container — the game
    //  lives on the host filesystem (often an external drive). Doorstop needs
    //  an absolute Windows path, which in Wine is the Z:\ mapping of the
    //  macOS host path.

    private func writeDoorstopConfig(for game: GameInstall, isIL2CPP: Bool) throws {
        // BepInEx 5 (Mono)  → Doorstop v3: [UnityDoorstop] / targetAssembly
        // BepInEx 6 (IL2CPP) → Doorstop v4: [General] / target_assembly + [Il2Cpp] section
        
        let targetDll = isIL2CPP ? "BepInEx\\core\\BepInEx.Unity.IL2CPP.dll" : "BepInEx\\core\\BepInEx.Preloader.dll"
        var targetPath = targetDll
        
        // For GameMac, use an absolute Z:\ path because game files are often on a separate volume
        if game.bottle.layer == .gameMac {
            let winFormattedPath = game.gameDirectory.appendingPathComponent(targetDll.replacingOccurrences(of: "\\", with: "/")).path.replacingOccurrences(of: "/", with: "\\")
            targetPath = "Z:" + winFormattedPath
        }

        let config: String
        if isIL2CPP {
            config = """
[General]
enabled = true
target_assembly = \(targetPath)
redirect_output_log = false
boot_config_override =
ignore_disable_switch = false

[UnityMono]
dll_search_path_override =
debug_enabled = false
debug_address = 127.0.0.1:10000
debug_suspend = false

[Il2Cpp]
coreclr_path = dotnet\\coreclr.dll
corlib_dir = dotnet
"""
        } else {
            config = """
[UnityDoorstop]
enabled=true
targetAssembly=\(targetPath)
redirectOutputLog=false
ignoreDisableSwitch=false
"""
        }
        do { try config.write(to: game.doorstopConfig, atomically: true, encoding: .utf8) }
        catch { throw InstallerError.configWriteFailed(error.localizedDescription) }
    }

    // ── Wine registry override (user.reg) ──────
    //
    //  Direct text-patch of user.reg — avoids needing to call wine reg,
    //  which may not be available or may require WINEPREFIX to be booted.

    private func injectWineDllOverride(for game: GameInstall) {
        // Use the layer's Wine binary to write the registry safely.
        // This avoids corrupting .reg files with malformed section headers.
        patchWineRegistry(for: game.bottle)
    }

    // ── Per-layer config patching dispatcher ───────────────────────────────
    //
    //  Each compatibility layer has its own mechanism for passing environment
    //  variables to Wine at game launch time. We patch all of them so that
    //  WINEDLLOVERRIDES is set regardless of how the user hits "Play".

    func patchLayerConfig(for game: GameInstall) {
        let layer = game.overrideLayer ?? game.bottle.layer
        switch layer {
        case .crossOver, .crossOverPreview:
            try? patchCrossOverConfig(for: game)
        case .whisky:
            try? patchWhiskyConfig(for: game)
        case .gameMac:
            try? patchGameMacConfig(for: game)
        case .porting:
            try? patchPortingKitConfig(for: game)
        case .wineskin:
            try? patchWineskinConfig(for: game)
        case .wine, .other:
            break   // user.reg patch above is sufficient for bare Wine
        }
    }

    // ── CrossOver: cxbottle.conf ───────────────────────────────────────────
    //
    //  CrossOver reads per-bottle environment overrides from cxbottle.conf.
    //  The [EnvironmentVariables] section uses quoted key=value pairs and
    //  CrossOver applies them verbatim to the Wine process environment before
    //  launching any exe in that bottle.

    private func patchCrossOverConfig(for game: GameInstall) throws {
        let configURL = game.bottle.path.appendingPathComponent("cxbottle.conf")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            print("[BepisLoader] cxbottle.conf not found at \(configURL.path)")
            return
        }

        var content = try String(contentsOf: configURL, encoding: .utf8)
        let section      = "[EnvironmentVariables]"
        let winhttpLine  = "\"WINEDLLOVERRIDES\"=\"winhttp,version=n,b\""

        if content.contains(section) {
            // Only add if not already present to avoid duplicates
            if !content.contains("WINEDLLOVERRIDES") {
                content = content.replacingOccurrences(
                    of: section,
                    with: "\(section)\n\(winhttpLine)"
                )
            }
        } else {
            content += "\n\n\(section)\n\(winhttpLine)\n"
        }

        try content.write(to: configURL, atomically: true, encoding: .utf8)
        print("[BepisLoader] Patched cxbottle.conf with WINEDLLOVERRIDES.")
    }

    // ── Whisky: bottle.plist ───────────────────────────────────────────────
    //
    //  Whisky stores per-bottle settings in a binary/XML plist. The key
    //  "environmentVariables" is a String→String dictionary that Whisky
    //  injects into the Wine process environment on every game launch.
    //
    //  Whisky 2.x: <bottle_dir>/bottle.plist
    //  Whisky 3.x: <bottles_parent>/<BottleName>.plist
    //
    //  After writing the plist, we also write a small shell wrapper at
    //  <bottle>/launch_bepis.sh that Whisky's "Run" button can be pointed
    //  at manually as a fallback — useful if Whisky ignores plist overrides
    //  for a particular game (which happens with some Steam titles).

    private func patchWhiskyConfig(for game: GameInstall) throws {
        // Try both known plist locations
        let candidates: [URL] = [
            game.bottle.path.appendingPathComponent("bottle.plist"),
            game.bottle.path.deletingLastPathComponent()
                .appendingPathComponent("\(game.bottle.name).plist"),
            // Whisky 3.x uses a UUID-named directory; the plist is named "bottle.plist"
            game.bottle.path.appendingPathComponent("Data/bottle.plist"),
        ]

        let fm = FileManager.default
        var plistURL: URL? = candidates.first { fm.fileExists(atPath: $0.path) }

        if plistURL == nil {
            // Create a fresh plist at the most likely location
            plistURL = candidates[0]
            print("[BepisLoader] Creating new Whisky bottle.plist at \(candidates[0].path)")
        }

        let url = plistURL!

        // Read existing plist or start fresh
        var plist: NSMutableDictionary
        if fm.fileExists(atPath: url.path),
           let existing = NSMutableDictionary(contentsOf: url) {
            plist = existing
        } else {
            plist = NSMutableDictionary()
        }

        var envVars = (plist["environmentVariables"] as? [String: String]) ?? [:]
        envVars["WINEDLLOVERRIDES"] = "winhttp,version=n,b"
        // DXVK_ASYNC prevents frame stalls during shader compilation — nice bonus
        envVars["DXVK_ASYNC"] = "1"
        plist["environmentVariables"] = envVars

        try (plist as NSDictionary).write(to: url)
        print("[BepisLoader] Patched Whisky bottle.plist.")

        // Also write a convenience launch wrapper script inside the bottle
        // so users can point Whisky's custom exe field at it if needed.
        writeWhiskyLaunchWrapper(for: game)
    }

    /// Writes a small shell wrapper inside the bottle that sets WINEDLLOVERRIDES
    /// and then exec's the real game exe. Whisky users can point their bottle's
    /// "Custom Program" field at this if the plist patch alone isn't enough.
    private func writeWhiskyLaunchWrapper(for game: GameInstall) {
        let wrapperURL = game.bottle.path.appendingPathComponent("launch_bepis.sh")
        let exePath = game.executablePath.path

        // Convert host path to Wine Z:\ path for use in the launch script
        let winePath = "Z:\\\\" + exePath.replacingOccurrences(of: "/", with: "\\\\")
        let preloaderPath = "Z:\\\\" + game.bepInExRoot.path.replacingOccurrences(of: "/", with: "\\\\") + "\\\\core\\\\BepInEx.Preloader.dll"

        let script = """
#!/usr/bin/env bash
# Auto-generated by BepisLoader — set this as Whisky's custom program if needed.
# It sets BepInEx env vars and launches the game exe directly via Wine.
export WINEDLLOVERRIDES="winhttp,version=n,b"
export DOORSTOP_ENABLE="TRUE"
export DOORSTOP_INVOKE_DLL_PATH="\(preloaderPath)"
exec "$(dirname "$0")/../../../MacOS/wine64" "\(winePath)" "$@"
"""
        try? script.write(to: wrapperURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: wrapperURL.path
        )
        print("[BepisLoader] Wrote Whisky launch wrapper at \(wrapperURL.path).")
    }

    // ── GameHub (GameMac): game-settings/<hash>.json ──────────────────────────
    //
    //  GameHub stores per-game settings in:
    //    ~/Library/Application Support/com.gamemac.www/gamehub/game-settings/<hash>.json
    //
    //  The filename is SHA256("steam:<platform_app_id>") — confirmed by cross-
    //  referencing game_container_store.json bindings against the filenames on disk.
    //
    //  The JSON almost certainly has an "environmentVariables" key (matching the
    //  "Environment Variables" UI option shown on gamemac.com). Writing
    //  WINEDLLOVERRIDES there is the correct, first-class way to inject env vars
    //  because GameHub applies them directly when it calls Wine — no registry
    //  overlay, no cxbottle.conf, no intermediary that can rebuild and wipe them.
    //
    //  We keep the registry patch as belt-and-suspenders for the case where
    //  GameHub ignores the settings file for a particular game.

    private func patchGameMacConfig(for game: GameInstall) throws {
        // Primary: write WINEDLLOVERRIDES into the per-game settings JSON.
        // Two lookup strategies, tried in order:
        //   1. game_container_store.json → platform_app_id → SHA256 filename
        //   2. Scan all settings files for matching binding_id (the container ID)
        //      This works even if game_container_store.json is unavailable.
        let containerId = game.bottle.path.lastPathComponent

        if let appId = gameMacAppId(for: game) {
            patchGameMacSettings(appId: appId, game: game)
        } else if let settingsURL = gameMacSettingsFileByBindingId(containerId) {
            patchGameMacSettingsFile(at: settingsURL, game: game)
        } else {
            print("[BepisLoader] Could not find GameHub settings file for \(game.name).")
            print("[BepisLoader] Launch the game once in GameHub (com.gamemac.www or com.www.gamemac), then re-run Install.")
        }

        // Belt-and-suspenders: also set via Wine registry
        patchWineRegistry(for: game.bottle)
        print("[BepisLoader] Patched GameHub registry for \(game.name).")
    }

    /// Returns the Steam platform_app_id for a game by looking it up in
    /// game_container_store.json, matched by the bottle's virtual_container_id.
    private func gameMacAppId(for game: GameInstall) -> String? {
        let home = NSHomeDirectory()
        let bundleIds = ["com.gamemac.www", "com.www.gamemac"]
        
        for bid in bundleIds {
            let storeURL = URL(fileURLWithPath: home)
                .appendingPathComponent("Library/Application Support/\(bid)/gamehub/game_container_store.json")
            guard let data = try? Data(contentsOf: storeURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let bindings = json["bindings"] as? [[String: Any]]
            else { continue }

            // Match by virtual_container_id — the last component of the bottle path
            let containerId = game.bottle.path.lastPathComponent
            if let appId = bindings
                .first(where: { ($0["virtual_container_id"] as? String) == containerId })
                .flatMap({ $0["platform_app_id"] as? String }) {
                return appId
            }
        }
        return nil
    }

    /// Fallback: scans all game-settings JSON files for one whose binding_id
    /// matches the container ID. The binding_id field in the settings file
    /// maps 1:1 to virtual_container_id in game_container_store.json.
    private func gameMacSettingsFileByBindingId(_ containerId: String) -> URL? {
        let home = NSHomeDirectory()
        let bundleIds = ["com.gamemac.www", "com.www.gamemac"]
        
        for bid in bundleIds {
            let settingsDir = URL(fileURLWithPath: home)
                .appendingPathComponent("Library/Application Support/\(bid)/gamehub/game-settings")
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: settingsDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            ) else { continue }

            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                // binding_id is an Int in the JSON; containerId is a String like "6"
                if let bindingId = root["binding_id"] as? Int,
                   String(bindingId) == containerId {
                    return file
                }
            }
        }
        return nil
    }

    /// Patches the per-game settings JSON with WINEDLLOVERRIDES.
    ///
    /// Confirmed file structure (from disk inspection):
    /// {
    ///   "stable_game_key_hash": "<hash>",   // SHA256("steam:<appId>") — the filename
    ///   "binding_id": 6,                    // matches virtual_container_id in game_container_store.json
    ///   "settings": {
    ///     ...                               // all per-game settings live here
    ///     "environment_variables": {        // snake_case, added by BepisLoader
    ///       "WINEDLLOVERRIDES": "winhttp=n,b;version=n,b"
    ///     }
    ///   }
    /// }
    private func patchGameMacSettings(appId: String, game: GameInstall) {
        let home = NSHomeDirectory()
        let bundleIds = ["com.gamemac.www", "com.www.gamemac"]
        
        for bid in bundleIds {
            let settingsDir = URL(fileURLWithPath: home)
                .appendingPathComponent("Library/Application Support/\(bid)/gamehub/game-settings")

            // Compute SHA256("steam:<appId>") to get the settings filename
            guard let hashData = "steam:\(appId)".data(using: .utf8) else { continue }
            var digest = [UInt8](repeating: 0, count: 32)
            hashData.withUnsafeBytes { ptr in
                _ = CC_SHA256(ptr.baseAddress, CC_LONG(hashData.count), &digest)
            }
            let hash = digest.map { String(format: "%02x", $0) }.joined()
            let settingsURL = settingsDir.appendingPathComponent("\(hash).json")

            // Must read the existing file — it contains critical settings like
            // compatibility_layer, graphics_stack etc. that we must not overwrite.
            if FileManager.default.fileExists(atPath: settingsURL.path) {
                patchGameMacSettingsFile(at: settingsURL, game: game)
                return
            }
        }
    }

    /// Core writer — merges WINEDLLOVERRIDES into an existing settings file.
    /// Called both from the hash-based path and the binding_id fallback path.
    /// Core writer — merges WINEDLLOVERRIDES into an existing settings file.
    /// Called both from the hash-based path and the binding_id fallback path.
    private func patchGameMacSettingsFile(at settingsURL: URL, game: GameInstall) {
        logDebug("Attempting to patch settings at: \(settingsURL.path)")
        guard let data = try? Data(contentsOf: settingsURL) else {
            logDebug("Failed to read settings file data.")
            return
        }
        guard var root = (try? JSONSerialization.jsonObject(with: data, options: [.mutableContainers])) as? [String: Any] else {
            logDebug("Failed to parse settings JSON.")
            return
        }
        
        // env vars confirmed at root → "settings" → "environment"
        var settings = (root["settings"] as? [String: Any]) ?? [:]
        var envVars  = (settings["environment"] as? [String: String]) ?? [:]

        // 1. Basic overrides (use both proxies to be sure)
        envVars["WINEDLLOVERRIDES"] = "winhttp=n,b;version=n,b"
        envVars["DOORSTOP_ENABLE"]  = "TRUE"
        
        // 2. Invoke DLL path
        let isIL2CPP = game.unityType == .il2cpp
        let targetDll = isIL2CPP ? "BepInEx\\core\\BepInEx.Unity.IL2CPP.dll" : "BepInEx\\core\\BepInEx.Preloader.dll"
        let winFormattedPath = game.gameDirectory.appendingPathComponent(targetDll.replacingOccurrences(of: "\\", with: "/")).path.replacingOccurrences(of: "/", with: "\\")
        envVars["DOORSTOP_INVOKE_DLL_PATH"] = "Z:" + winFormattedPath
        envVars["DOORSTOP_CORLIB_OVERRIDE"] = "FALSE"
        
        // 3. IL2CPP specific paths
        if isIL2CPP {
            let monoLib = game.gameDirectory.appendingPathComponent("mono/MonoBleedingEdge/EmbedRuntime/mono-2.0-sgen.dll").path.replacingOccurrences(of: "/", with: "\\")
            let monoEtc = game.gameDirectory.appendingPathComponent("mono/MonoBleedingEdge/etc").path.replacingOccurrences(of: "/", with: "\\")
            envVars["DOORSTOP_MONO_RUNTIME_LIB"] = "Z:" + monoLib
            envVars["DOORSTOP_MONO_CONFIG_DIR"]  = "Z:" + monoEtc
        }

        settings["environment"] = envVars
        root["settings"] = settings

        do {
            let patched = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
            try patched.write(to: settingsURL, options: .atomic)
            logDebug("Successfully injected Doorstop env vars into GameHub 'environment' for \(game.name).")
        } catch {
            logDebug("Failed to write patched JSON: \(error)")
        }
    }

    private func logDebug(_ msg: String) {
        let logURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/BepisLoader_Install.log")
        let timestamp = Date().description
        let line = "[\(timestamp)] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: logURL)
            }
        }
        print("[BepisLoader] \(msg)")
    }

    // ── Porting Kit: wine.cfg + user.reg ──────────────────────────────────
    //
    //  Porting Kit ships self-contained Wine engine bundles at:
    //    ~/Library/Application Support/PortingKit/engines/<engine>/
    //  Each engine has a wine.cfg (INI format) with a [DllOverrides] section
    //  that applies globally to all games using that engine.
    //  We patch every installed engine so the user doesn't have to pick one.

    private func patchPortingKitConfig(for game: GameInstall) throws {
        let enginesDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/PortingKit/engines")

        guard let engines = try? FileManager.default.contentsOfDirectory(
            at: enginesDir, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        ) else {
            print("[BepisLoader] No Porting Kit engines found.")
            return
        }

        for engine in engines {
            // Patch wine.cfg (Wine's own config file, read before the registry)
            let wineCfg = engine.appendingPathComponent("wine.cfg")
            if FileManager.default.fileExists(atPath: wineCfg.path) {
                try? patchWineCfg(at: wineCfg)
                print("[BepisLoader] Patched Porting Kit wine.cfg: \(engine.lastPathComponent)")
            }

            // Also patch the engine-level user.reg for belt-and-suspenders
            let engineReg = engine.appendingPathComponent("user.reg")
            if FileManager.default.fileExists(atPath: engineReg.path) {
                try? patchUserReg(at: engineReg)
            }
        }

        // Additionally patch the bottle's own user.reg
        let bottleReg = game.bottle.path.appendingPathComponent("user.reg")
        if FileManager.default.fileExists(atPath: bottleReg.path) {
            try? patchUserReg(at: bottleReg)
        }
    }

    // ── Wineskin: Info.plist LSEnvironment ────────────────────────────────
    //
    //  Wineskin wraps Wine in a macOS .app bundle. Environment variables are
    //  passed to the Wine process via the LSEnvironment key in Info.plist.
    //  The prefix lives at: MyGame.app/Contents/SharedSupport/prefix/
    //  So Info.plist is three levels up at: MyGame.app/Contents/Info.plist

    private func patchWineskinConfig(for game: GameInstall) throws {
        let infoPlist = game.bottle.path       // …/prefix
            .deletingLastPathComponent()        // …/SharedSupport
            .deletingLastPathComponent()        // …/Contents
            .appendingPathComponent("Info.plist")

        guard FileManager.default.fileExists(atPath: infoPlist.path) else {
            print("[BepisLoader] Wineskin Info.plist not found at \(infoPlist.path).")
            return
        }

        guard let plist = NSMutableDictionary(contentsOf: infoPlist) else {
            throw InstallerError.configWriteFailed("Could not read Wineskin Info.plist")
        }

        var lsEnv = (plist["LSEnvironment"] as? [String: String]) ?? [:]
        lsEnv["WINEDLLOVERRIDES"] = "winhttp,version=n,b"
        plist["LSEnvironment"] = lsEnv

        try (plist as NSDictionary).write(to: infoPlist)
        print("[BepisLoader] Patched Wineskin Info.plist LSEnvironment.")

        // Re-register the app so macOS Launch Services picks up the new plist
        let appBundle = infoPlist
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // MyGame.app
        shell(
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
            "-f", appBundle.path
        )
    }

    // ── Shared registry / config patchers ─────────────────────────────────
    //
    //  Wine .reg files have a strict format that is easy to corrupt with naive
    //  text replacement:
    //    - Section headers must use fully-qualified HKEY_ paths
    //    - Headers carry a trailing Unix timestamp: [HKEY_...] 1234567890
    //    - String values must be double-quoted
    //
    //  Corrupting a registry file causes GameHub/Wine to report errors like:
    //    [2004] failed to repair virtual overlay registry metadata
    //    Registry parse error: invalid quoted string literal
    //
    //  Primary strategy: call `wine reg add` via the layer's own Wine binary.
    //  Wine writes its own registry correctly by definition.
    //  Fallback: careful text patching that respects the HKEY_ format and
    //  inserts values after the header line rather than replacing the header.

    /// Sets winhttp + version DLL overrides using the layer's Wine binary.
    /// Falls back to text-patching user.reg only if no binary is found.
    func patchWineRegistry(for bottle: Bottle) {
        let key = "HKCU\\Software\\Wine\\DllOverrides"
        let env = environmentForBottle(bottle)

        if let wineBin = findWineBinary(for: bottle) {
            shell(env: env, wineBin, "reg", "add", key,
                  "/v", "winhttp", "/d", "native,builtin", "/f")
            shell(env: env, wineBin, "reg", "add", key,
                  "/v", "version", "/d", "native,builtin", "/f")
            print("[BepisLoader] Set DLL overrides via wine reg add for \(bottle.name).")
        } else {
            let userReg = bottle.path.appendingPathComponent("user.reg")
            if FileManager.default.fileExists(atPath: userReg.path) {
                try? patchUserReg(at: userReg)
            }
        }
    }

    /// Last-resort text patch for user.reg when no Wine binary is available.
    /// Inserts values after the existing section header (preserving its timestamp)
    /// or appends a correctly-formed new section with a fresh timestamp.
    private func patchUserReg(at regURL: URL) throws {
        var content = try String(contentsOf: regURL, encoding: .utf8)
        let hkeySection  = "HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides"
        let winhttpLine  = "\"winhttp\"=\"native,builtin\""
        let versionLine  = "\"version\"=\"native,builtin\""

        if let sectionRange = content.range(of: hkeySection) {
            guard !content.contains("\"winhttp\"") else { return }
            // Find the newline that ends this header line and insert after it
            if let eol = content[sectionRange.upperBound...].firstIndex(of: "\n") {
                let insertPoint = content.index(after: eol)
                content.insert(contentsOf: "\(winhttpLine)\n\(versionLine)\n", at: insertPoint)
            }
        } else {
            let ts = Int(Date().timeIntervalSince1970)
            content += "\n[\(hkeySection)] \(ts)\n\(winhttpLine)\n\(versionLine)\n"
        }
        try content.write(to: regURL, atomically: true, encoding: .utf8)
    }

    /// Last-resort text patch for system.reg.
    /// DllOverrides in system.reg lives under HKEY_LOCAL_MACHINE.
    private func patchSystemReg(at regURL: URL) throws {
        var content = try String(contentsOf: regURL, encoding: .utf8)
        let hkeySection  = "HKEY_LOCAL_MACHINE\\Software\\Wine\\DllOverrides"
        let winhttpLine  = "\"winhttp\"=\"native,builtin\""
        let versionLine  = "\"version\"=\"native,builtin\""

        if let sectionRange = content.range(of: hkeySection) {
            guard !content.contains("\"winhttp\"") else { return }
            if let eol = content[sectionRange.upperBound...].firstIndex(of: "\n") {
                let insertPoint = content.index(after: eol)
                content.insert(contentsOf: "\(winhttpLine)\n\(versionLine)\n", at: insertPoint)
            }
        } else {
            let ts = Int(Date().timeIntervalSince1970)
            content += "\n[\(hkeySection)] \(ts)\n\(winhttpLine)\n\(versionLine)\n"
        }
        try content.write(to: regURL, atomically: true, encoding: .utf8)
    }

    /// Patches a wine.cfg INI file's [DllOverrides] section (used by Porting Kit).
    private func patchWineCfg(at url: URL) throws {
        var content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let section = "[DllOverrides]"
        let winhttp = "winhttp=native,builtin"
        let version = "version=native,builtin"

        if content.contains(section) {
            if !content.contains("winhttp=") {
                content = content.replacingOccurrences(
                    of: section, with: "\(section)\n\(winhttp)\n\(version)"
                )
            }
        } else {
            content += "\n\(section)\n\(winhttp)\n\(version)\n"
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // ── Folder structure + metadata ────────────────────────────────────────

    private func createFolderStructure(for game: GameInstall) throws {
        for dir in [
            game.pluginsFolder,
            game.bepInExRoot.appendingPathComponent("config"),
            game.bepInExRoot.appendingPathComponent("patchers"),
        ] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func writeVersionFile(for game: GameInstall, version: String) throws {
        let versionFile = game.bepInExRoot.appendingPathComponent("BepInEx.version")
        try version.write(to: versionFile, atomically: true, encoding: .utf8)
    }

    private func enableBepInExConsole(for game: GameInstall) throws {
        let configDir = game.bepInExRoot.appendingPathComponent("config")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let cfg = """
[Logging.Console]
Enabled = true

[Logging.Disk]
Enabled = true
"""
        try? cfg.write(
            to: configDir.appendingPathComponent("BepInEx.cfg"),
            atomically: true, encoding: .utf8
        )
    }

    // ── Architecture detection ─────────────────────────────────────────────

    private func detectIs64Bit(_ url: URL) -> Bool {
        let result = shell("/usr/bin/file", url.path)
        if result.output.contains("PE32+") { return true }
        if result.output.contains("PE32")  { return false }
        return true   // default to 64-bit
    }

    // ── Wine binary / environment ──────────────────────────────────────────

    func findWineBinary(for bottle: Bottle) -> String? {
        if let known = findKnownWineBinary(for: bottle) { return known }

        for bundleId in bottle.layer.bundleIdentifiers {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
               let found = searchForWineBinary(in: appURL) {
                return found
            }
        }
        return nil
    }

    private func searchForWineBinary(in appURL: URL) -> String? {
        let result = shell("/usr/bin/find", appURL.path, "-name", "wine64", "-o", "-name", "wine")
        guard result.exitCode == 0 else { return nil }
        return result.output
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .first {
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir)
                    && !isDir.boolValue
                    && FileManager.default.isExecutableFile(atPath: $0)
            }
    }

    private func findKnownWineBinary(for bottle: Bottle) -> String? {
        let home = NSHomeDirectory()
        switch bottle.layer {
        case .crossOver, .crossOverPreview:
            return [
                "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine64",
                "/Applications/CrossOver Preview.app/Contents/SharedSupport/CrossOver/bin/wine64",
                "\(home)/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine64",
                "\(home)/Applications/CrossOver Preview.app/Contents/SharedSupport/CrossOver/bin/wine64",
            ].first { FileManager.default.fileExists(atPath: $0) }

        case .gameMac:
            let bundleIds = ["com.gamemac.www", "com.www.gamemac"]
            var gameMacContainers: [String] = []
            for bid in bundleIds {
                gameMacContainers.append("\(home)/Library/Containers/\(bid)/Data/Library/Application Support/\(bid)/wine-engine")
                gameMacContainers.append("\(home)/Library/Application Support/\(bid)/wine-engine")
            }

            for root in gameMacContainers {
                let cands = [
                    "\(root)/bin/wine64",
                    "\(root)/bin/wine",
                ]
                if let found = cands.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                    return found
                }
            }
            return nil

        case .wine:
            return [
                "/opt/homebrew/bin/wine64",
                "/usr/local/bin/wine64",
                "/usr/bin/wine64",
            ].first { FileManager.default.fileExists(atPath: $0) }

        case .wineskin:
            let shared = bottle.path.deletingLastPathComponent()
            return [
                shared.appendingPathComponent("wine/bin/wine64").path,
                shared.appendingPathComponent("wine/bin/wine").path,
            ].first { FileManager.default.fileExists(atPath: $0) }

        case .porting:
            let enginesDir = URL(fileURLWithPath: home)
                .appendingPathComponent("Library/Application Support/PortingKit/engines")
            guard let engines = try? FileManager.default.contentsOfDirectory(
                at: enginesDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
            for engine in engines {
                let cand = engine.appendingPathComponent("bin/wine64").path
                if FileManager.default.fileExists(atPath: cand) { return cand }
            }
            return nil

        case .whisky:
            return [
                "\(home)/Library/Containers/com.isaacmarovitz.Whisky/SharedSupport/Wine.bundle/Contents/MacOS/wine64",
                "/Applications/Whisky.app/Contents/Resources/Wine.bundle/Contents/MacOS/wine64",
            ].first { FileManager.default.fileExists(atPath: $0) }

        case .other:
            return nil
        }
    }

    func environmentForBottle(_ bottle: Bottle) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = bottle.path.path
        env["WINEDEBUG"]  = "-all"

        let home = NSHomeDirectory()
        switch bottle.layer {
        case .crossOver, .crossOverPreview:
            let cx  = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib"
            let cxp = "/Applications/CrossOver Preview.app/Contents/SharedSupport/CrossOver/lib"
            env["DYLD_LIBRARY_PATH"] = "\(cx):\(cxp):\(env["DYLD_LIBRARY_PATH"] ?? "")"
        case .whisky:
            let wLib = "\(home)/Library/Containers/com.isaacmarovitz.Whisky/SharedSupport/Wine.bundle/Contents/Resources/lib/wine"
            env["DYLD_LIBRARY_PATH"] = "\(wLib):\(env["DYLD_LIBRARY_PATH"] ?? "")"
        default:
            break
        }
        return env
    }

    // ── Shell helper ───────────────────────────

    @discardableResult
    func shell(_ args: String...) -> (exitCode: Int32, output: String) {
        shellRun(env: nil, args)
    }

    @discardableResult
    func shell(env: [String: String], _ args: String...) -> (exitCode: Int32, output: String) {
        shellRun(env: env, args)
    }

    @discardableResult
    private func shellRun(env: [String: String]? = nil, _ args: [String]) -> (exitCode: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: args[0])
        proc.arguments = Array(args.dropFirst())
        if let env = env { proc.environment = env }
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
