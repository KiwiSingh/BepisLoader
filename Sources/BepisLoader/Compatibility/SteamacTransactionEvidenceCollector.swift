import Foundation

// 41F-21D.6: Read-only guest evidence. No installation, authorization, or guest writes.
// Collected facts are scoped to one Steamac endpoint and one AppID. The caller must
// explicitly review transaction plans; live discovery cannot approve those plans.
enum SteamacCollectedEvidenceStatus: String, Codable, Hashable {
    case verified
    case missing
    case unknown
    case stale
}

struct SteamacCollectedEvidenceFact: Codable, Hashable {
    let status: SteamacCollectedEvidenceStatus
    let detail: String
}

struct SteamacCollectedTransactionEvidence: Codable, Hashable {
    let appID: UInt32
    let framework: SteamacInstallationFramework
    let endpointProcessID: Int32
    let collectedAt: Date
    let guest: SteamacCollectedEvidenceFact
    let capabilities: SteamacCollectedEvidenceFact
    let runtime: SteamacCollectedEvidenceFact
    let game: SteamacCollectedEvidenceFact
    let prefix: SteamacCollectedEvidenceFact
    let frameworkInventory: SteamacCollectedEvidenceFact

    // This is a diagnostic snapshot, not a durable authorization artifact.
    // Reject snapshots collected for another transaction target, process, or age.
    func isCurrent(for transaction: SteamacInstallationTransaction,
                   endpoint: SteamacBridgeEndpoint,
                   now: Date = Date(),
                   maximumAge: TimeInterval = 30) -> Bool {
        transaction.appID == appID && transaction.framework == framework &&
        endpoint.processId == endpointProcessID &&
        maximumAge > 0 && now >= collectedAt &&
        now.timeIntervalSince(collectedAt) <= maximumAge
    }

    // Fail closed: stale/mismatched evidence is never interpreted as verified.
    // Plan-review flags are deliberately FALSE: only an independent human-reviewed
    // plan can provide those, and this collector has no authority to mint them.
    func preflightEvidence(for transaction: SteamacInstallationTransaction,
                           endpoint: SteamacBridgeEndpoint,
                           now: Date = Date()) -> SteamacTransactionPreflightEvidence {
        let current = isCurrent(for: transaction, endpoint: endpoint, now: now)
        return SteamacTransactionPreflightEvidence(
            guestConnected: current && guest.status == .verified,
            requiredCapabilitiesPresent: current && capabilities.status == .verified,
            runtimeStaticallyAttested: current && runtime.status == .verified,
            gameInstalled: current && game.status == .verified,
            prefixPresent: current && prefix.status == .verified,
            frameworkInventory: current ? inventoryForPreflight : .unknown,
            payloadIntegrityPlanReviewed: false,
            snapshotPlanReviewed: false,
            verificationPlanReviewed: false,
            rollbackPlanReviewed: false
        )
    }

    private var inventoryForPreflight: SteamacTransactionEvidence {
        switch frameworkInventory.status {
        case .verified: return .verified // installed: blocks a new installation
        case .missing: return .missing   // positively confirmed absent
        case .unknown, .stale: return .unknown
        }
    }
}

enum SteamacTransactionEvidenceCollector {
    private static func fact(_ status: SteamacCollectedEvidenceStatus,
                             _ detail: String) -> SteamacCollectedEvidenceFact {
        SteamacCollectedEvidenceFact(status: status, detail: detail)
    }

    /// Only read-only SteamacBridge methods are used. Each failed query becomes
    /// unknown; neither missing capabilities nor transport errors imply absence.
    static func collect(appID: UInt32,
                        framework: SteamacInstallationFramework,
                        endpoint: SteamacBridgeEndpoint,
                        bridge: SteamacBridge = .shared,
                        now: Date = Date()) -> SteamacCollectedTransactionEvidence {
        let unknown = fact(.unknown, "Not established by read-only guest evidence.")
        var guest = unknown
        var capabilities = unknown
        var runtime = unknown
        var game = unknown
        var prefix = unknown
        var inventory = unknown

        guard appID != 0 else {
            return SteamacCollectedTransactionEvidence(
                appID: appID, framework: framework,
                endpointProcessID: endpoint.processId, collectedAt: now,
                guest: guest, capabilities: capabilities, runtime: runtime,
                game: game, prefix: prefix, frameworkInventory: inventory)
        }

        do {
            let hello = try bridge.handshake(endpoint: endpoint)
            guard hello.isKiwiSinghSteamac else {
                guest = fact(.unknown, "Unexpected Steamac bridge implementation.")
                return SteamacCollectedTransactionEvidence(
                    appID: appID, framework: framework,
                    endpointProcessID: endpoint.processId, collectedAt: now,
                    guest: guest, capabilities: capabilities, runtime: runtime,
                    game: game, prefix: prefix, frameworkInventory: inventory)
            }
            guest = fact(.verified, "Protocol handshake with KiwiSingh/steamac succeeded.")
            let base = hello.capabilities.supports(.steamLibraryDiscovery) &&
                hello.capabilities.supports(.protonRuntimeAttestationV1) &&
                hello.capabilities.supports(.protonEnvironmentInspection)
            let frameworkCapability: Bool
            switch framework {
            case .bepInEx:
                frameworkCapability = hello.capabilities.supports(.bepInExInstallationInventoryV1)
            case .reloadedII:
                frameworkCapability = hello.capabilities.supports(.reloadedIIModInventoryV1)
            }
            capabilities = fact(base && frameworkCapability ? .verified : .missing,
                                "Required read-only discovery and inventory capabilities.")
        } catch {
            guest = fact(.unknown, "Bridge handshake failed: \(error)")
            return SteamacCollectedTransactionEvidence(
                appID: appID, framework: framework,
                endpointProcessID: endpoint.processId, collectedAt: now,
                guest: guest, capabilities: capabilities, runtime: runtime,
                game: game, prefix: prefix, frameworkInventory: inventory)
        }

        do {
            let matches = try bridge.steamGames(endpoint: endpoint).filter { $0.appId == appID }
            game = fact(matches.count == 1 ? .verified :
                        (matches.isEmpty ? .missing : .unknown),
                        "Steam library discovery found \(matches.count) matching AppID records.")
        } catch {
            game = fact(.unknown, "Steam library discovery failed: \(error)")
        }
        do {
            let attestation = try bridge.protonRuntimeAttestation(for: appID, endpoint: endpoint)
            guard attestation.appId == appID else {
                runtime = fact(.unknown, "Proton attestation AppID mismatch.")
                throw SteamacBridgeError.requestFailed("AppID mismatch")
            }
            runtime = fact(attestation.isStaticallyVerified ? .verified :
                           (attestation.state == .missing ? .missing : .unknown),
                           "Proton attestation: \(attestation.state.rawValue), \(attestation.evidence). Static layout only; no launch proof.")
        } catch {
            if runtime.status != .unknown || runtime.detail == unknown.detail {
                runtime = fact(.unknown, "Proton attestation failed: \(error)")
            }
        }
        do {
            let inspection = try bridge.protonInspection(for: appID, endpoint: endpoint)
            // Never use another game's prefix response to establish absence.
            // Mismatched AppIDs are unknown regardless of the reported status.
            if inspection.appId != appID {
                prefix = fact(.unknown, "Proton prefix inspection AppID mismatch.")
            } else {
                prefix = fact(inspection.isStructurallyReady ? .verified :
                              (inspection.prefix == .missing ? .missing : .unknown),
                              "Proton prefix structural inspection (not runtime execution proof).")
            }
        } catch {
            prefix = fact(.unknown, "Proton prefix inspection failed: \(error)")
        }
        do {
            switch framework {
            case .bepInEx:
                let result = try bridge.bepInExInventory(appId: appID, endpoint: endpoint)
                if result.appId == appID {
                    switch result.installation {
                    case .installed: inventory = fact(.verified, "BepInEx installed: \(result.evidence)")
                    case .absent: inventory = fact(.missing, "BepInEx absent: \(result.evidence)")
                    case .partial, .unknown: inventory = fact(.unknown, "BepInEx uncertain: \(result.evidence)")
                    }
                }
            case .reloadedII:
                let result = try bridge.reloadedIIInventory(appId: appID, endpoint: endpoint)
                switch result.installation {
                case .installed: inventory = fact(.verified, "Reloaded-II installed (\(result.modConfigPaths.count) mod records).")
                case .absent: inventory = fact(.missing, "Reloaded-II absent.")
                }
            }
        } catch {
            inventory = fact(.unknown, "Framework inventory failed: \(error)")
        }
        return SteamacCollectedTransactionEvidence(
            appID: appID, framework: framework,
            endpointProcessID: endpoint.processId, collectedAt: now,
            guest: guest, capabilities: capabilities, runtime: runtime,
            game: game, prefix: prefix, frameworkInventory: inventory)
    }
}
