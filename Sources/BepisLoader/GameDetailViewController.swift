import AppKit
import Foundation

// ─────────────────────────────────────────────
//  GameDetailViewController
//  Right pane — shows BepInEx status, install /
//  launch buttons, mod list, and live log output.
// ─────────────────────────────────────────────

class GameDetailViewController: NSViewController {

    var game: GameInstall? { didSet { refresh() } }
    var onGameUpdated: ((GameInstall) -> Void)?

    // ── UI components ──────────────────────────

    private let titleLabel       = NSTextField(labelWithString: "Select a game")
    private let pathLabel        = NSTextField(labelWithString: "")
    private let archLabel        = NSTextField(labelWithString: "")
    private let statusLabel      = NSTextField(labelWithString: "")
    private let layerLabel       = NSTextField(labelWithString: "Launch Layer:")
    private let layerPopUp       = NSPopUpButton()
    private let installButton    = NSButton()
    private let uninstallButton  = NSButton()
    private let launchInfoLabel  = NSTextField(labelWithString: "⚠️ Launch via CrossOver to use mods")
    private let toggleEngineBtn  = NSButton()
    private let viewLogButton    = NSButton()
    private let progressBar      = NSProgressIndicator()
    private let progressLabel    = NSTextField(labelWithString: "")
    private let modsHeader       = NSTextField(labelWithString: "MODS")
    private let addModButton     = NSButton()
    private let modTableView     = NSTableView()
    private let modScrollView    = NSScrollView()
    private let logHeader        = NSTextField(labelWithString: "LOG OUTPUT")
    private let logTextView      = NSTextView()
    private let logScrollView    = NSScrollView()

    private var mods: [Mod] = []
    private var runningProcess: Process?
    private var logObserver: NSObjectProtocol?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        setupUI()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refresh()

        logObserver = NotificationCenter.default.addObserver(
            forName: .gameLogOutput, object: nil, queue: .main
        ) { [weak self] note in
            if let text = note.userInfo?["text"] as? String {
                self?.appendLog(text)
            }
        }
    }

    deinit {
        if let obs = logObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // ── Layout ─────────────────────────────────

    private func setupUI() {
        // Title
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        pathLabel.font = NSFont.systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pathLabel)

        archLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        archLabel.textColor = .secondaryLabelColor
        archLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(archLabel)

        toggleEngineBtn.title = "Toggle Engine"
        toggleEngineBtn.target = self
        toggleEngineBtn.action = #selector(toggleEngine)
        toggleEngineBtn.bezelStyle = .inline
        toggleEngineBtn.font = NSFont.systemFont(ofSize: 10)
        toggleEngineBtn.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toggleEngineBtn)

        viewLogButton.title = "View Log"
        viewLogButton.target = self
        viewLogButton.action = #selector(viewLogClicked)
        viewLogButton.bezelStyle = .rounded
        viewLogButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(viewLogButton)

        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        // Layer dropdown
        layerLabel.font = NSFont.systemFont(ofSize: 11)
        layerLabel.textColor = .secondaryLabelColor
        layerLabel.translatesAutoresizingMaskIntoConstraints = false
        
        layerPopUp.translatesAutoresizingMaskIntoConstraints = false
        layerPopUp.target = self
        layerPopUp.action = #selector(layerChanged)
        for layer in CompatibilityLayer.allCases {
            layerPopUp.addItem(withTitle: layer.rawValue)
        }
        
        let layerStack = NSStackView(views: [layerLabel, layerPopUp])
        layerStack.spacing = 8
        layerStack.orientation = .horizontal
        layerStack.alignment = .centerY
        layerStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(layerStack)

        // Buttons
        configureButton(installButton,   title: "Install BepisLoader",   action: #selector(installClicked))
        configureButton(uninstallButton, title: "Uninstall",         action: #selector(uninstallClicked))
        
        launchInfoLabel.font = .systemFont(ofSize: 12, weight: .medium)
        launchInfoLabel.textColor = .systemOrange
        launchInfoLabel.translatesAutoresizingMaskIntoConstraints = false

        let buttonStack = NSStackView(views: [installButton, uninstallButton, launchInfoLabel])
        buttonStack.spacing = 12
        buttonStack.orientation = .horizontal
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buttonStack)

        // Progress
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.isHidden = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressBar)

        progressLabel.font = NSFont.systemFont(ofSize: 11)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.isHidden = true
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressLabel)

        // Separator
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sep)

        // Mods header
        modsHeader.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        modsHeader.textColor = .secondaryLabelColor
        modsHeader.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(modsHeader)

        configureButton(addModButton, title: "+ Add Mod…", action: #selector(addModClicked))
        addModButton.controlSize = .small

        // Mod table
        let nameCol    = NSTableColumn(identifier: .init("name"))
        nameCol.title  = "Mod"
        nameCol.width  = 180
        let verCol     = NSTableColumn(identifier: .init("ver"))
        verCol.title   = "Version"
        verCol.width   = 80
        let enabledCol = NSTableColumn(identifier: .init("enabled"))
        enabledCol.title = "Enabled"
        enabledCol.width = 60
        modTableView.addTableColumn(nameCol)
        modTableView.addTableColumn(verCol)
        modTableView.addTableColumn(enabledCol)
        modTableView.rowHeight = 22
        modTableView.dataSource = self
        modTableView.delegate   = self
        modTableView.usesAlternatingRowBackgroundColors = true

        modScrollView.documentView = modTableView
        modScrollView.hasVerticalScroller = true
        modScrollView.borderType = .bezelBorder
        modScrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(modScrollView)

        // Log
        let sep2 = NSBox(); sep2.boxType = .separator
        sep2.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sep2)

        logHeader.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        logHeader.textColor = .secondaryLabelColor
        logHeader.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(logHeader)

        logTextView.isEditable = false
        logTextView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        logTextView.backgroundColor = NSColor(white: 0.08, alpha: 1)
        logTextView.textColor = NSColor(white: 0.85, alpha: 1)
        logTextView.textContainerInset = NSSize(width: 4, height: 4)

        logScrollView.documentView = logTextView
        logScrollView.hasVerticalScroller = true
        logScrollView.borderType = .bezelBorder
        logScrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(logScrollView)

        let modHeaderStack = NSStackView(views: [modsHeader, NSView(), addModButton])
        modHeaderStack.orientation = .horizontal
        modHeaderStack.distribution = .fill
        modHeaderStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(modHeaderStack)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            pathLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            pathLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            pathLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            archLabel.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 4),
            archLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            toggleEngineBtn.centerYAnchor.constraint(equalTo: archLabel.centerYAnchor),
            toggleEngineBtn.leadingAnchor.constraint(equalTo: archLabel.trailingAnchor, constant: 8),

            statusLabel.topAnchor.constraint(equalTo: archLabel.bottomAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            viewLogButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            viewLogButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            layerStack.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            layerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            buttonStack.topAnchor.constraint(equalTo: layerStack.bottomAnchor, constant: 12),
            buttonStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            progressBar.topAnchor.constraint(equalTo: buttonStack.bottomAnchor, constant: 10),
            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            progressLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 4),
            progressLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            sep.topAnchor.constraint(equalTo: progressLabel.bottomAnchor, constant: 12),
            sep.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            sep.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            modHeaderStack.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 8),
            modHeaderStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            modHeaderStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            modScrollView.topAnchor.constraint(equalTo: modHeaderStack.bottomAnchor, constant: 4),
            modScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            modScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            modScrollView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.22),

            sep2.topAnchor.constraint(equalTo: modScrollView.bottomAnchor, constant: 10),
            sep2.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            sep2.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            logHeader.topAnchor.constraint(equalTo: sep2.bottomAnchor, constant: 8),
            logHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            logScrollView.topAnchor.constraint(equalTo: logHeader.bottomAnchor, constant: 4),
            logScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            logScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            logScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])
    }

    private func configureButton(_ btn: NSButton, title: String, action: Selector) {
        btn.title      = title
        btn.bezelStyle = .rounded
        btn.font       = NSFont.systemFont(ofSize: 13)
        btn.target     = self
        btn.action     = action
        btn.translatesAutoresizingMaskIntoConstraints = false
    }

    // ── Data refresh ───────────────────────────

    private func refresh() {
        guard let game = game else {
            titleLabel.stringValue   = "Select a game"
            pathLabel.stringValue    = ""
            archLabel.stringValue    = ""
            statusLabel.stringValue  = ""
            layerPopUp.isHidden      = true
            layerLabel.isHidden      = true
            installButton.isHidden   = true
            uninstallButton.isHidden = true
            launchInfoLabel.isHidden = true
            mods = []
            modTableView.reloadData()
            return
        }

        titleLabel.stringValue    = game.name
        pathLabel.stringValue     = game.executablePath.path
        
        let archResult = shell("/usr/bin/file", game.executablePath.path)
        var archString = "Architecture: "
        if archResult.output.contains("PE32+") {
            archString += "64-bit (x64)"
        } else if archResult.output.contains("PE32") {
            archString += "32-bit (x86)"
        } else {
            archString += "Unknown"
        }
        
        archString += "  ·  Engine: \(game.unityType.rawValue)"
        archLabel.stringValue = archString
        
        let activeLayer = game.overrideLayer ?? game.bottle.layer
        layerPopUp.selectItem(withTitle: activeLayer.rawValue)
        
        installButton.isHidden    = game.isBepInExInstalled
        uninstallButton.isHidden  = !game.isBepInExInstalled
        launchInfoLabel.isHidden  = !game.isBepInExInstalled

        switch game.bepInExStatus {
        case .notInstalled:
            statusLabel.stringValue = "⚪ BepisLoader not installed"
            statusLabel.textColor   = .secondaryLabelColor
            installButton.title = "Install BepisLoader"
        case .installed(let v):
            if v == "unknown" {
                statusLabel.stringValue = "🟠 BepisLoader installed (version unknown)"
                statusLabel.textColor   = .systemOrange
                installButton.isHidden  = false
                installButton.title = "Redownload BepisLoader"
            } else {
                statusLabel.stringValue = "🟢 BepInEx \(v) installed"
                statusLabel.textColor   = .systemGreen
                installButton.title = "Install BepisLoader"
            }
            mods = ModManager.shared.listMods(for: game)
            modTableView.reloadData()
        case .incompatible(let r):
            statusLabel.stringValue = "🔴 Incompatible: \(r)"
            statusLabel.textColor   = .systemRed
            installButton.title = "Install BepisLoader"
        }
    }

    // ── Button actions ─────────────────────────

    @objc private func layerChanged() {
        guard var game = game, let selectedTitle = layerPopUp.titleOfSelectedItem else { return }
        if let layer = CompatibilityLayer.allCases.first(where: { $0.rawValue == selectedTitle }) {
            game.overrideLayer = layer
            self.game = game
            self.onGameUpdated?(game)
        }
    }

    @objc private func installClicked() {
        guard let game = game else { return }
        installButton.isEnabled  = false
        progressBar.isHidden     = false
        progressLabel.isHidden   = false

        BepInExInstaller.shared.install(
            into: game,
            progress: { [weak self] pct, msg in
                DispatchQueue.main.async {
                    self?.progressBar.doubleValue = pct
                    self?.progressLabel.stringValue = msg
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    self?.progressBar.isHidden   = true
                    self?.progressLabel.isHidden = true
                    self?.installButton.isEnabled = true
                    switch result {
                    case .success:
                        self?.showAlert("BepisLoader installed successfully!", style: .informational)
                        if let dir = self?.game?.gameDirectory, let oldGame = self?.game {
                            var updatedGame = oldGame
                            updatedGame.bepInExStatus = BottleScanner.shared.detectBepInExStatus(gameDir: dir)
                            self?.game = updatedGame
                            self?.onGameUpdated?(updatedGame)
                        }
                    case .failure(let err):
                        self?.showAlert("Installation failed:\n\(err.localizedDescription)", style: .critical)
                    }
                }
            }
        )
    }

    @objc private func uninstallClicked() {
        guard let game = game else { return }
        let alert = NSAlert()
        alert.messageText     = "Uninstall BepisLoader?"
        alert.informativeText = "This will remove BepInEx and all plugins from \(game.name)."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try BepInExInstaller.shared.uninstall(from: game)
            showAlert("BepisLoader uninstalled.", style: .informational)
            var updatedGame = game
            updatedGame.bepInExStatus = BottleScanner.shared.detectBepInExStatus(gameDir: game.gameDirectory)
            self.game = updatedGame
            self.onGameUpdated?(updatedGame)
        } catch {
            showAlert("Uninstall failed:\n\(error.localizedDescription)", style: .critical)
        }
    }


    @objc private func addModClicked() {
        guard let game = game else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.message = "Select mod .dll file(s)"
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls {
                do {
                    try ModManager.shared.install(mod: url, into: game)
                } catch {
                    self?.showAlert("Failed to install \(url.lastPathComponent):\n\(error.localizedDescription)", style: .warning)
                }
            }
            self?.mods = ModManager.shared.listMods(for: game)
            self?.modTableView.reloadData()
        }
    }

    // ── Process watcher callbacks ──────────────

    func onGameRunning(_ running: ProcessWatcher.RunningGame) {
        appendLog("[Process watcher] Detected: \(running.execName) (PID \(running.pid))\n")
    }

    func onGameExited(_ running: ProcessWatcher.RunningGame) {
        appendLog("[Process watcher] Exited: \(running.execName)\n")
    }

    // ── Log helpers ────────────────────────────

    private func appendLog(_ text: String) {
        let storage = logTextView.textStorage!
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(white: 0.85, alpha: 1)
        ]
        storage.append(NSAttributedString(string: text, attributes: attrs))
        logTextView.scrollToEndOfDocument(nil)
    }

    private func clearLog() {
        logTextView.textStorage?.setAttributedString(NSAttributedString(string: ""))
    }

    // ── Alert helper ───────────────────────────

    private func showAlert(_ msg: String, style: NSAlert.Style) {
        let a = NSAlert()
        a.messageText = msg
        a.alertStyle  = style
        a.runModal()
    }
}

// ─────────────────────────────────────────────
//  Mod table data source / delegate
// ─────────────────────────────────────────────

extension GameDetailViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { mods.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let mod = mods[row]
        let cell = NSTableCellView()

        switch tableColumn?.identifier.rawValue {
        case "name":
            let label = NSTextField(labelWithString: mod.name)
            label.font = NSFont.systemFont(ofSize: 12)
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            ])

        case "ver":
            let label = NSTextField(labelWithString: mod.version)
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            ])

        case "enabled":
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(modToggled(_:)))
            checkbox.state = mod.isEnabled ? .on : .off
            checkbox.tag   = row
            checkbox.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(checkbox)
            NSLayoutConstraint.activate([
                checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                checkbox.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            ])

        default: break
        }
        return cell
    }

    @objc private func modToggled(_ sender: NSButton) {
        guard let game = game, sender.tag < mods.count else { return }
        var mod = mods[sender.tag]
        mod.isEnabled = sender.state == .on
        mods[sender.tag] = mod
        do {
            try ModManager.shared.setEnabled(mod.isEnabled, mod: mod, in: game)
        } catch {
            showAlert("Could not toggle mod:\n\(error.localizedDescription)", style: .warning)
        }
    }

    @objc private func toggleEngine() {
        guard var game = game else { return }
        switch game.unityType {
        case .mono:    game.unityType = .il2cpp
        case .il2cpp:  game.unityType = .mono
        case .unknown: game.unityType = .il2cpp
        }
        self.game = game
        onGameUpdated?(game)
    }

    @objc private func viewLogClicked() {
        guard let game = game else { return }
        let logURL = game.bepInExRoot.appendingPathComponent("LogOutput.log")
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.open(logURL)
        } else {
            let alert = NSAlert()
            alert.messageText = "Log Not Found"
            alert.informativeText = "The BepisLoader log hasn't been created yet. This usually means BepInEx failed to initialize at the very start of the game launch."
            alert.runModal()
        }
    }

    @discardableResult
    private func shell(_ args: String...) -> (exitCode: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: args[0])
        proc.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}
