import Foundation
import Darwin

// 41F-21D.22: Host-only, advisory cross-process exclusion around 21D.21 journal APIs.
// The lock inode is persistent; never unlink it to "clear" a stale lock.
enum SteamacJournalLeaseError: Error {
    case unsafeDirectory, unsafeLock, busy, ioFailure(Int32)
}

enum SteamacRecoveryDisposition: String {
    case absent, requiresManualReview, corruptOrUnavailable
}

enum SteamacRecoveryJournalLease {
    private static let lockName = ".recovery-journal.lock"

    // The kernel releases flock on process death. There is no PID-based stale-lock breaking.
    // Hold this lease across ALL related read/modify/write operations.
    static func withExclusiveLease<T>(in directory: URL, _ body: () throws -> T) throws -> T {
        guard directory.isFileURL, directory.path.hasPrefix("/"),
              !directory.path.contains("\u{0}") else { throw SteamacJournalLeaseError.unsafeDirectory }
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw SteamacJournalLeaseError.ioFailure(errno) }
        defer { _ = close(dir) }
        var st = stat()
        guard fstat(dir, &st) == 0,
              (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (st.st_mode & 0o077) == 0 else { throw SteamacJournalLeaseError.unsafeDirectory }
        let fd = openat(dir, lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SteamacJournalLeaseError.ioFailure(errno) }
        defer { _ = close(fd) }
        var lockStat = stat()
        guard fstat(fd, &lockStat) == 0,
              (lockStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              lockStat.st_nlink == 1,
              (lockStat.st_mode & 0o077) == 0 else { throw SteamacJournalLeaseError.unsafeLock }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { throw SteamacJournalLeaseError.busy }
            throw SteamacJournalLeaseError.ioFailure(errno)
        }
        defer { _ = flock(fd, LOCK_UN) }
        // Prevent races where another actor replaced the lock filename after open.
        var current = stat()
        guard fstatat(dir, lockName, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == lockStat.st_dev,
              current.st_ino == lockStat.st_ino else { throw SteamacJournalLeaseError.unsafeLock }
        return try body()
    }

    // Observation only; never initiates recovery or resumes a transaction.
    // A missing journal is NOT authorization to install.
    static func inspect(in directory: URL, expectedTransactionID: UUID) -> SteamacRecoveryDisposition {
        do {
            return try withExclusiveLease(in: directory) {
                let journal = try SteamacDurableRecoveryJournal.reopen(
                    in: directory, expectedTransactionID: expectedTransactionID)
                _ = journal
                return .requiresManualReview
            }
        } catch SteamacDurableJournalError.ioFailure(let code) where code == ENOENT {
            return .absent
        } catch {
            return .corruptOrUnavailable
        }
    }

    static var permitsAutomaticResume: Bool { false }
    static var permitsGuestInstallation: Bool { false }
}
