import Foundation
import CryptoKit
import Darwin

// 41F-21D.21: Host-only persistence. Never interprets records as permission to act.
enum SteamacDurableJournalError: Error {
    case invalidJournal, corruptEnvelope, unsafePath, ioFailure(Int32), oversized
}

private struct SteamacDurableJournalEnvelope: Codable {
    let formatVersion: Int
    let transactionID: UUID
    let payload: Data
    let sha256: String
}

enum SteamacDurableRecoveryJournal {
    private static let maximumBytes = 16 * 1024 * 1024

    // Caller must provide an existing, private, trusted directory. The filename is fixed.
    // A checksum detects accidental corruption, NOT malicious modification.
    static func persist(_ journal: SteamacInstallationRecoveryJournal, in directory: URL) throws {
        guard journal.isWellFormed(), journal.entries.count <= 100_000 else { throw SteamacDurableJournalError.invalidJournal }
        let payload = try JSONEncoder().encode(journal)
        guard payload.count <= maximumBytes else { throw SteamacDurableJournalError.oversized }
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let envelope = SteamacDurableJournalEnvelope(formatVersion: 1, transactionID: journal.transactionID, payload: payload, sha256: digest)
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= maximumBytes else { throw SteamacDurableJournalError.oversized }
        let dir = try openDirectory(directory)
        defer { close(dir) }
        let name = "recovery-journal.json"
        try ensureAbsentOrRegular(name, dir: dir)
        let temp = ".recovery-\(UUID().uuidString).tmp"
        let fd = openat(dir, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SteamacDurableJournalError.ioFailure(errno) }
        var tempExists = true
        defer { if tempExists { _ = unlinkat(dir, temp, 0) } }
        do {
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, base.advanced(by: offset), raw.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw SteamacDurableJournalError.ioFailure(errno) }
                    offset += written
                }
            }
            guard fsync(fd) == 0 else { throw SteamacDurableJournalError.ioFailure(errno) }
        } catch {
            close(fd)
            throw error
        }
        guard close(fd) == 0 else { throw SteamacDurableJournalError.ioFailure(errno) }
        try ensureAbsentOrRegular(name, dir: dir)
        guard renameat(dir, temp, dir, name) == 0 else { throw SteamacDurableJournalError.ioFailure(errno) }
        tempExists = false
        guard fsync(dir) == 0 else { throw SteamacDurableJournalError.ioFailure(errno) }
    }

    static func reopen(in directory: URL, expectedTransactionID: UUID) throws -> SteamacInstallationRecoveryJournal {
        let dir = try openDirectory(directory)
        defer { close(dir) }
        let fd = openat(dir, "recovery-journal.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SteamacDurableJournalError.ioFailure(errno) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              st.st_size >= 0, st.st_size <= maximumBytes else { throw SteamacDurableJournalError.unsafePath }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw SteamacDurableJournalError.ioFailure(errno) }
            if count == 0 { break }
            guard data.count + count <= maximumBytes else { throw SteamacDurableJournalError.oversized }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let envelope = try? JSONDecoder().decode(SteamacDurableJournalEnvelope.self, from: data),
              envelope.formatVersion == 1, envelope.transactionID == expectedTransactionID,
              envelope.payload.count <= maximumBytes else { throw SteamacDurableJournalError.corruptEnvelope }
        let digest = SHA256.hash(data: envelope.payload).map { String(format: "%02x", $0) }.joined()
        guard digest == envelope.sha256,
              let journal = try? JSONDecoder().decode(SteamacInstallationRecoveryJournal.self, from: envelope.payload),
              journal.transactionID == expectedTransactionID, journal.isWellFormed(),
              journal.entries.count <= 100_000,
              journal.entries.allSatisfy({ $0.note.utf8.count <= 4096 }) else {
            throw SteamacDurableJournalError.corruptEnvelope
        }
        return journal
    }

    // Reopening is observational; recovery must always be explicitly reviewed.
    static var permitsAutomaticResume: Bool { false }
    static var permitsGuestInstallation: Bool { false }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\u{0}") else { throw SteamacDurableJournalError.unsafePath }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SteamacDurableJournalError.ioFailure(errno) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (st.st_mode & 0o077) == 0 else {
            close(fd)
            throw SteamacDurableJournalError.unsafePath
        }
        return fd
    }

    private static func ensureAbsentOrRegular(_ name: String, dir: Int32) throws {
        var st = stat()
        if fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), st.st_nlink == 1 else {
                throw SteamacDurableJournalError.unsafePath
            }
        } else if errno != ENOENT { throw SteamacDurableJournalError.ioFailure(errno) }
    }
}
