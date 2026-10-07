import Foundation


// ─────────────────────────────────────────────
//  Steamac Discovery
//
//  Discovers the macOS host application and its
//  configured SteamOS disk.
//
//  This is intentionally host-side only. Reading
//  Steam libraries, Proton prefixes, or guest files
//  belongs to the Steamac bridge.
// ─────────────────────────────────────────────

enum SteamacImplementation:
    String,
    Codable,
    Hashable
{
    /// An installation exposing KiwiSingh's enhanced
    /// integration metadata in a future bridge.
    ///
    /// Patch 37 cannot truthfully distinguish the fork
    /// from upstream solely from the shared bundle ID,
    /// so discovery reports compatible installations
    /// without guessing.
    case kiwiSingh =
        "KiwiSingh/steamac"

    case upstream =
        "fxgl/steamac"

    case compatible =
        "Steamac-compatible"
}


struct SteamacInstallation:
    Identifiable,
    Hashable
{
    let id:
        String

    let applicationURL:
        URL

    let launcherURL:
        URL

    let diskImageURL:
        URL?

    let version:
        String?

    let implementation:
        SteamacImplementation

    var environment:
        GameEnvironment
    {
        .steamac(
            identifier: id
        )
    }

    var hasConfiguredDisk:
        Bool
    {
        guard let diskImageURL
        else {
            return false
        }

        return FileManager.default
            .fileExists(
                atPath:
                    diskImageURL.path
            )
    }
}


final class SteamacDiscovery {

    static let shared =
        SteamacDiscovery()

    static let bundleIdentifier =
        "es.fxgam.steamac"

    static let executableName =
        "steamac-vm"

    static let applicationName =
        "FX Steam Launcher.app"

    static let diskImagePreferenceKey =
        "diskImage"

    private let fm:
        FileManager

    private init(
        fileManager:
            FileManager = .default
    ) {
        fm =
            fileManager
    }


    // MARK: - Discovery

    func installations()
        -> [SteamacInstallation]
    {
        var results:
            [SteamacInstallation] = []

        var seen =
            Set<String>()

        for candidate
            in applicationCandidates()
        {
            guard let installation =
                    inspect(
                        applicationURL:
                            candidate
                    )
            else {
                continue
            }

            let canonical =
                installation
                    .applicationURL
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path

            guard seen.insert(
                canonical
            ).inserted
            else {
                continue
            }

            results.append(
                installation
            )
        }

        return results.sorted {
            $0.applicationURL.path
                .localizedCaseInsensitiveCompare(
                    $1.applicationURL.path
                )
                == .orderedAscending
        }
    }


    func primaryInstallation()
        -> SteamacInstallation?
    {
        installations().first
    }


    // MARK: - Candidate locations

    private func applicationCandidates()
        -> [URL]
    {
        let home =
            fm.homeDirectoryForCurrentUser

        var candidates:
            [URL] = [
                URL(
                    fileURLWithPath:
                        "/Applications"
                )
                .appendingPathComponent(
                    Self.applicationName,
                    isDirectory: true
                ),

                home
                    .appendingPathComponent(
                        "Applications",
                        isDirectory: true
                    )
                    .appendingPathComponent(
                        Self.applicationName,
                        isDirectory: true
                    )
            ]

        // Spotlight is deliberately not required for
        // correctness. It merely lets us find copies
        // installed on external volumes or elsewhere.
        candidates.append(
            contentsOf:
                spotlightCandidates()
        )

        return candidates
    }


    private func spotlightCandidates()
        -> [URL]
    {
        let process =
            Process()

        let output =
            Pipe()

        process.executableURL =
            URL(
                fileURLWithPath:
                    "/usr/bin/mdfind"
            )

        process.arguments = [
            "kMDItemCFBundleIdentifier == '\(Self.bundleIdentifier)'"
        ]

        process.standardOutput =
            output

        process.standardError =
            FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        guard process.terminationStatus == 0
        else {
            return []
        }

        let data =
            output
                .fileHandleForReading
                .readDataToEndOfFile()

        guard let string =
                String(
                    data: data,
                    encoding: .utf8
                )
        else {
            return []
        }

        return string
            .split(
                whereSeparator:
                    \.isNewline
            )
            .map {
                URL(
                    fileURLWithPath:
                        String($0),
                    isDirectory: true
                )
            }
    }


    // MARK: - Inspection

    private func inspect(
        applicationURL:
            URL
    ) -> SteamacInstallation? {
        guard fm.fileExists(
            atPath:
                applicationURL.path
        )
        else {
            return nil
        }

        guard let bundle =
                Bundle(
                    url:
                        applicationURL
                ),
              bundle.bundleIdentifier
                == Self.bundleIdentifier
        else {
            return nil
        }

        let launcher =
            applicationURL
                .appendingPathComponent(
                    "Contents",
                    isDirectory: true
                )
                .appendingPathComponent(
                    "MacOS",
                    isDirectory: true
                )
                .appendingPathComponent(
                    Self.executableName
                )

        guard fm.isExecutableFile(
            atPath:
                launcher.path
        )
        else {
            return nil
        }

        let version =
            bundle.object(
                forInfoDictionaryKey:
                    "CFBundleShortVersionString"
            ) as? String

        let disk =
            configuredDiskImage()

        let canonicalApp =
            applicationURL
                .standardizedFileURL
                .resolvingSymlinksInPath()

        // Upstream and KiwiSingh currently intentionally
        // share the same application identity. Until the
        // bridge advertises implementation metadata,
        // guessing based on filesystem trivia would be
        // incorrect.
        let implementation:
            SteamacImplementation =
                .compatible

        return SteamacInstallation(
            id:
                stableIdentifier(
                    applicationURL:
                        canonicalApp,
                    diskImageURL:
                        disk
                ),
            applicationURL:
                canonicalApp,
            launcherURL:
                launcher
                    .standardizedFileURL,
            diskImageURL:
                disk,
            version:
                version,
            implementation:
                implementation
        )
    }


    // MARK: - Settings

    private func configuredDiskImage()
        -> URL?
    {
        let defaults =
            UserDefaults(
                suiteName:
                    Self.bundleIdentifier
            )

        let configured =
            defaults?
                .string(
                    forKey:
                        Self.diskImagePreferenceKey
                )?
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        if let configured,
           !configured.isEmpty
        {
            return URL(
                fileURLWithPath:
                    configured
            )
            .standardizedFileURL
        }

        return defaultDiskImage()
    }


    /// Steamac's own setting uses an empty `diskImage`
    /// value to mean "use AppBundle.defaultDisk()".
    ///
    /// The current launcher keeps its default SteamOS
    /// disk in the user's Application Support domain.
    /// We resolve only the canonical bundle-owned
    /// location here; arbitrary/custom locations come
    /// from `diskImage`.
    private func defaultDiskImage()
        -> URL?
    {
        guard let support =
                fm.urls(
                    for:
                        .applicationSupportDirectory,
                    in:
                        .userDomainMask
                )
                .first
        else {
            return nil
        }

        let candidates = [
            support
                .appendingPathComponent(
                    Self.bundleIdentifier,
                    isDirectory: true
                )
                .appendingPathComponent(
                    "steamos.img"
                ),

            support
                .appendingPathComponent(
                    "Steamac",
                    isDirectory: true
                )
                .appendingPathComponent(
                    "steamos.img"
                ),

            support
                .appendingPathComponent(
                    "FX Steam Launcher",
                    isDirectory: true
                )
                .appendingPathComponent(
                    "steamos.img"
                )
        ]

        // Do not fabricate a disk path. Only return a
        // default candidate that actually exists.
        return candidates.first {
            fm.fileExists(
                atPath:
                    $0.path
            )
        }
    }


    // MARK: - Identity

    private func stableIdentifier(
        applicationURL:
            URL,
        diskImageURL:
            URL?
    ) -> String {
        let app =
            applicationURL.path

        let disk =
            diskImageURL?
                .standardizedFileURL
                .path
                ?? "<default>"

        // This is intentionally human-readable rather
        // than Swift.Hasher-based: Hasher is randomized
        // between processes and therefore unsuitable
        // for a persistent environment identifier.
        return [
            Self.bundleIdentifier,
            app,
            disk
        ]
        .joined(
            separator:
                "|"
        )
    }
}
