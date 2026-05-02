import Foundation

class PersistenceManager {
    static let shared = PersistenceManager()
    
    private let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("BepInExMacClient")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("games.json")
    }()
    
    func save(games: [GameInstall]) {
        do {
            let data = try JSONEncoder().encode(games)
            try data.write(to: fileURL)
            print("[Persistence] Saved \(games.count) games.")
        } catch {
            print("[Persistence] Failed to save games: \(error)")
        }
    }
    
    func load() -> [GameInstall] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let games = try JSONDecoder().decode([GameInstall].self, from: data)
            print("[Persistence] Loaded \(games.count) games.")
            return games
        } catch {
            print("[Persistence] Failed to load games: \(error)")
            return []
        }
    }
}
