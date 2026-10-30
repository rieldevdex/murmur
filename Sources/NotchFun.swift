import SwiftUI
import AppKit
import Carbon
import EventKit
import ImageIO

// MARK: - Extras: the switches
// Everything here reacts to events (a beat, a click, a change) and animates with one spring;
// nothing runs its own frame loop, so it costs next to nothing while nothing happens.

enum Extras {
    private static var d: UserDefaults { .standard }
    static var pulse: Bool { d.object(forKey: "funPulse") as? Bool ?? true }
    static var flip: Bool { d.object(forKey: "funFlip") as? Bool ?? true }
    static var split: Bool { d.object(forKey: "funSplit") as? Bool ?? true }
    static var eyes: Bool { d.bool(forKey: "funEyes") }                       // off unless turned on
    static var jelly: Bool { d.object(forKey: "funJelly") as? Bool ?? true }
    static var keyboard: Bool { d.object(forKey: "funInput") as? Bool ?? true }
    static var screenshots: Bool { d.object(forKey: "funShots") as? Bool ?? true }
    static var greeting: Bool { d.object(forKey: "funGreeting") as? Bool ?? true }
}

extension IslandExtras {
    /// Set by the island each update: music (rather than only a timer) is what's playing
    static var musicActive = false
    /// How far the keyboard badge reaches past each side of the notch (fits the layout's name)
    static var badgeEar: CGFloat = 74
}

// MARK: - Beat pulse

/// One spring per beat: the island swells a touch and glows, then settles.
/// The beat is detected by the small waveform beside the notch, which is drawing anyway.
@MainActor
final class NotchPulse: ObservableObject {
    static let shared = NotchPulse()
    @Published private(set) var level: Double = 0
    private var last = Date.distantPast

    func hit(_ strength: Double) {
        guard Extras.pulse, Date().timeIntervalSince(last) > 0.22 else { return }
        last = Date()
        withAnimation(.spring(response: 0.11, dampingFraction: 0.6)) { level = min(1, strength) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.75)) { NotchPulse.shared.level = 0 }
        }
    }
}

/// Remembers the last beat value so only the moment a beat starts counts
final class BeatEdge {
    private var previous: Float = 0
    func rose(_ beat: Float) -> Bool {
        defer { previous = beat }
        return beat > 0.85 && previous < 0.6
    }
}

// MARK: - Cover flip

struct FlipModifier: ViewModifier {
    let angle: Double
    func body(content: Content) -> some View {
        content.rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
    }
}

extension AnyTransition {
    /// The old cover turns away, then the new one turns in, like a card
    static var coverFlip: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: FlipModifier(angle: -90), identity: FlipModifier(angle: 0))
                .animation(.spring(response: 0.38, dampingFraction: 0.78).delay(0.16)),
            removal: .modifier(active: FlipModifier(angle: 90), identity: FlipModifier(angle: 0))
                .combined(with: .opacity)
                .animation(.easeIn(duration: 0.18)))
    }
}

// MARK: - Liquid split: the timer as its own bubble

enum BubbleLayout {
    static let gap: CGFloat = 7
    static let width: CGFloat = 70
}

/// The bridge of "liquid" between the island and the bubble, which thins and lets go
/// as the bubble moves away (`separation` 0 = still part of the island, 1 = apart)
struct GooModifier: ViewModifier, Animatable {
    var separation: Double
    let height: CGFloat

    var animatableData: Double {
        get { separation }
        set { separation = newValue }
    }

    func body(content: Content) -> some View {
        // Clamped, so a springy finish can never push the bubble back into the island
        let s = CGFloat(min(1, max(0, separation)))
        let travel = BubbleLayout.gap + BubbleLayout.width * 0.75
        ZStack(alignment: .leading) {
            GooBridge(separation: s)
                .fill(Color.black)
                .frame(width: BubbleLayout.gap + height * 0.6, height: height)
                .opacity(Double(1 - max(0, s - 0.55) / 0.45))
            content
                .offset(x: BubbleLayout.gap - (1 - s) * travel)
                .opacity(Double(min(1, s * 1.6)))
        }
        .frame(width: BubbleLayout.gap + BubbleLayout.width, height: height, alignment: .leading)
    }
}

struct GooBridge: Shape {
    var separation: CGFloat
    var animatableData: CGFloat {
        get { separation }
        set { separation = newValue }
    }

    func path(in r: CGRect) -> Path {
        // Top and bottom edges pinch towards the middle as the bubble pulls away
        let pinch = r.height * 0.55 * min(1, separation * 1.4)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.minY + pinch))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY), control: CGPoint(x: r.midX, y: r.maxY - pinch))
        p.closeSubpath()
        return p
    }
}

extension AnyTransition {
    static func goo(height: CGFloat) -> AnyTransition {
        .modifier(active: GooModifier(separation: 0, height: height),
                  identity: GooModifier(separation: 1, height: height))
    }
}

struct TimerBubble: View {
    @ObservedObject var timer = IslandTimer.shared
    let height: CGFloat

    var body: some View {
        Button {
            NotchController.shared.expand(tab: .timer)
        } label: {
            TimerEar(height: height)
                .padding(.horizontal, 10)
                .frame(width: BubbleLayout.width, height: height)
                .background(Capsule().fill(Color.black))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .help("Open the timer")
    }
}

// MARK: - Notch eyes

@MainActor
final class EyesModel: ObservableObject {
    static let shared = EyesModel()
    @Published private(set) var look = CGSize.zero      // -1…1 each way
    @Published private(set) var blink = false
    @Published private(set) var asleep = false
    @Published private(set) var surprised = false

    private var blinker: Task<Void, Never>?
    private var lastMove = Date()
    private var lastMouse = NSPoint.zero

    /// Called from the island's pointer check, which is already running
    func follow(mouse: NSPoint, from centre: NSPoint) {
        if hypot(mouse.x - lastMouse.x, mouse.y - lastMouse.y) > 2 {
            lastMouse = mouse
            lastMove = Date()
            if asleep { withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { asleep = false } }
        } else if !asleep, Date().timeIntervalSince(lastMove) > 120 {
            withAnimation(.easeInOut(duration: 0.6)) { asleep = true }
        }
        // Rounded to steps, so the eyes only redraw when they'd visibly move
        let dx = max(-1, min(1, (mouse.x - centre.x) / 320))
        let dy = max(-1, min(1, (centre.y - mouse.y) / 220))
        let q = CGSize(width: (dx * 5).rounded() / 5, height: (dy * 5).rounded() / 5)
        if q != look { withAnimation(.easeOut(duration: 0.18)) { look = q } }
    }

    func surprise() {
        guard Extras.eyes else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.45)) { surprised = true; asleep = false }
        lastMove = Date()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { EyesModel.shared.surprised = false }
        }
    }

    /// Blinks every few seconds while the eyes are showing; sleeps between blinks
    func setRunning(_ on: Bool) {
        if !on { blinker?.cancel(); blinker = nil; return }
        guard blinker == nil else { return }
        blinker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 2.8...6.5) * 1_000_000_000))
                guard !Task.isCancelled else { break }
                let model = EyesModel.shared
                if model.asleep { continue }
                let twice = Int.random(in: 0..<5) == 0
                for _ in 0..<(twice ? 2 : 1) {
                    withAnimation(.easeIn(duration: 0.06)) { model.blink = true }
                    try? await Task.sleep(nanoseconds: 110_000_000)
                    withAnimation(.easeOut(duration: 0.09)) { model.blink = false }
                    try? await Task.sleep(nanoseconds: 140_000_000)
                }
            }
        }
    }
}

/// Two eyes, one in each ear beside the notch
struct EyesView: View {
    @ObservedObject private var model = EyesModel.shared
    let notch: CGSize

    var body: some View {
        HStack {
            eye
            Spacer(minLength: 0)
            eye.overlay(alignment: .topTrailing) { sleepyZ }
        }
        .padding(.horizontal, 11)
        .frame(height: notch.height)
    }

    private var eye: some View {
        let w: CGFloat = model.surprised ? 12 : 10
        let h: CGFloat = model.asleep ? 2 : model.blink ? 1.5 : (model.surprised ? 15 : 12)
        return ZStack {
            Capsule()
                .fill(Color.white.opacity(model.asleep ? 0.55 : 0.95))
                .frame(width: w, height: h)
            if !model.asleep && !model.blink {
                Circle()
                    .fill(Color.black)
                    .frame(width: model.surprised ? 4 : 5.5, height: model.surprised ? 4 : 5.5)
                    .offset(x: model.look.width * 2.2, y: model.look.height * 3)
            }
        }
        .frame(width: 14, height: 16)
    }

    @ViewBuilder
    private var sleepyZ: some View {
        if model.asleep {
            // Two z's that take turns, a few times a second at most
            TimelineView(.periodic(from: .now, by: 1.1)) { t in
                let odd = Int(t.date.timeIntervalSinceReferenceDate / 1.1) % 2 == 0
                Text(odd ? "z" : "z z")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .fixedSize()
                    .offset(x: 12, y: -6)
            }
            .transition(.opacity)
        }
    }
}

// MARK: - Keyboard language and Caps Lock

/// Watches the keyboard input source (English, Vietnamese Telex, …). macOS announces each
/// change, so nothing is polled.
final class InputSourceWatcher {
    static let shared = InputSourceWatcher()
    var onChange: ((String, String) -> Void)?       // short code ("VI"), name ("Telex")
    private var observer: NSObjectProtocol?
    private var last = ""
    private var pending: DispatchWorkItem?

    func start() {
        guard observer == nil else { return }
        last = Self.current()?.key ?? ""
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil, queue: .main) { _ in
            InputSourceWatcher.shared.scheduleRead()
        }
    }

    /// macOS announces the switch a moment before the new source is actually current, and often
    /// announces it more than once. So: wait until the announcements stop, then read it, and read
    /// once more a little later in case it was still settling.
    private func scheduleRead() {
        pending?.cancel()
        let work = DispatchWorkItem { InputSourceWatcher.shared.changed() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { InputSourceWatcher.shared.changed() }
    }

    func stop() {
        if let o = observer { DistributedNotificationCenter.default().removeObserver(o) }
        observer = nil
    }

    private func changed() {
        guard let now = Self.current(), now.key != last else { return }
        last = now.key
        onChange?(now.code, now.name)
    }

    static func current() -> (key: String, code: String, name: String)? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        func property(_ key: CFString) -> AnyObject? {
            guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
        }
        let id = property(kTISPropertyInputSourceID) as? String ?? ""
        var name = property(kTISPropertyLocalizedName) as? String ?? "Keyboard"
        let language = (property(kTISPropertyInputSourceLanguages) as? [String])?.first ?? ""
        let code = String(language.prefix(2)).uppercased()
        // "Vietnamese – Telex" reads better as just "Telex"
        for sep in [" – ", " - "] {
            if let r = name.range(of: sep) { name = String(name[r.upperBound...]) }
        }
        return (id, code.isEmpty ? "⌨︎" : code, name)
    }
}

/// The badge beside the notch: language on the left, the layout's name on the right
struct BadgeView: View {
    let activity: IslandActivity
    let notch: CGSize
    @State private var appeared = false

    var body: some View {
        HStack {
            left
                .scaleEffect(appeared ? 1 : 0.5)
                .opacity(appeared ? 1 : 0)
            Spacer(minLength: 0)
            right
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: max(30, IslandExtras.badgeEar - 18), alignment: .trailing)
        }
        .frame(height: notch.height)
        .onAppear { withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { appeared = true } }
    }

    @ViewBuilder
    private var left: some View {
        switch activity {
        case .keyboard(let code, _):
            Text(code)
                .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 5)
                .frame(minWidth: 24, minHeight: 16)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white))
        case .capsLock(let on):
            Image(systemName: on ? "capslock.fill" : "capslock")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? Color.white : Color.white.opacity(0.6))
        case .listening:
            Image(systemName: "airpodspro")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.white)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var right: some View {
        switch activity {
        case .keyboard(_, let name):
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.9))
        case .capsLock(let on):
            Text(on ? "On" : "Off")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Color.white : Color.white.opacity(0.6))
        case .listening(let mode):
            HStack(spacing: 6) {
                ListeningRings(mode: mode)
                    .id(mode)               // a new mode plays its animation again
                Text(mode.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(mode == .off ? Color.white.opacity(0.6) : Color.white)
            }
        default:
            EmptyView()
        }
    }
}

/// Turns macOS's own language bubble by the text cursor on or off. It's a system-wide setting
/// macOS reads when you log in, so the change shows after logging out or restarting.
enum SystemInputIndicator {
    private static let key = "TSMLanguageIndicatorEnabled" as CFString

    static var hidden: Bool {
        let v = CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                                       kCFPreferencesAnyHost)
        return (v as? Bool) == false
    }

    static func setHidden(_ hide: Bool) {
        let value: CFPropertyList? = hide ? kCFBooleanFalse : nil     // nil puts macOS's default back
        CFPreferencesSetValue(key, value, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}

// MARK: - Screenshot catcher

/// Finds new screenshots through Spotlight, which tags them as screen captures wherever
/// they're saved. The query sits idle until a screenshot appears.
final class ScreenshotWatcher: NSObject {
    static let shared = ScreenshotWatcher()
    var onNew: ((URL) -> Void)?
    private var query: NSMetadataQuery?
    private var seen = Set<String>()

    func start() {
        guard query == nil else { return }
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1 AND kMDItemFSCreationDate >= %@",
                                  Date() as NSDate)
        q.searchScopes = [NSMetadataQueryLocalComputerScope]
        NotificationCenter.default.addObserver(self, selector: #selector(updated(_:)),
                                               name: .NSMetadataQueryDidUpdate, object: q)
        q.start()
        query = q
    }

    func stop() {
        query?.stop()
        if let q = query { NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: q) }
        query = nil
    }

    @objc private func updated(_ note: Notification) {
        guard let added = note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] else { return }
        for item in added {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !seen.contains(path) else { continue }
            seen.insert(path)
            onNew?(URL(fileURLWithPath: path))
        }
    }

    /// A small preview, read straight from the file without decoding the full image
    static func thumbnail(_ url: URL, size: CGFloat = 260) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: size,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

struct ScreenshotCard: View {
    let url: URL
    let notch: CGSize
    @State private var image: NSImage?
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: max(12, notch.height * 0.42), weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .symbolBounce(appeared)
                Spacer(minLength: 0)
            }
            .frame(height: notch.height)

            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let img = image {
                        Image(nsImage: img).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.08)
                    }
                }
                .frame(width: 108, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                .offset(y: appeared ? 0 : -24)
                .scaleEffect(appeared ? 1 : 0.6, anchor: .top)
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                .help("Drag it into any app")

                VStack(alignment: .leading, spacing: 3) {
                    Text("Screenshot")
                        .font(IslandType.title)
                        .foregroundStyle(Color.white)
                    Text("Drag it anywhere")
                        .font(IslandType.subtitle)
                        .foregroundStyle(IslandType.secondary)
                    HStack(spacing: 6) {
                        pill("Keep in Shelf", primary: true) {
                            ShelfStore.shared.add([url])
                            NotchController.shared.dismissActivity()
                        }
                        pill("Show", primary: false) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                            NotchController.shared.dismissActivity()
                        }
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .onAppear {
            image = ScreenshotWatcher.thumbnail(url)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { appeared = true }
        }
    }

    private func pill(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button {
            NotchController.haptic(.generic)
            action()
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(primary ? Color.black : Color.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(primary ? Color.white : Color.white.opacity(0.12)))
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Daily greeting

struct Greeting: Equatable {
    var title: String
    var symbol: String
    var temperature: String?
    var weather: String?
    var event: String?
}

@MainActor
final class Greeter {
    static let shared = Greeter()
    var show: ((Greeting) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private let store = EKEventStore()

    func start() {
        guard observers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.screensDidWakeNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in Greeter.shared.greetIfFirstToday(after: 2) }
            })
        }
        greetIfFirstToday(after: 3)
    }

    func stop() {
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers = []
    }

    /// Once per day, the first time the Mac is in use
    func greetIfFirstToday(after seconds: Double) {
        guard Extras.greeting else { return }
        let today = Self.dayKey(Date())
        guard UserDefaults.standard.string(forKey: "greetLastDay") != today else { return }
        UserDefaults.standard.set(today, forKey: "greetLastDay")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await self.greet()
        }
    }

    /// Builds the greeting (one weather request at most) and shows it
    func greet() async {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "Good evening" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let name = Self.name
        var g = Greeting(title: name.isEmpty ? part : "\(part), \(name)",
                         symbol: hour >= 6 && hour < 18 ? "sun.horizon.fill" : "moon.stars.fill")
        if let w = await Weather.today() {
            g.symbol = w.symbol
            g.temperature = w.now
            g.weather = w.summary
        }
        g.event = firstEvent()
        show?(g)
    }

    static var name: String {
        if let saved = UserDefaults.standard.string(forKey: "greetName") { return saved }
        return NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
    }

    private static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    // MARK: Calendar

    static var calendarAllowed: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14, *) { if status == .fullAccess { return true } }
        return status == .authorized
    }

    func requestCalendar(done: @escaping (Bool) -> Void) {
        if #available(macOS 14, *) {
            store.requestFullAccessToEvents { ok, _ in DispatchQueue.main.async { done(ok) } }
        } else {
            store.requestAccess(to: .event) { ok, _ in DispatchQueue.main.async { done(ok) } }
        }
    }

    /// The next timed event today, e.g. "IELTS class at 8:00"
    private func firstEvent() -> String? {
        guard UserDefaults.standard.bool(forKey: "greetEvents"), Self.calendarAllowed else { return nil }
        let now = Date()
        guard let end = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: now) else { return nil }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        guard let next = store.events(matching: predicate)
            .filter({ !$0.isAllDay })
            .sorted(by: { $0.startDate < $1.startDate })
            .first else { return nil }
        let f = DateFormatter()
        f.timeStyle = .short
        return "\(next.title ?? "Event") at \(f.string(from: next.startDate))"
    }
}

/// Today's weather from Open-Meteo (free, no account), for the city set in Settings
enum Weather {
    struct Today { let symbol: String; let now: String; let summary: String }

    static func today() async -> Today? {
        guard let place = await location() else { return nil }
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(place.lat)),
            URLQueryItem(name: "longitude", value: String(place.lon)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1")
        ]
        guard let url = c.url,
              let json = await fetch(url),
              let current = json["current"] as? [String: Any],
              let temp = (current["temperature_2m"] as? NSNumber)?.doubleValue,
              let code = (current["weather_code"] as? NSNumber)?.intValue else { return nil }
        let day = ((current["is_day"] as? NSNumber)?.intValue ?? 1) == 1
        let daily = json["daily"] as? [String: Any]
        let hi = ((daily?["temperature_2m_max"] as? [NSNumber])?.first)?.doubleValue
        let lo = ((daily?["temperature_2m_min"] as? [NSNumber])?.first)?.doubleValue
        let (symbol, words) = describe(code, day: day)
        var summary = words
        if let h = hi, let l = lo { summary += " · \(Int(l.rounded()))°–\(Int(h.rounded()))°" }
        return Today(symbol: symbol, now: "\(Int(temp.rounded()))°", summary: summary)
    }

    /// The city's coordinates, looked up once and remembered
    static func location() async -> (lat: Double, lon: Double)? {
        let d = UserDefaults.standard
        let city = (d.string(forKey: "greetCity") ?? "").trimmingCharacters(in: .whitespaces)
        guard !city.isEmpty else { return nil }
        if d.string(forKey: "greetCityResolved") == city,
           let lat = d.object(forKey: "greetLat") as? Double, let lon = d.object(forKey: "greetLon") as? Double {
            return (lat, lon)
        }
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [URLQueryItem(name: "name", value: city), URLQueryItem(name: "count", value: "1")]
        guard let url = c.url, let json = await fetch(url),
              let first = (json["results"] as? [[String: Any]])?.first,
              let lat = (first["latitude"] as? NSNumber)?.doubleValue,
              let lon = (first["longitude"] as? NSNumber)?.doubleValue else { return nil }
        d.set(city, forKey: "greetCityResolved")
        d.set(lat, forKey: "greetLat")
        d.set(lon, forKey: "greetLon")
        return (lat, lon)
    }

    private static func fetch(_ url: URL) async -> [String: Any]? {
        let request = URLRequest(url: url, timeoutInterval: 5)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func describe(_ code: Int, day: Bool) -> (String, String) {
        switch code {
        case 0: return (day ? "sun.max.fill" : "moon.stars.fill", "Clear")
        case 1, 2: return (day ? "cloud.sun.fill" : "cloud.moon.fill", "Partly cloudy")
        case 3: return ("cloud.fill", "Cloudy")
        case 45, 48: return ("cloud.fog.fill", "Foggy")
        case 51...57: return ("cloud.drizzle.fill", "Drizzle")
        case 61...67: return ("cloud.rain.fill", "Rain")
        case 71...77, 85, 86: return ("cloud.snow.fill", "Snow")
        case 80...82: return ("cloud.heavyrain.fill", "Showers")
        case 95...99: return ("cloud.bolt.rain.fill", "Thunderstorms")
        default: return (day ? "sun.max.fill" : "moon.fill", "")
        }
    }
}

struct GreetingCard: View {
    let greeting: Greeting
    let notch: CGSize
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: greeting.symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: max(13, notch.height * 0.45), weight: .medium))
                    .scaleEffect(appeared ? 1 : 0.4)
                    .rotationEffect(.degrees(appeared ? 0 : -40))
                Spacer(minLength: 0)
                if let t = greeting.temperature {
                    Text(t)
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.white)
                }
            }
            .frame(height: notch.height)

            Text(greeting.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .padding(.top, 6)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 6)
            if let w = greeting.weather, !w.isEmpty {
                Text(w)
                    .font(IslandType.subtitle)
                    .foregroundStyle(IslandType.secondary)
                    .padding(.top, 2)
            }
            if let e = greeting.event {
                Label(e, systemImage: "calendar")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .lineLimit(1)
                    .padding(.top, 3)
            }
            Spacer(minLength: 0)
        }
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.1)) { appeared = true } }
    }
}
