import Foundation
import AppKit

// ─────────────────────────────────────────────
//  WineEnvironment
//
//  Generic Wine / compatibility-layer plumbing.
//  This intentionally contains no BepInEx logic,
//  allowing other modding frameworks such as
//  Reloaded-II to use the same environment.
// ─────────────────────────────────────────────

final class WineEnvironment {

    static let shared = WineEnvironment()
    private init() {}

    // ── Wine binary discovery ─────────────────

    func findWineBinary(for bottle: Bottle) -> String? {
        if let known = findKnownWineBinary(for: bottle) {
            return known
        }

        for bundleId in bottle.layer.bundleIdentifiers {
            if let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleId
            ),
               let found = searchForWineBinary(in: appURL) {
                return found
            }
        }

        return nil
    }

    private func searchForWineBinary(in appURL: URL) -> String? {
        let result = shell(
            "/usr/bin/find",
            appURL.path,
            "-name", "wine64",
            "-o", "-name", "wine"
        )

        guard result.exitCode == 0 else {
            return nil
        }

        return result.output
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .first {
                var isDir: ObjCBool = false

                return FileManager.default.fileExists(
                    atPath: $0,
                    isDirectory: &isDir
                )
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
            ].first {
                FileManager.default.fileExists(atPath: $0)
            }

        case .gameMac:
            let bundleIds = [
                "com.gamemac.www",
                "com.www.gamemac"
            ]

            var roots: [String] = []

            for bundleId in bundleIds {
                roots.append(
                    "\(home)/Library/Containers/\(bundleId)/Data/Library/Application Support/\(bundleId)/wine-engine"
                )
                roots.append(
                    "\(home)/Library/Application Support/\(bundleId)/wine-engine"
                )
            }

            for root in roots {
                let candidates = [
                    "\(root)/bin/wine64",
                    "\(root)/bin/wine",
                ]

                if let found = candidates.first(where: {
                    FileManager.default.fileExists(atPath: $0)
                }) {
                    return found
                }
            }

            return nil

        case .wine:
            return [
                "/opt/homebrew/bin/wine64",
                "/usr/local/bin/wine64",
                "/usr/bin/wine64",
            ].first {
                FileManager.default.fileExists(atPath: $0)
            }

        case .wineskin:
            let shared = bottle.path.deletingLastPathComponent()

            return [
                shared.appendingPathComponent("wine/bin/wine64").path,
                shared.appendingPathComponent("wine/bin/wine").path,
            ].first {
                FileManager.default.fileExists(atPath: $0)
            }

        case .porting:
            let enginesDir = URL(fileURLWithPath: home)
                .appendingPathComponent(
                    "Library/Application Support/PortingKit/engines"
                )

            guard let engines = try? FileManager.default.contentsOfDirectory(
                at: enginesDir,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else {
                return nil
            }

            for engine in engines {
                let candidate = engine
                    .appendingPathComponent("bin/wine64")
                    .path

                if FileManager.default.fileExists(atPath: candidate) {
                    return candidate
                }
            }

            return nil

        case .whisky:
            return [
                "\(home)/Library/Containers/com.isaacmarovitz.Whisky/SharedSupport/Wine.bundle/Contents/MacOS/wine64",
                "/Applications/Whisky.app/Contents/Resources/Wine.bundle/Contents/MacOS/wine64",
            ].first {
                FileManager.default.fileExists(atPath: $0)
            }

        case .other:
            return nil
        }
    }

    // ── Environment ───────────────────────────

    func environment(for bottle: Bottle) -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        env["WINEPREFIX"] = bottle.path.path
        env["WINEDEBUG"] = "-all"

        let home = NSHomeDirectory()

        switch bottle.layer {

        case .crossOver, .crossOverPreview:
            let crossover =
                "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib"

            let preview =
                "/Applications/CrossOver Preview.app/Contents/SharedSupport/CrossOver/lib"

            env["DYLD_LIBRARY_PATH"] =
                "\(crossover):\(preview):\(env["DYLD_LIBRARY_PATH"] ?? "")"

        case .whisky:
            let library =
                "\(home)/Library/Containers/com.isaacmarovitz.Whisky/SharedSupport/Wine.bundle/Contents/Resources/lib/wine"

            env["DYLD_LIBRARY_PATH"] =
                "\(library):\(env["DYLD_LIBRARY_PATH"] ?? "")"

        default:
            break
        }

        return env
    }

    // ── Process helper ────────────────────────

    private func shell(_ args: String...) -> (
        exitCode: Int32,
        output: String
    ) {
        guard let executable = args.first else {
            return (-1, "")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(args.dropFirst())

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, error.localizedDescription)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        return (
            process.terminationStatus,
            String(data: data, encoding: .utf8) ?? ""
        )
    }
}
