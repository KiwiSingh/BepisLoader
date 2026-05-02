import Foundation

// ─────────────────────────────────────────────
//  ProcessWatcher
//  Polls the macOS process list to detect when
//  a Windows game starts or stops inside Wine.
// ─────────────────────────────────────────────

class ProcessWatcher {

    static let shared = ProcessWatcher()
    private init() {}

    // ── Callbacks ──────────────────────────────
    var onGameLaunched: ((RunningGame) -> Void)?
    var onGameExited:   ((RunningGame) -> Void)?

    // ── State ──────────────────────────────────
    private var timer: DispatchSourceTimer?
    private var knownGames: [pid_t: RunningGame] = [:]
    private let queue = DispatchQueue(label: "bepinex.processwatcher", qos: .utility)

    struct RunningGame {
        let pid:          pid_t
        let execName:     String
        let commandLine:  String
        let bottle:       Bottle?
        let startTime:    Date
    }

    // ── Start / Stop ───────────────────────────

    func startWatching(interval: TimeInterval = 2.0) {
        stopWatching()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stopWatching() {
        timer?.cancel()
        timer = nil
    }

    // ── Polling ────────────────────────────────

    private func poll() {
        let current = scanWineProcesses()

        let currentPIDs = Set(current.map(\.pid))
        let knownPIDs   = Set(knownGames.keys)

        // New processes
        for game in current where !knownPIDs.contains(game.pid) {
            knownGames[game.pid] = game
            DispatchQueue.main.async { self.onGameLaunched?(game) }
        }

        // Exited processes
        for pid in knownPIDs where !currentPIDs.contains(pid) {
            if let game = knownGames.removeValue(forKey: pid) {
                DispatchQueue.main.async { self.onGameExited?(game) }
            }
        }
    }

    // ── Process scan ──────────────────────────

    /// Returns all running Wine processes that look like game executables
    /// (i.e., not wineserver, explorer.exe, services.exe, etc.)
    private func scanWineProcesses() -> [RunningGame] {
        var processList: [RunningGame] = []

        // Use `ps` to get all process info – PIDs, command
        let result = runCommand("/bin/ps", "-axo", "pid,comm,command")
        let lines = result.split(separator: "\n", omittingEmptySubsequences: true)

        let systemExes: Set<String> = [
            "wineserver", "winedevice.exe", "explorer.exe",
            "services.exe", "svchost.exe", "rpcss.exe",
            "plugplay.exe", "tabtip.exe", "conhost.exe",
        ]

        for line in lines.dropFirst() {  // drop header
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2,
                  let pid = pid_t(parts[0]) else { continue }

            let comm    = String(parts[1])
            let cmdLine = parts.count > 2 ? String(parts[2]) : comm

            // Must be a wine64 or wine process carrying a .exe
            guard (comm.contains("wine64") || comm.contains("wine")) else { continue }

            // The last component of the command line is the Windows exe
            let tokens = cmdLine.split(separator: " ")
            guard let exeToken = tokens.last,
                  exeToken.lowercased().hasSuffix(".exe") else { continue }

            let exeName = String(exeToken).split(separator: "\\").last.map(String.init)
                       ?? String(exeToken).split(separator: "/").last.map(String.init)
                       ?? String(exeToken)

            guard !systemExes.contains(exeName.lowercased()) else { continue }

            // Try to match to a known bottle via WINEPREFIX in the environment
            let bottle = bottleForProcess(pid: pid)

            processList.append(RunningGame(
                pid:         pid,
                execName:    exeName,
                commandLine: cmdLine,
                bottle:      bottle,
                startTime:   Date()
            ))
        }
        return processList
    }

    private func bottleForProcess(pid: pid_t) -> Bottle? {
        // Read the process environment to find WINEPREFIX
        // Only works if we have access — on macOS this is unreliable without entitlements
        // but we try a best-effort approach via `ps e`
        let envOutput = runCommand("/bin/ps", "-p", "\(pid)", "-Eo", "command")
        if let prefixRange = envOutput.range(of: "WINEPREFIX=") {
            let start = envOutput.index(prefixRange.upperBound, offsetBy: 0)
            let rest = String(envOutput[start...])
            let prefixPath = rest.split(separator: " ").first.map(String.init) ?? ""
            if !prefixPath.isEmpty {
                return Bottle(
                    name: URL(fileURLWithPath: prefixPath).lastPathComponent,
                    path: URL(fileURLWithPath: prefixPath),
                    layer: .wine
                )
            }
        }
        return nil
    }

    private func runCommand(_ args: String...) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: args[0])
        proc.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    // ── Current running games ──────────────────

    var runningGames: [RunningGame] {
        Array(knownGames.values)
    }
}
