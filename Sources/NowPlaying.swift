import AppKit
import CryptoKit
import Network

struct LyricLine: Equatable {
    let time: Double         // seconds into the track
    let text: String
}

@MainActor
final class NowPlaying: ObservableObject {
    @Published var title = "Nothing playing"
    @Published var artist = ""
    @Published var album = ""
    @Published var isPlaying = false
    @Published var artwork: NSImage?
    @Published private(set) var duration: Double = 0          // seconds
    @Published private(set) var lyrics: [LyricLine] = []
    /// Goes up by one each time a new track starts, so the notch can announce it
    @Published private(set) var trackChangeCount = 0
    /// True when macOS hasn't given this app permission to control Spotify (Automation)
    @Published private(set) var needsAutomation = false

    private var lastTrack = ""
    private var artCache: [String: NSImage] = [:]
    private var fullArtists: [String: String] = [:]      // track → "Artist, Featured, …"
    private var pathMonitor: NWPathMonitor?
    private var wasOnline = true
    private var lyricsCache: [String: [LyricLine]] = [:]
    private var observers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private static let spotifyID = "com.spotify.client"

    // Playback position: where Spotify last said it was, and when
    private var anchorPosition: Double = 0
    private var anchorDate = Date()
    /// Right after a seek, Spotify briefly still reports the old position; trust the seek until then
    private var holdPositionUntil = Date.distantPast

    var spotifyRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.spotifyID).isEmpty
    }

    init() {
        watchConnection()
        DiskCache.prune("Artwork")
        DiskCache.prune("Lyrics")
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(changed(_:)),
            name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"), object: nil)

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.spotify.client" else { return }
            Task { @MainActor in self?.reset() }
        })

        // Re-check the position now and then, so lyrics stay in sync after seeking
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPosition() }
        }

        // Spotify only announces changes, so ask it once for whatever is already playing,
        // and make sure macOS has asked about controlling Spotify
        Task { @MainActor [weak self] in
            self?.checkAutomation(ask: true)
            self?.queryCurrent()
        }
    }

    // MARK: Position

    /// Where playback is at a given moment, counting forward from Spotify's last report
    func position(at date: Date) -> Double {
        let p = anchorPosition + (isPlaying ? date.timeIntervalSince(anchorDate) : 0)
        return duration > 0 ? min(max(0, p), duration) : max(0, p)
    }

    /// The lyric line being sung at a given moment, or nil before the first line
    func lineIndex(at date: Date) -> Int? {
        guard !lyrics.isEmpty else { return nil }
        let t = position(at: date) + 0.2           // show each line a fraction early
        var lo = 0, hi = lyrics.count - 1, found: Int? = nil
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lyrics[mid].time <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }

    private func setAnchor(_ position: Double) {
        anchorPosition = position
        anchorDate = Date()
    }

    // MARK: Updates from Spotify

    @objc private func changed(_ note: Notification) {
        guard let i = note.userInfo else { return }
        let state = i["Player State"] as? String ?? ""
        if state == "Stopped" { reset(); return }
        let durationMs = (i["Duration"] as? NSNumber)?.doubleValue ?? 0
        apply(title: i["Name"] as? String ?? "",
              artist: i["Artist"] as? String ?? "",
              album: i["Album"] as? String ?? "",
              trackID: i["Track ID"] as? String ?? "",
              playing: state == "Playing",
              position: (i["Playback Position"] as? NSNumber)?.doubleValue,
              duration: durationMs > 0 ? durationMs / 1000 : nil)
    }

    private func apply(title: String, artist: String, album: String, trackID: String, playing: Bool,
                       position: Double?, duration: Double?) {
        // Freeze the position at the moment playback state changes
        let now = Date()
        if playing != isPlaying { setAnchor(self.position(at: now)) }

        self.title = title.isEmpty ? "Nothing playing" : title
        // Spotify only reports the first artist; the full list is filled in once found
        self.artist = fullArtists[trackID] ?? artist
        self.album = album
        isPlaying = playing
        if let d = duration { self.duration = d }
        // Ignore a stale position Spotify sends just after a seek (unless the song changed)
        if let p = position, Date() >= holdPositionUntil || trackID != lastTrack { setAnchor(p) }

        if trackID != lastTrack {
            lastTrack = trackID
            if !trackID.isEmpty { trackChangeCount += 1 }
            artwork = nil                       // never leave the previous track's cover up
            lyrics = []
            if position == nil { setAnchor(0) }
            if !trackID.isEmpty {
                Task { await loadArtwork(trackID, artist: artist, album: album) }
                Task { await loadArtists(trackID, first: artist) }
                Task { await loadLyrics(key: trackID, title: title, artist: artist, album: album,
                                        duration: self.duration) }
            }
        }
    }

    private func reset() {
        title = "Nothing playing"
        artist = ""
        album = ""
        isPlaying = false
        artwork = nil
        lyrics = []
        duration = 0
        lastTrack = ""
        setAnchor(0)
    }

    /// Reads the current track over AppleScript. Only runs if Spotify is already open,
    /// because "tell application" would otherwise launch it.
    private func queryCurrent() {
        guard spotifyRunning else { return }
        let source = """
        tell application "Spotify"
            if player state is stopped then return {}
            set t to current track
            return {name of t, artist of t, album of t, id of t, (player state as string), player position, duration of t}
        end tell
        """
        guard let list = run(source), list.numberOfItems >= 7 else { return }
        let text = { (i: Int) in list.atIndex(i)?.stringValue ?? "" }
        apply(title: text(1), artist: text(2), album: text(3), trackID: text(4),
              playing: text(5) == "playing",
              position: list.atIndex(6)?.doubleValue,
              duration: (list.atIndex(7)?.doubleValue ?? 0) / 1000)
    }

    private func pollPosition() {
        guard isPlaying, spotifyRunning, Date() >= holdPositionUntil,
              let result = run("tell application \"Spotify\" to return player position") else { return }
        let actual = result.doubleValue
        // Only correct real drift or a seek, so the lyrics don't jitter
        if abs(actual - position(at: Date())) > 0.35 { setAnchor(actual) }
    }

    private var scripts: [String: NSAppleScript] = [:]

    @discardableResult
    private func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        // Compiling a script costs far more than running it, so each one is compiled once and kept
        let script: NSAppleScript?
        if let cached = scripts[source] {
            script = cached
        } else {
            script = NSAppleScript(source: source)
            script?.compileAndReturnError(nil)
            if let s = script, !source.contains("position to") { scripts[source] = s }   // seeks differ each time
        }
        let result = script?.executeAndReturnError(&error)
        if let e = error {
            // -1743: the user hasn't allowed this app to control Spotify
            if (e[NSAppleScript.errorNumber] as? Int) == -1743 { needsAutomation = true }
            return nil
        }
        if needsAutomation { needsAutomation = false }
        return result
    }

    /// Asks macOS whether this app may control Spotify, showing the permission prompt if it
    /// hasn't been answered yet. Runs off the main thread because the prompt waits for the user.
    func checkAutomation(ask: Bool) {
        guard spotifyRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.spotify.client")
            let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard),
                                                               AEEventID(typeWildCard), ask)
            let blocked = status == -1743 || (status == -1744 && !ask)   // 0 means allowed
            Task { @MainActor in self.needsAutomation = blocked }
        }
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Playback controls

    // Each control tries Spotify directly first; if that isn't allowed, it falls back to
    // macOS's own media controls (the same ones Control Center uses), which need no permission.
    func playPause() { send("playpause", fallback: .togglePlayPause) }
    func nextTrack() { send("next track", fallback: .next) }
    func previousTrack() { send("previous track", fallback: .previous) }

    func seek(to seconds: Double) {
        guard duration > 0 else { return }
        let s = min(max(0, seconds), duration)
        guard spotifyRunning else { return }
        // Spotify directly if allowed; otherwise through macOS's own media controls
        if run("tell application \"Spotify\" to set player position to \(String(format: "%.2f", s))") == nil {
            MediaRemote.setPosition(s)
        }
        setAnchor(s)
        holdPositionUntil = Date().addingTimeInterval(2.5)
    }

    private func send(_ command: String, fallback: MediaRemote.Command?) {
        guard spotifyRunning else { return }
        if run("tell application \"Spotify\" to \(command)") == nil, let f = fallback {
            MediaRemote.send(f)
        }
        // Spotify announces track changes itself; this catches position and anything it missed
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self.queryCurrent()
        }
    }

    // MARK: Artwork

    /// Looks for the cover in memory, then on disk (songs played before, or any song from an album
    /// played before), then online. Downloaded covers are saved, so they work offline next time.
    private func loadArtwork(_ uri: String, artist: String, album: String) async {
        if let cached = artCache[uri] { artwork = cached; return }
        let albumKey = album.isEmpty ? nil : "album:\(artist.lowercased())|\(album.lowercased())"

        if let data = DiskCache.read("Artwork", uri) ?? albumKey.flatMap({ DiskCache.read("Artwork", $0) }),
           let image = NSImage(data: data) {
            show(image, for: uri)
            return
        }

        guard let data = await downloadArtwork(uri), let image = NSImage(data: data) else { return }
        DiskCache.write(data, "Artwork", uri)
        if let key = albumKey { DiskCache.write(data, "Artwork", key) }
        show(image, for: uri)
    }

    private func show(_ image: NSImage, for uri: String) {
        if artCache.count > 40 { artCache.removeAll() }
        artCache[uri] = image
        guard uri == lastTrack else { return }   // a newer track started while this one was loading
        artwork = image
    }

    /// Spotify's own link to the cover (640 px) when it's the current track; otherwise Spotify's
    /// public page info (300 px)
    private func downloadArtwork(_ uri: String) async -> Data? {
        if uri == lastTrack,
           let link = run("tell application \"Spotify\" to return artwork url of current track")?.stringValue,
           let url = URL(string: link), url.scheme == "https",
           let data = await fetchData(url), NSImage(data: data) != nil {
            return data
        }
        let parts = uri.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify",
              parts[1] == "track" || parts[1] == "episode",
              let api = URL(string: "https://open.spotify.com/oembed?url=https://open.spotify.com/\(parts[1])/\(parts[2])"),
              let info = await fetchData(api),
              let json = try? JSONSerialization.jsonObject(with: info) as? [String: Any],
              let thumb = json["thumbnail_url"] as? String,
              let thumbURL = URL(string: thumb) else { return nil }
        return await fetchData(thumbURL)
    }

    private func fetchData(_ url: URL) async -> Data? {
        let request = URLRequest(url: url, timeoutInterval: 8)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    // MARK: Every artist on the song

    /// Spotify's song page is titled "Song - song and lyrics by Artist, Featured | Spotify".
    /// Read once per song, remembered on disk, so it also works offline next time.
    private func loadArtists(_ uri: String, first: String) async {
        if let known = fullArtists[uri] { if uri == lastTrack { artist = known }; return }
        if let saved = DiskCache.read("Artists", uri), let text = String(data: saved, encoding: .utf8) {
            remember(text, for: uri, first: first)
            return
        }
        let parts = uri.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify", parts[1] == "track",
              let url = URL(string: "https://open.spotify.com/track/\(parts[2])") else { return }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data.prefix(200_000), encoding: .utf8),
              let open = html.range(of: "<title>"),
              let close = html.range(of: "</title>", range: open.upperBound..<html.endIndex) else { return }
        let title = Self.unescape(String(html[open.upperBound..<close.lowerBound]))
        guard let by = title.range(of: " by ", options: .backwards),
              let end = title.range(of: " | Spotify", range: by.upperBound..<title.endIndex) else { return }
        let names = String(title[by.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard !names.isEmpty, names.count < 300 else { return }
        DiskCache.write(Data(names.utf8), "Artists", uri)
        remember(names, for: uri, first: first)
    }

    private func remember(_ names: String, for uri: String, first: String) {
        // Only trust it if it agrees with Spotify's own first artist
        guard names.localizedCaseInsensitiveContains(first) || first.isEmpty else { return }
        if fullArtists.count > 200 { fullArtists.removeAll() }
        fullArtists[uri] = names
        if uri == lastTrack, artist != names { artist = names }
    }

    private static func unescape(_ s: String) -> String {
        var t = s
        for (k, v) in ["&amp;": "&", "&#x27;": "'", "&#39;": "'", "&quot;": "\"", "&lt;": "<", "&gt;": ">"] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        return t
    }

    // MARK: Coming back online

    /// When the connection returns, fetch whatever the current song is missing
    private func watchConnection() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.connectionChanged(online) }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        pathMonitor = monitor
    }

    private func connectionChanged(_ online: Bool) {
        defer { wasOnline = online }
        guard online, !wasOnline, !lastTrack.isEmpty else { return }
        let track = lastTrack
        if artwork == nil {
            Task { await loadArtwork(track, artist: artist, album: album) }
        }
        if lyrics.isEmpty {
            lyricsCache[track] = nil
            Task { await loadLyrics(key: track, title: title, artist: artist, album: album, duration: duration) }
        }
    }

    // MARK: Lyrics (LRCLIB, a free database of time-stamped lyrics)

    private func loadLyrics(key: String, title: String, artist: String, album: String, duration: Double) async {
        if let cached = lyricsCache[key] {
            if key == lastTrack { lyrics = cached }
            return
        }
        guard !title.isEmpty, !artist.isEmpty, key.hasPrefix("spotify:track:") else { return }

        // Saved from an earlier play: works offline. An empty file means "no lyrics found"; that's
        // trusted for 3 days, then asked again, since songs get added to LRCLIB all the time
        if let saved = DiskCache.read("Lyrics", key), let text = String(data: saved, encoding: .utf8) {
            let missAge = Date().timeIntervalSince(DiskCache.modified("Lyrics", key) ?? .distantPast)
            if !text.isEmpty || missAge < 3 * 86400 {
                let parsed = Self.parseLRC(text)
                lyricsCache[key] = parsed
                if key == lastTrack { lyrics = parsed }
                return
            }
        }

        let result = await Self.findLyrics(title: title, artist: artist, album: album, duration: duration)

        // Offline or the server had trouble: remember nothing, so it's tried again later
        guard result.answered else { return }
        let found = result.lrc

        let parsed = found.map(Self.parseLRC) ?? []
        DiskCache.write(Data((found ?? "").utf8), "Lyrics", key)
        if lyricsCache.count > 60 { lyricsCache.removeAll() }
        lyricsCache[key] = parsed
        if key == lastTrack { lyrics = parsed }
    }

    /// Tries several ways to find a song's synced lyrics on LRCLIB, from most to least exact.
    /// `answered` is true only if every request got a proper answer (found or genuinely not found),
    /// so a slow or failing server never gets remembered as "this song has no lyrics".
    static func findLyrics(title: String, artist: String, album: String,
                           duration: Double) async -> (lrc: String?, answered: Bool) {
        var answered = true
        let clean = cleanTitle(title)
        let seconds = duration > 0 ? String(Int(duration.rounded())) : nil

        func get(_ t: String, album: String?) async -> String? {
            var c = URLComponents(string: "https://lrclib.net/api/get")!
            c.queryItems = [URLQueryItem(name: "track_name", value: t),
                            URLQueryItem(name: "artist_name", value: artist)]
            if let a = album, !a.isEmpty { c.queryItems?.append(URLQueryItem(name: "album_name", value: a)) }
            if let s = seconds { c.queryItems?.append(URLQueryItem(name: "duration", value: s)) }
            let r = await fetchJSON(c.url)
            if !r.answered { answered = false }
            return (r.json as? [String: Any])?["syncedLyrics"] as? String
        }

        func search(_ items: [URLQueryItem]) async -> String? {
            var c = URLComponents(string: "https://lrclib.net/api/search")!
            c.queryItems = items
            let r = await fetchJSON(c.url)
            if !r.answered { answered = false }
            return best(r.json as? [[String: Any]] ?? [], duration: duration)
        }

        // 1. Exact matches (title, artist, length; with and without the album)
        if let l = await get(title, album: album) { return (l, true) }
        if let l = await get(title, album: nil) { return (l, true) }
        // 2. Search by title and artist, then with "(feat. …)" / " - Remastered" removed
        if let l = await search([URLQueryItem(name: "track_name", value: title),
                                 URLQueryItem(name: "artist_name", value: artist)]) { return (l, true) }
        if clean != title, let l = await search([URLQueryItem(name: "track_name", value: clean),
                                                 URLQueryItem(name: "artist_name", value: artist)]) { return (l, true) }
        // 3. A free-text search, for songs filed under a slightly different artist name
        if let l = await search([URLQueryItem(name: "q", value: "\(clean) \(artist)")]) { return (l, true) }
        return (nil, answered)
    }

    /// The synced result closest in length to the song (within 8 s); any synced one if the length is unknown
    private static func best(_ results: [[String: Any]], duration: Double) -> String? {
        let synced = results.compactMap { item -> (String, Double?)? in
            guard let lrc = item["syncedLyrics"] as? String, !lrc.isEmpty else { return nil }
            return (lrc, (item["duration"] as? NSNumber)?.doubleValue)
        }
        guard duration > 0 else { return synced.first?.0 }
        return synced
            .compactMap { lrc, d -> (String, Double)? in
                guard let d = d else { return nil }
                let gap = abs(d - duration)
                return gap <= 8 ? (lrc, gap) : nil
            }
            .min { $0.1 < $1.1 }?.0
    }

    /// "Song (feat. Someone) - 2011 Remaster" → "Song"
    static func cleanTitle(_ title: String) -> String {
        var t = title
        for pattern in [#"\s*[\(\[](feat\.?|ft\.?|with|from)\s[^\)\]]*[\)\]]"#,
                        #"\s+-\s+.*$"#] {
            t = t.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        t = t.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? title : t
    }

    /// `answered` is false when the server couldn't be reached or had a problem (offline, timeout,
    /// rate limit, server error), as opposed to a clear "found" or "not found"
    private static func fetchJSON(_ url: URL?) async -> (json: Any?, answered: Bool) {
        guard let url = url else { return (nil, false) }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Murmur/1.2 (+https://github.com/rieldevdex/Murmur)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return (nil, false) }
        if status == 404 { return (nil, true) }
        guard status == 200 else { return (nil, false) }
        return (try? JSONSerialization.jsonObject(with: data), true)
    }

    /// Parses "[01:23.45] some words" lines; a line can carry several time tags
    static func parseLRC(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for raw in text.components(separatedBy: .newlines) {
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                let parts = tag.split(separator: ":")
                if parts.count == 2, let m = Double(parts[0]),
                   let s = Double(parts[1].replacingOccurrences(of: ",", with: ".")) {
                    times.append(m * 60 + s)
                }
                rest = rest[rest.index(after: close)...]
            }
            let words = rest.trimmingCharacters(in: .whitespaces)
            for t in times { lines.append(LyricLine(time: t, text: words)) }
        }
        return lines.sorted { $0.time < $1.time }
    }
}

/// macOS's system-wide media controls. A private framework, so it's loaded carefully and
/// simply does nothing if a future macOS removes it.
enum MediaRemote {
    enum Command: Int32 {
        case togglePlayPause = 2
        case next = 4
        case previous = 5
    }

    private typealias SendCommand = @convention(c) (Int32, CFDictionary?) -> Bool

    private static let sendCommand: SendCommand? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
              let sym = dlsym(handle, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(sym, to: SendCommand.self)
    }()

    @discardableResult
    static func send(_ command: Command) -> Bool {
        sendCommand?(command.rawValue, nil) ?? false
    }

    private typealias SetElapsed = @convention(c) (Double) -> Void

    private static let setElapsed: SetElapsed? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
              let sym = dlsym(handle, "MRMediaRemoteSetElapsedTime") else { return nil }
        return unsafeBitCast(sym, to: SetElapsed.self)
    }()

    /// Jumps the current song to a position, in seconds
    static func setPosition(_ seconds: Double) {
        setElapsed?(seconds)
    }
}

// MARK: - Saved covers and lyrics
// Kept in ~/Library/Caches/<app>/, so macOS may clear them if the disk gets full. Each file is
// named by a hash of its key. The oldest are removed once there are more than 4000 of a kind.

enum DiskCache {
    static let root: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Murmur", isDirectory: true)
    }()

    static func folder(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func file(_ folderName: String, _ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder(folderName).appendingPathComponent(hash)
    }

    static func read(_ folderName: String, _ key: String) -> Data? {
        try? Data(contentsOf: file(folderName, key))
    }

    /// When an entry was saved
    static func modified(_ folderName: String, _ key: String) -> Date? {
        (try? file(folderName, key).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    static func write(_ data: Data, _ folderName: String, _ key: String) {
        let url = file(folderName, key)
        DispatchQueue.global(qos: .utility).async {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Keeps each folder to a sensible size (covers are about 50–100 KB each)
    static func prune(_ folderName: String, keep: Int = 4000) {
        let dir = folder(folderName)
        DispatchQueue.global(qos: .background).async {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]),
                  files.count > keep else { return }
            let dated = files.map { url -> (URL, Date) in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return (url, date ?? .distantPast)
            }
            for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - keep) {
                try? fm.removeItem(at: url)
            }
        }
    }
}
