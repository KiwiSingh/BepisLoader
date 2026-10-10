import AppKit
import Foundation
import CryptoKit
import UniformTypeIdentifiers

// 41F-21D.38-R1: Steamac cockpit with generic plugin inspection.
// Runtime launch stays fail closed. Asset publication is checked by the guest.
final class SteamacCockpitViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let bridge = SteamacBridge.shared
    private let status = NSTextField(labelWithString: "Checking Steamac…")
    private let details = NSTextField(wrappingLabelWithString: "")
    private let gameTable = NSTableView()
    private let gameInfo = NSTextField(wrappingLabelWithString: "Select a Steam game to inspect its Proton and Reloaded-II configuration.")
    // 41F-21D.10-R1: Strongly retained report sink, never discovered through view traversal.
    private let reportTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 330))
    private let refreshButton = NSButton(title: "Refresh connection & library", target: nil, action: nil)
    private let launchButton = NSButton(title: "Launch via Steamac", target: nil, action: nil)
    private let installFrameworkButton = NSButton(title: "Install BepInEx…", target: nil, action: nil)
    private let installPluginButton = NSButton(title: "Install Plugins…", target: nil, action: nil)
    // 42A-14: local read-only inspection; NOT an installation or provenance approval.
    private let inspectPayloadButton = NSButton(title: "Inspect Local Payload…", target: nil, action: nil)
    private let fetchReleaseButton = NSButton(title: "Fetch Latest Reloaded-II (Host Only)…", target: nil, action: nil)
    private let discoverProvenanceButton = NSButton(title: "Fetch & Discover Reloaded-II Provenance…", target: nil, action: nil)
    private let recoveryRehearsalButton = NSButton(title: "Rehearse Recovery (Host Fixture Only)…", target: nil, action: nil)
    private let recoveryScopeButton = NSButton(title: "Review Recovery Scope Plan (Read Only)…", target: nil, action: nil)
    private let discoverScopeButton = NSButton(title: "Discover Guest Recovery Scope (Read Only)…", target: nil, action: nil)
    private let guestInventoryButton = NSButton(title: "Collect Guest Recovery Inventory (Read Only)…", target: nil, action: nil)
    private var recoveryScopeReport: String?
    private var recoveryRehearsalBusy = false
    private var releaseFetchBusy = false
    private let installAssetButton = NSButton(title: "Install asset mod…", target: nil, action: nil)
    private var assetProfileWindow: AssetModProfileWindowController?
    private let manageAssetButton = NSButton(title: "Manage asset mods…", target: nil, action: nil)
    private let disableAssetButton = NSButton(title: "Disable asset mods", target: nil, action: nil)
    private var pluginOperationBusy = false
    private var games: [SteamacGame] = []
    private var activeEndpoint: SteamacBridgeEndpoint?
    private var refreshGeneration = 0
    // 41F-20D.3B: Invalidate pending game-detail responses.
    private var selectionGeneration = 0

    override func loadView() {
        view = NSView()
        let title = NSTextField(labelWithString: "🐸 Steamac")
        title.font = .boldSystemFont(ofSize: 25)
        status.font = .boldSystemFont(ofSize: 13)
        details.textColor = .secondaryLabelColor
        details.font = .systemFont(ofSize: 12)
        gameInfo.font = .systemFont(ofSize: 12)
        gameInfo.maximumNumberOfLines = 0
        gameInfo.lineBreakMode = .byWordWrapping
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("steamGame"))
        column.title = "SteamOS library"
        gameTable.addTableColumn(column)
        gameTable.dataSource = self
        gameTable.delegate = self
        gameTable.rowHeight = 28
        let scroll = NSScrollView()
        scroll.documentView = gameTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        launchButton.target = self
        launchButton.action = #selector(launchViaSteamac)
        installFrameworkButton.target = self
        installFrameworkButton.action = #selector(installFramework)
        installPluginButton.target = self
        installPluginButton.action = #selector(installPlugin)
        inspectPayloadButton.target = self
        inspectPayloadButton.action = #selector(inspectLocalPayload)
        guestInventoryButton.target = self
        guestInventoryButton.action = #selector(collectGuestRecoveryInventory)
        discoverScopeButton.target = self
        discoverScopeButton.action = #selector(discoverGuestRecoveryScope)
        recoveryScopeButton.target = self
        recoveryScopeButton.action = #selector(reviewRecoveryScope)
        recoveryRehearsalButton.target = self
        recoveryRehearsalButton.action = #selector(rehearseHostRecovery)
        discoverProvenanceButton.target = self
        discoverProvenanceButton.action = #selector(discoverReloadedProvenance)
        fetchReleaseButton.target = self
        fetchReleaseButton.action = #selector(fetchLatestReloadedRelease)
        installAssetButton.target = self
        installAssetButton.action = #selector(installAssetMod)
        manageAssetButton.target = self
        manageAssetButton.action = #selector(manageAssetMods)
        disableAssetButton.target = self
        disableAssetButton.action = #selector(disableAssetMods)
        updatePluginButtons()
        // A nonzero initial document frame plus a constrained scroll viewport.
        reportTextView.isEditable = false
        reportTextView.isSelectable = true
        reportTextView.drawsBackground = false
        reportTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        reportTextView.textContainerInset = NSSize(width: 8, height: 8)
        reportTextView.isHorizontallyResizable = false
        reportTextView.isVerticallyResizable = true
        reportTextView.autoresizingMask = [.width]
        reportTextView.textContainer?.widthTracksTextView = true
        reportTextView.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        let reportScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 330))
        reportScroll.hasVerticalScroller = true
        reportScroll.hasHorizontalScroller = false
        reportScroll.borderType = .bezelBorder
        reportScroll.documentView = reportTextView
        reportScroll.heightAnchor.constraint(equalToConstant: 330).isActive = true
        let assetActions = NSStackView(views: [installAssetButton, manageAssetButton, disableAssetButton])
        assetActions.orientation = .horizontal
        assetActions.spacing = 8
        let stack = NSStackView(views: [title, status, details, refreshButton, scroll, assetActions, reportScroll, installFrameworkButton, installPluginButton, launchButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        for item in [details, scroll, reportScroll] {
            item.translatesAutoresizingMaskIntoConstraints = false
            item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20)
        ])
    }

    private func showReport(_ text: String) {
        // Preserve existing report state while presenting it in a scrollable viewport.
        gameInfo.stringValue = text
        reportTextView.string = text
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refresh()
    }

    @objc private func refresh() {
        recoveryScopeReport = nil
        recoveryScopeButton.isEnabled = false
        refreshGeneration += 1
        selectionGeneration += 1
        let generation = refreshGeneration
        refreshButton.isEnabled = false
        status.stringValue = "Connecting to Steamac…"
        details.stringValue = "Looking for the guest bridge."
        showReport("Select a game after discovery completes.")
        games = []
        activeEndpoint = nil
        gameTable.reloadData()
        updatePluginButtons()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let endpoints = self.bridge.endpoints()
            guard let endpoint = endpoints.first else {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.refreshGeneration == generation else { return }
                    self.invalidateDiscoveredGames()
                    self.status.stringValue = "Disconnected"
                    self.details.stringValue = "No Steamac bridge detected. Start the Steamac VM and confirm its guest agent is running."
                    self.refreshButton.isEnabled = true
                }
                return
            }
            do {
                let handshake = try self.bridge.handshake(endpoint: endpoint)
                let reachable = try self.bridge.ping(endpoint: endpoint)
                guard reachable else { throw SteamacBridgeError.requestFailed("Guest ping failed") }
                let discovered = try self.bridge.steamGames(endpoint: endpoint)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.refreshGeneration == generation else { return }
                    // A fresh library snapshot invalidates the previous
                    // selection even if the endpoint socket is unchanged.
                    self.invalidateDiscoveredGames()
                    self.activeEndpoint = endpoint
                    self.games = discovered
                    self.gameTable.reloadData()
                    self.updatePluginButtons()
                    self.status.stringValue = "Connected · \(discovered.count) Steam games"
                    self.details.stringValue = "Guest: \(handshake.implementation) · Protocol \(handshake.protocolVersion) · PID \(endpoint.processId)\nBridge: \(endpoint.socketURL.path)\nModded launch: not available (launch/injection verification pending)"
                    self.refreshButton.isEnabled = true
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.refreshGeneration == generation else { return }
                    self.invalidateDiscoveredGames()
                    self.status.stringValue = "Connection or discovery failed"
                    self.details.stringValue = error.localizedDescription
                    self.refreshButton.isEnabled = true
                }
            }
        }
    }

    // 41F-21B.5: Drop stale selection, endpoint and library together.
    // Call only on the main thread. Any pending detail response is invalidated.
    private func invalidateDiscoveredGames() {
        selectionGeneration += 1
        activeEndpoint = nil
        games = []
        gameTable.reloadData()
        updatePluginButtons()
        showReport("Select a Steam game to inspect.")
    }

    func numberOfRows(in tableView: NSTableView) -> Int { games.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard games.indices.contains(row) else { return nil }
        let field = NSTextField(labelWithString: "\(games[row].name) · AppID \(games[row].appId)")
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectionGeneration += 1
        recoveryScopeReport = nil
        updatePluginButtons()
        let selection = selectionGeneration
        let index = gameTable.selectedRow
        guard games.indices.contains(index), let endpoint = activeEndpoint else {
            showReport("Select a Steam game to inspect.")
            return
        }
        let game = games[index]
        showReport("Inspecting \(game.name)…")
        let generation = refreshGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let prefix: String
            do {
                if let path = try self.bridge.protonPrefix(for: game.appId, endpoint: endpoint) {
                    prefix = path.guestPath ?? "Unavailable"
                } else { prefix = "Not found" }
            } catch { prefix = "Unavailable: \(error.localizedDescription)" }

            // 41F-19C: Proton environment diagnostics.
            // An unresolved runtime must not be presented as a
            // verified Proton version.
            let runtime: String
            do {
                runtime = try self.bridge.protonRuntime(
                    for: game.appId,
                    endpoint: endpoint
                ) ?? "Unknown (not verified)"
            } catch {
                runtime = "Unavailable: \(error.localizedDescription)"
            }

            // 41F-21C.9C: Static runtime attestation is independent of
            // runtime path resolution and does not prove launch/injection.
            let attestationDetails: String
            var protonStaticallyVerified = false
            do {
                let attestation = try self.bridge.protonRuntimeAttestation(
                    for: game.appId,
                    endpoint: endpoint
                )
                protonStaticallyVerified = attestation.isStaticallyVerified
                if protonStaticallyVerified {
                    attestationDetails = "Verified (static filesystem layout; launch not verified)"
                } else {
                    attestationDetails = "\(attestation.state.rawValue) · \(attestation.evidence) (not verified)"
                }
            } catch {
                attestationDetails = "Unavailable (not verified): \(error.localizedDescription)"
            }

            let environmentDetails: String
            do {
                let inspection = try self.bridge.protonInspection(
                    for: game.appId,
                    endpoint: endpoint
                )

                let readiness = inspection.isStructurallyReady
                    ? "Components present (not launch verification)"
                    : "Missing or invalid components"

                environmentDetails = """
                Prefix status: \(inspection.prefix.rawValue)
                Windows drive: \(inspection.driveC.rawValue)
                DOS devices: \(inspection.dosdevices.rawValue)
                System registry: \(inspection.systemRegistry.rawValue)
                User registry: \(inspection.userRegistry.rawValue)
                Structure: \(readiness)
                """
            } catch {
                environmentDetails =
                    "Inspection unavailable: \(error.localizedDescription)"
            }

            // 41F-20D.3B: Read-only Reloaded-II inventory and metadata.
            let reloaded: String
            let mods: String
            // A failed or unavailable inventory is UNKNOWN, never absent.
            var reloadedInstalled: Bool? = nil

            do {
                let inventory = try self.bridge.reloadedIIInventory(
                    appId: game.appId,
                    endpoint: endpoint
                )

                switch inventory.installation {
                case .absent:
                    reloadedInstalled = false
                    reloaded = "Not installed"
                    mods = "No Reloaded-II installation detected."

                case .installed:
                    reloadedInstalled = true
                    reloaded = "Installed (discovered; not runtime-verified)"

                    do {
                        let handshake = try self.bridge.handshake(
                            endpoint: endpoint
                        )

                        if handshake.capabilities.supports(.reloadedIIModMetadataV1) {
                            let metadata = try self.bridge.reloadedIIMetadataInventory(
                                appId: game.appId,
                                endpoint: endpoint
                            )

                            if metadata.entries.isEmpty {
                                mods = "No Reloaded-II mods discovered."
                            } else {
                                var descriptions: [String] = [
                                    "\(metadata.entries.count) discovered configuration(s)"
                                ]

                                for entry in metadata.entries {
                                    switch entry.result {
                                    case .parsed(let mod):
                                        let name = mod.modName.isEmpty
                                            ? mod.modId
                                            : mod.modName

                                        var lines = [
                                            "",
                                            name,
                                            "  ID: \(mod.modId)",
                                            "  Author: \(mod.modAuthor.isEmpty ? "Unknown" : mod.modAuthor)",
                                            "  Version: \(mod.modVersion.isEmpty ? "Unknown" : mod.modVersion)"
                                        ]

                                        if !mod.modDescription.isEmpty {
                                            lines.append(
                                                "  Description: \(mod.modDescription)"
                                            )
                                        }

                                        if mod.isUniversalMod {
                                            lines.append(
                                                "  Declared compatibility: Universal"
                                            )
                                        } else if !mod.supportedAppIds.isEmpty {
                                            lines.append(
                                                "  Declared AppIDs: \(mod.supportedAppIds.joined(separator: ", "))"
                                            )
                                        } else {
                                            lines.append(
                                                "  Declared compatibility: Unspecified"
                                            )
                                        }

                                        lines.append(
                                            "  Configuration: \(entry.configPath)"
                                        )

                                        descriptions.append(
                                            lines.joined(separator: "\n")
                                        )

                                    case .invalid(let reason):
                                        descriptions.append(
                                            """

                                            ⚠ Invalid mod configuration
                                              Configuration: \(entry.configPath)
                                              Reason: \(reason)
                                            """
                                        )
                                    }
                                }

                                descriptions.append(
                                    "\nDiscovery does not verify mod loading, enablement, or runtime compatibility."
                                )

                                mods = descriptions.joined(separator: "\n")
                            }
                        } else {
                            mods = "\(inventory.modConfigPaths.count) discovered configs (metadata unavailable on this guest; not runtime proof)"
                        }
                    } catch {
                        mods = "Metadata unavailable: \(error.localizedDescription)"
                    }
                }
            } catch {
                reloaded = "Unavailable"
                mods = "Inventory unavailable: \(error.localizedDescription)"
            }
            // 41F-21B.2: real read-only guest preflight, no install actions.
            // Runtime paths are not attestation; use the independently
            // verified static-layout result. Installation remains disabled.
            let capabilityStatus: Bool
            do {
                let hello = try self.bridge.handshake(endpoint: endpoint)
                capabilityStatus = hello.capabilities.supports(.reloadedIIModInventoryV1)
            } catch {
                capabilityStatus = false
            }
            // 41F-21B.5: A library path is not proof of installation.
            // Require guest-side discovery of a game executable, scoped to
            // this SteamacGame. Any error or ambiguity fails closed.
            let gameDetected: Bool
            let gameEvidence: String
            do {
                if try self.bridge.gameInstall(for: game, endpoint: endpoint) != nil {
                    gameDetected = true
                    gameEvidence = "Guest executable discovery succeeded (not launch verification)."
                } else {
                    gameDetected = false
                    gameEvidence = "No unambiguous game executable found by guest discovery."
                }
            } catch {
                gameDetected = false
                gameEvidence = "Guest game discovery unavailable: \(error.localizedDescription)"
            }
            let reloadedPlan = SteamacFrameworkInstallationPlanner.makePlan(
                context: SteamacFrameworkInstallationContext(
                    appID: game.appId,
                    framework: .reloadedII,
                    gameInstalled: gameDetected,
                    guestConnected: true,
                    requiredCapabilitiesPresent: capabilityStatus,
                    protonRuntimeVerified: protonStaticallyVerified,
                    frameworkInstalled: reloadedInstalled
                )
            )
            // 41F-21B.6: BepInEx inventory is independent of Reloaded-II.
            // Unknown/partial/error remain blocked; only absent means false.
            var bepInstalled: Bool? = nil
            var bepCapability = false
            var bepEvidence = "Unavailable (guest capability not verified)."
            do {
                let hello = try self.bridge.handshake(endpoint: endpoint)
                bepCapability = hello.capabilities.supports(.bepInExInstallationInventoryV1)
                if bepCapability {
                    let inventory = try self.bridge.bepInExInventory(
                        appId: game.appId, endpoint: endpoint
                    )
                    bepEvidence = "\(inventory.installation.rawValue) · \(inventory.evidence)"
                    switch inventory.installation {
                    case .installed: bepInstalled = true
                    case .absent: bepInstalled = false
                    case .partial, .unknown: bepInstalled = nil
                    }
                }
            } catch {
                bepEvidence = "Unavailable: \(error.localizedDescription)"
            }
            let bepPlan = SteamacFrameworkInstallationPlanner.makePlan(
                context: SteamacFrameworkInstallationContext(
                    appID: game.appId,
                    framework: .bepInEx,
                    gameInstalled: gameDetected,
                    guestConnected: true,
                    requiredCapabilitiesPresent: bepCapability,
                    protonRuntimeVerified: false,
                    frameworkInstalled: bepInstalled
                )
            )
            func summary(_ plan: SteamacFrameworkInstallationPlan) -> String {
                let unresolved = plan.findings.filter { $0.status != .passed }
                let reasons = unresolved.map { "\($0.check.rawValue): \($0.detail)" }
                return "\(plan.framework.displayName): \(plan.state.rawValue) · Install disabled (explicit authorization required)" +
                    (reasons.isEmpty ? "" : "\n" + reasons.joined(separator: "\n"))
            }
            let preflight = [summary(reloadedPlan), summary(bepPlan)]
                .joined(separator: "\n\n")
            // 41F-21D.9: Read-only diagnostics, no authorization or guest mutation.
            let snapshots: [(SteamacInstallationFramework, SteamacCollectedTransactionEvidence)] =
                [.bepInEx, .reloadedII].map { framework in
                    (framework, SteamacTransactionEvidenceCollector.collect(
                        appID: game.appId, framework: framework,
                        endpoint: endpoint, bridge: self.bridge
                    ))
                }
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      self.refreshGeneration == generation,
                      self.selectionGeneration == selection,
                      self.activeEndpoint?.socketURL == endpoint.socketURL,
                      self.gameTable.selectedRow >= 0,
                      self.games.indices.contains(self.gameTable.selectedRow),
                      self.games[self.gameTable.selectedRow].appId == game.appId else { return }
                // Snapshot age is checked when rendered; selection and endpoint
                // identity are checked by the existing guard above.
                let readiness = snapshots.map { framework, snapshot -> String in
                    let transaction = SteamacInstallationTransaction(
                        appID: game.appId, framework: framework,
                        operations: SteamacTransactionReviewPlan.operations(for: framework)
                    )
                    // 41F-21D.13: coordinator-backed read-only review.
                    // All reviews remain unreviewed; this cannot authorize installation.
                    let current = snapshot.isCurrent(for: transaction, endpoint: endpoint)
                    var coordinator = SteamacTransactionReviewCoordinator(transaction: transaction)
                    let decision: SteamacTransactionSafetyResult
                    let reviewOutcome: String
                    do {
                        decision = try coordinator.review(
                            snapshot: snapshot,
                            expectedEndpointProcessID: endpoint.processId,
                            reviews: .unreviewed
                        )
                        reviewOutcome = "REVIEW READY (NOT AUTHORIZED)"
                    } catch {
                        // The coordinator retains its structured rejected result.
                        guard let rejected = coordinator.lastReview else {
                            return "Review unavailable · fail closed · Installation: DISABLED"
                        }
                        decision = rejected
                        reviewOutcome = "BLOCKED (\(String(describing: error)))"
                    }
                    let issues = decision.issues.map(\.rawValue).joined(separator: ", ")
                    let preflightIssues = decision.preflightIssues.map(\.rawValue).joined(separator: ", ")
                    let name = framework == .bepInEx ? "BepInEx" : "Reloaded-II"
                    let status = current ? "fresh at render time (≤30s; refresh to recheck)" : "STALE / mismatched"
                    func shown(_ fact: SteamacCollectedEvidenceFact) -> String {
                        current ? fact.status.rawValue : "unknown"
                    }
                    return """
                    \(name) · \(status)
                    Guest: \(shown(snapshot.guest)) · Capabilities: \(shown(snapshot.capabilities))
                    Runtime: \(shown(snapshot.runtime)) (static only)
                    Library: \(shown(snapshot.game)) · Prefix: \(shown(snapshot.prefix))
                    Framework inventory: \(shown(snapshot.frameworkInventory))
                    Coordinator: \(reviewOutcome)
                    Safety decision: \(decision.decision.rawValue)
                    Blocking issues: \(issues.isEmpty ? "none" : issues)
                    Preflight issues: \(preflightIssues.isEmpty ? "none" : preflightIssues)
                    Transaction plan: DECLARED (payload validation, snapshot, verification, rollback; none executed)
                    42A-13 evidence preparation: local SHA-256 verifier available (not run automatically)
                    Release provenance: NOT AUTHENTICATED · Recovery: CHECKLIST ONLY (no snapshot/restore)
                    Review attestations: UNCHANGED · No installation authorization
                    Safety reviews: UNREVIEWED (no authenticated payload, snapshot, rollback, or verification approvals)
                    Installation: DISABLED · No authorization or launch verification
                    """
                }.joined(separator: "\n\n")
                self.recoveryScopeReport = SteamacRecoveryScopePlan.report(
                    appID: game.appId, name: game.name, installPath: game.installPath,
                    libraryPath: game.libraryPath, prefix: prefix, runtime: runtime)
                self.updatePluginButtons()
                self.showReport("""
                \(game.name) · AppID \(game.appId)
                Install: \(game.installPath)
                Game evidence: \(gameEvidence)

                PROTON ENVIRONMENT
                Runtime: \(runtime)
                Runtime attestation: \(attestationDetails)
                Prefix: \(prefix)
                \(environmentDetails)

                RELOADED-II
                Installation: \(reloaded)
                Mods: \(mods)

                BEPINEX
                Installation: \(bepEvidence)
                Detection is not runtime/injection verification.

                BASIC ENVIRONMENT PREFLIGHT (READ-ONLY · NOT INSTALL AUTHORIZATION)
                \(preflight)

                TRANSACTION EVIDENCE (READ-ONLY · SAFETY REVIEWS PENDING)
                \(readiness)
                """)
            }
        }
    }
    // Generic BepInEx DLL workflow. Guest mutations remain fail-closed.
    private var selectedPluginGame: SteamacGame? {
        let row = gameTable.selectedRow
        guard games.indices.contains(row) else { return nil }
        return games[row]
    }

    private func updatePluginButtons() {
        fetchReleaseButton.isEnabled = !releaseFetchBusy && !pluginOperationBusy && !recoveryRehearsalBusy
        discoverProvenanceButton.isEnabled = fetchReleaseButton.isEnabled
        recoveryRehearsalButton.isEnabled = fetchReleaseButton.isEnabled
        recoveryScopeButton.isEnabled = recoveryScopeReport != nil && selectedPluginGame != nil && activeEndpoint != nil && !pluginOperationBusy && !releaseFetchBusy && !recoveryRehearsalBusy
        let enabled = selectedPluginGame != nil && activeEndpoint != nil && !pluginOperationBusy
        discoverScopeButton.isEnabled = enabled && !releaseFetchBusy && !recoveryRehearsalBusy
        guestInventoryButton.isEnabled = discoverScopeButton.isEnabled
        installFrameworkButton.isEnabled = enabled
        installPluginButton.isEnabled = enabled
        launchButton.isEnabled = enabled
        installAssetButton.isEnabled = enabled
        disableAssetButton.isEnabled = enabled
        manageAssetButton.isEnabled = enabled
        inspectPayloadButton.isEnabled = enabled
    }

    // 41F-21D.40: explicit, per-game framework installation. The existing
    // installer owns download, staging and guest deployment; never run this on
    // the main thread or claim success without a fresh guest inventory.
    @objc private func installFramework() {
        guard let game = selectedPluginGame, let endpoint = activeEndpoint,
              !pluginOperationBusy else { return }
        let confirm = NSAlert()
        confirm.messageText = "Install BepInEx for \(game.name)?"
        confirm.informativeText = "AppID \(game.appId). Choose the Unity runtime explicitly; the guest PE/Unity architecture cannot yet be determined automatically. Existing files may be modified. Back up mods before proceeding."
        confirm.addButton(withTitle: "Unity Mono (x64)")
        confirm.addButton(withTitle: "Unity IL2CPP (x64)")
        confirm.addButton(withTitle: "Cancel")
        let choice = confirm.runModal()
        guard choice == .alertFirstButtonReturn || choice == .alertSecondButtonReturn else { return }
        let il2cpp = choice == .alertSecondButtonReturn
        let release = BepInExInstaller.latestStable(is64Bit: true, isIL2CPP: il2cpp)
        pluginOperationBusy = true
        updatePluginButtons()
        showReport("Preparing BepInEx \(release.version) for AppID \(game.appId)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let inventory = try self.bridge.bepInExInventory(appId: game.appId, endpoint: endpoint)
                guard inventory.installation == .absent else {
                    throw NSError(domain: "BepisFramework", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Refusing installation: guest inventory is \(inventory.installation.rawValue). Repair/overwrite requires a separately reviewed transaction."])
                }
                guard let install = try self.bridge.gameInstall(for: game, endpoint: endpoint) else {
                    throw NSError(domain: "BepisFramework", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Game executable could not be resolved in the guest."])
                }
                BepInExInstaller.shared.install(into: install, asset: release,
                    progress: { [weak self] _, message in
                        DispatchQueue.main.async { self?.showReport(message) }
                    }, completion: { [weak self] result in
                        guard let self else { return }
                        let report: String
                        switch result {
                        case .failure(let error):
                            report = "BepInEx installation failed: \(error.localizedDescription)"
                        case .success:
                            do {
                                let verified = try self.bridge.bepInExInventory(appId: game.appId, endpoint: endpoint)
                                report = verified.installation == .installed
                                    ? "BepInEx files installed and guest inventory verified for AppID \(game.appId). Runtime loading is not yet attested."
                                    : "Installation returned success but inventory is \(verified.installation.rawValue). Inspect guest state before retrying."
                            } catch {
                                report = "Installation returned success, but inventory verification failed: \(error.localizedDescription)"
                            }
                        }
                        DispatchQueue.main.async {
                            self.pluginOperationBusy = false
                            self.updatePluginButtons()
                            self.showReport(report)
                        }
                    })
            } catch {
                DispatchQueue.main.async {
                    self.pluginOperationBusy = false
                    self.updatePluginButtons()
                    self.showReport(error.localizedDescription)
                }
            }
        }
    }

    @objc private func installPlugin() {
        guard let game = selectedPluginGame, let endpoint = activeEndpoint, !pluginOperationBusy else { return }
        let picker = NSOpenPanel(); picker.title = "Select BepInEx plugin DLLs"
        picker.allowedContentTypes = [UTType(filenameExtension: "dll") ?? .data]
        picker.canChooseDirectories = false; picker.allowsMultipleSelection = true
        guard picker.runModal() == .OK else { return }
        let plugins: [BepInExPluginSnapshot]
        do { plugins = try BepInExPluginBatch.inspect(picker.urls) }
        catch { showReport("Cannot read selected plugins: \(error.localizedDescription)"); return }
        guard game.installPath.hasPrefix("/"), !game.installPath.split(separator: "/").contains("..") else { showReport("Invalid guest installation path."); return }
        let directory = game.installPath + "/BepInEx/plugins"
        let confirmation = NSAlert(); confirmation.messageText = "Install \(plugins.count) plugins?"
        confirmation.informativeText = plugins.map(\.filename).joined(separator: "\n") + "\n\nDestination: \(directory)\nUser-selected DLLs are unverified. Existing plugins will not be overwritten."
        confirmation.addButton(withTitle: "Install Plugins"); confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        pluginOperationBusy = true; updatePluginButtons(); showReport("Uploading and verifying selected plugins…")
        DispatchQueue.global(qos: .userInitiated).async {
            var installed: [String] = []
            var failed: String?
            do {
                guard try self.bridge.guestFileInfo(at: directory, endpoint: endpoint).kind == .directory else { throw AssetModPackage.failure("BepInEx/plugins directory is missing.") }
                // Preflight the entire batch before uploading any plugin.
                for plugin in plugins {
                    guard try self.bridge.guestFileInfo(at: directory + "/" + plugin.filename, endpoint: endpoint).kind == .missing else {
                        throw AssetModPackage.failure("\(plugin.filename) already exists; no plugins uploaded.")
                    }
                }
                for plugin in plugins {
                    do { try self.installPluginSnapshot(plugin, directory: directory, game: game, endpoint: endpoint); installed.append(plugin.filename) }
                    catch { failed = "\(plugin.filename): \(error.localizedDescription)"; break }
                }
            } catch { failed = error.localizedDescription }
            let report = "Installed and verified \(installed.count) of \(plugins.count) plugins.\n" + installed.joined(separator: "\n")
                + (failed.map { "\nStopped: \($0). Successfully installed plugins are retained; inspect guest state before retrying." } ?? "\nRuntime loading has not been verified.")
            DispatchQueue.main.async { self.pluginOperationBusy = false; self.updatePluginButtons(); self.showReport(report) }
        }
    }
    private func installPluginSnapshot(_ plugin: BepInExPluginSnapshot, directory: String, game: SteamacGame, endpoint: SteamacBridgeEndpoint) throws {
        let stage = directory + "/.bepis-stage-" + UUID().uuidString.lowercased() + ".tmp"
        guard try bridge.guestFileInfo(at: stage, endpoint: endpoint).kind == .missing else { throw AssetModPackage.failure("Unexpected staging collision.") }
        defer { try? bridge.removeGuestItem(at: stage, endpoint: endpoint) }
        try bridge.writeGuestFile(plugin.data, to: stage, endpoint: endpoint)
        guard try bridge.readGuestFile(at: stage, endpoint: endpoint, maximumSize: UInt64(plugin.data.count)) == plugin.data else {
            throw AssetModPackage.failure("Staging verification failed.")
        }
        try bridge.commitGuestPlugin(appId: game.appId, stage: stage, filename: plugin.filename, endpoint: endpoint)
        guard try bridge.readGuestFile(at: directory + "/" + plugin.filename, endpoint: endpoint, maximumSize: UInt64(plugin.data.count)) == plugin.data else {
            throw AssetModPackage.failure("Published plugin verification failed.")
        }
    }

    @objc private func collectGuestRecoveryInventory() {
        guard guestInventoryButton.isEnabled, let game = selectedPluginGame,
              let endpoint = activeEndpoint, !pluginOperationBusy else { return }
        let selection = selectionGeneration
        let generation = refreshGeneration
        pluginOperationBusy = true
        updatePluginButtons()
        showReport("42A-20: Collecting bounded no-follow guest inventory; no file contents or guest mutations…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var report: String
            do {
                let fm = FileManager.default
                let root = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let directory = root.appendingPathComponent("BepisLoader/42A-20/" + UUID().uuidString)
                try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                var summaries: [String] = []
                for scope in ["game", "prefix", "users", "userdata"] {
                    do {
                        let inventory = try self.bridge.recoveryInventory(appID: game.appId, scope: scope, endpoint: endpoint)
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        try encoder.encode(inventory).write(to: directory.appendingPathComponent(scope + ".json"), options: .atomic)
                        summaries.append(inventory.summary(scope: scope))
                    } catch { summaries.append("Scope: \(scope) · UNAVAILABLE: \(error.localizedDescription)") }
                }
                report = """
                42A-20 · READ-ONLY APPID-SCOPED GUEST INVENTORY
                Game: \(game.name) · AppID \(game.appId)
                Collected: \(ISO8601DateFormatter().string(from: Date()))
                Host evidence: \(directory.path)
                \(summaries.joined(separator: "\n\n"))

                Scope remains INCOMPLETE: metadata observations are non-atomic, saved-name matches are hypotheses, and external save completeness, Cloud synchronization, and installer writes are unresolved.
                Traversal uses no-follow directory descriptors; symlinks are recorded, never traversed. Device or Linux mount-ID crossings are detected and skipped.
                File contents/SHA-256, ACLs, extended attributes, consistency/quiescence, capacity and crash recovery: NOT VERIFIED.
                Real guest snapshot/rollback restorability: NOT VERIFIED
                Publisher provenance: NOT VERIFIED · Verification criteria: NOT APPROVED
                Safety attestations: UNCHANGED · Installation/injection authorization: NONE
                No game/prefix/save writes, snapshot/restore, installer or mod execution.
                """
                try report.write(to: directory.appendingPathComponent("evidence.txt"), atomically: true, encoding: .utf8)
            } catch { report = "42A-20 inventory failed: \(error.localizedDescription). Safety attestations unchanged." }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pluginOperationBusy = false
                self.updatePluginButtons()
                guard self.selectionGeneration == selection, self.refreshGeneration == generation,
                      self.activeEndpoint?.socketURL == endpoint.socketURL,
                      self.selectedPluginGame?.appId == game.appId else { return }
                self.showReport(report)
            }
        }
    }

    @objc private func discoverGuestRecoveryScope() {
        guard discoverScopeButton.isEnabled, let game = selectedPluginGame,
              let endpoint = activeEndpoint, !pluginOperationBusy else { return }
        let selection = selectionGeneration
        let generation = refreshGeneration
        pluginOperationBusy = true
        updatePluginButtons()
        showReport("42A-19: Collecting bounded guest path metadata (read-only)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var prefix: String?
            let prefixEvidence: String
            do {
                prefix = try self.bridge.protonPrefix(for: game.appId, endpoint: endpoint)?.guestPath
                prefixEvidence = prefix ?? "Not resolved"
            } catch { prefixEvidence = "UNAVAILABLE: \(error.localizedDescription)" }
            let report = SteamacRecoveryScopeDiscovery.report(appID: game.appId, name: game.name,
                install: game.installPath, prefix: prefix, prefixEvidence: prefixEvidence) { path in
                let info = try self.bridge.guestFileInfo(at: path, endpoint: endpoint)
                return (kind: info.kind.rawValue, size: info.size)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pluginOperationBusy = false
                self.updatePluginButtons()
                guard self.selectionGeneration == selection, self.refreshGeneration == generation,
                      self.activeEndpoint?.socketURL == endpoint.socketURL,
                      self.selectedPluginGame?.appId == game.appId else { return }
                self.showReport(report)
            }
        }
    }

    @objc private func reviewRecoveryScope() {
        guard recoveryScopeButton.isEnabled, let report = recoveryScopeReport else { return }
        showReport(report)
    }

    @objc private func rehearseHostRecovery() {
        guard !recoveryRehearsalBusy, !releaseFetchBusy, !pluginOperationBusy else { return }
        recoveryRehearsalBusy = true
        updatePluginButtons()
        showReport("42A-17: Rehearsing snapshot and restore with disposable host fixtures only…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report: String
            do { report = try SteamacRecoveryRehearsal.run() }
            catch { report = "42A-17: Rehearsal FAILED: \(error.localizedDescription)\nNo real guest recovery was attempted; safety reviews remain unchanged." }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.recoveryRehearsalBusy = false
                self.updatePluginButtons()
                self.showReport(report)
            }
        }
    }

    // Independent of guest selection/connectivity; evidence never enters safety reviews.
    @objc private func discoverReloadedProvenance() {
        fetchReloadedRelease(discoverProvenance: true)
    }

    @objc private func fetchLatestReloadedRelease() {
        fetchReloadedRelease(discoverProvenance: false)
    }

    private func fetchReloadedRelease(discoverProvenance: Bool) {
        guard !releaseFetchBusy, !pluginOperationBusy, !recoveryRehearsalBusy else { return }
        releaseFetchBusy = true
        updatePluginButtons()
        showReport("42A-15: Fetching latest official stable release and hashing Setup-Linux.exe on the Mac only…")
        Task { [weak self] in
            let report: String
            do { report = try await SteamacReloadedReleaseFetcher().fetch(discoverProvenance: discoverProvenance) }
            catch { report = "Release fetch/discovery failed: \(error.localizedDescription)\nIncomplete payload discarded. No installation, guest operation, or safety approval performed." }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.releaseFetchBusy = false
                self.updatePluginButtons()
                self.showReport(report)
            }
        }
    }

    // 42A-14: The user chooses a LOCAL file and supplies a separately obtained
    // reference digest. The verifier only compares bytes; it cannot authenticate
    // the reference, verify release provenance, or approve an installation.
    @objc private func inspectLocalPayload() {
        guard let game = selectedPluginGame, let endpoint = activeEndpoint,
              !pluginOperationBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Inspect local installer (read-only)"
        panel.message = "Select a local payload. No file is uploaded or installed."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let prompt = NSAlert()
        prompt.messageText = "Enter independently obtained SHA-256"
        prompt.informativeText = "AppID \(game.appId). Paste a 64-character reference digest from a source you independently trust. This comparison does NOT authenticate that source. Cancel leaves everything unchanged."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        input.placeholderString = "64 hexadecimal characters"
        prompt.accessoryView = input
        prompt.addButton(withTitle: "Compare Locally")
        prompt.addButton(withTitle: "Cancel")
        guard prompt.runModal() == .alertFirstButtonReturn else { return }
        let expected = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard expected.count == 64, expected.utf8.allSatisfy({
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102)
        }) else {
            showReport("42A-14: Invalid SHA-256 reference. No file read or installation performed.")
            return
        }
        let selectionAtStart = selectionGeneration
        let refreshAtStart = refreshGeneration
        pluginOperationBusy = true
        updatePluginButtons()
        showReport("42A-14: Hashing selected local file (read-only)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report: String
            do {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                guard values.isSymbolicLink != true, values.isRegularFile == true else {
                    throw SteamacEvidencePreparationError.notRegularFile
                }
                let result = try SteamacTransactionEvidencePreparation.verifyLocalPayload(
                    at: url, expectedSHA256: expected)
                let recovery = SteamacRecoveryReadinessPreparation.checklist(
                    appID: game.appId, framework: .reloadedII)
                report = """
                42A-14 · LOCAL PAYLOAD INSPECTION · AppID \(game.appId)
                Filename: \(result.fileName)
                Bytes: \(result.byteCount)
                Computed SHA-256: \(result.computedSHA256)
                Reference SHA-256: \(result.expectedSHA256)
                Digest comparison: \(result.digestMatches ? "MATCH" : "MISMATCH — DO NOT USE")
                Reference provenance: UNAUTHENTICATED (user-supplied)
                Upstream signature/release identity: NOT VERIFIED
                Snapshot restorability: NOT VERIFIED
                Rollback restorability: NOT VERIFIED
                Verification criteria: NOT APPROVED
                Recovery checklist:
                \(recovery.items.map { "• " + $0 }.joined(separator: "\n"))
                Coordinator safety reviews: UNREVIEWED
                Installation: DISABLED · No guest operation or game modification
                """
            } catch {
                report = "42A-14: Local inspection failed: \(error). No guest operation or installation performed."
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pluginOperationBusy = false
                self.updatePluginButtons()
                guard self.selectionGeneration == selectionAtStart,
                      self.refreshGeneration == refreshAtStart,
                      self.activeEndpoint?.socketURL == endpoint.socketURL,
                      self.selectedPluginGame?.appId == game.appId else { return }
                self.showReport(report)
            }
        }
    }

    @objc private func installAssetMod() {
        guard !pluginOperationBusy, let game = selectedPluginGame, let endpoint = activeEndpoint else { return }
        guard AssetModAdapter.forGame(game.appId) != nil else { showReport("No asset adapter is available for this game yet."); return }
        let panel = NSOpenPanel(); panel.title = "Choose asset mod folders"
        panel.message = "Select extracted mod folders containing ModConfig.json. Review enablement and conflicts before applying."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }; let folders = panel.urls
        pluginOperationBusy = true; updatePluginButtons(); showReport("Checking asset mods and current profile…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let profile = try AssetModProfiles.load(game: game, endpoint: endpoint, bridge: self.bridge)
                let packages = try folders.map { try AssetModPackage.inspect(folder: $0, appId: game.appId) }
                var cache = try AssetModProfiles.packages(profile, game: game, endpoint: endpoint, bridge: self.bridge)
                guard cache.values.reduce(0, { $0 + $1.totalBytes }) + packages.reduce(0, { $0 + $1.totalBytes }) <= 256 * 1024 * 1024 else {
                    throw AssetModPackage.failure("The stored packages in this profile would exceed 256 MiB. Remove unused mods from the profile first.")
                }
                DispatchQueue.main.async {
                    let review = NSAlert(); review.messageText = "Add \(packages.count) asset mods?"
                    review.informativeText = packages.map { "\($0.name): \($0.files.count) assets" }.joined(separator: "\n") + "\n\nPackages are stored in the guest. You will review the combined profile before activation."
                    review.addButton(withTitle: "Add mods"); review.addButton(withTitle: "Cancel")
                    guard review.runModal() == .alertFirstButtonReturn else { self.pluginOperationBusy = false; self.updatePluginButtons(); return }
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let next = try AssetModProfiles.add(packages, to: profile, game: game, endpoint: endpoint, bridge: self.bridge)
                            for (mod, package) in zip(next.mods.dropFirst(profile.mods.count), packages) { cache[mod.id] = package }
                            DispatchQueue.main.async { self.pluginOperationBusy = false; self.updatePluginButtons(); self.presentAssetProfile(next, packages: cache, game: game, endpoint: endpoint) }
                        } catch { self.assetOperationFailed(error) }
                    }
                }
            } catch { self.assetOperationFailed(error) }
        }
    }
    @objc private func manageAssetMods() {
        guard !pluginOperationBusy, let game = selectedPluginGame, let endpoint = activeEndpoint else { return }
        pluginOperationBusy = true; updatePluginButtons(); showReport("Loading installed asset mods…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let profile = try AssetModProfiles.load(game: game, endpoint: endpoint, bridge: self.bridge)
                let packages = try AssetModProfiles.packages(profile, game: game, endpoint: endpoint, bridge: self.bridge)
                DispatchQueue.main.async { self.pluginOperationBusy = false; self.updatePluginButtons(); self.presentAssetProfile(profile, packages: packages, game: game, endpoint: endpoint) }
            } catch { self.assetOperationFailed(error) }
        }
    }
    private func presentAssetProfile(_ profile: AssetModProfile, packages: [String: AssetModPackage], game: SteamacGame, endpoint: SteamacBridgeEndpoint) {
        guard let adapter = AssetModAdapter.forGame(game.appId) else { return }
        assetProfileWindow?.close()
        let controller = AssetModProfileWindowController(profile: profile, packages: packages, adapter: adapter) { next, merge, window in
            guard !self.pluginOperationBusy else { window.allowRetry(); return }
            self.pluginOperationBusy = true; self.updatePluginButtons(); self.showReport("Applying combined asset profile…")
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let report = try AssetModProfiles.apply(next, merge: merge, game: game, endpoint: endpoint, bridge: self.bridge)
                    DispatchQueue.main.async { window.close(); self.assetProfileWindow = nil; self.pluginOperationBusy = false; self.updatePluginButtons(); self.showReport(report) }
                } catch { DispatchQueue.main.async { window.allowRetry() }; self.assetOperationFailed(error) }
            }
        }
        assetProfileWindow = controller; controller.showWindow(nil)
    }
    private func assetOperationFailed(_ error: Error) {
        let message = error.localizedDescription
        DispatchQueue.main.async { self.pluginOperationBusy = false; self.updatePluginButtons(); self.showReport("Asset operation stopped: \(message)") }
    }
    @objc private func disableAssetMods() {
        guard !pluginOperationBusy, let game = selectedPluginGame, let endpoint = activeEndpoint else { return }
        pluginOperationBusy = true; updatePluginButtons()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var profile = try AssetModProfiles.load(game: game, endpoint: endpoint, bridge: self.bridge)
                let packages = try AssetModProfiles.packages(profile, game: game, endpoint: endpoint, bridge: self.bridge)
                for index in profile.mods.indices { profile.mods[index].enabled = false }
                guard let adapter = AssetModAdapter.forGame(game.appId) else { throw AssetModPackage.failure("Unsupported asset adapter.") }
                let merge = try AssetModProfiles.merge(profile, packages: packages, adapter: adapter)
                let report = try AssetModProfiles.apply(profile, merge: merge, game: game, endpoint: endpoint, bridge: self.bridge)
                DispatchQueue.main.async { self.pluginOperationBusy = false; self.updatePluginButtons(); self.showReport(report) }
            } catch { self.assetOperationFailed(error) }
        }
    }

    @objc private func launchViaSteamac() {
        guard let game = selectedPluginGame, let endpoint = activeEndpoint, !pluginOperationBusy else { return }
        pluginOperationBusy = true
        updatePluginButtons()
        showReport("Checking attested Steamac launch availability…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let message: String
            do {
                let state = try self.bridge.modLaunchState(appId: game.appId,
                    requestID: UUID(), endpoint: endpoint)
                let unloaded = game.appId == 1984270
                    ? try SteamacUnloadedIIPlan.inspect(game: game, endpoint: endpoint, bridge: self.bridge).report + "\n"
                    : ""
                message = unloaded + "Guest launch status: \(state.rawValue). No launch sent: this protocol does not attest plugin runtime loading. Use Steam's Play button until an attested launch endpoint is implemented."
            } catch {
                message = "Launch blocked: \(error.localizedDescription). No unsafe fallback attempted."
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.pluginOperationBusy = false
                self.updatePluginButtons()
                self.showReport(message)
            }
        }
    }

}
