import SwiftUI
import AppKit
import Combine
import IOBluetooth

// MARK: - Notch size and fine-tuning

/// The open player, measured from the reference layout. x is from the island's left edge,
/// y from the top of the screen.
/// Quick Preview: the cover tucked in beside the notch, the words just under it
enum PreviewLayout {
    static let artSize: CGFloat = 56
    static let artLeft: CGFloat = 14
    static let artTop: CGFloat = 8
    static let textLeft: CGFloat = artLeft + artSize + 12
}

enum PlayerLayout {
    static let artSize: CGFloat = 64
    static let artLeft: CGFloat = 18
    static let artTop: CGFloat = 8
    /// Gap between the cover and the notch, and the same margin on the right
    static let earGap: CGFloat = 16
    static let otherTabsWidth: CGFloat = 460

    /// Just wide enough for the cover beside the notch, mirrored on the other side
    static func width(_ notch: CGSize) -> CGFloat { notch.width + 2 * (artLeft + artSize + earGap) }

    // Rows, measured from the top of the screen
    static func titleY(_ notch: CGSize) -> CGFloat { notch.height + 12 }
    static func artistY(_ notch: CGSize) -> CGFloat { titleY(notch) + 19 }
    static func lyricY(_ notch: CGSize) -> CGFloat { artistY(notch) + 22 }
    static func progressY(_ notch: CGSize, lyrics: Bool) -> CGFloat {
        max(artTop + artSize + 12, (lyrics ? lyricY(notch) : artistY(notch)) + 24)
    }
    static func controlsY(_ notch: CGSize, lyrics: Bool) -> CGFloat { progressY(notch, lyrics: lyrics) + 32 }
    static func height(_ notch: CGSize, lyrics: Bool) -> CGFloat { controlsY(notch, lyrics: lyrics) + 24 }
}

enum NotchDefaults {
    static let widthAdjust = 0.0     // points added to the detected notch width
    static let heightAdjust = 0.0    // points added to the detected notch height
    static let shift = 0.0           // move left (negative) or right
    static let radius = 10.0         // roundness of the bottom corners
    static let ear = 34.0            // how far the island reaches past each side while music plays
    static let flare = 8.0           // the inward curve where the top corners meet the bezel

    static func value(_ key: String, _ fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? fallback
    }
}

struct NotchMetrics {
    let screen: NSScreen
    let detected: CGSize
    let notch: CGSize
    let shift: CGFloat
    let radius: CGFloat
    let ear: CGFloat
    let flare: CGFloat

    static let expandedWidth: CGFloat = PlayerLayout.otherTabsWidth
    static let expandedExtra: CGFloat = 152          // height of the expanded panel below the notch
    static let lyricRow: CGFloat = 32                // extra height when a lyric line is shown
    static let previewExtra: CGFloat = 44            // just the title and artist, below the notch

    /// The display with a notch, or the main display if there isn't one
    static var notchScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func detectedSize(of screen: NSScreen) -> CGSize {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return CGSize(width: screen.frame.width - left.width - right.width,
                          height: screen.safeAreaInsets.top)
        }
        // No notch: draw a notch-sized island in the middle of the menu bar
        let bar = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        return CGSize(width: 190, height: bar)
    }

    private static var cached: NotchMetrics?
    private static var cachedAt = Date.distantPast

    /// Cheap to call often: re-measures at most twice a second, or after the displays change
    static func current() -> NotchMetrics? {
        if let c = cached, Date().timeIntervalSince(cachedAt) < 0.5 { return c }
        cached = fresh()
        cachedAt = Date()
        return cached
    }

    static func invalidate() { cachedAt = .distantPast }

    /// Measures right now, skipping the cache (for the island's own drawing, so tuning shows instantly)
    static func fresh() -> NotchMetrics? {
        guard let screen = notchScreen else { return nil }
        let detected = detectedSize(of: screen)
        let width = max(80, detected.width + NotchDefaults.value("notchWidthAdjust", NotchDefaults.widthAdjust))
        let height = max(18, detected.height + NotchDefaults.value("notchHeightAdjust", NotchDefaults.heightAdjust))
        return NotchMetrics(screen: screen, detected: detected,
                            notch: CGSize(width: width, height: height),
                            shift: CGFloat(NotchDefaults.value("notchShift", NotchDefaults.shift)),
                            radius: CGFloat(NotchDefaults.value("notchRadius", NotchDefaults.radius)),
                            ear: CGFloat(NotchDefaults.value("notchEar", NotchDefaults.ear)),
                            flare: CGFloat(NotchDefaults.flare))
    }

    /// Height of the open island below the notch, which depends on the tab
    static func expandedExtra(tab: IslandTab, lyrics: Bool) -> CGFloat {
        switch tab {
        case .music: return 231
        case .shelf: return 134
        case .timer: return max(132, CGFloat(IslandExtras.timerPresetRows) * 54 + 14)
        case .system: return 184
        }
    }

    /// The island's body size for each state, not counting the top flares
    func islandSize(_ mode: IslandMode, lyrics: Bool = false, tab: IslandTab = .music) -> CGSize {
        // Room for the ring and "59:59" (or "1:02:03") beside the notch, clear of the camera
        // With music playing too, the timer moves into its own bubble instead (liquid split)
        let timerInIsland = IslandExtras.timerActive && !(IslandExtras.musicActive && Extras.split)
        let sideEar = timerInIsland ? max(ear, IslandExtras.timerLong ? 104 : 86) : ear
        let compact = CGSize(width: notch.width + sideEar * 2, height: notch.height)
        switch mode {
        case .idle:
            // The eyes need a little room either side of the camera
            return Extras.eyes ? CGSize(width: notch.width + 52, height: notch.height) : notch
        case .idleHover:
            return CGSize(width: notch.width + (Extras.eyes ? 60 : 14), height: notch.height + 4)
        case .badge:
            return CGSize(width: notch.width + 2 * max(ear, IslandExtras.badgeEar), height: notch.height)
        case .compact:
            return compact
        case .peek:
            return CGSize(width: compact.width + 16, height: compact.height + 4)
        case .preview:
            // The cover sits in the left ear, so the island only needs to be that wide on each side
            return CGSize(width: max(compact.width + 40, notch.width + 2 * PreviewLayout.textLeft),
                          height: notch.height + Self.previewExtra)
        case .hud:
            // Icon and value sit in the ears beside the notch; only the bar hangs below
            return CGSize(width: max(compact.width + 60, notch.width + 170), height: notch.height + 24)
        case .device:
            return CGSize(width: max(compact.width + 40, 360), height: notch.height + 62)
        case .alert:
            return CGSize(width: max(compact.width + 80, 400), height: notch.height + 86)
        case .expanded:
            if tab == .music {
                return CGSize(width: max(PlayerLayout.width(notch), notch.width + ear * 2),
                              height: PlayerLayout.height(notch, lyrics: lyrics))
            }
            return CGSize(width: max(Self.expandedWidth, notch.width + 280),
                          height: notch.height + Self.expandedExtra(tab: tab, lyrics: lyrics))
        }
    }

    /// Where an island of this size sits on screen, in screen coordinates
    func screenRect(_ size: CGSize) -> NSRect {
        let w = size.width + flare * 2
        return NSRect(x: screen.frame.midX + shift - w / 2, y: screen.frame.maxY - size.height,
                      width: w, height: size.height)
    }
}

// MARK: - Shape: flush with the top of the screen, flaring into the bezel, rounded at the bottom

struct NotchShape: Shape {
    var flare: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, radius) }
        set { flare = newValue.first; radius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let f = min(flare, r.width / 4)
        let br = max(0, min(radius, r.height / 2, (r.width - 2 * f) / 2))
        var p = Path()

        // The body: a continuous ("squircle") rounded rectangle whose top corners sit above the screen
        let body = CGRect(x: r.minX + f, y: r.minY - br, width: r.width - 2 * f, height: r.height + br)
        p.addRoundedRect(in: body, cornerSize: CGSize(width: br, height: br), style: .continuous)

        // The flares: small inward curves that melt the top corners into the screen bezel
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addCurve(to: CGPoint(x: r.minX + f, y: r.minY + f),
                   control1: CGPoint(x: r.minX + f * 0.55, y: r.minY),
                   control2: CGPoint(x: r.minX + f, y: r.minY + f * 0.45))
        p.addLine(to: CGPoint(x: r.minX + f, y: r.minY))
        p.closeSubpath()

        p.move(to: CGPoint(x: r.maxX, y: r.minY))
        p.addCurve(to: CGPoint(x: r.maxX - f, y: r.minY + f),
                   control1: CGPoint(x: r.maxX - f * 0.55, y: r.minY),
                   control2: CGPoint(x: r.maxX - f, y: r.minY + f * 0.45))
        p.addLine(to: CGPoint(x: r.maxX - f, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - States

/// What the island is showing, from smallest to largest
enum IslandMode: Equatable {
    case idle          // nothing playing: exactly the notch, so it disappears into it
    case idleHover     // nothing playing, pointer over it: grows a touch to show it's there
    case compact       // music playing: artwork and bars either side of the notch
    case peek          // music playing, pointer over it: a little bigger, ready to click
    case preview       // Quick Preview: the song's name below the notch
    case hud           // volume or brightness level
    case device        // headphones just connected
    case alert         // something needs attention: an app working hard, low battery, heat
    case badge         // a small label beside the notch: keyboard language, Caps Lock
    case expanded      // clicked: the full player
}

/// Short-lived announcements that take over the island for a moment
enum IslandActivity: Equatable {
    case volume(Double, muted: Bool)
    case brightness(Double)
    case device(DeviceInfo)
    case message(symbol: String, title: String, subtitle: String)
    case alert(SystemAlert)
    case definition(WordDefinition)
    case power(BatteryInfo)
    case keyboard(code: String, name: String)
    case capsLock(Bool)
    case screenshot(URL)
    case greeting(Greeting)
    case listening(ListeningMode)

    var isHUD: Bool {
        switch self {
        case .volume, .brightness: return true
        case .device, .message, .alert, .definition, .power, .keyboard, .capsLock, .screenshot, .greeting,
             .listening:
            return false
        }
    }

    /// Activities of the same kind update in place; different kinds animate between shapes
    var kind: Int {
        switch self {
        case .volume, .brightness: return 0
        case .device, .message: return 1
        case .alert: return 2
        case .definition: return 3
        case .power: return 4
        case .keyboard, .capsLock, .listening: return 5
        case .screenshot: return 6
        case .greeting: return 7
        }
    }

    /// Cards with their own buttons, or ones you drag from: clicks there don't open the island
    var handlesOwnClicks: Bool {
        switch self {
        case .alert, .screenshot, .greeting: return true
        default: return false
        }
    }
}

enum IslandTab: Equatable {
    case music, shelf, timer, system
}

final class NotchState: ObservableObject {
    @Published var expanded = false
    @Published var hovering = false
    @Published var previewing = false
    @Published var activity: IslandActivity?
    @Published var tab: IslandTab = .music
    @Published var swipeFlash = 0          // -1 just went back a track, 1 just skipped ahead
    @Published var dragOffset: CGFloat = 0 // follows the pointer during a click-drag swipe
    @Published var pinned = false          // locked open: stays until unlocked
    @Published var pull: CGFloat = 0       // pulled down with the pointer (rubber band)

    func mode(active: Bool) -> IslandMode {
        if expanded { return .expanded }
        if let a = activity {
            switch a {
            case .alert, .definition, .screenshot, .greeting: return .alert   // all the same card shape
            case .keyboard, .capsLock, .listening: return .badge
            default: break
            }
            return a.isHUD ? .hud : .device
        }
        if active && previewing { return .preview }
        if active { return hovering ? .peek : .compact }
        return hovering ? .idleHover : .idle
    }

    @MainActor
    static func isActive(np: NowPlaying, tap: AudioTap) -> Bool {
        let system = UserDefaults.standard.integer(forKey: "source") == AudioSource.system.rawValue
        return np.isPlaying || (system && tap.status == .running) || UserDefaults.standard.bool(forKey: "notchTuning")
            || IslandExtras.timerActive || IslandExtras.definitionReady
    }
}

// The island's motion. Opening is a little bouncy, like the Dynamic Island; closing settles quickly.
enum IslandMotion {
    static var open: Animation { Motion.spring(0.5, 0.74) }
    static var close: Animation { Motion.spring(0.42, 0.9) }
    static var hover: Animation { Motion.spring(0.3, 0.7) }
    static var preview: Animation { Motion.spring(0.48, 0.8) }
}

// MARK: - Window

/// A panel that is allowed to sit over the menu bar and never takes keyboard focus
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Lets the first click on a button work even though the panel is never the active window
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: Content) { super.init(rootView: rootView) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The parts of a scroll event the controller needs, copied out so they can cross to the main actor
struct ScrollInfo {
    let dx: CGFloat
    let dy: CGFloat
    let precise: Bool
    let inverted: Bool
    let began: Bool
    let momentum: Bool
    let windowNumber: Int
}

// MARK: - Controller: pointer tracking, clicks, haptics, song announcements

@MainActor
final class NotchController {
    static let shared = NotchController()

    private var panel: NotchPanel?
    private let state = NotchState()
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var clickMonitors: [Any] = []
    private var trackWatch: AnyCancellable?
    private weak var np: NowPlaying?
    private weak var tap: AudioTap?

    private var leftAt: Date?
    private var previewUntil = Date.distantPast
    private var hoverPreview = false

    // Volume, brightness and headphones
    private let volumeWatcher = VolumeWatcher()
    private var brightnessTimer: Timer?
    private var lastBrightness: Float?
    private var activityUntil = Date.distantPast
    private var startedAt = Date.distantPast
    private var permissionTimer: Timer?

    // Gestures and the file shelf
    private var scrollMonitor: Any?
    private var scrollX: CGFloat = 0
    private var scrollY: CGFloat = 0
    private var scrollFired = false
    private var dragBaseline = NSPasteboard(name: .drag).changeCount
    private var wasDraggingFiles = false

    private let panelSize = NSSize(width: 700, height: 320)

    func setEnabled(_ on: Bool, tap: AudioTap, np: NowPlaying) {
        if on { start(tap: tap, np: np) } else { stop() }
    }

    /// A tap on the Force Touch trackpad. Only felt while a finger is resting on it.
    static func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard UserDefaults.standard.object(forKey: "notchHaptics") as? Bool ?? true else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    private func start(tap: AudioTap, np: NowPlaying) {
        guard panel == nil else { return }
        self.np = np
        self.tap = tap

        let p = NotchPanel(contentRect: NSRect(origin: .zero, size: panelSize),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above the menu bar, on every Space, including next to full-screen apps
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = FirstMouseHostingView(rootView: NotchIslandView(tap: tap, np: np, state: state))
        panel = p
        reposition()
        p.orderFrontRegardless()
        // Lift it onto its own layer above every Space, so it doesn't slide away with a three-finger
        // swipe and stays on the Lock Screen (falls back to the normal behaviour if unavailable)
        if UserDefaults.standard.object(forKey: "notchAllSpaces") as? Bool ?? true {
            SkyLightSpace.adopt(p)
        }

        // Check where the pointer is 60 times a second near the notch, 10 times when it's far away;
        // needs no extra permissions
        tickFast = false
        setTickRate(fast: true)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            NotchMetrics.invalidate()
            Task { @MainActor in NotchController.shared.reposition() }
        }

        // Clicks, drags and releases are judged by where the pointer is, not by which window got them.
        // That way a click counts anywhere the island reacts to hover, even right up in the notch,
        // and a click that slipped through to the menu bar still opens the island.
        let pointerEvents: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: pointerEvents, handler: { e in
            let type = e.type
            Task { @MainActor in NotchController.shared.pointer(type) }
        }) {
            clickMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: pointerEvents, handler: { e in
            let type = e.type
            Task { @MainActor in NotchController.shared.pointer(type) }
            return e
        }) {
            clickMonitors.append(l)
        }

        // Quick Preview: announce each new song
        trackWatch = np.$trackChangeCount
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { _ in
                Task { @MainActor in NotchController.shared.announce() }
            }

        // Two-finger swipes and scrolling over the island
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            let info = ScrollInfo(dx: e.scrollingDeltaX, dy: e.scrollingDeltaY,
                                  precise: e.hasPreciseScrollingDeltas,
                                  inverted: e.isDirectionInvertedFromDevice,
                                  began: e.phase.contains(.began) || e.phase.contains(.mayBegin),
                                  momentum: e.momentumPhase != [],
                                  windowNumber: e.windowNumber)
            Task { @MainActor in NotchController.shared.scrolled(info) }
            return e
        }

        volumeWatcher.onChange = { volume, muted in
            Task { @MainActor in NotchController.shared.showVolume(Double(volume), muted: muted) }
        }
        BluetoothWatcher.shared.onConnect = { device in
            Task { @MainActor in NotchController.shared.deviceConnected(device) }
        }
        BluetoothWatcher.shared.onDisconnect = { device in
            Task { @MainActor in NotchController.shared.deviceDisconnected(device) }
        }
        startedAt = Date()
        OutputRoute.shared.start()
        SystemMonitor.shared.onAlert = { alert in
            Task { @MainActor in NotchController.shared.showAlert(alert) }
        }
        IslandTimer.shared.nowPlaying = np
        IslandTimer.shared.announce = { symbol, title, subtitle in
            NotchController.haptic(.levelChange)
            NotchController.shared.show(.message(symbol: symbol, title: title, subtitle: subtitle), for: 5)
        }
        ClipboardStore.shared.start()
        InputSourceWatcher.shared.onChange = { code, name in
            Task { @MainActor in NotchController.shared.keyboardChanged(code, name) }
        }
        ScreenshotWatcher.shared.onNew = { url in
            Task { @MainActor in NotchController.shared.screenshotTaken(url) }
        }
        HearingMonitor.shared.onWarning = { title, subtitle in
            NotchController.haptic(.levelChange)
            NotchController.shared.show(.message(symbol: "ear.trianglebadge.exclamationmark",
                                                 title: title, subtitle: subtitle), for: 7)
        }
        ListeningModeWatcher.shared.onChange = { mode in
            NotchController.shared.listeningChanged(mode)
        }
        Greeter.shared.show = { g in
            NotchController.haptic(.levelChange)
            NotchController.shared.show(.greeting(g), for: 8)
        }
        PowerWatcher.shared.onChange = { info in
            Task { @MainActor in NotchController.shared.powerChanged(info) }
        }
        stateWatch = state.$tab.combineLatest(state.$expanded)
            .receive(on: RunLoop.main)
            .sink { _ in
                Task { @MainActor in NotchController.shared.updateMonitor() }
            }
        refreshOptions()

        // Starting with no window: say where the app went, so it never looks like it didn't open
        if NotchOnlyMode.isOn {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                self.show(.message(symbol: "rectangle.topthird.inset.filled",
                                   title: "Murmur is in the notch",
                                   subtitle: "Click here for controls · open the app again for the window"),
                          for: 4.5)
            }
        }
    }

    /// Applies the island's switches from settings; safe to call any time
    func refreshOptions() {
        guard panel != nil else { return }
        let d = UserDefaults.standard
        let hud = d.object(forKey: "notchHUD") as? Bool ?? true
        let replace = d.bool(forKey: "notchReplaceHUD")
        let devices = d.object(forKey: "notchDevices") as? Bool ?? true

        if hud {
            volumeWatcher.start()
            if brightnessTimer == nil {
                lastBrightness = Brightness.get()
                brightnessTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
                    Task { @MainActor in NotchController.shared.pollBrightness() }
                }
            }
        } else {
            volumeWatcher.stop()
            brightnessTimer?.invalidate()
            brightnessTimer = nil
        }

        permissionTimer?.invalidate()
        permissionTimer = nil
        if hud && replace {
            if !MediaKeyTap.shared.start() {
                // Ask once, then keep checking until permission is granted or the switch is turned off
                MediaKeyTap.requestPermission()
                permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
                    Task { @MainActor in
                        if MediaKeyTap.shared.start() || !UserDefaults.standard.bool(forKey: "notchReplaceHUD") {
                            t.invalidate()
                        }
                    }
                }
            }
        } else {
            MediaKeyTap.shared.stop()
        }

        if devices { BluetoothWatcher.shared.start() } else { BluetoothWatcher.shared.stop() }
        ClipboardStore.shared.refresh()
        if d.object(forKey: "notchPower") as? Bool ?? true { PowerWatcher.shared.start() } else { PowerWatcher.shared.stop() }
        if Extras.keyboard { InputSourceWatcher.shared.start() } else { InputSourceWatcher.shared.stop() }
        if Extras.screenshots { ScreenshotWatcher.shared.start() } else { ScreenshotWatcher.shared.stop() }
        if Extras.greeting { Greeter.shared.start() } else { Greeter.shared.stop() }
        if HearingMonitor.enabled { HearingMonitor.shared.start() } else { HearingMonitor.shared.stop() }
        if ListeningModeWatcher.enabled { ListeningModeWatcher.shared.start() } else { ListeningModeWatcher.shared.stop() }
        updateMonitor()
    }

    /// The monitor samples in detail only while the System tab is open, and lightly in the
    /// background when alerts are on; otherwise it doesn't run at all
    func updateMonitor() {
        let d = UserDefaults.standard
        let alerts = panel != nil && (d.object(forKey: "sysAlerts") as? Bool ?? true)
        let detail = panel != nil && state.expanded && state.tab == .system
        SystemMonitor.shared.update(detail: detail, alerts: alerts)
    }

    func showAlert(_ alert: SystemAlert) {
        guard panel != nil else { return }
        if state.expanded { collapse() }
        Self.haptic(.levelChange)
        show(.alert(alert), for: 14)
    }

    /// Moves the island above every Space now (the setting was just turned on)
    func adoptSkyLight() {
        if let p = panel { SkyLightSpace.adopt(p) }
    }

    /// The charger was connected or removed
    /// Plugging in makes macOS brighten the screen by itself; that shouldn't cover the charging card
    private var powerChangedAt = Date.distantPast

    func powerChanged(_ info: BatteryInfo) {
        powerChangedAt = Date()
        guard panel != nil, UserDefaults.standard.object(forKey: "notchPower") as? Bool ?? true else { return }
        Self.haptic(.levelChange)
        EyesModel.shared.surprise()
        show(.power(info), for: 4)
    }

    /// Closes whatever announcement is showing
    func dismissActivity() {
        withAnimation(IslandMotion.close) { state.activity = nil }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
        screenObserver = nil
        for m in clickMonitors { NSEvent.removeMonitor(m) }
        clickMonitors = []
        if let m = scrollMonitor { NSEvent.removeMonitor(m) }
        scrollMonitor = nil
        trackWatch = nil
        volumeWatcher.stop()
        brightnessTimer?.invalidate()
        brightnessTimer = nil
        permissionTimer?.invalidate()
        permissionTimer = nil
        MediaKeyTap.shared.stop()
        BluetoothWatcher.shared.stop()
        stateWatch = nil
        SystemMonitor.shared.update(detail: false, alerts: false)
        ClipboardStore.shared.stop()
        PowerWatcher.shared.stop()
        InputSourceWatcher.shared.stop()
        ScreenshotWatcher.shared.stop()
        HearingMonitor.shared.stop()
        ListeningModeWatcher.shared.stop()
        Greeter.shared.stop()
        EyesModel.shared.setRunning(false)
        state.activity = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        state.expanded = false
        state.hovering = false
        state.previewing = false
    }

    func reposition() {
        guard let p = panel, let m = NotchMetrics.current() else { return }
        let frame = NSRect(x: m.screen.frame.midX - panelSize.width / 2,
                           y: m.screen.frame.maxY - panelSize.height,
                           width: panelSize.width, height: panelSize.height)
        p.setFrame(frame, display: true)
    }

    // MARK: Actions

    func expand(tab: IslandTab? = nil) {
        if let t = tab, state.expanded, state.tab != t {
            withAnimation(.easeInOut(duration: 0.2)) { state.tab = t }
        }
        guard !state.expanded else { return }
        Self.haptic(.levelChange)
        hoverPreview = false
        previewUntil = .distantPast
        leftAt = nil
        np?.checkAutomation(ask: false)
        withAnimation(IslandMotion.open) {
            if let t = tab { state.tab = t }
            state.previewing = false
            state.activity = nil
            state.expanded = true
        }
        panel?.ignoresMouseEvents = false
    }

    // MARK: Activities

    func show(_ activity: IslandActivity, for seconds: Double) {
        guard panel != nil else { return }
        if state.expanded {
            if case .alert = activity {} else { return }
        }
        activityUntil = Date().addingTimeInterval(seconds)
        if let current = state.activity, current.kind == activity.kind {
            // Same kind already showing: just update the numbers
            withAnimation(.easeOut(duration: 0.15)) { state.activity = activity }
        } else {
            withAnimation(IslandMotion.preview) { state.activity = activity }
        }
    }

    func showVolume(_ level: Double, muted: Bool) {
        // Ignore the burst of reports while starting up or when the output device switches
        guard Date().timeIntervalSince(startedAt) > 1.5 else { return }
        guard !CurveCalibrator.running else { return }      // the AirPods measurement steps the volume
        show(.volume(level, muted: muted), for: 1.6)
    }

    func showBrightness(_ level: Double) {
        lastBrightness = Float(level)
        show(.brightness(level), for: 1.6)
    }

    fileprivate func pollBrightness() {
        guard let b = Brightness.get() else { return }
        defer { lastBrightness = b }
        // Key presses move it quickly; automatic brightness drifts slowly and is ignored
        if let last = lastBrightness, abs(b - last) > 0.012 {
            // For a few seconds after plugging in or unplugging, the change is macOS's own
            // (it brightens on power), so the charging card stays on show
            if Date().timeIntervalSince(powerChangedAt) < 5 { return }
            if case .power? = state.activity { return }
            show(.brightness(Double(b)), for: 1.6)
        }
    }

    fileprivate func deviceDisconnected(_ device: IOBluetoothDevice) {
        ListeningModeWatcher.shared.rescan()
        guard var info = BluetoothWatcher.info(for: device) else { return }
        info.connected = false
        info.left = nil; info.right = nil; info.caseLevel = nil; info.single = nil
        show(.device(info), for: 2.6)
    }

    fileprivate func deviceConnected(_ device: IOBluetoothDevice) {
        ListeningModeWatcher.shared.rescan()
        guard let info = BluetoothWatcher.info(for: device) else { return }
        Self.haptic(.levelChange)
        show(.device(info), for: 4.5)
        // AirPods report their battery a moment after connecting
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard case .device(let shown)? = self.state.activity, shown.name == info.name,
                  let fresh = BluetoothWatcher.info(for: device), fresh != shown else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.state.activity = .device(fresh) }
        }
    }

    // MARK: Gestures

    /// Skips forward or back, with a tap on the trackpad and a little arrow in the island
    func swipe(next: Bool) {
        guard let np = np, np.spotifyRunning else { return }
        if next { np.nextTrack() } else { np.previousTrack() }
        Self.haptic(.levelChange)
        let direction = next ? 1 : -1
        withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { state.swipeFlash = direction }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if self.state.swipeFlash == direction {
                withAnimation(.easeOut(duration: 0.25)) { self.state.swipeFlash = 0 }
            }
        }
    }

    fileprivate func scrolled(_ e: ScrollInfo) {
        guard let p = panel, e.windowNumber == p.windowNumber, !state.expanded, !e.momentum else { return }
        let d = UserDefaults.standard

        // Which way the fingers actually moved, whatever the natural-scrolling setting
        let fx = e.inverted ? e.dx : -e.dx
        let fy = e.inverted ? e.dy : -e.dy

        if !e.precise {
            // A mouse wheel: each notch is one volume step
            if d.object(forKey: "notchScrollVolume") as? Bool ?? true, e.dy != 0 {
                SystemVolume.step(e.dy > 0 ? 1.0 / 16 : -1.0 / 16)
            }
            return
        }

        if e.began { scrollX = 0; scrollY = 0; scrollFired = false }
        scrollX += fx
        scrollY += fy

        if abs(scrollX) > abs(scrollY) {
            // Sideways: one skip per swipe
            guard d.object(forKey: "notchSwipe") as? Bool ?? true, !scrollFired, abs(scrollX) > 45 else { return }
            scrollFired = true
            swipe(next: scrollX < 0)
        } else if d.object(forKey: "notchScrollVolume") as? Bool ?? true {
            // Up and down: volume, in small steps as the fingers move
            let stepSize: CGFloat = 14
            while scrollY <= -stepSize { SystemVolume.step(1.0 / 32); scrollY += stepSize }
            while scrollY >= stepSize { SystemVolume.step(-1.0 / 32); scrollY -= stepSize }
        }
    }

    func collapse() {
        guard state.expanded else { return }
        state.pinned = false
        ClipboardStore.shared.reading = nil
        leftAt = nil
        withAnimation(IslandMotion.close) {
            state.expanded = false
            state.hovering = false
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            if !self.state.expanded { self.state.tab = .music }
        }
        panel?.ignoresMouseEvents = true
    }

    private func announce() {
        guard UserDefaults.standard.object(forKey: "notchAnnounce") as? Bool ?? true,
              !state.expanded else { return }
        previewUntil = Date().addingTimeInterval(4)
    }

    /// The area that reacts to the pointer while the island is closed: the island itself,
    /// plus a little room below and at the sides so it's easy to hit
    private func hotRect(_ m: NotchMetrics, _ rect: NSRect) -> NSRect {
        var hot = rect.insetBy(dx: -6, dy: 0)
        hot.origin.y -= 8
        hot.size.height += 8 + 4      // and a few points above, in case the pointer is pushed into the edge
        return hot
    }

    private var pressStart: NSPoint?

    /// Whether the open island shows a lyric line (it's a little taller when it does)
    private var stateWatch: AnyCancellable?

    private var lyricRow: Bool {
        guard let np = np, !np.lyrics.isEmpty, state.tab == .music else { return false }
        return UserDefaults.standard.object(forKey: "notchLyrics") as? Bool ?? true
    }

    fileprivate func pointer(_ type: NSEvent.EventType) {
        guard panel != nil, let m = NotchMetrics.current(), let np = np, let tap = tap else { return }
        let mouse = NSEvent.mouseLocation

        if state.expanded {
            // Clicking anywhere else closes it
            if type == .leftMouseDown || type == .rightMouseDown {
                let rect = m.screenRect(m.islandSize(.expanded, lyrics: lyricRow, tab: state.tab)).insetBy(dx: -4, dy: -4)
                if !rect.contains(mouse) && !state.pinned { collapse() }
            }
            return
        }

        let active = NotchState.isActive(np: np, tap: tap)
        let rect = m.screenRect(m.islandSize(state.mode(active: active)))
        let swipeOn = UserDefaults.standard.object(forKey: "notchSwipe") as? Bool ?? true

        switch type {
        case .leftMouseDown:
            if let a = state.activity, a.handlesOwnClicks { pressStart = nil; return }
            pressStart = hotRect(m, rect).contains(mouse) ? mouse : nil
        case .leftMouseDragged:
            guard let start = pressStart else { return }
            let dx = mouse.x - start.x
            let down = start.y - mouse.y
            if Extras.jelly && down > 4 && down > abs(dx) {
                // Pulling down stretches it like a rubber band
                state.pull = 22 * (1 - exp(-down / 45))
                state.dragOffset = 0
            } else if swipeOn {
                state.dragOffset = dx
                if state.pull != 0 { state.pull = 0 }
            }
        case .leftMouseUp:
            guard let start = pressStart else { return }
            pressStart = nil
            let dx = mouse.x - start.x
            let dy = mouse.y - start.y
            if state.pull > 0 {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) { state.pull = 0 }
            }
            if Extras.jelly && -dy > 36 && -dy > abs(dx) {
                expand()
            } else if abs(dx) < 8 && abs(dy) < 8 {
                if case .alert? = state.activity {
                    // its own buttons handle the click
                } else if case .definition(let d)? = state.activity {
                    DictionaryApp.open(d.word)
                    dismissActivity()
                } else {
                    expand()
                }
            } else if swipeOn && abs(dx) > 40 && abs(dx) > abs(dy) {
                swipe(next: dx < 0)
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.62)) { state.dragOffset = 0 }
        default:
            break
        }
    }

    // MARK: Pointer tracking

    private var tickFast = true
    private var lastDragCheck = Date.distantPast
    private var lastCaps = NSEvent.modifierFlags.contains(.capsLock)

    func keyboardChanged(_ code: String, _ name: String) {
        guard panel != nil, Extras.keyboard else { return }
        Self.haptic(.alignment)
        // Wide enough for the layout's name ("Simple Telex") to sit fully beside the notch
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let textWidth = (name as NSString).size(withAttributes: [.font: font]).width
        IslandExtras.badgeEar = min(150, max(74, ceil(textWidth) + 28))
        show(.keyboard(code: code, name: name), for: 1.4)
    }

    func listeningChanged(_ mode: ListeningMode) {
        guard panel != nil, ListeningModeWatcher.enabled else { return }
        Self.haptic(.alignment)
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let textWidth = (mode.title as NSString).size(withAttributes: [.font: font]).width
        IslandExtras.badgeEar = min(170, max(74, ceil(textWidth) + 28 + 26))    // name plus the rings
        show(.listening(mode), for: 1.8)
    }

    func screenshotTaken(_ url: URL) {
        guard panel != nil, Extras.screenshots else { return }
        Self.haptic(.levelChange)
        EyesModel.shared.surprise()
        show(.screenshot(url), for: 7)
    }

    /// 60 checks a second while the pointer is near the island or something is happening, 10 otherwise.
    /// Hover still feels instant: the pointer has to cross the slow zone before it reaches the notch.
    private func setTickRate(fast: Bool) {
        guard fast != tickFast || timer == nil else { return }
        tickFast = fast
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: fast ? 1.0 / 60 : 0.1, repeats: true) { _ in
            Task { @MainActor in NotchController.shared.tick() }
        }
        timer?.tolerance = fast ? 0.002 : 0.03      // lets macOS group wake-ups when idle
    }

    private func tick() {
        guard let p = panel, let m = NotchMetrics.current(), let np = np, let tap = tap else { return }
        let mouse = NSEvent.mouseLocation
        let now = Date()
        let active = NotchState.isActive(np: np, tap: tap)
        let rect = m.screenRect(m.islandSize(state.mode(active: active), lyrics: lyricRow, tab: state.tab))
        let mouseDown = NSEvent.pressedMouseButtons & 1 != 0

        let near = rect.insetBy(dx: -180, dy: -160).contains(mouse)
        let busy = state.expanded || state.hovering || state.previewing || state.activity != nil
            || mouseDown || pressStart != nil
        setTickRate(fast: near || busy)

        // Music (not just a timer) decides whether the timer gets its own bubble
        let system = UserDefaults.standard.integer(forKey: "source") == AudioSource.system.rawValue
        IslandExtras.musicActive = np.isPlaying || (system && tap.status == .running)
            || UserDefaults.standard.bool(forKey: "notchTuning")

        // Caps Lock: read from the keyboard state already in memory, no permission needed
        let caps = NSEvent.modifierFlags.contains(.capsLock)
        if caps != lastCaps {
            lastCaps = caps
            if Extras.keyboard && !state.expanded {
                Self.haptic(.alignment)
                IslandExtras.badgeEar = 74
                show(.capsLock(caps), for: 1.1)
            }
        }

        // The eyes, when nothing else is out
        let eyes = Extras.eyes && !active && !state.expanded
        EyesModel.shared.setRunning(eyes)
        if eyes {
            EyesModel.shared.follow(mouse: mouse, from: NSPoint(x: rect.midX, y: rect.maxY - m.notch.height / 2))
        }

        // Announcements time out on their own
        if state.activity != nil, now > activityUntil, !state.hovering {
            withAnimation(IslandMotion.close) { state.activity = nil }
        }

        // Dragging files from anywhere towards the notch opens the shelf
        // (Reading the drag pasteboard asks another process, so the baseline is refreshed at most
        // 10 times a second; the drag pasteboard only changes when a drag starts, so that's enough)
        let dragBoard = NSPasteboard(name: .drag)
        if !mouseDown, now.timeIntervalSince(lastDragCheck) > 0.1 {
            dragBaseline = dragBoard.changeCount
            lastDragCheck = now
        }
        let draggingFiles = mouseDown && dragBoard.changeCount != dragBaseline
            && (dragBoard.types?.contains(.fileURL) ?? false)
        let shelfOn = UserDefaults.standard.object(forKey: "notchShelf") as? Bool ?? true

        // Backup for the drop itself: files let go over the open shelf are taken straight from the
        // drag, even if the drop never reached the island (adding the same file twice does nothing)
        let releasedFiles = wasDraggingFiles && !mouseDown
        wasDraggingFiles = draggingFiles
        if releasedFiles, shelfOn, state.expanded, state.tab == .shelf,
           rect.insetBy(dx: -12, dy: -12).contains(mouse) {
            ShelfStore.shared.add(ShelfStore.urls(on: dragBoard))
        }

        if draggingFiles, shelfOn {
            var zone = m.screenRect(m.islandSize(.compact))
            zone = zone.insetBy(dx: -140, dy: 0)
            zone.origin.y -= 120
            zone.size.height += 120
            if zone.contains(mouse) {
                // Dragging files in shows the files, even if the shelf was last on the clipboard
                if UserDefaults.standard.string(forKey: "shelfMode") != "files" {
                    UserDefaults.standard.set("files", forKey: "shelfMode")
                }
                expand(tab: .shelf)
                leftAt = nil
                return
            }
        }

        if state.expanded {
            // Never close in the middle of a drag (dropping onto, or dragging out of, the shelf)
            if mouseDown { leftAt = nil; return }
            // Stay open while the pointer is on it or close by (or while locked open);
            // close shortly after it leaves
            if state.pinned || rect.insetBy(dx: -16, dy: -16).contains(mouse) {
                leftAt = nil
            } else {
                if leftAt == nil { leftAt = now }
                if let t = leftAt, now.timeIntervalSince(t) > 0.5 { collapse() }
            }
            return
        }

        // Mid-swipe: keep catching the pointer even if it slides off the island
        if pressStart != nil || (mouseDown && !p.ignoresMouseEvents) { return }

        // The timer's bubble beside the island counts as part of it
        let bubble = IslandExtras.timerActive && IslandExtras.musicActive && Extras.split
            && !state.expanded && state.activity == nil
            ? NSRect(x: rect.maxX - m.flare + BubbleLayout.gap, y: rect.maxY - m.notch.height,
                     width: BubbleLayout.width, height: m.notch.height).insetBy(dx: -4, dy: -4)
            : .zero
        let inside = hotRect(m, rect).contains(mouse) || bubble.contains(mouse)

        if inside != state.hovering {
            if inside { Self.haptic(.alignment) }
            withAnimation(IslandMotion.hover) { state.hovering = inside }
        }

        // A word was just copied: pointing at the island shows what it means
        if inside, !state.expanded, state.activity == nil, IslandExtras.definitionReady,
           let d = ClipboardStore.shared.takeDefinition() {
            Self.haptic(.generic)
            show(.definition(d), for: 1.2)
        }

        // Hovering the artwork on the left opens Quick Preview, which stays while the pointer is on it
        if !inside {
            hoverPreview = false
        } else if active && !hoverPreview && state.activity == nil {
            let artZone = NSRect(x: rect.minX - 6, y: rect.minY - 8, width: m.flare + m.ear + 16, height: rect.height + 12)
            if artZone.contains(mouse) {
                hoverPreview = true
                Self.haptic(.generic)
            }
        }

        let wantPreview = active && (hoverPreview || now < previewUntil)
        if wantPreview != state.previewing {
            withAnimation(IslandMotion.preview) { state.previewing = wantPreview }
        }

        // Only catch clicks while the pointer is over the island; otherwise the menu bar works as normal
        let catches = state.hovering
        if p.ignoresMouseEvents == catches { p.ignoresMouseEvents = !catches }
    }
}

// MARK: - The island

/// Shared by the small and large meters so they move together
final class NotchMeter {
    let processor = BandProcessor(particles: false)
    private let edge = BeatEdge()

    /// Passes the start of each beat on to the island's pulse (from the frame that's drawing anyway)
    func report(_ beat: Float) {
        guard edge.rose(beat) else { return }
        let strength = Double(beat)
        Task { @MainActor in NotchPulse.shared.hit(strength) }
    }
}

/// Content fades out fast before the shape shrinks, and fades in once the shape has grown,
/// so nothing gets squashed mid-animation
extension AnyTransition {
    static var islandContent: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.94, anchor: .top))
                .animation(.easeOut(duration: 0.26).delay(0.12)),
            removal: .opacity.animation(.easeIn(duration: 0.09))
        )
    }
}

/// Type sizes and colours, kept in one place so every state matches
enum IslandType {
    static let title = Font.system(size: 14, weight: .semibold)
    static let subtitle = Font.system(size: 12, weight: .regular)
    static let small = Font.system(size: 10, weight: .medium).monospacedDigit()
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.35)
}

struct NotchIslandView: View {
    @ObservedObject var tap: AudioTap
    @ObservedObject var np: NowPlaying
    @ObservedObject var state: NotchState
    @ObservedObject private var route = OutputRoute.shared

    // Re-read so tuning changes show immediately
    @AppStorage("notchWidthAdjust") private var widthAdjust = NotchDefaults.widthAdjust
    @AppStorage("notchHeightAdjust") private var heightAdjust = NotchDefaults.heightAdjust
    @AppStorage("notchShift") private var shift = NotchDefaults.shift
    @AppStorage("notchRadius") private var radius = NotchDefaults.radius
    @AppStorage("notchEar") private var ear = NotchDefaults.ear
    @AppStorage("notchTuning") private var tuning = false
    @AppStorage("notchLyrics") private var notchLyrics = true
    @AppStorage("colourIndex") private var colourIndex = 0
    @AppStorage("source") private var sourceIndex = 0
    @AppStorage("notchShelf") private var shelfEnabled = true
    @AppStorage("sysTab") private var systemTabEnabled = true
    @AppStorage("timerTab") private var timerTabEnabled = true
    @AppStorage("shelfMode") private var shelfMode = "files"
    @ObservedObject private var timer = IslandTimer.shared
    @ObservedObject private var clipboard = ClipboardStore.shared
    @ObservedObject private var pulse = NotchPulse.shared
    @ObservedObject private var hearing = HearingMonitor.shared
    @AppStorage("funEyes") private var eyesOn = false
    @AppStorage("funFlip") private var flipOn = true
    @AppStorage("funSplit") private var splitOn = true
    @AppStorage("funJelly") private var jellyOn = true
    @State private var squish = false

    @State private var artRamp = Ramp.ember
    @State private var meter = NotchMeter()
    @State private var dropTargeted = false
    @State private var cornerHover = false

    /// The tabs stay out of sight on the player (like the reference) until you point at the corner;
    /// on the other tabs they always show, so you can get back
    @AppStorage("notchTabsAlways") private var tabsAlways = true
    /// The tab switcher shows all the time, or on the music tab only when the corner is hovered
    private var showTabs: Bool { tabsAlways || cornerHover || state.tab != .music }
    private var hasTabs: Bool { shelfEnabled || systemTabEnabled || timerTabEnabled }
    @Namespace private var tabSpace

    private var ramp: Ramp { (Palette(rawValue: colourIndex) ?? .art).ramp(art: artRamp) }
    private var accent: Color { ramp.color(0) }
    private var systemMode: Bool { sourceIndex == AudioSource.system.rawValue }
    /// Music (or system audio) is playing
    private var musicActive: Bool { np.isPlaying || (systemMode && tap.status == .running) || tuning }
    /// Anything that keeps the island out beside the notch: music, a timer, a word to look up
    private var active: Bool { musicActive || timer.isActive || clipboard.pendingDefinition != nil }
    /// Music and a timer at once: the timer gets its own bubble beside the island
    private var splitTimer: Bool { splitOn && musicActive && timer.isActive }

    var body: some View {
        // Reading the settings here makes the view redraw when any of them change
        let _ = (widthAdjust, heightAdjust, shift, ear)
        let m = NotchMetrics.fresh()
        let notch = m?.notch ?? CGSize(width: 190, height: 32)
        let flare = CGFloat(NotchDefaults.flare)
        let mode = state.mode(active: active)
        let size = m?.islandSize(mode, lyrics: showLyricRow, tab: state.tab) ?? notch
        let corner = cornerRadius(mode)
        let lifted = mode == .expanded || mode == .preview || mode == .hud || mode == .device

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(flare: flare, radius: corner)
                    .fill(Color.black)
                if tuning {
                    NotchShape(flare: flare, radius: corner)
                        .stroke(accent, lineWidth: 1.5)
                }

                Group {
                    switch mode {
                    case .expanded:
                        expanded(notch: notch)
                            .padding(.horizontal, 20)
                    case .preview:
                        quickPreview(notch: notch)          // lays itself out edge to edge
                    case .hud:
                        if let a = state.activity {
                            LevelView(activity: a, notch: notch)
                                .padding(.horizontal, 18)
                        }
                    case .device:
                        if case .device(let info)? = state.activity {
                            DeviceActivityView(info: info, notch: notch)
                                .padding(.horizontal, 18)
                        } else if case .message(let symbol, let title, let subtitle)? = state.activity {
                            IslandMessage(symbol: symbol, title: title, subtitle: subtitle, notch: notch)
                                .padding(.horizontal, 18)
                        } else if case .power(let info)? = state.activity {
                            PowerActivityView(info: info, notch: notch)
                                .padding(.horizontal, 18)
                        }
                    case .alert:
                        if case .alert(let a)? = state.activity {
                            AlertView(alert: a, notch: notch)
                                .padding(.horizontal, 18)
                        } else if case .definition(let d)? = state.activity {
                            DefinitionCard(definition: d, notch: notch)
                                .padding(.horizontal, 18)
                        } else if case .screenshot(let url)? = state.activity {
                            ScreenshotCard(url: url, notch: notch)
                                .padding(.horizontal, 18)
                        } else if case .greeting(let g)? = state.activity {
                            GreetingCard(greeting: g, notch: notch)
                                .padding(.horizontal, 18)
                        }
                    case .badge:
                        if let a = state.activity {
                            BadgeView(activity: a, notch: notch)
                                .padding(.horizontal, 10)
                        }
                    case .compact, .peek:
                        collapsed(notch: notch)
                            .padding(.horizontal, 9)
                    case .idle, .idleHover:
                        if eyesOn {
                            EyesView(notch: notch)
                        } else {
                            Color.clear
                        }
                    }
                }
                .padding(.horizontal, flare)
                .id(contentID(mode))
                .transition(.islandContent)

                // The artwork is one view that moves and grows between states, so opening the island
                // carries the cover from beside the notch into the player, like the Dynamic Island
                let art = artPlacement(mode, notch: notch, flare: flare)
                thumb(size: art.size, corner: art.corner)
                    .shadow(color: .black.opacity(art.shadow ? 0.4 : 0), radius: 8, y: 3)
                    .scaleEffect(art.visible ? 1 : 0.6)
                    .opacity(art.visible ? 1 : 0)
                    .position(x: art.center.x, y: art.center.y)
                    .allowsHitTesting(false)

                // A small arrow on the side you swiped towards
                if state.swipeFlash != 0 && mode != .expanded {
                    HStack {
                        if state.swipeFlash > 0 { Spacer(minLength: 0) }
                        Image(systemName: state.swipeFlash > 0 ? "forward.fill" : "backward.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(width: notch.height - 12, height: notch.height - 12)
                            .background(Circle().fill(Color.white.opacity(0.18)))
                        if state.swipeFlash < 0 { Spacer(minLength: 0) }
                    }
                    .padding(.horizontal, flare + 9)
                    .frame(height: notch.height)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .frame(width: size.width + flare * 2, height: size.height)
            .clipShape(NotchShape(flare: flare, radius: corner))
            .contentShape(NotchShape(flare: flare, radius: corner))
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard shelfEnabled else { return false }
                ShelfStore.load(providers)
                NotchController.shared.expand(tab: .shelf)
                return true
            }
            // The timer's own bubble, pulled out of the island like liquid
            .overlay(alignment: .topTrailing) {
                if splitTimer && (mode == .compact || mode == .peek) {
                    TimerBubble(height: notch.height)
                        // Only the bubble stretches and settles; it never pulls the island with it
                        .transition(.goo(height: notch.height)
                            .animation(.spring(response: 0.5, dampingFraction: 0.8)))
                        .offset(x: BubbleLayout.gap + BubbleLayout.width - flare)
                }
            }
            // The island itself resizes without overshooting, so it never dips inwards
            .animation(.spring(response: 0.45, dampingFraction: 0.95), value: splitTimer && (mode == .compact || mode == .peek))
            // A glow in the album's colours that swells with each beat
            .shadow(color: accent.opacity(beatGlow(mode) * 0.7), radius: 9)
            .shadow(color: .black.opacity(lifted ? 0.35 : 0), radius: 24, y: 10)
            .scaleEffect(x: jellyScale(mode).width, y: jellyScale(mode).height, anchor: .top)
            .offset(x: CGFloat(shift))

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(IslandMotion.hover, value: active)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: radius)
        .preferredColorScheme(.dark)
        .onReceive(np.$artwork) { img in
            if let img = img { artRamp = img.dominantRamp() }
        }
        .onChange(of: state.hovering) { h in
            // A little squash when the pointer arrives, like poking jelly
            guard h, jellyOn, !state.expanded else { return }
            withAnimation(.spring(response: 0.16, dampingFraction: 0.5)) { squish = true }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 110_000_000)
                withAnimation(.spring(response: 0.5, dampingFraction: 0.42)) { squish = false }
            }
        }
        .onAppear { IslandExtras.musicActive = musicActive }
        .onChange(of: musicActive) { IslandExtras.musicActive = $0 }
    }

    /// How strongly the beat glow shows (only beside the notch, never over open panels)
    private func beatGlow(_ mode: IslandMode) -> Double {
        (mode == .compact || mode == .peek) && musicActive ? pulse.level : 0
    }

    /// Beat swell + hover squash + swipe stretch + pull-down, all as one scale
    private func jellyScale(_ mode: IslandMode) -> CGSize {
        var x: CGFloat = 1, y: CGFloat = 1
        if mode == .compact || mode == .peek {
            let beat = musicActive ? CGFloat(pulse.level) : 0
            x += beat * 0.012
            y += beat * 0.06
        }
        guard jellyOn else { return CGSize(width: x, height: y) }
        if squish { x += 0.03; y -= 0.07 }
        let drag = min(0.05, abs(state.dragOffset) / 900)
        x += drag
        y -= drag * 0.6
        if state.pull > 0 {
            let h = max(20, NotchMetrics.current()?.notch.height ?? 32)
            y += state.pull / h
            x -= state.pull / 900
        }
        return CGSize(width: x, height: y)
    }

    private struct ArtPlacement {
        var center: CGPoint
        var size: CGFloat
        var corner: CGFloat
        var visible: Bool
        var shadow: Bool
    }

    /// Where the artwork sits in each state (these match the gaps left for it in each layout)
    private func artPlacement(_ mode: IslandMode, notch: CGSize, flare: CGFloat) -> ArtPlacement {
        let small = max(14, notch.height - 14)
        let drag = max(-14, min(14, state.dragOffset * 0.25))
        var p = ArtPlacement(center: CGPoint(x: flare + 9 + small / 2 + drag, y: notch.height / 2),
                             size: small, corner: 5, visible: false, shadow: false)
        switch mode {
        case .compact, .peek:
            p.visible = musicActive
        case .preview:
            let half = PreviewLayout.artSize / 2
            p = ArtPlacement(center: CGPoint(x: flare + PreviewLayout.artLeft + half, y: PreviewLayout.artTop + half),
                             size: PreviewLayout.artSize, corner: 12, visible: true, shadow: false)
        case .expanded:
            let half = PlayerLayout.artSize / 2
            p = ArtPlacement(center: CGPoint(x: flare + PlayerLayout.artLeft + half, y: PlayerLayout.artTop + half),
                             size: PlayerLayout.artSize, corner: 14, visible: state.tab == .music, shadow: true)
        case .idle, .idleHover, .hud, .device, .alert, .badge:
            break
        }
        return p
    }

    /// The cover's top edge in the open player: tucked up beside the notch, low enough that the
    /// title next to it clears the notch

    private func cornerRadius(_ mode: IslandMode) -> CGFloat {
        switch mode {
        case .expanded: return 30
        case .preview: return 22
        case .device, .alert: return 26
        case .hud: return 22
        case .peek, .idleHover: return CGFloat(radius) + 2
        case .compact, .idle, .badge: return CGFloat(radius)
        }
    }

    /// Compact and peek share content, so hovering doesn't fade it out and back in
    private func contentID(_ mode: IslandMode) -> String {
        switch mode {
        case .compact, .peek: return "compact"
        case .idle, .idleHover: return "idle"
        case .preview: return "preview"
        case .hud: return "hud"
        case .device: return "device"
        case .alert: return "alert"
        case .badge: return "badge"
        case .expanded: return "expanded"
        }
    }

    // MARK: Compact: artwork on the left ear, a small waveform on the right

    /// Left: the cover (or what the island is out for). Right: the timer, a copied word waiting to
    /// be looked up, or the waveform.
    private func collapsed(notch: CGSize) -> some View {
        let icon = max(14, notch.height - 14)
        return HStack {
            if musicActive {
                Color.clear.frame(width: icon, height: icon)
            } else {
                Image(systemName: timer.isActive ? "timer" : "character.book.closed.fill")
                    .font(.system(size: icon * 0.7, weight: .semibold))
                    .foregroundStyle(timer.isActive ? TimerColour.of(timer.phase) : Color.white.opacity(0.85))
                    .frame(width: icon, height: icon)
            }
            Spacer(minLength: 0)
            if timer.isActive && !splitTimer {
                TimerEar(height: notch.height)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else if clipboard.pendingDefinition != nil && musicActive {
                Image(systemName: "character.book.closed.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .help("Hover to see what it means")
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            } else if musicActive {
                MiniBars(tap: tap, meter: meter, ramp: ramp, count: 4, reportsBeats: true)
                    .frame(width: min(22, max(12, CGFloat(ear) - 16)), height: max(10, notch.height - 18))
                    .id(flipOn ? np.trackChangeCount : 0)
                    .transition(.asymmetric(insertion: .scale(scale: 0.2, anchor: .bottom).combined(with: .opacity)
                                                .animation(.spring(response: 0.45, dampingFraction: 0.6).delay(0.2)),
                                            removal: .scale(scale: 1.6).combined(with: .opacity)
                                                .animation(.easeOut(duration: 0.2))))
            }
        }
        .frame(height: notch.height)
        .animation(Motion.spring(0.35, 0.85), value: timer.isActive)
        .animation(Motion.spring(0.35, 0.85), value: clipboard.pendingDefinition)
    }

    // MARK: Quick Preview: the new song, laid out like a Live Activity

    /// The cover rises into the left ear beside the notch, the waveform sits in the right ear,
    /// and only the title and artist hang below, so the preview is barely taller than the notch
    private func quickPreview(notch: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            HStack {
                Spacer(minLength: 0)
                MiniBars(tap: tap, meter: meter, ramp: ramp, count: 4)
                    .frame(width: 20, height: max(10, min(14, notch.height - 18)))
            }
            .padding(.trailing, 16)
            .frame(height: notch.height)

            VStack(alignment: .leading, spacing: 1) {
                MarqueeText(text: titleText, font: IslandType.title, color: .white, height: 19)
                MarqueeText(text: artistText, font: IslandType.subtitle, color: IslandType.secondary, height: 16)
            }
            .padding(.leading, PreviewLayout.textLeft)
            .padding(.trailing, 16)
            .padding(.top, notch.height + 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Expanded: tabs and output device beside the notch, then the player or the shelf

    private func expanded(notch: CGSize) -> some View {
        ZStack(alignment: .top) {
            // The strip beside the notch: a label on the left (except on Music, where the cover
            // rises into that space), the tabs and a menu on the right
            HStack(spacing: 6) {
                switch state.tab {
                case .system: systemTitle
                case .shelf: shelfSwitch
                case .timer:
                    Text("Timer")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IslandType.secondary)
                case .music: Text("")
                }
                Spacer(minLength: notch.width + 12)
                // On the music tab the ear beside the notch is narrow, so everything is a size smaller
                // and sits a little closer to the edge
                HStack(spacing: 2) {
                    if state.tab != .music {
                        pinButton
                            .opacity(cornerHover || state.pinned ? 1 : 0)
                            .scaleEffect(cornerHover || state.pinned ? 1 : 0.6)
                    }
                    tabSwitcher(compact: true)
                }
                .padding(.trailing, state.tab == .music ? -14 : 0)
                .opacity(showTabs ? 1 : 0)
                .animation(Motion.spring(0.3, 0.85), value: showTabs)
                .contentShape(Rectangle())
                .onHover { cornerHover = $0 }
            }
            .frame(height: notch.height)

            Group {
                switch state.tab {
                case .music:
                    musicCard(notch: notch)
                        .padding(.horizontal, -20)        // the player lays itself out edge to edge
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                case .shelf:
                    Group {
                        if shelfMode == "clipboard" && !dropTargeted {
                            ClipboardView()
                        } else {
                            ShelfView(accent: accent, targeted: dropTargeted)
                        }
                    }
                    .padding(.top, notch.height + 8)
                    .padding(.bottom, 14)
                    .transition(.opacity)
                case .timer:
                    TimerTabView()
                        .padding(.top, notch.height + 8)
                        .padding(.bottom, 14)
                        .transition(.opacity)
                case .system:
                    SystemTabView()
                        .padding(.top, notch.height + 8)
                        .padding(.bottom, 14)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
        }
        .onChange(of: dropTargeted) { over in
            if over && shelfEnabled { withAnimation(.easeInOut(duration: 0.2)) { state.tab = .shelf } }
        }
    }

    private func tabItem(_ tab: IslandTab, _ title: String) -> some View {
        Button {
            withAnimation(Motion.spring(0.4, 0.85)) { state.tab = tab }
        } label: {
            if state.tab == tab { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private func togglePin() {
        NotchController.haptic(.levelChange)
        withAnimation(Motion.spring(0.3, 0.8)) { state.pinned.toggle() }
    }

    private var pinButton: some View {
        Button { togglePin() } label: {
            PinIcon(pinned: state.pinned)
        }
        .buttonStyle(PressableStyle())
        .help(state.pinned ? "Unlock (close when the pointer leaves)" : "Lock open")
    }

    /// An on/off setting for the menu; turning one on or off starts or stops what it needs
    private func quick(_ key: String, _ fallback: Bool) -> Binding<Bool> {
        Binding(get: { UserDefaults.standard.object(forKey: key) as? Bool ?? fallback },
                set: { on in
                    UserDefaults.standard.set(on, forKey: key)
                    NotchController.shared.refreshOptions()
                })
    }

    /// "System" with an expand arrow: opens the full-screen view with graphs
    private var systemTitle: some View {
        Button {
            NotchController.haptic(.generic)
            NotchController.shared.collapse()
            SystemDashboard.shared.show()
        } label: {
            HStack(spacing: 5) {
                Text("System")
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(IslandType.secondary)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help("Open full screen, with graphs")
    }

    /// Tabs, settings and the main window, tucked into one menu
    private func moreMenu(compact: Bool) -> some View {
        Menu {
            if state.tab == .shelf && shelfMode == "clipboard" && !clipboard.items.isEmpty {
                Button("Clear Clipboard History") { clipboard.clear() }
            } else if state.tab == .shelf && !ShelfStore.shared.items.isEmpty {
                Button("Clear Shelf") { ShelfStore.shared.clear() }
            } else if state.tab == .timer {
                Button("Edit Timer Presets…") { TimerTabView.editPresets() }
            }
            Menu("Quick Settings") {
                Toggle("Headphone Level (dB)", isOn: quick("funHearing", true))
                Toggle("Noise Control Animation", isOn: quick("funListening", true))
                Toggle("Keyboard Language Badge", isOn: quick("funInput", true))
                Toggle("Screenshot Catcher", isOn: quick("funShots", true))
                Divider()
                Toggle("Beat Pulse", isOn: quick("funPulse", true))
                Toggle("Cover Flip", isOn: quick("funFlip", true))
                Toggle("Timer Bubble", isOn: quick("funSplit", true))
                Toggle("Jelly Motion", isOn: quick("funJelly", true))
                Toggle("Eyes", isOn: quick("funEyes", false))
                Divider()
                Button("Calibrate Headphone Level…") {
                    NotchController.shared.collapse()
                    SettingsWindow.shared.show(tab: "Extras")
                }
            }
            Button("System Monitor (Full Screen)") {
                NotchController.shared.collapse()
                SystemDashboard.shared.show()
            }
            Button("Hearing History…") {
                NotchController.shared.collapse()
                HearingWindow.shared.show()
            }
            Button("Settings…") {
                NotchController.shared.collapse()
                SettingsWindow.shared.show()
            }
            Button("Open Murmur") {
                NotchController.shared.collapse()
                WindowModes.shared.showMainWindow()
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IslandType.secondary)
                .frame(width: compact ? 17 : 22, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Where the sound is going, like the AirPlay button in Apple Music: click to switch outputs
    private var routeButton: some View {
        Menu {
            ForEach(OutputRoute.outputs(), id: \.id) { out in
                Button {
                    OutputRoute.select(out.id)
                } label: {
                    if out.id == route.deviceID {
                        Label(out.name, systemImage: "checkmark")
                    } else {
                        Text(out.name)
                    }
                }
            }
            if route.isHeadphones && ListeningModeWatcher.shared.canSet {
                Divider()
                Text("Noise Control")
                let current = ListeningModeWatcher.shared.current
                ForEach(listeningChoices, id: \.rawValue) { mode in
                    Button {
                        ListeningModeWatcher.shared.set(mode)
                    } label: {
                        if mode == current { Label(mode.title, systemImage: "checkmark") } else { Text(mode.title) }
                    }
                }
            }
            Divider()
            Button("Sound Settings…") {
                NotchController.shared.collapse()
                if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        } label: {
            Image(systemName: route.symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(route.isHeadphones ? Color.white.opacity(0.85) : Color.white.opacity(0.5))
                .symbolReplace()
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(route.name.isEmpty ? "Output" : "Playing through \(route.name)")
    }

    private var listeningChoices: [ListeningMode] {
        ListeningModeWatcher.shared.supportsAdaptive
            ? [.off, .transparency, .adaptive, .noiseCancellation]
            : [.off, .transparency, .noiseCancellation]
    }

    /// Lyrics on and off, balancing the output button on the other side of the controls
    private var lyricsButton: some View {
        Button {
            NotchController.haptic(.generic)
            withAnimation(IslandMotion.open) { notchLyrics.toggle() }
        } label: {
            Image(systemName: notchLyrics ? "quote.bubble.fill" : "quote.bubble")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(notchLyrics ? Color.white.opacity(0.85) : Color.white.opacity(0.5))
                .symbolReplace()
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(notchLyrics ? "Hide lyrics" : "Show lyrics")
        .opacity(np.lyrics.isEmpty ? 0.35 : 1)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button {
            NotchController.haptic(.generic)
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(IslandType.tertiary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(help)
    }

    /// A small segmented control with a sliding highlight
    /// One capsule: the tabs, then the menu (settings and the rest) at its end
    private func tabSwitcher(compact: Bool) -> some View {
        HStack(spacing: compact ? 0 : 2) {
            if hasTabs {
                tabIcon(.music, "music.note", compact: compact)
                if shelfEnabled { tabIcon(.shelf, "tray.full.fill", compact: compact) }
                if timerTabEnabled { tabIcon(.timer, "timer", compact: compact) }
                if systemTabEnabled { tabIcon(.system, "cpu", compact: compact) }
            }
            moreMenu(compact: compact)
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    /// Files or Clipboard, in the ear beside the notch
    private var shelfSwitch: some View {
        HStack(spacing: 10) {
            shelfOption("Files", "files")
            if clipboard.historyOn { shelfOption("Clipboard", "clipboard") }
        }
    }

    private func shelfOption(_ title: String, _ value: String) -> some View {
        let on = shelfMode == value || (!clipboard.historyOn && value == "files")
        return Button {
            NotchController.haptic(.generic)
            withAnimation(.easeInOut(duration: 0.2)) { shelfMode = value }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Color.white : IslandType.tertiary)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func tabIcon(_ tab: IslandTab, _ symbol: String, compact: Bool = false) -> some View {
        let on = state.tab == tab
        return Button {
            NotchController.haptic(.generic)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.tab = tab }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: compact ? 9.5 : 10, weight: .semibold))
                .foregroundStyle(on ? Color.white : IslandType.tertiary)
                .frame(width: compact ? 17 : 24, height: 18)
                .background {
                    if on {
                        Capsule().fill(Color.white.opacity(0.18))
                            .matchedGeometryEffect(id: "tab", in: tabSpace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// A lyric line is shown when lyrics are on and this song has them
    /// The current lyric gets its own line between the artist and the progress bar
    private var showLyricRow: Bool {
        notchLyrics && !np.lyrics.isEmpty && !systemOnly && state.tab == .music
    }

    /// A soft, desaturated version of the album colour, like the reference's blue-grey
    private var muted: Color {
        let c = OKLab.mix(ramp.inner, SIMD3(0.78, 0.8, 0.84), 0.55)
        return Color(red: c.x, green: c.y, blue: c.z)
    }

    private func musicCard(notch: CGSize) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let lyrics = showLyricRow
            let textLeft = PlayerLayout.artLeft + PlayerLayout.artSize + 14
            let barsWidth: CGFloat = 22
            let chipWidth: CGFloat = hearing.level == nil ? 0 : 52
            let textWidth = max(60, w - textLeft - 18 - barsWidth - 10 - chipWidth)
            let lineWidth = w - 36
            let mid = w / 2
            let controlsY = PlayerLayout.controlsY(notch, lyrics: lyrics)

            ZStack(alignment: .topLeading) {
                // Title and artist, just below the notch, beside the cover
                MarqueeText(text: titleText, font: .system(size: 15, weight: .semibold),
                            color: .white, height: 19)
                    .frame(width: textWidth)
                    .position(x: textLeft + textWidth / 2, y: PlayerLayout.titleY(notch))
                MarqueeText(text: artistText, font: .system(size: 13),
                            color: Color.white.opacity(0.5), height: 17)
                    .frame(width: textWidth)
                    .position(x: textLeft + textWidth / 2, y: PlayerLayout.artistY(notch))

                // The estimated level in your ears (with headphones on), then the waveform
                HStack(spacing: 7) {
                    HearingChip()
                    MiniBars(tap: tap, meter: meter, ramp: ramp, count: 7, tint: muted)
                        .frame(width: barsWidth, height: 12)
                }
                .frame(width: barsWidth + 70, alignment: .trailing)
                .position(x: w - 18 - (barsWidth + 70) / 2, y: PlayerLayout.titleY(notch) - 1)
                .animation(.easeInOut(duration: 0.25), value: hearing.level == nil)

                // The current lyric, on its own line
                if lyrics {
                    IslandLyric(np: np, colour: muted, size: 14)
                        .frame(width: lineWidth)
                        .position(x: 18 + lineWidth / 2, y: PlayerLayout.lyricY(notch))
                        .transition(.opacity)
                }

                // Progress (or the permission prompt)
                Group {
                    if np.needsAutomation && np.spotifyRunning {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(IslandType.secondary)
                            Text("Allow control of Spotify")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(IslandType.secondary)
                            Spacer(minLength: 6)
                            Button {
                                NotchController.shared.collapse()
                                NowPlaying.openAutomationSettings()
                            } label: {
                                Text("Settings")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.black)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.white))
                            }
                            .buttonStyle(PressableStyle())
                        }
                    } else if np.duration > 0 && !systemOnly {
                        ProgressStrip(np: np, tint: muted)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: lineWidth, height: 14)
                .position(x: 18 + lineWidth / 2, y: PlayerLayout.progressY(notch, lyrics: lyrics))

                // Five controls, close together
                lyricsButton
                    .position(x: mid - 104, y: controlsY)
                control("backward.fill", size: 17) { np.previousTrack() }
                    .disabled(!np.spotifyRunning)
                    .position(x: mid - 52, y: controlsY)
                control(np.isPlaying ? "pause.fill" : "play.fill", size: 24) { np.playPause() }
                    .disabled(!np.spotifyRunning)
                    .position(x: mid, y: controlsY)
                control("forward.fill", size: 17) { np.nextTrack() }
                    .disabled(!np.spotifyRunning)
                    .position(x: mid + 52, y: controlsY)
                routeButton
                    .position(x: mid + 104, y: controlsY)

                // Hover the bottom-right corner for the lock
                PinCorner(pinned: state.pinned) { togglePin() }
                    .position(x: w - 26, y: controlsY)
            }
            .frame(width: w, height: geo.size.height, alignment: .topLeading)
            .animation(IslandMotion.open, value: lyrics)
        }
    }

    private var systemOnly: Bool { systemMode && !np.isPlaying }
    private var titleText: String { systemOnly ? "System audio" : np.title }
    private var artistText: String { systemOnly ? "All apps" : np.artist }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            NotchController.haptic(.generic)
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(Color.white)
                .symbolReplace()
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    /// Changes whenever a different cover (or no cover) shows, which turns the card over
    private var artKey: String {
        if systemOnly { return "system" }
        return np.artwork.map { String(describing: ObjectIdentifier($0)) } ?? "none"
    }

    private func thumb(size: CGFloat, corner: CGFloat) -> some View {
        ZStack {
            thumbFace(size: size)
                .id(flipOn ? artKey : "cover")
                .transition(flipOn ? .coverFlip : .identity)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .animation(.easeInOut(duration: 0.4), value: artKey)
    }

    private func thumbFace(size: CGFloat) -> some View {
        Group {
            if let art = np.artwork, !systemOnly {
                Image(nsImage: art).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.1)
                    .overlay(Image(systemName: systemOnly ? "waveform" : "music.note")
                        .font(.system(size: size * 0.42, weight: .medium))
                        .foregroundStyle(IslandType.secondary))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Buttons shrink slightly while pressed
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// A few rounded bars, each the average of a slice of the spectrum, in the album's colour
struct MiniBars: View {
    @ObservedObject var tap: AudioTap
    let meter: NotchMeter
    let ramp: Ramp
    let count: Int
    var tint: Color? = nil
    var reportsBeats = false

    var body: some View {
        // The four bars beside the notch are tiny, so 30 frames a second looks the same and costs half
        TimelineView(.animation(minimumInterval: count <= 4 ? 1.0 / 30 : 1.0 / 60,
                                paused: tap.status != .running)) { timeline in
            let visual = meter.processor.step(tap.snapshot(), now: timeline.date, range: 42)
            let _ = reportsBeats ? meter.report(visual.beat) : ()
            Canvas { ctx, size in
                let levels = visual.levels
                guard !levels.isEmpty, count > 0 else { return }
                // Skip the very top bands, which are mostly air
                let usable = Int(Double(levels.count) * 0.85)
                let slot = size.width / CGFloat(count)
                let bw = max(2, min(3.5, slot * 0.6))
                // Silence or paused: a calm, still equaliser shape rather than a row of dots
                let silent = (levels.max() ?? 0) < 0.03
                let rest: [CGFloat] = [0.35, 0.6, 0.45, 0.75, 0.4, 0.55]
                var still = ctx
                if silent { still.opacity = 0.45 }
                for i in 0..<count {
                    let a = i * usable / count
                    let b = max(a + 1, (i + 1) * usable / count)
                    let avg = levels[a..<b].reduce(0, +) / Float(b - a)
                    let v = silent ? rest[i % rest.count] * 0.6 : CGFloat(min(1, max(0, avg * 1.3)))
                    let h = max(bw * 1.4, v * size.height)
                    let rect = CGRect(x: CGFloat(i) * slot + (slot - bw) / 2, y: (size.height - h) / 2,
                                      width: bw, height: h)
                    still.fill(Path(roundedRect: rect, cornerRadius: bw / 2), with: .color(tint ?? ramp.color(0.2)))
                }
            }
        }
    }
}

/// Elapsed time, a thin bar you can click to jump, and the time remaining
struct ProgressStrip: View {
    @ObservedObject var np: NowPlaying
    var tint: Color = .white
    @State private var hovering = false
    @State private var scrub: Double?          // 0...1 while dragging

    var body: some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 0.5)) { t in
                Text(Self.time(shownTime(at: t.date)))
            }
            .frame(width: 30, alignment: .leading)

            GeometryReader { geo in
                let w = max(1, geo.size.width)
                // Only the drawing follows the clock; the drag is attached outside it
                TimelineView(.periodic(from: .now, by: 0.1)) { t in
                    bar(width: w, fraction: fraction(at: t.date))
                }
                .frame(width: w, height: geo.size.height)
                .contentShape(Rectangle())
                .onHover { h in withAnimation(Motion.spring(0.22, 0.9)) { hovering = h } }
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { g in
                            if scrub == nil { NotchController.haptic(.alignment) }
                            scrub = min(1, max(0, Double(g.location.x / w)))
                        }
                        .onEnded { g in
                            let f = min(1, max(0, Double(g.location.x / w)))
                            scrub = f
                            np.seek(to: f * np.duration)
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 600_000_000)
                                scrub = nil
                            }
                        }
                )
            }
            .frame(height: 14)

            TimelineView(.periodic(from: .now, by: 0.5)) { t in
                Text("-" + Self.time(max(0, np.duration - shownTime(at: t.date))))
            }
            .frame(width: 36, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(Color.white.opacity(hovering || scrub != nil ? 0.6 : 0.42))
    }

    private func fraction(at date: Date) -> Double {
        if let s = scrub { return s }
        guard np.duration > 0 else { return 0 }
        return min(1, max(0, np.position(at: date) / np.duration))
    }

    private func shownTime(at date: Date) -> Double {
        scrub.map { $0 * np.duration } ?? np.position(at: date)
    }

    private func bar(width w: CGFloat, fraction: Double) -> some View {
        let active = hovering || scrub != nil
        let h: CGFloat = active ? 7 : 4          // thin until you point at it
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.14))
                .frame(width: w, height: h)
            Capsule().fill(tint)
                .frame(width: max(h, w * CGFloat(fraction)), height: h)
            Circle()
                .fill(Color.white)
                .frame(width: 11, height: 11)
                .shadow(color: .black.opacity(0.35), radius: 2)
                .offset(x: w * CGFloat(fraction) - 5.5)
                .opacity(active ? 1 : 0)
                .scaleEffect(active ? 1 : 0.4)
        }
        .frame(width: w, height: 14, alignment: .leading)
        .animation(Motion.spring(0.22, 0.9), value: active)
    }

    static func time(_ s: Double) -> String {
        let t = Int(max(0, s))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Volume or brightness: the icon and value sit in the ears beside the notch, and a slim
/// segmented bar hangs just below it
struct LevelView: View {
    let activity: IslandActivity
    let notch: CGSize

    private var level: Double {
        switch activity {
        case .volume(let v, let muted): return muted ? 0 : v
        case .brightness(let b): return b
        default: return 0
        }
    }

    private var symbol: String {
        switch activity {
        case .volume(let v, let muted):
            if muted || v <= 0.001 { return "speaker.slash.fill" }
            return v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        case .brightness(let b):
            return b < 0.5 ? "sun.min.fill" : "sun.max.fill"
        default:
            return "circle"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.white)
                    .symbolReplace()
                Spacer(minLength: 0)
                Text("\(Int((level * 100).rounded()))%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.85))
            }
            .frame(height: notch.height)

            SegmentedLevel(level: level)
                .frame(height: 6)
                .padding(.top, 7)
            Spacer(minLength: 0)
        }
    }
}

/// One smooth line, filled from the left
struct SegmentedLevel: View {
    let level: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule().fill(Color.white)
                    .frame(width: max(geo.size.height, geo.size.width * CGFloat(level)))
                    .opacity(level > 0.001 ? 1 : 0)
            }
        }
        .animation(Motion.spring(0.22, 0.9), value: level)
    }
}

/// A short notice: an icon in the left ear, a title and a line of detail below the notch
struct IslandMessage: View {
    let symbol: String
    let title: String
    let subtitle: String
    let notch: CGSize
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: symbol)
                    .font(.system(size: max(12, notch.height * 0.42), weight: .medium))
                    .foregroundStyle(Color.white)
                    .symbolBounce(appeared)
                Spacer(minLength: 0)
            }
            .frame(height: notch.height)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(IslandType.title)
                    .foregroundStyle(Color.white)
                Text(subtitle)
                    .font(IslandType.subtitle)
                    .foregroundStyle(IslandType.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .onAppear { appeared = true }
    }
}

// MARK: - Lock open

struct PinIcon: View {
    let pinned: Bool
    var body: some View {
        Image(systemName: pinned ? "lock.fill" : "lock.open.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(pinned ? Color.white.opacity(0.9) : IslandType.secondary)
            .symbolReplace()
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color.white.opacity(pinned ? 0.16 : 0.08)))
            .contentShape(Circle())
    }
}

/// An empty corner that shows a lock when the pointer is over it (or while locked)
struct PinCorner: View {
    let pinned: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())     // catches the hover while the lock is hidden
            Button(action: action) { PinIcon(pinned: pinned) }
                .buttonStyle(PressableStyle())
                .opacity(pinned || hovering ? 1 : 0)
                .scaleEffect(pinned || hovering ? 1 : 0.6)
        }
        .frame(width: 44, height: 40)
        .onHover { h in withAnimation(Motion.spring(0.25, 0.8)) { hovering = h } }
        .help(pinned ? "Unlock (close when the pointer leaves)" : "Lock open")
    }
}

// MARK: - Above every Space
// Ordinary windows, even ones on "all Spaces", belong to whichever Space is showing, so they slide
// out and back in when you swipe between desktops, and they're hidden on the Lock Screen. Apps like
// NotchNook avoid that by putting their window on a Space of its own that the window server keeps
// above all the others. That needs SkyLight, the private framework behind the window server: if a
// macOS update removes these functions, `adopt` returns false and the island works as before.

enum SkyLightSpace {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, UnsafeRawPointer?) -> UInt64
    private typealias SetLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias MoveWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32

    private static var connection: Int32 = 0
    private static var space: UInt64 = 0
    private static var move: MoveWindows?

    /// Made once: the private Space, set above everything and shown on every display
    private static let ready: Bool = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW),
              let main = dlsym(h, "SLSMainConnectionID"),
              let create = dlsym(h, "SLSSpaceCreate"),
              let level = dlsym(h, "SLSSpaceSetAbsoluteLevel"),
              let show = dlsym(h, "SLSShowSpaces"),
              let add = dlsym(h, "SLSSpaceAddWindowsAndRemoveFromSpaces") else { return false }
        connection = unsafeBitCast(main, to: MainConnection.self)()
        space = unsafeBitCast(create, to: SpaceCreate.self)(connection, 1, nil)
        guard connection != 0, space != 0 else { return false }
        _ = unsafeBitCast(level, to: SetLevel.self)(connection, space, 100)
        _ = unsafeBitCast(show, to: ShowSpaces.self)(connection, [NSNumber(value: space)] as CFArray)
        move = unsafeBitCast(add, to: MoveWindows.self)
        return true
    }()

    @discardableResult
    static func adopt(_ window: NSWindow) -> Bool {
        guard ready, let move = move, window.windowNumber > 0 else { return false }
        return move(connection, space, [NSNumber(value: window.windowNumber)] as CFArray, 7) == 0
    }
}
