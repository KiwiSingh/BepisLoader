import Foundation
import AppKit

// ─────────────────────────────────────────────
//  BepInExInstaller
//  Downloads BepInEx (Windows x64 build),
//  extracts it into the game directory inside
//  the Wine bottle, and writes Doorstop config.
// ─────────────────────────────────────────────

class BepInExInstaller {

    static let shared = BepInExInstaller()
    private init() {}

    // ── BepInEx GitHub release ─────────────────

    struct ReleaseAsset {
        let version: String
        let downloadURL: URL
        let sha256: String?
    }

    static func latestStable(is64Bit: Bool, isIL2CPP: Bool) -> ReleaseAsset {
        if isIL2CPP {
            // BepInEx 6 Bleeding Edge is required for IL2CPP
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

    // ── Installation ───────────────────────────

    typealias ProgressHandler = (Double, String) -> Void
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

    /// Full installation pipeline:
    ///   1. Download BepInEx zip
    ///   2. Extract into game directory
    ///   3. Write doorstop_config.ini
    ///   4. Inject WINEDLLOVERRIDES into the bottle's Wine registry
    func install(
        into game: GameInstall,
        asset: ReleaseAsset? = nil,
        progress: @escaping ProgressHandler,
        completion: @escaping CompletionHandler
    ) {
        // Use the provided asset or detect architecture/engine for default
        let is64Bit = detectIs64Bit(game.executablePath)
        let isIL2CPP = game.unityType == .il2cpp
        let release = asset ?? BepInExInstaller.latestStable(is64Bit: is64Bit, isIL2CPP: isIL2CPP)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                progress(0.0, "Preparing…")

                let gameDir = game.gameDirectory
                guard FileManager.default.fileExists(atPath: gameDir.path) else {
                    throw InstallerError.gameDirectoryNotFound
                }

                // 1. Download
                progress(0.05, "Downloading BepInEx \(release.version)…")
                let zipURL = try self.downloadRelease(release, progressHandler: { p in
                    progress(0.05 + p * 0.50, "Downloading… \(Int(p * 100))%")
                })

                // 2. Extract
                progress(0.50, "Cleaning up old installation…")
                let oldFiles = [
                    game.gameDirectory.appendingPathComponent("winhttp.dll"),
                    game.gameDirectory.appendingPathComponent("doorstop_config.ini"),
                    game.gameDirectory.appendingPathComponent(".doorstop_version"),
                    game.bepInExRoot.appendingPathComponent("BepInEx.version")
                ]
                for f in oldFiles where FileManager.default.fileExists(atPath: f.path) {
                    try? FileManager.default.removeItem(at: f)
                }

                progress(0.55, "Extracting…")
                try self.extract(zipURL, into: gameDir)

                // 2.5 Create version.dll proxy (for better compatibility)
                let winhttp = game.gameDirectory.appendingPathComponent("winhttp.dll")
                let versionDll = game.gameDirectory.appendingPathComponent("version.dll")
                if FileManager.default.fileExists(atPath: winhttp.path) {
                    try? FileManager.default.copyItem(at: winhttp, to: versionDll)
                }
                
                // 2.7 Strip quarantine attributes
                _ = self.shell("/usr/bin/xattr", "-d", "com.apple.quarantine", winhttp.path)
                _ = self.shell("/usr/bin/xattr", "-d", "com.apple.quarantine", versionDll.path)
                _ = self.shell("/usr/bin/xattr", "-rs", "com.apple.quarantine", game.bepInExRoot.path)

                // 3. Doorstop config
                if !isIL2CPP {
                    progress(0.75, "Writing Doorstop configuration…")
                    try self.writeDoorstopConfig(for: game)
                }

                // 4. Wine DLL override in registry
                progress(0.85, "Configuring Wine DLL overrides…")
                try self.injectWineDllOverride(for: game)
                
                // 4.5 Patch cxbottle.conf for CrossOver bottles
                if game.bottle.layer == .crossOver || game.bottle.layer == .crossOverPreview {
                    try? self.patchCrossOverConfig(for: game)
                }

                // 5. Create standard folder structure
                progress(0.92, "Creating plugin directories…")
                try self.createFolderStructure(for: game)

                // 6. Write version file so BottleScanner doesn't show "unknown" before first launch
                try self.writeVersionFile(for: game, version: release.version)

                // 7. Pre-enable console for debugging
                try? self.enableBepInExConsole(for: game)

                progress(1.0, "Installation complete ✓")
                DispatchQueue.main.async { completion(.success(())) }

            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Removes BepInEx from a game installation
    func uninstall(from game: GameInstall) throws {
        let fm = FileManager.default

        // Remove BepInEx directory
        if fm.fileExists(atPath: game.bepInExRoot.path) {
            try fm.removeItem(at: game.bepInExRoot)
        }
        // Remove Doorstop files
        let doorstopFiles = [
            game.gameDirectory.appendingPathComponent("winhttp.dll"),
            game.gameDirectory.appendingPathComponent("doorstop_config.ini"),
            game.gameDirectory.appendingPathComponent(".doorstop_version"),
        ]
        for f in doorstopFiles where fm.fileExists(atPath: f.path) {
            try fm.removeItem(at: f)
        }
    }

    // ── Private helpers ────────────────────────

    private func downloadRelease(
        _ asset: ReleaseAsset,
        progressHandler: (Double) -> Void
    ) throws -> URL {
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bepinex_\(asset.version).zip")

        if FileManager.default.fileExists(atPath: dest.path) {
            progressHandler(1.0)
            return dest   // cached
        }

        // Synchronous download with URLSession (fine on background thread)
        var downloadError: Error?
        var localURL: URL?

        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.downloadTask(with: asset.downloadURL) { url, _, error in
            downloadError = error
            if let url = url {
                try? FileManager.default.moveItem(at: url, to: dest)
                localURL = dest
            }
            sem.signal()
        }
        task.resume()
        sem.wait()

        if let err = downloadError { throw InstallerError.downloadFailed(err.localizedDescription) }
        guard let url = localURL else { throw InstallerError.downloadFailed("No file received") }
        return url
    }

    private func extract(_ zipURL: URL, into targetDir: URL) throws {
        // Use the system unzip binary — always available on macOS
        let result = shell("/usr/bin/unzip", "-o", zipURL.path, "-d", targetDir.path)
        if result.exitCode != 0 {
            throw InstallerError.extractionFailed(result.output)
        }
    }

    private func writeDoorstopConfig(for game: GameInstall) throws {
        // BepInEx uses Unity Doorstop to inject the bootstrap loader.
        // We must tell Doorstop where the BepInEx chainloader DLL lives.
        let chainloaderPath = "BepInEx\\core\\BepInEx.Preloader.dll"  // Windows-style path inside Wine
        let config = """
[UnityDoorstop]
enabled=true
targetAssembly=\(chainloaderPath)
redirectOutputLog=false
ignoreDisableSwitch=false
"""
        do {
            try config.write(to: game.doorstopConfig, atomically: true, encoding: .utf8)
        } catch {
            throw InstallerError.configWriteFailed(error.localizedDescription)
        }
    }

    /// Adds `winhttp=native,builtin` to the bottle's Wine registry so Doorstop is loaded.
    private func injectWineDllOverride(for game: GameInstall) throws {
        let bottle = game.bottle
        let userRegURL = bottle.path.appendingPathComponent("user.reg")
        
        guard FileManager.default.fileExists(atPath: userRegURL.path) else {
            print("[BepisLoader] WARN: user.reg not found at \(userRegURL.path). Skipping direct registry patch.")
            return
        }
        
        do {
            var regContent = try String(contentsOf: userRegURL, encoding: .utf8)
            let winhttpOverride = "\"winhttp\"=\"native,builtin\""
            let versionOverride = "\"version\"=\"native,builtin\""
            
            // Regex to find the [Software\\Wine\\DllOverrides] section (with or without timestamp)
            let sectionPattern = "\\[Software\\\\\\\\Wine\\\\\\\\DllOverrides\\].*"
            if let range = regContent.range(of: sectionPattern, options: .regularExpression) {
                // Found existing section, insert after it
                let sectionHeader = regContent[range]
                if !regContent.contains(winhttpOverride) {
                    regContent = regContent.replacingOccurrences(of: sectionHeader, with: "\(sectionHeader)\n\(winhttpOverride)")
                }
                if !regContent.contains(versionOverride) {
                    // Update header if we just added winhttp
                    let newHeader = regContent.range(of: sectionPattern, options: .regularExpression).map { regContent[$0] } ?? sectionHeader
                    regContent = regContent.replacingOccurrences(of: newHeader, with: "\(newHeader)\n\(versionOverride)")
                }
            } else {
                // No section found, create a new one
                regContent += "\n\n[Software\\\\Wine\\\\DllOverrides]\n\(winhttpOverride)\n\(versionOverride)\n"
            }
            
            try regContent.write(to: userRegURL, atomically: true, encoding: .utf8)
            print("[BepisLoader] Successfully patched user.reg at: \(userRegURL.path)")
            print("[BepisLoader] with winhttp/version overrides.")
        } catch {
            print("[BepisLoader] ERROR: Could not patch user.reg: \(error.localizedDescription)")
        }
    }

    private func createFolderStructure(for game: GameInstall) throws {
        let fm = FileManager.default
        let dirs = [
            game.pluginsFolder,
            game.bepInExRoot.appendingPathComponent("config"),
            game.bepInExRoot.appendingPathComponent("patchers"),
        ]
        for dir in dirs {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func writeVersionFile(for game: GameInstall, version: String) throws {
        let versionFile = game.bepInExRoot.appendingPathComponent("BepInEx.version")
        try version.write(to: versionFile, atomically: true, encoding: .utf8)
    }

    private func detectIs64Bit(_ url: URL) -> Bool {
        // Simple heuristic using 'file' command to check PE architecture
        let result = shell("/usr/bin/file", url.path)
        if result.output.contains("PE32+") { return true }
        if result.output.contains("PE32") { return false }
        // Fallback to 64-bit as it's most common nowadays
        return true
    }

    // ── Wine binary / environment helpers ──────

    func findWineBinary(for bottle: Bottle) -> String? {
        // 1. Try known static paths
        if let staticPath = findKnownWineBinary(for: bottle) {
            return staticPath
        }
        
        // 2. Fallback: ask macOS where the app is and search its contents
        for bundleId in bottle.layer.bundleIdentifiers {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                if let found = searchForWineBinary(in: appURL) {
                    return found
                }
            }
        }
        
        return nil
    }
    
    private func searchForWineBinary(in appURL: URL) -> String? {
        let result = shell("/usr/bin/find", appURL.path, "-name", "wine64", "-o", "-name", "wine")
        if result.exitCode == 0 {
            let lines = result.output.components(separatedBy: .newlines).filter { !$0.isEmpty }
            for line in lines {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: line, isDirectory: &isDir), !isDir.boolValue {
                    if FileManager.default.isExecutableFile(atPath: line) {
                        return line
                    }
                }
            }
        }
        return nil
    }

    private func findKnownWineBinary(for bottle: Bottle) -> String? {
        switch bottle.layer {
        case .crossOver, .crossOverPreview:
            let candidates = [
                "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine64",
                "/Applications/CrossOver Preview.app/Contents/SharedSupport/CrossOver/bin/wine64",
                "\(NSHomeDirectory())/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine64",
                "\(NSHomeDirectory())/Applications/CrossOver Preview.app/Contents/SharedSupport/CrossOver/bin/wine64"
            ]
            return candidates.first { FileManager.default.fileExists(atPath: $0) }

        case .gameHub:
            // GameHub bundles wine in its app resources
            let candidates = [
                "/Applications/GameHub.app/Contents/Resources/wine/bin/wine64",
                "\(NSHomeDirectory())/Applications/GameHub.app/Contents/Resources/wine/bin/wine64",
            ]
            return candidates.first { FileManager.default.fileExists(atPath: $0) }

        case .wine:
            // Try common Homebrew / system paths
            let candidates = ["/usr/local/bin/wine64", "/opt/homebrew/bin/wine64", "/usr/bin/wine64"]
            return candidates.first { FileManager.default.fileExists(atPath: $0) }

        case .wineskin:
            let sharedSupport = bottle.path.deletingLastPathComponent()
            let candidates = [
                sharedSupport.appendingPathComponent("wine/bin/wine64").path,
                sharedSupport.appendingPathComponent("wine/bin/wine").path
            ]
            return candidates.first { FileManager.default.fileExists(atPath: $0) }

        case .porting:
            let enginesDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/PortingKit/engines")
            guard let engines = try? FileManager.default.contentsOfDirectory(at: enginesDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
            for engine in engines {
                let cand = engine.appendingPathComponent("bin/wine64").path
                if FileManager.default.fileExists(atPath: cand) { return cand }
            }
            return nil
            
        case .whisky:
            let candidates = [
                "\(NSHomeDirectory())/Library/Containers/com.isaacmarovitz.Whisky/SharedSupport/Wine.bundle/Contents/MacOS/wine64",
                "/Applications/Whisky.app/Contents/Resources/Wine.bundle/Contents/MacOS/wine64"
            ]
            return candidates.first { FileManager.default.fileExists(atPath: $0) }
            
        case .other:
            return nil
        }
    }

    /// Returns a suitable WINEPREFIX environment for running wine commands.
    func environmentForBottle(_ bottle: Bottle) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = bottle.path.path
        env["WINEDEBUG"]  = "-all"   // suppress debug spam

        if bottle.layer == .crossOver || bottle.layer == .crossOverPreview {
            // CrossOver needs its own library paths
            let cxLib = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib"
            let cxLibPreview = "/Applications/CrossOver Preview.app/Contents/SharedSupport/CrossOver/lib"
            let existing = env["DYLD_LIBRARY_PATH"] ?? ""
            env["DYLD_LIBRARY_PATH"] = "\(cxLib):\(cxLibPreview):\(existing)"
        } else if bottle.layer == .whisky {
            // Whisky environment
            let whiskyLib = "\(NSHomeDirectory())/Library/Containers/com.isaacmarovitz.Whisky/SharedSupport/Wine.bundle/Contents/Resources/lib/wine"
            let existing = env["DYLD_LIBRARY_PATH"] ?? ""
            env["DYLD_LIBRARY_PATH"] = "\(whiskyLib):\(existing)"
        }
        return env
    }

    // ── Shell helper ───────────────────────────

    @discardableResult
    private func shell(_ args: String...) -> (exitCode: Int32, output: String) {
        shell(env: nil, args)
    }

    @discardableResult
    private func shell(env: [String: String]? = nil, _ args: String...) -> (exitCode: Int32, output: String) {
        shell(env: env, args)
    }

    @discardableResult
    private func shell(env: [String: String]? = nil, _ args: [String]) -> (exitCode: Int32, output: String) {
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
        let output = String(data: data, encoding: .utf8) ?? ""
        return (proc.terminationStatus, output)
    }

    private func patchCrossOverConfig(for game: GameInstall) throws {
        let configURL = game.bottle.path.appendingPathComponent("cxbottle.conf")
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        
        var content = try String(contentsOf: configURL, encoding: .utf8)
        let envSection = "[EnvironmentVariables]"
        let override = "WINEDLLOVERRIDES=winhttp,version=n,b"
        
        if content.contains(envSection) {
            if !content.contains("WINEDLLOVERRIDES") {
                content = content.replacingOccurrences(of: envSection, with: "\(envSection)\n\(override)")
            }
        } else {
            content += "\n\n\(envSection)\n\(override)\n"
        }
        
        try content.write(to: configURL, atomically: true, encoding: .utf8)
        print("[BepisLoader] Patched cxbottle.conf for global overrides.")
    }

    private func enableBepInExConsole(for game: GameInstall) throws {
        let configDir = game.bepInExRoot.appendingPathComponent("config")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        
        let configFile = configDir.appendingPathComponent("BepInEx.cfg")
        let configContent = """
[Logging.Console]
Enabled = true

[Logging.Disk]
Enabled = true
"""
        try? configContent.write(to: configFile, atomically: true, encoding: .utf8)
    }
}
