import AppKit
import Foundation
import CryptoKit
import UniformTypeIdentifiers

// 41F-21D.38-R1: Steamac cockpit with generic plugin inspection.
// No guest launches, reservations, or mod mutations are issued by this UI.
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
    private let installPluginButton = NSButton(title: "Install Plugin…", target: nil, action: nil)
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
        let stack = NSStackView(views: [title, status, details, refreshButton, scroll, reportScroll, installFrameworkButton, installPluginButton, launchButton])
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
                        appID: game.appId, framework: framework, operations: []
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
                    Safety reviews: UNREVIEWED (no authenticated payload, snapshot, rollback, or verification approvals)
                    Installation: DISABLED · No authorization or launch verification
                    """
                }.joined(separator: "\n\n")
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
        let enabled = selectedPluginGame != nil && activeEndpoint != nil && !pluginOperationBusy
        installFrameworkButton.isEnabled = enabled
        installPluginButton.isEnabled = enabled
        launchButton.isEnabled = enabled
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
        let picker = NSOpenPanel()
        picker.title = "Select a BepInEx plugin DLL"
        picker.allowedContentTypes = [UTType(filenameExtension: "dll") ?? .data]
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let file = picker.url else { return }
        let filename = file.lastPathComponent
        guard filename.lowercased().hasSuffix(".dll"),
              filename.count > 4,
              filename == (filename as NSString).lastPathComponent,
              filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\\\\"),
              !filename.contains("\n"), !filename.contains("\\r") else {
            showReport("Refused: select a regular DLL with a safe filename.")
            return
        }
        let data: Data
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            guard (attrs[.type] as? FileAttributeType) == .typeRegular else {
                showReport("Refused: plugin source must be a regular file.")
                return
            }
            data = try Data(contentsOf: file)
        } catch {
            showReport("Cannot read plugin: \(error.localizedDescription)")
            return
        }
        guard !data.isEmpty, data.count <= 64 * 1024 * 1024 else {
            showReport("Refused: DLL must be nonempty and at most 64 MiB.")
            return
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard game.installPath.hasPrefix("/"),
              !game.installPath.split(separator: "/").contains("..") else {
            showReport("Invalid guest installation path. No changes made.")
            return
        }
        let destination = game.installPath + "/BepInEx/plugins/" + filename
        let confirmation = NSAlert()
        confirmation.messageText = "Review plugin destination"
        confirmation.informativeText = "AppID \(game.appId)\nDestination: \(destination)\nSHA-256: \(digest)\nInstalls a user-selected, unverified DLL. Existing plugins are never overwritten."
        confirmation.addButton(withTitle: "Install Plugin")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        pluginOperationBusy = true
        updatePluginButtons()
        showReport("Uploading and verifying plugin…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let message: String
            do {
                let directory = game.installPath + "/BepInEx/plugins"
                let directoryInfo = try self.bridge.guestFileInfo(at: directory, endpoint: endpoint)
                guard directoryInfo.kind == .directory else {
                    throw NSError(domain: "BepisPlugin", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "BepInEx/plugins directory is missing"])
                }
                let destinationInfo = try self.bridge.guestFileInfo(at: destination, endpoint: endpoint)
                guard destinationInfo.kind == .missing else {
                    throw NSError(domain: "BepisPlugin", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Plugin already exists; refusing overwrite"])
                }
                let stage = directory + "/.bepis-stage-" + UUID().uuidString.lowercased() + ".tmp"
                let stageInfo = try self.bridge.guestFileInfo(at: stage, endpoint: endpoint)
                guard stageInfo.kind == .missing else {
                    throw NSError(domain: "BepisPlugin", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Unexpected stage collision"])
                }
                // Random stage name; guest commit is the atomic, no-overwrite
                // boundary. Stage cleanup is best-effort after failures.
                defer { try? self.bridge.removeGuestItem(at: stage, endpoint: endpoint) }
                try self.bridge.writeGuestFile(data, to: stage, endpoint: endpoint)
                let staged = try self.bridge.readGuestFile(at: stage, endpoint: endpoint,
                    maximumSize: UInt64(data.count))
                guard staged == data else {
                    throw NSError(domain: "BepisPlugin", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Staging readback mismatch"])
                }
                try self.bridge.commitGuestPlugin(appId: game.appId, stage: stage,
                    filename: filename, endpoint: endpoint)
                let installed = try self.bridge.readGuestFile(at: destination,
                    endpoint: endpoint, maximumSize: UInt64(data.count))
                guard installed == data else {
                    throw NSError(domain: "BepisPlugin", code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "Published plugin readback mismatch"])
                }
                message = "Installed and verified \(filename) for AppID \(game.appId). SHA-256: \(digest). Runtime loading not yet verified."
            } catch {
                message = "Plugin installation not verified: \(error.localizedDescription). Inspect guest state before retrying."
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.pluginOperationBusy = false
                self.updatePluginButtons()
                self.showReport(message)
            }
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
