import Foundation

/// The app used to be called Visualiser (bundle ID com.visualiser.app). On the first launch as Murmur,
/// bring over its settings (including the measured volume curve) and its saved data, so nothing is lost.
/// Runs once; does nothing on a Mac that never had Visualiser.
enum Migration {
    private static let oldID = "com.visualiser.app"
    private static let doneKey = "migratedFromVisualiser"

    static func run() {
        moveFromVisualiser()
        clearLyricMisses()
    }

    private static func moveFromVisualiser() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: doneKey) else { return }
        defer { d.set(true, forKey: doneKey) }
        guard let newID = Bundle.main.bundleIdentifier, newID != oldID else { return }

        // Settings: copy anything the new app doesn't have yet
        if let old = d.persistentDomain(forName: oldID) {
            for (key, value) in old where d.object(forKey: key) == nil {
                d.set(value, forKey: key)
            }
        }

        // Hearing history, clipboard history and usage logs (Application Support); artwork, lyrics
        // and artist caches (Caches). Moved, not copied, so there's one copy of each.
        let fm = FileManager.default
        for dir in [FileManager.SearchPathDirectory.applicationSupportDirectory, .cachesDirectory] {
            guard let base = fm.urls(for: dir, in: .userDomainMask).first else { continue }
            let from = base.appendingPathComponent(oldID, isDirectory: true)
            let to = base.appendingPathComponent(newID, isDirectory: true)
            guard fm.fileExists(atPath: from.path) else { continue }
            if !fm.fileExists(atPath: to.path) {
                try? fm.moveItem(at: from, to: to)
            } else if let items = try? fm.contentsOfDirectory(atPath: from.path) {
                for name in items where !fm.fileExists(atPath: to.appendingPathComponent(name).path) {
                    try? fm.moveItem(at: from.appendingPathComponent(name), to: to.appendingPathComponent(name))
                }
            }
        }
    }

    /// Earlier versions remembered "no lyrics" forever, even after a server hiccup. Forget those
    /// once, so every song gets looked up again with the better search.
    private static func clearLyricMisses() {
        let d = UserDefaults.standard
        let key = "lyricMissesCleared1"
        guard !d.bool(forKey: key) else { return }
        d.set(true, forKey: key)
        let fm = FileManager.default
        let dir = DiskCache.folder("Lyrics")
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        for url in files where ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 1) == 0 {
            try? fm.removeItem(at: url)
        }
    }
}
