import Foundation

/// Compose a single override assignment: separate assignments would discard loaders.
enum SteamacLaunchOptions {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
    static func make(assetRoot: String? = nil, executableHash: String? = nil,
                     reshade: Bool = false, existingOverrides: String = "") throws -> String {
        var overrides: [(String, String)] = []
        for entry in existingOverrides.split(separator: ";") {
            let parts = entry.split(separator: "=", omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw invalidOverrides() }
            let names = parts[0].split(separator: ",", omittingEmptySubsequences: false)
            let mode = parts[1].trimmingCharacters(in: .whitespaces)
            guard ["", "n", "b", "n,b", "b,n"].contains(mode) else { throw invalidOverrides() }
            for rawName in names {
                let name = rawName.trimmingCharacters(in: .whitespaces).lowercased()
                guard !name.isEmpty, name.utf8.allSatisfy({ ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95 || $0 == 45 || $0 == 46 || $0 == 42 }) else { throw invalidOverrides() }
                overrides.removeAll { $0.0 == name }; overrides.append((name, mode))
            }
        }
        func require(_ name: String) {
            overrides.removeAll { $0.0 == name }; overrides.append((name, "n,b"))
        }
        var settings: [String] = []
        if let root = assetRoot, let hash = executableHash {
            settings.append("BEPIS_MVGL_ASSET_ROOT=" + quote("Z:" + root))
            settings.append("BEPIS_MVGL_EXE_SHA256=" + quote(hash))
            require("winmm")
        }
        if reshade { require("dxgi"); require("d3dcompiler_47") }
        if !overrides.isEmpty {
            settings.append("WINEDLLOVERRIDES=" + quote(overrides.map { "\($0.0)=\($0.1)" }.joined(separator: ";")))
        }
        settings.append("%command%")
        return settings.joined(separator: " ")
    }
    private static func invalidOverrides() -> NSError {
        NSError(domain: "SteamacLaunchOptions", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter only the value of WINEDLLOVERRIDES, for example winmm=n,b;dinput8=n,b."])
    }
}
