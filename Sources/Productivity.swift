import SwiftUI
import AppKit
import CoreServices
import IOKit.ps

// MARK: - Shared flags for the island's size
// The island's geometry is worked out outside SwiftUI, so the stores below also keep these
// simple flags up to date.

enum IslandExtras {
    static var timerActive = false
    static var timerLong = false        // an hour or more left: the time beside the notch needs more room
    static var timerPresetRows = 2      // rows of preset buttons in the Timer tab
    static var definitionReady = false
}

// MARK: - Timer

struct TimerPhase: Identifiable, Equatable, Codable {
    var id = UUID()
    var name: String
    var seconds: Double
    var isBreak = false
}

struct TimerPreset: Identifiable, Equatable, Codable {
    var id = UUID().uuidString
    var title: String
    var phases: [TimerPhase]
    var repeats = false

    /// "1 min Prepare · 2 min Speak", or "20 minutes" for a single part
    var detail: String {
        if phases.count == 1, let only = phases.first { return Self.minutes(only.seconds, long: true) }
        let parts = phases.map { "\(Self.minutes($0.seconds, long: false)) \($0.name.lowercased())" }
        return parts.joined(separator: " · ")
    }

    private static func minutes(_ seconds: Double, long: Bool) -> String {
        let m = Int((seconds / 60).rounded())
        return long ? "\(m) minute\(m == 1 ? "" : "s")" : "\(m) min"
    }

    static let defaults: [TimerPreset] = [
        TimerPreset(id: "speaking", title: "Speaking Part 2",
                    phases: [TimerPhase(name: "Prepare", seconds: 60), TimerPhase(name: "Speak", seconds: 120)]),
        TimerPreset(id: "task1", title: "Writing Task 1", phases: [TimerPhase(name: "Task 1", seconds: 20 * 60)]),
        TimerPreset(id: "task2", title: "Writing Task 2", phases: [TimerPhase(name: "Task 2", seconds: 40 * 60)]),
        TimerPreset(id: "pomodoro", title: "Pomodoro",
                    phases: [TimerPhase(name: "Focus", seconds: 25 * 60),
                             TimerPhase(name: "Break", seconds: 5 * 60, isBreak: true)],
                    repeats: true),
        TimerPreset(id: "listening", title: "Listening",
                    phases: [TimerPhase(name: "Listening", seconds: 30 * 60),
                             TimerPhase(name: "Transfer", seconds: 10 * 60)])
    ]

    static func custom(minutes: Int) -> TimerPreset {
        TimerPreset(id: "custom", title: "\(minutes) min timer",
                    phases: [TimerPhase(name: "Timer", seconds: Double(minutes) * 60)])
    }
}

@MainActor
final class IslandTimer: ObservableObject {
    static let shared = IslandTimer()

    @Published private(set) var preset: TimerPreset?
    @Published private(set) var phaseIndex = 0
    @Published private(set) var round = 1
    @Published private(set) var endDate: Date?             // set while running
    @Published private(set) var pausedRemaining: Double?   // set while paused
    @Published var customMinutes: Int = UserDefaults.standard.object(forKey: "timerCustom") as? Int ?? 10 {
        didSet { UserDefaults.standard.set(customMinutes, forKey: "timerCustom") }
    }

    /// Your presets (edited in Settings › Timer); up to eight show in the island
    @Published var presets: [TimerPreset] = IslandTimer.loadPresets() {
        didSet {
            if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: "timerPresets") }
            IslandExtras.timerPresetRows = IslandTimer.rows(for: presets.count)
        }
    }
    static let maxPresets = 8

    private static func loadPresets() -> [TimerPreset] {
        let saved = UserDefaults.standard.data(forKey: "timerPresets")
            .flatMap { try? JSONDecoder().decode([TimerPreset].self, from: $0) }
        let list = saved ?? TimerPreset.defaults
        IslandExtras.timerPresetRows = rows(for: list.count)
        return list
    }

    /// The presets plus the Custom button, three to a row
    static func rows(for count: Int) -> Int { (min(maxPresets, count) + 1 + 2) / 3 }

    func restoreDefaultPresets() { presets = TimerPreset.defaults }

    /// Shows a message in the island: symbol, title, subtitle
    var announce: ((String, String, String) -> Void)?
    weak var nowPlaying: NowPlaying?

    private var phaseTimer: Timer?
    private var pausedMusic = false

    var isActive: Bool { preset != nil }
    var isRunning: Bool { endDate != nil }
    var phase: TimerPhase? { preset.map { $0.phases[phaseIndex] } }
    var nextPhase: TimerPhase? {
        guard let p = preset else { return nil }
        if phaseIndex + 1 < p.phases.count { return p.phases[phaseIndex + 1] }
        return p.repeats ? p.phases[0] : nil
    }

    func remaining(at date: Date = Date()) -> Double {
        if let end = endDate { return max(0, end.timeIntervalSince(date)) }
        return pausedRemaining ?? 0
    }

    func progress(at date: Date = Date()) -> Double {
        guard let total = phase?.seconds, total > 0 else { return 0 }
        return min(1, max(0, 1 - remaining(at: date) / total))
    }

    func start(_ p: TimerPreset) {
        NotchController.haptic(.levelChange)
        preset = p
        phaseIndex = 0
        round = 1
        IslandExtras.timerActive = true
        begin(p.phases[0].seconds)
        music(for: p.phases[0])
    }

    func pause() {
        guard let end = endDate else { return }
        pausedRemaining = max(0, end.timeIntervalSinceNow)
        endDate = nil
        phaseTimer?.invalidate()
    }

    func resume() {
        guard let r = pausedRemaining else { return }
        begin(r)
    }

    func toggle() { isRunning ? pause() : resume() }

    func addMinute() {
        if let end = endDate {
            endDate = end.addingTimeInterval(60)
            schedule()
        } else if let r = pausedRemaining {
            pausedRemaining = r + 60
        }
        if remaining() >= 3600 { IslandExtras.timerLong = true }
    }

    /// Back to the start of the current part
    func restartPhase() {
        guard let p = phase else { return }
        if isRunning { begin(p.seconds) } else { pausedRemaining = p.seconds }
    }

    func skip() { phaseEnded(skipped: true) }

    func stop() {
        phaseTimer?.invalidate()
        phaseTimer = nil
        if pausedMusic, let np = nowPlaying, !np.isPlaying { np.playPause() }
        pausedMusic = false
        preset = nil
        endDate = nil
        pausedRemaining = nil
        IslandExtras.timerActive = false
    }

    private func begin(_ seconds: Double) {
        pausedRemaining = nil
        endDate = Date().addingTimeInterval(seconds)
        IslandExtras.timerLong = seconds >= 3600
        schedule()
    }

    private func schedule() {
        phaseTimer?.invalidate()
        guard let end = endDate else { return }
        let t = Timer(fire: end, interval: 0, repeats: false) { _ in
            Task { @MainActor in IslandTimer.shared.phaseEnded(skipped: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        phaseTimer = t
    }

    private func phaseEnded(skipped: Bool) {
        guard let p = preset else { return }
        let finished = p.phases[phaseIndex]
        if !skipped && UserDefaults.standard.object(forKey: "timerSound") as? Bool ?? true {
            NSSound(named: "Glass")?.play()
        }

        if phaseIndex + 1 < p.phases.count || p.repeats {
            phaseIndex = (phaseIndex + 1) % p.phases.count
            if phaseIndex == 0 { round += 1 }
            let next = p.phases[phaseIndex]
            begin(next.seconds)
            music(for: next)
            if !skipped {
                announce?(next.isBreak ? "cup.and.saucer.fill" : "timer",
                          "\(finished.name) is over", "\(next.name) · \(Self.format(next.seconds))")
            }
        } else {
            if !skipped { announce?("checkmark.circle.fill", "Time's up", p.title) }
            stop()
        }
    }

    /// Pomodoro: pause the music for breaks, and bring it back for the next focus
    private func music(for phase: TimerPhase) {
        guard preset?.repeats == true,
              UserDefaults.standard.object(forKey: "timerPauseMusic") as? Bool ?? true,
              let np = nowPlaying else { return }
        if phase.isBreak {
            if np.isPlaying { np.playPause(); pausedMusic = true }
        } else if pausedMusic {
            if !np.isPlaying { np.playPause() }
            pausedMusic = false
        }
    }

    /// 1:05, 24:59, 1:02:03 (rounded up, so a fresh 25 min timer reads 25:00)
    static func format(_ seconds: Double) -> String {
        let t = Int(seconds.rounded(.up))
        if t >= 3600 { return String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) }
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: Timer colours

enum TimerColour {
    static let focus = Color(red: 1.0, green: 0.62, blue: 0.26)
    static let rest = Color(red: 0.36, green: 0.86, blue: 0.56)
    static func of(_ phase: TimerPhase?) -> Color { phase?.isBreak == true ? rest : focus }
}

/// A thin ring that empties as time runs out
struct TimerRing: View {
    let progress: Double
    let colour: Color
    var lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle().stroke(colour.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(max(0.001, 1 - progress)))
                .stroke(colour, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// The time beside the notch: a small ring and the minutes left
struct TimerEar: View {
    @ObservedObject var timer = IslandTimer.shared
    let height: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { t in
            let colour = TimerColour.of(timer.phase)
            HStack(spacing: 5) {
                TimerRing(progress: timer.progress(at: t.date), colour: colour, lineWidth: 2)
                    .frame(width: height * 0.62, height: height * 0.62)
                Text(IslandTimer.format(timer.remaining(at: t.date)))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(colour)
                    .opacity(timer.isRunning ? 1 : 0.55)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}

/// The Timer tab: presets, or the running timer with its controls
struct TimerTabView: View {
    @ObservedObject private var timer = IslandTimer.shared

    var body: some View {
        Group {
            if timer.isActive {
                running
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                presets
                    .transition(.opacity)
            }
        }
        .animation(Motion.spring(0.4, 0.85), value: timer.isActive)
    }

    // MARK: Presets

    private var presets: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(timer.presets.prefix(IslandTimer.maxPresets))) { preset in
                PresetChip(title: preset.title, detail: preset.detail) { timer.start(preset) }
                    .contextMenu {
                        Button("Edit Presets…") { TimerTabView.editPresets() }
                    }
            }
            customChip
        }
    }

    static func editPresets() {
        NotchController.shared.collapse()
        SettingsWindow.shared.show(tab: "Timer")
    }

    private var customChip: some View {
        HStack(spacing: 0) {
            stepper("minus") { timer.customMinutes = max(1, timer.customMinutes - (timer.customMinutes > 10 ? 5 : 1)) }
            Button {
                timer.start(.custom(minutes: timer.customMinutes))
            } label: {
                VStack(spacing: 1) {
                    Text("\(timer.customMinutes) min")
                        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.white)
                    Text("Custom")
                        .font(.system(size: 10.5))
                        .foregroundStyle(IslandType.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            stepper("plus") { timer.customMinutes = min(180, timer.customMinutes + (timer.customMinutes >= 10 ? 5 : 1)) }
        }
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private func stepper(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            NotchController.haptic(.alignment)
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(IslandType.secondary)
                .frame(width: 26, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: Running

    private var running: some View {
        VStack(spacing: 12) {
            TimelineView(.periodic(from: .now, by: 0.5)) { t in
                let colour = TimerColour.of(timer.phase)
                HStack(spacing: 16) {
                    ZStack {
                        TimerRing(progress: timer.progress(at: t.date), colour: colour, lineWidth: 5)
                        Image(systemName: timer.phase?.isBreak == true ? "cup.and.saucer.fill" : "timer")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(colour)
                    }
                    .frame(width: 58, height: 58)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(timer.phase?.name ?? "")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(colour)
                            if timer.preset?.repeats == true {
                                Text("Round \(timer.round)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(IslandType.tertiary)
                            }
                            if !timer.isRunning {
                                Text("Paused")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(IslandType.tertiary)
                            }
                        }
                        Text(IslandTimer.format(timer.remaining(at: t.date)))
                            .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(Color.white)
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(IslandType.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 6) {
                pill("arrow.counterclockwise", help: "Restart this part") { timer.restartPhase() }
                pill(timer.isRunning ? "pause.fill" : "play.fill", help: timer.isRunning ? "Pause" : "Resume",
                     primary: true) { timer.toggle() }
                pill("goforward.60", help: "Add a minute") { timer.addMinute() }
                pill("forward.end.fill", help: "Skip to the next part") { timer.skip() }
                    .disabled(timer.nextPhase == nil)
                    .opacity(timer.nextPhase == nil ? 0.35 : 1)
                Spacer(minLength: 0)
                pill("xmark", help: "Stop") { timer.stop() }
            }
        }
    }

    private var subtitle: String {
        guard let p = timer.preset else { return "" }
        if let next = timer.nextPhase { return "\(p.title) · then \(next.name) \(IslandTimer.format(next.seconds))" }
        return p.title
    }

    private func pill(_ symbol: String, help: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            NotchController.haptic(.generic)
            withAnimation(Motion.spring(0.3, 0.85)) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(primary ? Color.black : Color.white.opacity(0.85))
                .symbolReplace()
                .frame(width: primary ? 52 : 38, height: 28)
                .background(Capsule().fill(primary ? Color.white : Color.white.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .help(help)
    }
}

private struct PresetChip: View {
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(IslandType.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.12 : 0.07)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Clipboard history

struct ClipItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case text, link, image, file }
    var id = UUID()
    var kind: Kind
    var text: String?            // the text, the link, or file paths (one per line)
    var imageFile: String?       // for images: a PNG in the clipboard folder
    var date = Date()
    var app: String?             // where it was copied from
    var definition: WordDefinition?   // for a copied word the dictionary knows
}

struct WordDefinition: Equatable, Codable {
    let word: String
    let pronunciation: String?
    let text: String
}

@MainActor
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    @Published private(set) var items: [ClipItem] = []
    /// A word you just copied that the dictionary knows; hover the notch to read it
    @Published private(set) var pendingDefinition: WordDefinition? {
        didSet { IslandExtras.definitionReady = pendingDefinition != nil }
    }

    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var expiry: Task<Void, Never>?
    private let limit = 20

    private static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Murmur", isDirectory: true)
            .appendingPathComponent("Clipboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    private static var indexFile: URL { folder.appendingPathComponent("history.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.indexFile),
           let saved = try? JSONDecoder().decode([ClipItem].self, from: data) {
            items = saved
        }
    }

    var historyOn: Bool { UserDefaults.standard.object(forKey: "clipHistory") as? Bool ?? true }
    var lookupOn: Bool { UserDefaults.standard.object(forKey: "clipDefine") as? Bool ?? true }

    func start() {
        guard timer == nil, historyOn || lookupOn else { return }
        lastChange = NSPasteboard.general.changeCount
        let t = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { _ in
            Task { @MainActor in ClipboardStore.shared.poll() }
        }
        t.tolerance = 0.25
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        stop()
        start()
    }

    // MARK: Watching the clipboard

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount

        // Password managers and some apps mark private copies; those are never kept
        let skip: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                                 "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword",
                                 "de.petermaurer.TransientPasteboardType"]
        let types = pb.types ?? []
        if types.contains(where: { skip.contains($0.rawValue) }) { return }

        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        let hasString = types.contains(.string)
        let hasImage = types.contains(.png) || types.contains(.tiff)

        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            add(ClipItem(kind: .file, text: urls.map(\.path).joined(separator: "\n"), app: app))
        } else if hasImage && !hasString, let image = NSImage(pasteboard: pb) {
            addImage(image, app: app)
        } else if let s = pb.string(forType: .string) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let isLink = !trimmed.contains(" ") && !trimmed.contains("\n")
                && (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"))
            let found = lookupOn && !isLink ? Self.define(trimmed) : nil
            add(ClipItem(kind: isLink ? .link : .text, text: s, app: app, definition: found))
            if let d = found { offer(d) }
        }
    }

    private func add(_ item: ClipItem) {
        guard historyOn else { return }
        // The same text copied again moves to the front instead of appearing twice
        if item.kind != .image, let i = items.firstIndex(where: { $0.kind == item.kind && $0.text == item.text }) {
            items.remove(at: i)
        }
        items.insert(item, at: 0)
        trim()
        save()
    }

    private func addImage(_ image: NSImage, app: String?) {
        guard historyOn,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let name = UUID().uuidString + ".png"
        let url = Self.folder.appendingPathComponent(name)
        DispatchQueue.global(qos: .utility).async { try? png.write(to: url, options: .atomic) }
        add(ClipItem(kind: .image, imageFile: name, app: app))
    }

    private func trim() {
        while items.count > limit {
            let gone = items.removeLast()
            deleteFile(of: gone)
        }
    }

    private func deleteFile(of item: ClipItem) {
        if let name = item.imageFile {
            try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(name))
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        let url = Self.indexFile
        DispatchQueue.global(qos: .utility).async { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Using the history

    func imageURL(_ item: ClipItem) -> URL? {
        item.imageFile.map { Self.folder.appendingPathComponent($0) }
    }

    /// Puts an item back on the clipboard (and moves it to the front)
    func copy(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text, .link:
            pb.setString(item.text ?? "", forType: .string)
        case .file:
            let urls = (item.text ?? "").split(separator: "\n").map { URL(fileURLWithPath: String($0)) as NSURL }
            pb.writeObjects(urls)
        case .image:
            if let url = imageURL(item), let image = NSImage(contentsOf: url) { pb.writeObjects([image]) }
        }
        lastChange = pb.changeCount
        if let i = items.firstIndex(of: item) {
            var moved = items.remove(at: i)
            moved.date = Date()
            items.insert(moved, at: 0)
            save()
        }
    }

    func remove(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        deleteFile(of: item)
        save()
    }

    func clear() {
        for item in items { deleteFile(of: item) }
        items = []
        save()
    }

    // MARK: Looking up a copied word

    /// A definition to read: shown inside the Shelf (from a clipboard card)
    @Published var reading: WordDefinition?

    private func offer(_ found: WordDefinition) {
        pendingDefinition = found
        expiry?.cancel()
        expiry = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if !Task.isCancelled { ClipboardStore.shared.pendingDefinition = nil }
        }
    }

    /// Hands over the waiting definition (once) to show in the island
    func takeDefinition() -> WordDefinition? {
        let d = pendingDefinition
        pendingDefinition = nil
        expiry?.cancel()
        return d
    }

    /// One word or a short phrase, through the dictionaries turned on in the Dictionary app
    static func define(_ raw: String) -> WordDefinition? {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard (2...40).contains(word.count), !word.contains("\n"),
              word.split(separator: " ").count <= 3,
              word.rangeOfCharacter(from: .letters) != nil,
              word.rangeOfCharacter(from: .decimalDigits) == nil else { return nil }
        let range = CFRange(location: 0, length: (word as NSString).length)
        guard let raw = DCSCopyTextDefinition(nil, word as CFString, range)?.takeRetainedValue() as String?,
              !raw.isEmpty else { return nil }

        // Apple's dictionaries read "word | pronunciation | noun the meaning … ORIGIN …"
        var body = raw
        for cut in [" ORIGIN ", " DERIVATIVES ", " PHRASES ", " PHRASAL VERBS "] {
            if let r = body.range(of: cut) { body = String(body[..<r.lowerBound]) }
        }
        let parts = body.components(separatedBy: " | ")
        if parts.count >= 3 {
            return WordDefinition(word: parts[0].trimmingCharacters(in: .whitespaces),
                                  pronunciation: parts[1].trimmingCharacters(in: .whitespaces),
                                  text: parts[2...].joined(separator: " | ").trimmingCharacters(in: .whitespaces))
        }
        return WordDefinition(word: word, pronunciation: nil, text: body.trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - Clipboard view (inside the Shelf)

struct ClipboardView: View {
    @ObservedObject private var store = ClipboardStore.shared

    var body: some View {
        if let d = store.reading {
            DefinitionReader(definition: d)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        } else if store.items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 20, weight: .medium))
                Text(store.historyOn ? "Things you copy will appear here" : "Clipboard history is off in Settings")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Color.white.opacity(0.45))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.items) { item in
                        ClipCard(item: item)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct ClipCard: View {
    let item: ClipItem
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                NotchController.haptic(.generic)
                ClipboardStore.shared.copy(item)
                withAnimation(Motion.spring(0.3, 0.8)) { copied = true }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    withAnimation(.easeOut(duration: 0.2)) { copied = false }
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    if item.kind != .image {
                        Text(footer)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(IslandType.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(item.kind == .image ? 0 : 9)
                .frame(width: 108, height: 92)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.12 : 0.07)))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    if copied {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.6))
                            .overlay(Label("Copied", systemImage: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.white))
                            .transition(.opacity)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(PressableStyle())
            .help("Click to copy")

            if let d = item.definition, !copied {
                Button {
                    NotchController.haptic(.generic)
                    withAnimation(Motion.spring(0.35, 0.85)) { ClipboardStore.shared.reading = d }
                } label: {
                    Image(systemName: "character.book.closed.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(hovering ? 0.95 : 0.6))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(hovering ? 0.18 : 0.1)))
                        .contentShape(Circle())
                }
                .buttonStyle(PressableStyle())
                .padding(5)
                .frame(width: 108, height: 92, alignment: .bottomTrailing)
                .help("Read the definition")
            }

            if hovering && !copied {
                Button {
                    withAnimation(Motion.spring(0.3, 0.85)) { ClipboardStore.shared.remove(item) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.black.opacity(0.7)))
                        .contentShape(Circle())
                }
                .buttonStyle(PressableStyle())
                .padding(5)
                .help("Remove")
                .transition(.opacity)
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            if let d = item.definition {
                let entry = DictEntry.parse(d)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.headword)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let pos = entry.sections.first?.pos {
                        Text(pos)
                            .font(.system(size: 10, weight: .medium).italic())
                            .foregroundStyle(Color(red: 0.55, green: 0.74, blue: 1.0))
                    }
                    Text(entry.sections.first?.senses.first?.text ?? d.text)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(2)
                        .padding(.top, 1)
                }
            } else {
                Text(item.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
            }
        case .link:
            let url = URL(string: item.text ?? "")
            VStack(alignment: .leading, spacing: 3) {
                Image(systemName: "link")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 0.45, green: 0.7, blue: 1))
                Text(url?.host?.replacingOccurrences(of: "www.", with: "") ?? "Link")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Text(url?.path ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(IslandType.tertiary)
                    .lineLimit(2)
            }
        case .image:
            if let url = ClipboardStore.shared.imageURL(item), let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 108, height: 92)
                    .clipped()
            } else {
                Image(systemName: "photo").foregroundStyle(IslandType.tertiary)
            }
        case .file:
            let paths = (item.text ?? "").split(separator: "\n").map(String.init)
            VStack(alignment: .leading, spacing: 4) {
                if let first = paths.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: first))
                        .resizable()
                        .frame(width: 30, height: 30)
                }
                Text(paths.count == 1 ? ((paths.first ?? "") as NSString).lastPathComponent : "\(paths.count) files")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .lineLimit(2)
            }
        }
    }

    private var footer: String {
        guard item.kind != .image else { return "" }
        let age = Date().timeIntervalSince(item.date)
        let when = age < 60 ? "now" : age < 3600 ? "\(Int(age / 60))m" : age < 86400 ? "\(Int(age / 3600))h" : "\(Int(age / 86400))d"
        return [item.app, when].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Definition card

/// The whole definition, inside the Shelf, with a way back to the clipboard
struct DefinitionReader: View {
    let definition: WordDefinition

    var body: some View {
        let entry = DictEntry.parse(definition)
        HStack(alignment: .top, spacing: 12) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    DictHeadline(entry: entry, size: 17, showFirstPOS: false)
                    ForEach(entry.sections.indices, id: \.self) { i in
                        DictSectionView(section: entry.sections[i], showPronunciation: i > 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            VStack(spacing: 6) {
                roundButton("xmark", help: "Back to the clipboard") {
                    withAnimation(Motion.spring(0.35, 0.85)) { ClipboardStore.shared.reading = nil }
                }
                roundButton("arrow.up.forward.app", help: "Open in Dictionary") {
                    DictionaryApp.open(definition.word)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private func roundButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button {
            NotchController.haptic(.generic)
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.8))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .help(help)
    }
}

enum DictionaryApp {
    static func open(_ word: String) {
        let w = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        if let url = URL(string: "dict://\(w)") { NSWorkspace.shared.open(url) }
    }
}

struct DefinitionCard: View {
    let definition: WordDefinition
    let notch: CGSize
    @State private var appeared = false

    var body: some View {
        let entry = DictEntry.parse(definition)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "character.book.closed.fill")
                    .font(.system(size: max(12, notch.height * 0.4), weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .symbolBounce(appeared)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IslandType.tertiary)
                    .help("Click to open in Dictionary")
            }
            .frame(height: notch.height)

            DictHeadline(entry: entry, size: 16, showFirstPOS: true)
                .padding(.top, 5)

            // Just the first meaning here; the Shelf's clipboard has the full entry
            if let sense = entry.sections.first?.senses.first {
                DictSenseRow(sense: sense, number: nil, compact: true)
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .onAppear { appeared = true }
    }
}

// MARK: - Dictionary entries
// macOS hands over a definition as one flat line, e.g.
//   "deliberate de·lib·er·ateadjective | dəˈlib(ə)rət | done consciously and intentionally: a
//    deliberate attempt… • fully considered… verb | dəˈlibəˌrāt | [no object] engage in…"
// This splits it back into its parts so it can be laid out like the Dictionary app.

struct DictEntry {
    struct Sense {
        var number: String?        // "1", "2"… for numbered senses
        var sub = false            // a • sub-sense
        var label: String?         // grammar or usage, e.g. "[no object]", "informal"
        var text: String
        var example: String?
    }
    struct Section {
        var pos: String?           // part of speech
        var pronunciation: String?
        var senses: [Sense]
    }
    var headword: String
    var pronunciation: String?
    var sections: [Section]

    private static let partsOfSpeech = [
        "plural noun", "phrasal verb", "modal verb", "auxiliary verb", "combining form", "proper noun",
        "noun", "verb", "adjective", "adverb", "pronoun", "preposition", "conjunction", "exclamation",
        "determiner", "predeterminer", "abbreviation", "prefix", "suffix", "symbol", "contraction",
        "number", "interjection", "article"
    ].sorted { $0.count > $1.count }      // longest first, so "adverb" isn't read as "…ad" + "verb"

    static func parse(_ d: WordDefinition) -> DictEntry {
        let raw = d.pronunciation.map { "\(d.word) | \($0) | \(d.text)" } ?? d.text
        var chunks = raw.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }

        guard chunks.count >= 3 else {
            // Another dictionary's layout (a bilingual one, say): keep the text, split into meanings
            var text = raw
            if text.lowercased().hasPrefix(d.word.lowercased() + " ") { text = String(text.dropFirst(d.word.count + 1)) }
            let pos = leadingPOS(&text)
            return DictEntry(headword: d.word, pronunciation: nil,
                             sections: [Section(pos: pos, pronunciation: nil, senses: senses(in: text))])
        }

        var head = chunks.removeFirst()
        var pos = trailingPOS(&head, inHead: true)
        let headword = headwordFrom(head, word: d.word)

        var sections: [Section] = []
        var firstPronunciation: String?
        var i = 0
        while i < chunks.count {
            let hasPair = i + 1 < chunks.count
            let pron: String? = hasPair ? chunks[i] : nil
            var text = hasPair ? chunks[i + 1] : chunks[i]
            i += hasPair ? 2 : 1
            // The next part of speech is stuck to the end of this text ("…unhurried way. verb")
            let nextPOS = i < chunks.count ? trailingPOS(&text, inHead: false) : nil
            if pos == nil { pos = leadingPOS(&text) }
            if firstPronunciation == nil { firstPronunciation = pron }
            sections.append(Section(pos: pos, pronunciation: pron, senses: senses(in: text)))
            pos = nextPOS
        }
        return DictEntry(headword: headword, pronunciation: firstPronunciation, sections: sections)
    }

    /// "deliberate de·lib·er·ateadjective" → "adjective", leaving "deliberate de·lib·er·ate"
    private static func trailingPOS(_ s: inout String, inHead: Bool) -> String? {
        let lower = s.lowercased()
        for p in partsOfSpeech where lower.hasSuffix(p) {
            let base = String(s.dropLast(p.count))
            let trimmed = base.trimmingCharacters(in: .whitespaces)
            if inHead {
                // Only when there's a word before it (so "pronoun" on its own stays "pronoun")
                guard trimmed.contains(" ") || trimmed.contains("·") else { continue }
            } else {
                // In a definition, it has to stand alone after the end of a sentence
                guard base.hasSuffix(" "), let last = trimmed.last, ".;:)]".contains(last) else { continue }
            }
            s = trimmed
            return p
        }
        return nil
    }

    private static func leadingPOS(_ s: inout String) -> String? {
        let lower = s.lowercased()
        for p in partsOfSpeech where lower.hasPrefix(p + " ") {
            s = String(s.dropFirst(p.count + 1))
            return p
        }
        return nil
    }

    /// The dictionary's spelled-out form ("de·lib·er·ate") when it gives one
    private static func headwordFrom(_ head: String, word: String) -> String {
        var rest = head
        if rest.lowercased().hasPrefix(word.lowercased() + " ") { rest = String(rest.dropFirst(word.count + 1)) }
        rest = rest.trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? word : rest
    }

    /// Numbered senses ("1 … 2 …"), • sub-senses, a leading [label], and the example after a colon
    private static func senses(in text: String) -> [Sense] {
        var result: [Sense] = []
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var current: [String] = []
        var number: String?
        var sub = false

        func flush() {
            let joined = current.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { result.append(makeSense(joined, number: number, sub: sub)) }
            current = []
        }

        for (i, w) in words.enumerated() {
            let previous = i > 0 ? words[i - 1] : ""
            let startsSentence = i == 0 || ".;:!?)]".contains(previous.last ?? " ")
            if let n = Int(w), (1...30).contains(n), startsSentence, i + 1 < words.count {
                flush()
                number = w
                sub = false
            } else if w == "•" || w == "▸" {
                flush()
                number = nil
                sub = true
            } else {
                current.append(w)
            }
        }
        flush()
        return result
    }

    private static func makeSense(_ text: String, number: String?, sub: Bool) -> Sense {
        var body = text
        var label: String?
        if body.hasPrefix("["), let close = body.firstIndex(of: "]") {
            label = String(body[body.index(after: body.startIndex)..<close])
            body = String(body[body.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        var example: String?
        if let colon = body.range(of: ": ") {
            let ex = body[colon.upperBound...].trimmingCharacters(in: .whitespaces)
            if !ex.isEmpty {
                example = ex
                body = String(body[..<colon.lowerBound])
            }
        }
        return Sense(number: number, sub: sub, label: label, text: body, example: example)
    }
}

private enum DictStyle {
    static let pos = Color(red: 0.55, green: 0.74, blue: 1.0)
    static let label = Color.white.opacity(0.42)
}

/// "de·lib·er·ate  /dəˈlib(ə)rət/  adjective"
struct DictHeadline: View {
    let entry: DictEntry
    var size: CGFloat = 16
    var showFirstPOS = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.headword)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
            if let p = entry.pronunciation, !p.isEmpty {
                Text("/\(p)/")
                    .font(.system(size: size * 0.72))
                    .foregroundStyle(IslandType.tertiary)
                    .lineLimit(1)
            }
            if showFirstPOS, let pos = entry.sections.first?.pos {
                Text(pos)
                    .font(.system(size: size * 0.72, weight: .medium).italic())
                    .foregroundStyle(DictStyle.pos)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// One part of speech and its meanings
struct DictSectionView: View {
    let section: DictEntry.Section
    var showPronunciation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if section.pos != nil || (showPronunciation && section.pronunciation != nil) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let pos = section.pos {
                        Text(pos)
                            .font(.system(size: 12, weight: .semibold).italic())
                            .foregroundStyle(DictStyle.pos)
                    }
                    if showPronunciation, let p = section.pronunciation {
                        Text("/\(p)/")
                            .font(.system(size: 11))
                            .foregroundStyle(IslandType.tertiary)
                    }
                }
                .padding(.top, 2)
            }
            ForEach(section.senses.indices, id: \.self) { i in
                let sense = section.senses[i]
                DictSenseRow(sense: sense,
                             number: sense.number ?? (section.senses.count > 1 && !sense.sub ? "\(i + 1)" : nil),
                             compact: false)
            }
        }
    }
}

/// "1  [no object] engage in long and careful consideration"
///        "the jury deliberated for two days"  (italic, dimmer)
struct DictSenseRow: View {
    let sense: DictEntry.Sense
    let number: String?
    var compact = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if !compact {
                Text(sense.sub ? "•" : (number ?? "•"))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(sense.sub ? DictStyle.label : Color.white.opacity(0.6))
                    .frame(width: 14, alignment: sense.sub ? .center : .trailing)
            }
            VStack(alignment: .leading, spacing: 1) {
                (Text(sense.label.map { "[\($0)]  " } ?? "")
                    .font(.system(size: 11).italic())
                    .foregroundColor(DictStyle.label)
                 + Text(sense.text)
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.88)))
                    .lineLimit(compact ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                if let ex = sense.example {
                    Text(ex)
                        .font(.system(size: 11.5).italic())
                        .foregroundStyle(Color.white.opacity(0.48))
                        .lineLimit(compact ? 1 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, sense.sub && !compact ? 14 : 0)
    }
}

// MARK: - Plugging in and unplugging

/// Tells the island when the charger is connected or removed (macOS announces every change in
/// power; only a change between battery and power adapter counts here)
final class PowerWatcher {
    static let shared = PowerWatcher()
    var onChange: ((BatteryInfo) -> Void)?
    private var source: CFRunLoopSource?
    private var lastPlugged: Bool?

    func start() {
        guard source == nil else { return }
        lastPlugged = SystemMonitor.readBattery()?.pluggedIn
        guard let s = IOPSNotificationCreateRunLoopSource({ _ in PowerWatcher.shared.changed() }, nil)?
            .takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .defaultMode)
        source = s
    }

    func stop() {
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .defaultMode) }
        source = nil
    }

    fileprivate func changed() {
        guard let info = SystemMonitor.readBattery() else { return }   // Macs without a battery
        if let last = lastPlugged, last != info.pluggedIn { onChange?(info) }
        lastPlugged = info.pluggedIn
    }
}

/// The card: a battery that fills up (plugging in) or lets go of its bolt (unplugging) on the
/// left, the percentage on the right, and a bar below with light running along it while charging
struct PowerActivityView: View {
    let info: BatteryInfo
    let notch: CGSize
    @State private var settled = false

    private static let green = Color(red: 0.3, green: 0.88, blue: 0.45)
    private var level: Double { Double(info.percent) / 100 }
    private var low: Bool { info.percent <= 20 }
    private var colour: Color { info.pluggedIn ? Self.green : low ? .orange : .white }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                // Plugging in: fills from empty, bolt pops in. Unplugging: starts green with its bolt,
                // then the bolt leaves and the colour fades to white
                let shownLevel = info.pluggedIn ? (settled ? level : 0.02) : level
                let showBolt = info.pluggedIn ? settled : !settled
                BatteryGlyph(level: shownLevel,
                             colour: info.pluggedIn ? Self.green : (settled ? (low ? .orange : .white) : Self.green),
                             bolt: showBolt)
                    .frame(width: 30, height: 14)
                Spacer(minLength: 0)
                Text("\(info.percent)%")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(colour)
            }
            .frame(height: notch.height)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(IslandType.title)
                    .foregroundStyle(Color.white)
                if let d = detail {
                    Text(d)
                        .font(IslandType.subtitle)
                        .foregroundStyle(IslandType.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 7)

            ChargeBar(level: settled || !info.pluggedIn ? level : 0.02, colour: colour,
                      flowing: info.pluggedIn && info.charging)
                .frame(height: 5)
                .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .onAppear {
            withAnimation(.spring(response: 1.0, dampingFraction: 0.86).delay(0.18)) { settled = true }
        }
    }

    private var title: String {
        if !info.pluggedIn { return "On battery" }
        if info.charging { return "Charging" }
        return info.percent >= 99 ? "Fully charged" : "Plugged in"
    }

    private var detail: String? {
        if let m = info.minutesLeft {
            return info.pluggedIn ? "Full in \(SystemMonitor.duration(m))" : "\(SystemMonitor.duration(m)) left"
        }
        if info.pluggedIn && !info.charging && info.percent < 99 { return "Charging on hold to protect the battery" }
        return nil
    }
}

struct BatteryGlyph: View {
    let level: Double
    let colour: Color
    let bolt: Bool

    var body: some View {
        HStack(spacing: 1.5) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.white.opacity(0.45), lineWidth: 1.2)
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(colour)
                        .frame(width: max(2, (g.size.width - 4) * CGFloat(min(1, max(0, level)))),
                               height: max(1, g.size.height - 4))
                        .offset(x: 2)
                    if bolt {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: g.size.height * 0.72, weight: .black))
                            .foregroundStyle(Color.white)
                            .shadow(color: .black.opacity(0.5), radius: 1)
                            .frame(width: g.size.width, height: g.size.height)
                            .transition(.scale(scale: 0.2).combined(with: .opacity))
                    }
                }
            }
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white.opacity(0.45))
                .frame(width: 2, height: 5)
        }
    }
}

/// The charge level as a slim bar; while charging, a soft highlight runs along the filled part
struct ChargeBar: View {
    let level: Double
    let colour: Color
    let flowing: Bool

    var body: some View {
        GeometryReader { g in
            let fill = max(4, g.size.width * CGFloat(min(1, max(0, level))))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(colour).frame(width: fill)
                if flowing {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { t in
                        let phase = t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        LinearGradient(colors: [.white.opacity(0), .white.opacity(0.65), .white.opacity(0)],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: 44)
                            .offset(x: CGFloat(phase) * (fill + 44) - 44)
                    }
                    .frame(width: fill, alignment: .leading)
                    .clipShape(Capsule())
                }
            }
        }
    }
}
