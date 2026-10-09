import Foundation

// Patch 41F-14: bounded, fail-closed mod-aware launch retry policy.
// This coordinator intentionally does not invent a guest launch command.
// The caller must supply an idempotent guest operation and authoritative status.
enum SteamacModLaunchState: Equatable {
    case runningAndModsVerified
    case runningModsUnverified
    case notRunning
    case unknown
}

enum SteamacModLaunchFailure: LocalizedError {
    case cancelled
    case alreadyInProgress
    case unverifiedMods
    case ambiguousOutcome
    case exhausted(Int)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Steamac launch cancelled."
        case .alreadyInProgress: return "A launch is already in progress for this Steam game."
        case .unverifiedMods: return "Game is running, but Reloaded-II mod loading is not verified."
        case .ambiguousOutcome: return "Guest launch outcome is unknown; refusing a duplicate launch."
        case .exhausted(let attempts): return "Mod-aware game launch failed after \(attempts) attempts."
        }
    }
}

/// A successful launch requires guest evidence of BOTH the game process and mods.
/// `launch` MUST be idempotent for the supplied `requestID`; never retry an
/// uncertain guest request under a new ID. `observe` must query authoritative
/// guest state rather than infer success from installed mod files.
final class SteamacModLaunchRetryCoordinator {
    static let shared = SteamacModLaunchRetryCoordinator()
    private let lock = NSLock()
    private var active = Set<String>()
    private init() {}

    func launch(
        appId: UInt32,
        endpoint: SteamacBridgeEndpoint,
        maximumAttempts: Int = 3,
        isCancelled: () -> Bool = { false },
        observe: (_ appId: UInt32, _ requestID: UUID) throws -> SteamacModLaunchState,
        launch: (_ appId: UInt32, _ requestID: UUID) throws -> Void
    ) throws {
        let key = "\(endpoint.processId):\(appId)"
        lock.lock()
        let inserted = active.insert(key).inserted
        lock.unlock()
        guard inserted else { throw SteamacModLaunchFailure.alreadyInProgress }
        defer {
            lock.lock()
            active.remove(key)
            lock.unlock()
        }
        let attempts = max(1, min(3, maximumAttempts))
        // One logical operation ID across all attempts. Guest MUST deduplicate.
        let requestID = UUID()
        for attempt in 1...attempts {
            if isCancelled() { throw SteamacModLaunchFailure.cancelled }
            guard try SteamacBridge.shared.ping(endpoint: endpoint) else {
                throw SteamacModLaunchFailure.ambiguousOutcome
            }
            switch try observe(appId, requestID) {
            case .runningAndModsVerified: return
            case .runningModsUnverified: throw SteamacModLaunchFailure.unverifiedMods
            case .unknown: throw SteamacModLaunchFailure.ambiguousOutcome
            case .notRunning: break
            }
            // Transport failures can mean the guest accepted the request.
            // Query state before any retry; never blindly resend.
            do {
                try launch(appId, requestID)
            } catch {
                switch try observe(appId, requestID) {
                case .runningAndModsVerified: return
                case .runningModsUnverified: throw SteamacModLaunchFailure.unverifiedMods
                case .unknown: throw SteamacModLaunchFailure.ambiguousOutcome
                case .notRunning: break
                }
            }
            switch try observe(appId, requestID) {
            case .runningAndModsVerified: return
            case .runningModsUnverified: throw SteamacModLaunchFailure.unverifiedMods
            case .unknown: throw SteamacModLaunchFailure.ambiguousOutcome
            case .notRunning: break
            }
            if attempt < attempts {
                let delay = attempt == 1 ? 2 : 5
                for _ in 0..<(delay * 10) {
                    if isCancelled() { throw SteamacModLaunchFailure.cancelled }
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
        }
        throw SteamacModLaunchFailure.exhausted(attempts)
    }
}
