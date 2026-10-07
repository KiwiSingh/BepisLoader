import Foundation

// ─────────────────────────────────────────────
//  ReloadedIIModConfig
//
//  Codable representation of Reloaded-II's
//  current ModConfig.json metadata.
//
//  BepisLoader only needs metadata required for
//  discovery, display, compatibility and basic
//  management. Unknown JSON fields are naturally
//  ignored by JSONDecoder.
// ─────────────────────────────────────────────

struct ReloadedIIModConfig:
    Codable,
    Hashable
{
    var modId: String
    var modName: String
    var modAuthor: String
    var modVersion: String
    var modDescription: String

    var modDll: String
    var modIcon: String

    var modR2RManagedDll32: String
    var modR2RManagedDll64: String

    var modNativeDll32: String
    var modNativeDll64: String

    var tags: [String]

    var canUnload: Bool?
    var hasExports: Bool?

    var isLibrary: Bool

    var releaseMetadataFileName: String

    var ignoreRegexes: [String]
    var includeRegexes: [String]

    var isUniversalMod: Bool

    var modDependencies: [String]
    var optionalDependencies: [String]
    var supportedAppId: [String]

    var projectUrl: String

    enum CodingKeys:
        String,
        CodingKey
    {
        case modId =
            "ModId"

        case modName =
            "ModName"

        case modAuthor =
            "ModAuthor"

        case modVersion =
            "ModVersion"

        case modDescription =
            "ModDescription"

        case modDll =
            "ModDll"

        case modIcon =
            "ModIcon"

        case modR2RManagedDll32 =
            "ModR2RManagedDll32"

        case modR2RManagedDll64 =
            "ModR2RManagedDll64"

        case modNativeDll32 =
            "ModNativeDll32"

        case modNativeDll64 =
            "ModNativeDll64"

        case tags =
            "Tags"

        case canUnload =
            "CanUnload"

        case hasExports =
            "HasExports"

        case isLibrary =
            "IsLibrary"

        case releaseMetadataFileName =
            "ReleaseMetadataFileName"

        case ignoreRegexes =
            "IgnoreRegexes"

        case includeRegexes =
            "IncludeRegexes"

        case isUniversalMod =
            "IsUniversalMod"

        case modDependencies =
            "ModDependencies"

        case optionalDependencies =
            "OptionalDependencies"

        case supportedAppId =
            "SupportedAppId"

        case projectUrl =
            "ProjectUrl"
    }

    init(
        from decoder: Decoder
    ) throws {
        let c = try decoder.container(
            keyedBy: CodingKeys.self
        )

        modId = try c.decode(
            String.self,
            forKey: .modId
        )

        modName =
            try c.decodeIfPresent(
                String.self,
                forKey: .modName
            ) ?? modId

        modAuthor =
            try c.decodeIfPresent(
                String.self,
                forKey: .modAuthor
            ) ?? ""

        modVersion =
            try c.decodeIfPresent(
                String.self,
                forKey: .modVersion
            ) ?? ""

        modDescription =
            try c.decodeIfPresent(
                String.self,
                forKey: .modDescription
            ) ?? ""

        modDll =
            try c.decodeIfPresent(
                String.self,
                forKey: .modDll
            ) ?? ""

        modIcon =
            try c.decodeIfPresent(
                String.self,
                forKey: .modIcon
            ) ?? ""

        modR2RManagedDll32 =
            try c.decodeIfPresent(
                String.self,
                forKey: .modR2RManagedDll32
            ) ?? ""

        modR2RManagedDll64 =
            try c.decodeIfPresent(
                String.self,
                forKey: .modR2RManagedDll64
            ) ?? ""

        modNativeDll32 =
            try c.decodeIfPresent(
                String.self,
                forKey: .modNativeDll32
            ) ?? ""

        modNativeDll64 =
            try c.decodeIfPresent(
                String.self,
                forKey: .modNativeDll64
            ) ?? ""

        tags =
            try c.decodeIfPresent(
                [String].self,
                forKey: .tags
            ) ?? []

        canUnload =
            try c.decodeIfPresent(
                Bool.self,
                forKey: .canUnload
            )

        hasExports =
            try c.decodeIfPresent(
                Bool.self,
                forKey: .hasExports
            )

        isLibrary =
            try c.decodeIfPresent(
                Bool.self,
                forKey: .isLibrary
            ) ?? false

        releaseMetadataFileName =
            try c.decodeIfPresent(
                String.self,
                forKey:
                    .releaseMetadataFileName
            ) ?? "Sewer56.Update.ReleaseMetadata.json"

        ignoreRegexes =
            try c.decodeIfPresent(
                [String].self,
                forKey: .ignoreRegexes
            ) ?? []

        includeRegexes =
            try c.decodeIfPresent(
                [String].self,
                forKey: .includeRegexes
            ) ?? []

        isUniversalMod =
            try c.decodeIfPresent(
                Bool.self,
                forKey: .isUniversalMod
            ) ?? false

        modDependencies =
            try c.decodeIfPresent(
                [String].self,
                forKey: .modDependencies
            ) ?? []

        optionalDependencies =
            try c.decodeIfPresent(
                [String].self,
                forKey: .optionalDependencies
            ) ?? []

        supportedAppId =
            try c.decodeIfPresent(
                [String].self,
                forKey: .supportedAppId
            ) ?? []

        projectUrl =
            try c.decodeIfPresent(
                String.self,
                forKey: .projectUrl
            ) ?? ""
    }
}

// ─────────────────────────────────────────────
//  Discovered mod
// ─────────────────────────────────────────────

struct ReloadedIIDiscoveredMod:
    Hashable
{
    let config:
        ReloadedIIModConfig

    let configURL: URL

    var directory: URL {
        configURL
            .deletingLastPathComponent()
    }
}

// ─────────────────────────────────────────────
//  Discovery
// ─────────────────────────────────────────────

enum ReloadedIIModDiscovery {

    private static let fm =
        FileManager.default

    static func mods(
        under root: URL
    ) -> [ReloadedIIDiscoveredMod] {
        guard let enumerator =
                fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: [
                        .isRegularFileKey
                    ],
                    options: [
                        .skipsHiddenFiles
                    ]
                )
        else {
            return []
        }

        var result:
            [ReloadedIIDiscoveredMod] = []

        var seenIds =
            Set<String>()

        for case let url as URL in enumerator {
            guard url.lastPathComponent
                    .caseInsensitiveCompare(
                        "ModConfig.json"
                    ) == .orderedSame
            else {
                continue
            }

            guard let mod = read(
                at: url
            ) else {
                continue
            }

            let normalizedId =
                mod.config.modId.lowercased()

            // Reloaded-II deduplicates discovered
            // mods by ModId.
            guard seenIds.insert(
                normalizedId
            ).inserted else {
                continue
            }

            result.append(
                mod
            )
        }

        return result
    }

    static func firstMod(
        under root: URL
    ) -> ReloadedIIDiscoveredMod? {
        mods(
            under: root
        ).first
    }

    static func read(
        at configURL: URL
    ) -> ReloadedIIDiscoveredMod? {
        guard let data =
                try? Data(
                    contentsOf: configURL
                )
        else {
            return nil
        }

        guard let config =
                try? JSONDecoder().decode(
                    ReloadedIIModConfig.self,
                    from: data
                )
        else {
            return nil
        }

        guard !config.modId
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                .isEmpty
        else {
            return nil
        }

        return ReloadedIIDiscoveredMod(
            config: config,
            configURL: configURL
        )
    }
}
