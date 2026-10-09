import Foundation

// MARK: - Steamac Framework Installation Planning
//
// Phase 41F-21B.1
//
// This file defines a read-only installation planning contract.
// It does not download, stage, install, activate, or launch anything.

enum SteamacModFramework: String, CaseIterable, Codable, Sendable {
    case bepInEx
    case reloadedII

    var displayName: String {
        switch self {
        case .bepInEx:
            return "BepInEx"
        case .reloadedII:
            return "Reloaded-II"
        }
    }
}

enum SteamacFrameworkInstallationState: String, Codable, Sendable {
    case available
    case installed
    case unavailable
    case blocked
    case failed
}

enum SteamacFrameworkPreflightCheck: String, Codable, Sendable {
    case validAppID
    case gameInstalled
    case guestConnected
    case requiredCapabilities
    case protonRuntimeVerified
    case frameworkNotInstalled
}

struct SteamacFrameworkPreflightFinding: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case passed
        case failed
        case unknown
    }

    let check: SteamacFrameworkPreflightCheck
    let status: Status
    let detail: String
}

enum SteamacFrameworkInstallationOperation: String, Codable, Sendable {
    case downloadOfficialRelease
    case validateRelease
    case stageGuestPayload
    case executeFrameworkInstaller
    case activateFramework
    case verifyInstallation
    case rollbackOnFailure
}

struct SteamacFrameworkInstallationPlan: Codable, Sendable {
    let appID: UInt32
    let framework: SteamacModFramework
    let state: SteamacFrameworkInstallationState
    let findings: [SteamacFrameworkPreflightFinding]
    let operations: [SteamacFrameworkInstallationOperation]
    let requiresExplicitAuthorization: Bool

    var canOfferInstallation: Bool {
        state == .available &&
        findings.allSatisfy { $0.status == .passed }
    }
}

struct SteamacFrameworkInstallationContext: Sendable {
    let appID: UInt32
    let framework: SteamacModFramework

    let gameInstalled: Bool
    let guestConnected: Bool
    let requiredCapabilitiesPresent: Bool

    // Must come from an independently verified Proton runtime check.
    // A present Proton prefix does not imply runtime verification.
    let protonRuntimeVerified: Bool

    // nil means detection unavailable, NOT absent.
    let frameworkInstalled: Bool?
}

enum SteamacFrameworkInstallationPlanner {

    static func makePlan(
        context: SteamacFrameworkInstallationContext
    ) -> SteamacFrameworkInstallationPlan {

        var findings: [SteamacFrameworkPreflightFinding] = []

        func append(
            _ check: SteamacFrameworkPreflightCheck,
            _ passed: Bool,
            _ detail: String
        ) {
            findings.append(
                SteamacFrameworkPreflightFinding(
                    check: check,
                    status: passed ? .passed : .failed,
                    detail: detail
                )
            )
        }

        append(
            .validAppID,
            context.appID > 0,
            context.appID > 0
                ? "Valid nonzero Steam AppID."
                : "Steam AppID must be nonzero."
        )

        append(
            .gameInstalled,
            context.gameInstalled,
            context.gameInstalled
                ? "Game installation detected."
                : "Game installation not verified."
        )

        append(
            .guestConnected,
            context.guestConnected,
            context.guestConnected
                ? "Steamac guest connection available."
                : "Steamac guest connection unavailable."
        )

        append(
            .requiredCapabilities,
            context.requiredCapabilitiesPresent,
            context.requiredCapabilitiesPresent
                ? "Required framework capabilities advertised."
                : "Required framework capabilities unavailable."
        )

        if context.framework == .reloadedII {
            append(
                .protonRuntimeVerified,
                context.protonRuntimeVerified,
                context.protonRuntimeVerified
                    ? "Proton runtime independently verified."
                    : "Proton runtime not verified."
            )
        }

        if let installed = context.frameworkInstalled {
            append(
                .frameworkNotInstalled,
                !installed,
                installed
                    ? "Framework already installed."
                    : "Framework installation not detected."
            )
        } else {
            findings.append(
                SteamacFrameworkPreflightFinding(
                    check: .frameworkNotInstalled,
                    status: .unknown,
                    detail: "Framework installation state could not be established."
                )
            )
        }

        let state: SteamacFrameworkInstallationState

        if context.frameworkInstalled == true {
            state = .installed
        } else if !context.guestConnected {
            state = .unavailable
        } else if findings.contains(where: { $0.status != .passed }) {
            state = .blocked
        } else {
            state = .available
        }

        let operations: [SteamacFrameworkInstallationOperation]

        switch context.framework {
        case .bepInEx:
            operations = [
                .downloadOfficialRelease,
                .validateRelease,
                .stageGuestPayload,
                .activateFramework,
                .verifyInstallation,
                .rollbackOnFailure
            ]

        case .reloadedII:
            operations = [
                .downloadOfficialRelease,
                .validateRelease,
                .stageGuestPayload,
                .executeFrameworkInstaller,
                .verifyInstallation,
                .rollbackOnFailure
            ]
        }

        return SteamacFrameworkInstallationPlan(
            appID: context.appID,
            framework: context.framework,
            state: state,
            findings: findings,
            operations: operations,
            requiresExplicitAuthorization: true
        )
    }
}
