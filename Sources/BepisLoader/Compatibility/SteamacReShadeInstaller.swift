import Foundation

struct SteamacReShadeInstaller {
    /// Fetch Microsoft's tested SDK component on demand; do not redistribute it in the app.
    static func shaderCompiler() throws -> Data {
        let fm = FileManager.default
        let cache = ProcessInfo.processInfo.environment["BEPIS_DOWNLOAD_CACHE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BepisLoader/ReShade", isDirectory: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let dll = cache.appendingPathComponent("d3dcompiler_47.dll")
        if fm.fileExists(atPath: dll.path), let data = try? ReShadePackage.boundedRead(dll, maximum: 64 * 1024 * 1024), ReShadePackage.hash(data) == ReShadePackage.compilerHash { return data }
        let url = URL(string: "https://download.microsoft.com/download/B/0/C/B0C80BA3-8AD6-4958-810B-6882485230B5/standalonesdk/Installers/61d57a7a82309cd161a854a6f4619e52.cab")!
        let semaphore = DispatchSemaphore(value: 0)
        final class Response: @unchecked Sendable { var data: Data?; var error: Error? }
        let result = Response()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url) { data, response, error in
            result.error = error
            if let response = response as? HTTPURLResponse, response.statusCode == 200 { result.data = data }
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + 120) == .success else { task.cancel(); throw ReShadePackage.failure("Microsoft shader compiler download timed out. Try again.") }
        if let error = result.error { throw error }
        guard let data = result.data, data.count <= 32 * 1024 * 1024,
              ReShadePackage.hash(data) == "f736e161547095bb8d98c636b85fdfeb4070fefeee3c3745db3ce88f6eb1d9de" else { throw ReShadePackage.failure("Microsoft shader compiler download failed its integrity check.") }
        let scratch = cache.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let cab = scratch.appendingPathComponent("compiler.cab"); try data.write(to: cab)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xf", cab.path, "-C", scratch.path, "fil3585cb2ea5db13cc0838f8d06b5c9679"]
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ReShadePackage.failure("Cannot extract Microsoft's shader compiler.") }
        let extracted = try ReShadePackage.boundedRead(scratch.appendingPathComponent("fil3585cb2ea5db13cc0838f8d06b5c9679"), maximum: 64 * 1024 * 1024)
        guard ReShadePackage.hash(extracted) == ReShadePackage.compilerHash, ReShadePackage.isX64DLL(extracted) else { throw ReShadePackage.failure("Extracted shader compiler failed validation.") }
        try extracted.write(to: dll, options: .atomic)
        return extracted
    }
    static func install(_ snapshot: ReShadePackage, game: SteamacGame, endpoint: SteamacBridgeEndpoint,
                        bridge: SteamacBridge = .shared, existingOverrides: String = "") throws -> String {
        guard try bridge.handshake(endpoint: endpoint).capabilities.supports(.reShadeInstallV1) else {
            throw ReShadePackage.failure("Update Steamac to Kiwi Build 8 or later and restart its VM to enable checked ReShade installation.")
        }
        guard let install = try bridge.gameInstall(for: game, endpoint: endpoint),
              case .guest(let executable) = install.environmentExecutablePath,
              try bridge.peArchitecture(for: install, endpoint: endpoint) == .x64 else {
            throw ReShadePackage.failure("This installer currently supports Windows x64 Direct3D / DXGI games under Proton.")
        }
        guard try bridge.protonRuntime(for: game.appId, endpoint: endpoint) != nil else { throw ReShadePackage.failure("Select a Proton runtime in Steam's Compatibility settings first.") }
        // Compose before publication: malformed existing overrides cannot cause a late error.
        var root: String?, hash: String?
        if let adapter = AssetModAdapter.forGame(game.appId) {
            let profile = try AssetModProfiles.load(game: game, endpoint: endpoint, bridge: bridge)
            if !profile.baseRoot.isEmpty { root = game.installPath + "/.bepis-assets-active"; hash = adapter.executableSHA256 }
        }
        let options = try SteamacLaunchOptions.make(assetRoot: root, executableHash: hash, reshade: true, existingOverrides: existingOverrides)
        let target = try bridge.reShadeTarget(appId: game.appId, executable: executable, endpoint: endpoint)
        var package = snapshot
        if package.files["d3dcompiler_47.dll"] == nil { package.files["d3dcompiler_47.dll"] = try shaderCompiler() }
        guard package.totalBytes <= 256 * 1024 * 1024 else { throw ReShadePackage.failure("Package plus compiler exceeds 256 MiB.") }
        let stage = target.directory + "/.bepis-reshade-stage-" + UUID().uuidString.lowercased()
        try bridge.createGuestDirectory(stage + "/files", endpoint: endpoint)
        for (name, data) in package.files.sorted(by: { $0.key < $1.key }) {
            let path = stage + "/files/" + name
            try bridge.createGuestDirectory((path as NSString).deletingLastPathComponent, endpoint: endpoint)
            try bridge.writeGuestFile(data, to: path, endpoint: endpoint)
        }
        try bridge.writeGuestFile(try package.manifest(appId: game.appId, executable: executable, executableHash: target.executableHash), to: stage + "/manifest.json", endpoint: endpoint)
        try bridge.commitReShade(appId: game.appId, stage: stage, endpoint: endpoint)
        return "Installed ReShade for \(game.name).\n\nCopy into Steam → Properties → Launch Options:\n\n\(options)\n\nReplace your existing WINEDLLOVERRIDES with this single combined entry. Preserve other environment settings and arguments. Steam can stay open; restart the game. The selected preset is active; use Down arrow to toggle effects if selected during installation. ReShade runs separately from the managed asset profile."
    }
}
