import AppKit
import Foundation

// ─────────────────────────────────────────────
//  MainViewController
//  Three-pane layout:
//    Left   — Bottles list
//    Middle — Games list for selected bottle
//    Right  — Detail / actions for selected game
// ─────────────────────────────────────────────

class MainViewController: NSSplitViewController {

    private var bottleListVC: BottleListViewController!
    private var gameListVC:   GameListViewController!
    private var detailVC:     GameDetailViewController!

    override func viewDidLoad() {
        super.viewDidLoad()

        bottleListVC = BottleListViewController()
        gameListVC   = GameListViewController()
        detailVC     = GameDetailViewController()

        // Wire selection callbacks
        bottleListVC.onBottleSelected = { [weak self] bottle in
            self?.gameListVC.bottle = bottle
        }
        gameListVC.onGameSelected = { [weak self] game in
            self?.detailVC.game = game
        }
        detailVC.onGameUpdated = { [weak self] game in
            if let index = self?.gameListVC.allGames.firstIndex(where: { $0.id == game.id }) {
                self?.gameListVC.allGames[index] = game
                PersistenceManager.shared.save(games: self?.gameListVC.allGames ?? [])
            }
        }

        let leftItem   = NSSplitViewItem(viewController: bottleListVC)
        leftItem.minimumThickness  = 180
        leftItem.maximumThickness  = 260
        leftItem.preferredThicknessFraction = 0.22

        let middleItem = NSSplitViewItem(viewController: gameListVC)
        middleItem.minimumThickness = 200

        let rightItem  = NSSplitViewItem(viewController: detailVC)
        rightItem.minimumThickness  = 320

        addSplitViewItem(leftItem)
        addSplitViewItem(middleItem)
        addSplitViewItem(rightItem)

        splitView.isVertical = true
        splitView.dividerStyle = .thin

        // Start process watching
        ProcessWatcher.shared.onGameLaunched = { [weak self] running in
            self?.detailVC.onGameRunning(running)
        }
        ProcessWatcher.shared.onGameExited = { [weak self] running in
            self?.detailVC.onGameExited(running)
        }
        ProcessWatcher.shared.startWatching()

        // Initial scan
        DispatchQueue.global(qos: .userInitiated).async {
            let saved = PersistenceManager.shared.load()
            let scannedBottles = BottleScanner.shared.scanAll()
            
            DispatchQueue.main.async { [weak self] in
                self?.bottleListVC.bottles = scannedBottles
                self?.gameListVC.allGames = saved
                // Re-scan current bottles to find new games too
                for bottle in scannedBottles {
                    let games = BottleScanner.shared.findGames(in: bottle)
                    self?.gameListVC.addUniqueGames(games)
                }
                PersistenceManager.shared.save(games: self?.gameListVC.allGames ?? [])
            }
        }
    }
}

// ─────────────────────────────────────────────
//  BottleListViewController
// ─────────────────────────────────────────────

class BottleListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    var bottles: [Bottle] = [] { didSet { tableView.reloadData() } }
    var onBottleSelected: ((Bottle?) -> Void)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let scanButton = NSButton()
    private let header = NSTextField(labelWithString: "BOTTLES")

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        // Header
        header.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        header.textColor = NSColor.secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        // Table
        let col = NSTableColumn(identifier: .init("bottle"))
        col.title = "Bottle"
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = 46
        tableView.dataSource = self
        tableView.delegate   = self
        tableView.style = .sourceList
        tableView.usesAlternatingRowBackgroundColors = false

        scrollView.documentView        = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType          = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        // Scan button
        scanButton.title  = "↺  Scan"
        scanButton.bezelStyle = .rounded
        scanButton.font   = NSFont.systemFont(ofSize: 12)
        scanButton.target = self
        scanButton.action = #selector(scanClicked)
        scanButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scanButton)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: scanButton.topAnchor, constant: -8),

            scanButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scanButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scanButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])
    }

    @objc private func scanClicked() {
        scanButton.isEnabled = false
        scanButton.title = "Scanning…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = BottleScanner.shared.scanAll()
            DispatchQueue.main.async { [weak self] in
                self?.bottles = result
                self?.scanButton.isEnabled = true
                self?.scanButton.title = "↺  Scan"
            }
        }
    }

    // Table data
    func numberOfRows(in tableView: NSTableView) -> Int { bottles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let bottle = bottles[row]
        let cell = NSTableCellView()
        cell.textField = makeLabel(bottle.name, size: 13, weight: .medium)
        let sub        = makeLabel(bottle.layer.rawValue, size: 11, color: .secondaryLabelColor)
        cell.addSubview(cell.textField!)
        cell.addSubview(sub)
        NSLayoutConstraint.activate([
            cell.textField!.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
            cell.textField!.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            cell.textField!.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            sub.topAnchor.constraint(equalTo: cell.textField!.bottomAnchor, constant: 2),
            sub.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        onBottleSelected?(row >= 0 ? bottles[row] : nil)
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                            color: NSColor = .labelColor) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = NSFont.systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }
}

// ─────────────────────────────────────────────
//  GameListViewController
// ─────────────────────────────────────────────

class GameListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    var bottle: Bottle? { didSet { reload() } }
    var allGames: [GameInstall] = [] { didSet { reload() } }
    var games: [GameInstall] = [] { didSet { tableView.reloadData() } }
    var onGameSelected: ((GameInstall?) -> Void)?

    func addUniqueGames(_ newGames: [GameInstall]) {
        for g in newGames {
            if !allGames.contains(where: { $0.executablePath == g.executablePath }) {
                allGames.append(g)
            }
        }
    }

    private let tableView  = NSTableView()
    private let scrollView = NSScrollView()
    private let header     = NSTextField(labelWithString: "GAMES")
    private let emptyLabel = NSTextField(labelWithString: "Select a bottle to see games")
    private let browseButton = NSPopUpButton(frame: .zero, pullsDown: true)

    override func loadView() {
        view = NSView()

        header.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        header.textColor = NSColor.secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        let col = NSTableColumn(identifier: .init("game"))
        col.title = "Game"
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.dataSource = self
        tableView.delegate   = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        browseButton.bezelStyle = .rounded
        browseButton.font = NSFont.systemFont(ofSize: 12)
        browseButton.translatesAutoresizingMaskIntoConstraints = false
        
        let menu = NSMenu()
        menu.addItem(withTitle: "+ Add Game…", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "From C: Drive (Default)", action: #selector(browseCDrive), keyEquivalent: "")
        menu.addItem(withTitle: "From Mac / External Drive", action: #selector(browseMacDrive), keyEquivalent: "")
        
        for item in menu.items { item.target = self }
        browseButton.menu = menu
        view.addSubview(browseButton)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: browseButton.topAnchor, constant: -8),

            browseButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            browseButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            browseButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])
    }

    private func reload() {
        guard let bottle = bottle else {
            games = []
            emptyLabel.isHidden = false
            return
        }
        
        let filtered = allGames.filter { $0.bottle.path == bottle.path }
        self.games = filtered
        self.emptyLabel.isHidden = !filtered.isEmpty
        self.emptyLabel.stringValue = filtered.isEmpty ? "No Unity games found in this bottle" : ""
    }

    @objc private func browseCDrive() {
        browseClicked(directoryURL: bottle?.driveCRoot)
    }
    
    @objc private func browseMacDrive() {
        browseClicked(directoryURL: URL(fileURLWithPath: "/Volumes"))
    }
    
    private func browseClicked(directoryURL: URL?) {
        guard let bottle = bottle else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.message = "Select the game's .exe"
        panel.directoryURL = directoryURL
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            var game = GameInstall(
                name:           url.deletingPathExtension().lastPathComponent,
                executablePath: url,
                bottle:         bottle
            )
            
            game.unityType = BottleScanner.shared.detectUnityType(for: game)
            
            self?.allGames.append(game)
            PersistenceManager.shared.save(games: self?.allGames ?? [])
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { games.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let game = games[row]
        let cell = NSTableCellView()

        let nameLabel = NSTextField(labelWithString: game.name)
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let statusLabel: NSTextField
        switch game.bepInExStatus {
        case .notInstalled:         statusLabel = makeStatus("BepInEx not installed", color: .systemOrange)
        case .installed(let v):     statusLabel = makeStatus("BepInEx \(v) ✓", color: .systemGreen)
        case .incompatible(let r):  statusLabel = makeStatus("⚠ \(r)", color: .systemRed)
        }

        cell.addSubview(nameLabel)
        cell.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: cell.topAnchor, constant: 7),
            nameLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            statusLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            statusLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
        ])
        return cell
    }

    private func makeStatus(_ text: String, color: NSColor) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = NSFont.systemFont(ofSize: 11)
        f.textColor = color
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        onGameSelected?(row >= 0 ? games[row] : nil)
    }
}
