import Foundation

// ─────────────────────────────────────────────
//  ReloadedIIUpdater
//
//  Updates an existing Reloaded-II installation
//  using the official Release.zip distribution.
//
//  The update is transactional:
//
//    download
//      → extract
//      → validate payload
//      → backup existing installation
//      → install new payload
//      → restore preserved user state
//      → verify
//
//  Any failure after the backup is created
//  restores the original installation.
// ─────────────────────────────────────────────

final class ReloadedIIUpdater {

    static let shared =
        ReloadedIIUpdater()

    private let fm =
        FileManager.default

    private let releaseURL =
        URL(
            string:
                "https://github.com/Reloaded-Project/Reloaded-II/releases/latest/download/Release.zip"
        )!

    // Reloaded-II state managed by BepisLoader or
    // the user. Never replace these directories
    // with copies from the distribution archive.
    private let preservedDirectories:
        Set<String> = [
            "Mods",
            "Apps"
        ]

    private init() {}

    func update(
        game: GameInstall,
        expectedVersion: String?,
        progress:
            @escaping (Double, String) -> Void,
        completion:
            @escaping (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.global(
            qos: .userInitiated
        ).async {
            do {
                self.report(
                    progress,
                    0.05,
                    "Preparing Reloaded-II update…"
                )

                let paths =
                    ReloadedIIPaths(
                        game: game
                    )

                guard let executable =
                        paths.executable
                else {
                    throw UpdateError
                        .installationNotFound
                }

                let installationRoot =
                    executable
                        .deletingLastPathComponent()

                guard self.fm.fileExists(
                    atPath:
                        executable.path
                ) else {
                    throw UpdateError
                        .installationNotFound
                }

                self.report(
                    progress,
                    0.12,
                    "Downloading Reloaded-II Release.zip…"
                )

                let workspace =
                    try Workspace(
                        fileManager:
                            self.fm
                    )

                defer {
                    workspace.cleanup()
                }

                let archive =
                    try self.downloadRelease(
                        into: workspace
                    )

                self.report(
                    progress,
                    0.35,
                    "Extracting Reloaded-II update…"
                )

                let extracted =
                    try self.extract(
                        archive,
                        in: workspace
                    )

                self.report(
                    progress,
                    0.48,
                    "Validating Reloaded-II update…"
                )

                let payload =
                    try self.findPayloadRoot(
                        under: extracted
                    )

                try self.validatePayload(
                    payload
                )

                if let expectedVersion,
                   let payloadVersion =
                    WindowsExecutableMetadata
                        .fileVersion(
                            at:
                                payload
                                    .appendingPathComponent(
                                        "Reloaded-II.exe"
                                    )
                        ),
                   !self.versionsEquivalent(
                        payloadVersion,
                        expectedVersion
                   )
                {
                    throw UpdateError
                        .unexpectedVersion(
                            expected:
                                expectedVersion,
                            received:
                                payloadVersion
                        )
                }

                self.report(
                    progress,
                    0.58,
                    "Backing up current Reloaded-II installation…"
                )

                let backup =
                    workspace.root
                        .appendingPathComponent(
                            "backup",
                            isDirectory: true
                        )

                try self.fm.copyItem(
                    at:
                        installationRoot,
                    to:
                        backup
                )

                var replacementStarted =
                    false

                do {
                    self.report(
                        progress,
                        0.70,
                        "Installing Reloaded-II update…"
                    )

                    replacementStarted =
                        true

                    try self.replaceInstallation(
                        at:
                            installationRoot,
                        with:
                            payload,
                        backup:
                            backup
                    )

                    self.report(
                        progress,
                        0.90,
                        "Verifying Reloaded-II update…"
                    )

                    try self.verifyInstallation(
                        at:
                            installationRoot,
                        expectedVersion:
                            expectedVersion
                    )

                } catch {
                    if replacementStarted {
                        self.report(
                            progress,
                            0.92,
                            "Update failed — restoring previous Reloaded-II installation…"
                        )

                        do {
                            try self.restore(
                                backup:
                                    backup,
                                installationRoot:
                                    installationRoot
                            )
                        } catch {
                            throw UpdateError
                                .rollbackFailed(
                                    error
                                        .localizedDescription
                                )
                        }
                    }

                    throw error
                }

                self.report(
                    progress,
                    1.0,
                    "Reloaded-II update completed"
                )

                DispatchQueue.main.async {
                    completion(
                        .success(())
                    )
                }

            } catch {
                DispatchQueue.main.async {
                    completion(
                        .failure(error)
                    )
                }
            }
        }
    }

    // ── Download ──────────────────────────────

    private func downloadRelease(
        into workspace: Workspace
    ) throws -> URL {
        let destination =
            workspace.root
                .appendingPathComponent(
                    "Release.zip"
                )

        var downloaded:
            URL?

        var receivedError:
            Error?

        let semaphore =
            DispatchSemaphore(
                value: 0
            )

        URLSession.shared.downloadTask(
            with: releaseURL
        ) {
            temporaryURL,
            response,
            error in

            defer {
                semaphore.signal()
            }

            if let error {
                receivedError =
                    error
                return
            }

            if let http =
                    response
                        as? HTTPURLResponse,
               !(200..<300)
                    .contains(
                        http.statusCode
                    )
            {
                receivedError =
                    UpdateError
                        .downloadFailed(
                            "HTTP \(http.statusCode)"
                        )
                return
            }

            guard let temporaryURL else {
                receivedError =
                    UpdateError
                        .downloadFailed(
                            "No archive was received"
                        )
                return
            }

            do {
                try self.fm.moveItem(
                    at:
                        temporaryURL,
                    to:
                        destination
                )

                downloaded =
                    destination

            } catch {
                receivedError =
                    error
            }

        }.resume()

        semaphore.wait()

        if let receivedError {
            throw UpdateError
                .downloadFailed(
                    receivedError
                        .localizedDescription
                )
        }

        guard let downloaded else {
            throw UpdateError
                .downloadFailed(
                    "No archive was received"
                )
        }

        return downloaded
    }

    // ── Extraction ────────────────────────────

    private func extract(
        _ archive: URL,
        in workspace: Workspace
    ) throws -> URL {
        let destination =
            workspace.root
                .appendingPathComponent(
                    "extracted",
                    isDirectory: true
                )

        try fm.createDirectory(
            at: destination,
            withIntermediateDirectories:
                true
        )

        let process =
            Process()

        process.executableURL =
            URL(
                fileURLWithPath:
                    "/usr/bin/ditto"
            )

        process.arguments = [
            "-x",
            "-k",
            archive.path,
            destination.path
        ]

        let pipe =
            Pipe()

        process.standardOutput =
            pipe

        process.standardError =
            pipe

        do {
            try process.run()
        } catch {
            throw UpdateError
                .extractionFailed(
                    error
                        .localizedDescription
                )
        }

        process.waitUntilExit()

        let output =
            String(
                data:
                    pipe
                        .fileHandleForReading
                        .readDataToEndOfFile(),
                encoding:
                    .utf8
            ) ?? ""

        guard process.terminationStatus
                == 0
        else {
            throw UpdateError
                .extractionFailed(
                    output
                        .trimmingCharacters(
                            in:
                                .whitespacesAndNewlines
                        )
                )
        }

        return destination
    }

    // ── Payload discovery ─────────────────────

    private func findPayloadRoot(
        under extractedRoot: URL
    ) throws -> URL {
        guard let enumerator =
                fm.enumerator(
                    at:
                        extractedRoot,
                    includingPropertiesForKeys:
                        [
                            .isRegularFileKey,
                            .isSymbolicLinkKey
                        ],
                    options: [
                        .skipsHiddenFiles
                    ]
                )
        else {
            throw UpdateError
                .invalidPayload(
                    "Could not inspect extracted archive"
                )
        }

        var executables:
            [URL] = []

        for case let candidate as URL
            in enumerator
        {
            guard candidate
                    .lastPathComponent
                    .caseInsensitiveCompare(
                        "Reloaded-II.exe"
                    )
                    == .orderedSame
            else {
                continue
            }

            let values =
                try candidate
                    .resourceValues(
                        forKeys: [
                            .isRegularFileKey,
                            .isSymbolicLinkKey
                        ]
                    )

            guard values
                    .isRegularFile
                    == true,
                  values
                    .isSymbolicLink
                    != true
            else {
                continue
            }

            executables.append(
                candidate
            )
        }

        guard executables.count
                == 1,
              let executable =
                executables.first
        else {
            if executables.isEmpty {
                throw UpdateError
                    .invalidPayload(
                        "Reloaded-II.exe was not found in Release.zip"
                    )
            }

            throw UpdateError
                .invalidPayload(
                    "Release.zip contains multiple Reloaded-II.exe files"
                )
        }

        return executable
            .deletingLastPathComponent()
    }

    private func validatePayload(
        _ payload: URL
    ) throws {
        let executable =
            payload
                .appendingPathComponent(
                    "Reloaded-II.exe"
                )

        guard fm.fileExists(
            atPath:
                executable.path
        ) else {
            throw UpdateError
                .invalidPayload(
                    "Reloaded-II.exe is missing"
                )
        }

        guard WindowsExecutableMetadata
                .fileVersion(
                    at:
                        executable
                ) != nil
        else {
            throw UpdateError
                .invalidPayload(
                    "Reloaded-II.exe does not contain readable Windows version metadata"
                )
        }

        try validateTree(
            payload
        )
    }

    private func validateTree(
        _ root: URL
    ) throws {
        let canonicalRoot =
            root
                .standardizedFileURL
                .resolvingSymlinksInPath()

        guard let enumerator =
                fm.enumerator(
                    at:
                        root,
                    includingPropertiesForKeys:
                        [
                            .isSymbolicLinkKey
                        ],
                    options: []
                )
        else {
            throw UpdateError
                .invalidPayload(
                    "Could not enumerate update payload"
                )
        }

        for case let entry as URL
            in enumerator
        {
            let standardized =
                entry
                    .standardizedFileURL

            guard isContained(
                standardized,
                within:
                    root.standardizedFileURL
            ) else {
                throw UpdateError
                    .unsafePayloadEntry(
                        entry.path
                    )
            }

            let values =
                try entry
                    .resourceValues(
                        forKeys: [
                            .isSymbolicLinkKey
                        ]
                    )

            if values.isSymbolicLink
                == true
            {
                let resolved =
                    entry
                        .resolvingSymlinksInPath()

                guard isContained(
                    resolved,
                    within:
                        canonicalRoot
                ) else {
                    throw UpdateError
                        .unsafePayloadEntry(
                            entry.path
                        )
                }

                guard fm.fileExists(
                    atPath:
                        resolved.path
                ) else {
                    throw UpdateError
                        .unsafePayloadEntry(
                            entry.path
                        )
                }
            }
        }
    }

    // ── Replacement ───────────────────────────

    private func replaceInstallation(
        at installationRoot: URL,
        with payload: URL,
        backup: URL
    ) throws {
        // Start with a clean framework directory.
        // User/BepisLoader state is restored from
        // the backup immediately afterwards.
        if fm.fileExists(
            atPath:
                installationRoot.path
        ) {
            try fm.removeItem(
                at:
                    installationRoot
            )
        }

        try fm.createDirectory(
            at:
                installationRoot,
            withIntermediateDirectories:
                true
        )

        let payloadEntries =
            try fm.contentsOfDirectory(
                at:
                    payload,
                includingPropertiesForKeys:
                    nil,
                options: []
            )

        for entry in payloadEntries {
            if preservedDirectories
                .contains(
                    entry.lastPathComponent
                )
            {
                continue
            }

            try fm.copyItem(
                at:
                    entry,
                to:
                    installationRoot
                        .appendingPathComponent(
                            entry.lastPathComponent
                        )
            )
        }

        for name in preservedDirectories {
            let preserved =
                backup
                    .appendingPathComponent(
                        name,
                        isDirectory: true
                    )

            guard fm.fileExists(
                atPath:
                    preserved.path
            ) else {
                continue
            }

            let destination =
                installationRoot
                    .appendingPathComponent(
                        name,
                        isDirectory: true
                    )

            try fm.copyItem(
                at:
                    preserved,
                to:
                    destination
            )
        }
    }

    // ── Verification / rollback ───────────────

    private func verifyInstallation(
        at installationRoot: URL,
        expectedVersion: String?
    ) throws {
        let executable =
            installationRoot
                .appendingPathComponent(
                    "Reloaded-II.exe"
                )

        guard fm.fileExists(
            atPath:
                executable.path
        ) else {
            throw UpdateError
                .verificationFailed(
                    "Reloaded-II.exe is missing after update"
                )
        }

        guard let installedVersion =
                WindowsExecutableMetadata
                    .fileVersion(
                        at:
                            executable
                    )
        else {
            throw UpdateError
                .verificationFailed(
                    "Updated Reloaded-II.exe has no readable version metadata"
                )
        }

        if let expectedVersion,
           !versionsEquivalent(
                installedVersion,
                expectedVersion
           )
        {
            throw UpdateError
                .unexpectedVersion(
                    expected:
                        expectedVersion,
                    received:
                        installedVersion
                )
        }
    }

    private func restore(
        backup: URL,
        installationRoot: URL
    ) throws {
        if fm.fileExists(
            atPath:
                installationRoot.path
        ) {
            try fm.removeItem(
                at:
                    installationRoot
            )
        }

        try fm.copyItem(
            at:
                backup,
            to:
                installationRoot
        )
    }

    // ── Helpers ───────────────────────────────

    private func versionsEquivalent(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        normalizedVersion(lhs)
            == normalizedVersion(rhs)
    }

    private func normalizedVersion(
        _ value: String
    ) -> [Int]? {
        var value =
            value.trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        if value.first == "v"
            || value.first == "V"
        {
            value.removeFirst()
        }

        let pieces =
            value.split(
                separator: ".",
                omittingEmptySubsequences:
                    false
            )

        guard !pieces.isEmpty else {
            return nil
        }

        var numbers:
            [Int] = []

        for piece in pieces {
            guard !piece.isEmpty,
                  piece.allSatisfy({
                      $0.isNumber
                  }),
                  let number =
                    Int(piece)
            else {
                return nil
            }

            numbers.append(
                number
            )
        }

        while numbers.count > 1,
              numbers.last == 0
        {
            numbers.removeLast()
        }

        return numbers
    }

    private func isContained(
        _ candidate: URL,
        within root: URL
    ) -> Bool {
        let candidatePath =
            candidate
                .standardizedFileURL
                .path

        let rootPath =
            root
                .standardizedFileURL
                .path

        return candidatePath
            == rootPath
            || candidatePath
                .hasPrefix(
                    rootPath
                    + "/"
                )
    }

    private func report(
        _ handler:
            @escaping (Double, String) -> Void,
        _ progress: Double,
        _ message: String
    ) {
        DispatchQueue.main.async {
            handler(
                progress,
                message
            )
        }
    }

    // ── Workspace ─────────────────────────────

    private final class Workspace {

        let root: URL

        private let fm:
            FileManager

        init(
            fileManager: FileManager
        ) throws {
            fm =
                fileManager

            root =
                fm.temporaryDirectory
                    .appendingPathComponent(
                        "BepisLoader-ReloadedII-Update-\(UUID().uuidString)",
                        isDirectory: true
                    )

            try fm.createDirectory(
                at:
                    root,
                withIntermediateDirectories:
                    true
            )
        }

        func cleanup() {
            try? fm.removeItem(
                at:
                    root
            )
        }
    }

    // ── Errors ────────────────────────────────

    enum UpdateError:
        LocalizedError
    {
        case installationNotFound
        case downloadFailed(String)
        case extractionFailed(String)
        case invalidPayload(String)
        case unsafePayloadEntry(String)
        case unexpectedVersion(
            expected: String,
            received: String
        )
        case verificationFailed(String)
        case rollbackFailed(String)

        var errorDescription:
            String?
        {
            switch self {

            case .installationNotFound:
                return """
                Reloaded-II is not installed for \
                this game
                """

            case .downloadFailed(
                let reason
            ):
                return """
                Failed to download Reloaded-II \
                update: \(reason)
                """

            case .extractionFailed(
                let reason
            ):
                if reason.isEmpty {
                    return """
                    Failed to extract Reloaded-II \
                    Release.zip
                    """
                }

                return """
                Failed to extract Reloaded-II \
                Release.zip: \(reason)
                """

            case .invalidPayload(
                let reason
            ):
                return """
                Reloaded-II update archive is \
                invalid: \(reason)
                """

            case .unsafePayloadEntry(
                let path
            ):
                return """
                Reloaded-II update contains an \
                unsafe filesystem entry: \(path)
                """

            case .unexpectedVersion(
                let expected,
                let received
            ):
                return """
                Reloaded-II update version mismatch. \
                Expected \(expected), received \
                \(received)
                """

            case .verificationFailed(
                let reason
            ):
                return """
                Reloaded-II update verification \
                failed: \(reason)
                """

            case .rollbackFailed(
                let reason
            ):
                return """
                Reloaded-II update failed and the \
                previous installation could not be \
                restored automatically: \(reason)
                """
            }
        }
    }
}
