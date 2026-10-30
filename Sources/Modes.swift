import SwiftUI
import AppKit

// MARK: - Window modes
// The live wallpaper gets a window of its own, made by us, so nothing fights SwiftUI over the
// main window. While it's showing, the main window is simply hidden. The mini player only
// moves and resizes the main window.

@MainActor
final class WindowModes: NSObject, NSMenuDelegate {
    static let shared = WindowModes()
    private override init() { super.init() }

    private weak var mainWindow: NSWindow?
    private var mainClosed = false
    private var closeObserver: NSObjectProtocol?
    /// Re-creates the main window if it was closed (set by the window's own view)
    var openMain: (() -> Void)?
    private weak var tap: AudioTap?
    private weak var nowPlaying: NowPlaying?
    private var keyObserver: NSObjectProtocol?

    private var wallpaperWindows: [NSWindow] = []
    private var wallpaperOn: Bool { !wallpaperWindows.isEmpty }
    private var wallpaperSince = Date.distantPast
    private var statusItem: NSStatusItem?
    private var screenObserver: NSObjectProtocol?
    private var seeThrough = false

    private var inMini = false
    private var savedFrame: NSRect?
    private var savedBehavior: NSWindow.CollectionBehavior?

    /// Called once the main window exists (from a tiny view inside it)
    func attach(main w: NSWindow, tap: AudioTap, nowPlaying: NowPlaying) {
        self.tap = tap
        self.nowPlaying = nowPlaying
        mainClosed = false
        guard mainWindow !== w else { return }
        mainWindow = w
        if NotchOnlyMode.isOn { w.orderOut(nil) }

        // Remember when the window is really closed (red button or ⌘W), so it can be re-created
        if let old = closeObserver { NotificationCenter.default.removeObserver(old) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            Task { @MainActor in WindowModes.shared.mainClosed = true }
        }

        // Clicking the Dock icon brings the main window back: treat that as leaving the wallpaper
        if let old = keyObserver { NotificationCenter.default.removeObserver(old) }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { _ in
            Task { @MainActor in
                let modes = WindowModes.shared
                if modes.wallpaperOn, Date().timeIntervalSince(modes.wallpaperSince) > 1 {
                    modes.leaveWallpaper()
                }
            }
        }

        // Displays plugged in, unplugged or rearranged: rebuild the wallpaper to fit
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in WindowModes.shared.refreshWallpaper() }
            }
        }
    }

    func update(look: Look, wallpaper: Bool, floating: Bool, seeThrough: Bool) {
        guard let w = mainWindow else { return }

        // See-through: let the desktop and windows behind show wherever nothing is drawn
        if seeThrough != self.seeThrough {
            self.seeThrough = seeThrough
            if wallpaperOn { refreshWallpaper() }
        }
        w.isOpaque = !seeThrough
        w.backgroundColor = seeThrough ? .clear : .windowBackgroundColor
        w.hasShadow = !seeThrough

        if wallpaper {
            showWallpaper(hiding: w)
        } else if wallpaperOn {
            hideWallpaper(showing: w)
        }

        let wantMini = look == .mini && !wallpaper
        if wantMini != inMini {
            if wantMini { enterMini(w) } else { leaveMini(w) }
            inMini = wantMini
        }

        if !wallpaper {
            w.level = (inMini || floating) ? .floating : .normal
        }
    }

    /// Full screen for the visualiser window, even when the settings window is the one in front
    func toggleMainFullScreen() {
        guard !wallpaperOn, let w = mainWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.toggleFullScreen(nil)
    }

    /// Brings the main window forward (from the notch island); also ends the wallpaper and Notch Only
    func showMainWindow() {
        if NotchOnlyMode.isOn {
            UserDefaults.standard.set(false, forKey: "notchOnly")
            NotchOnlyMode.shared.apply(false)
        }
        NSApp.activate(ignoringOtherApps: true)
        if wallpaperOn {
            leaveWallpaper()
        } else if let w = mainWindow, !mainClosed {
            w.makeKeyAndOrderFront(nil)
        } else {
            openMain?()
        }
    }

    /// Rebuilds the wallpaper windows, e.g. after choosing a different display
    func refreshWallpaper() {
        guard wallpaperOn, let main = mainWindow else { return }
        for win in wallpaperWindows { win.orderOut(nil); win.contentView = nil }
        wallpaperWindows = []
        showWallpaper(hiding: main)
    }

    /// The displays the wallpaper should cover: all of them, or the one picked in settings
    static func wallpaperScreens() -> [NSScreen] {
        let choice = UserDefaults.standard.string(forKey: "wallpaperScreen") ?? "all"
        if choice == "all" { return NSScreen.screens }
        if let match = NSScreen.screens.first(where: { displayID($0) == choice }) { return [match] }
        return NSScreen.main.map { [$0] } ?? NSScreen.screens       // that display was unplugged
    }

    static func displayID(_ screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number.map { "\($0.uint32Value)" } ?? screen.localizedName
    }

    /// Turns the wallpaper off from anywhere (menu-bar icon, Display menu, Dock click)
    func leaveWallpaper() {
        UserDefaults.standard.set(false, forKey: "wallpaper")
        if let w = mainWindow { hideWallpaper(showing: w) }
    }

    // MARK: Wallpaper

    private func showWallpaper(hiding main: NSWindow) {
        guard !wallpaperOn, let tap = tap, let np = nowPlaying else { return }

        for screen in Self.wallpaperScreens() {
            let win = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                               backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            // Just above the desktop picture, below the desktop icons
            win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            win.ignoresMouseEvents = true
            win.hasShadow = false
            win.isOpaque = !seeThrough
            win.backgroundColor = seeThrough ? .clear : .black
            win.contentView = NSHostingView(rootView: ContentView(tap: tap, np: np, role: .wallpaper))
            win.setFrame(screen.frame, display: true)
            win.orderFront(nil)
            wallpaperWindows.append(win)
        }
        guard wallpaperOn else { return }

        wallpaperSince = Date()
        addStatusItem()

        if main.styleMask.contains(.fullScreen) {
            main.toggleFullScreen(nil)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 900_000_000)
                if self.wallpaperOn { main.orderOut(nil) }
            }
        } else {
            main.orderOut(nil)
        }
    }

    private func hideWallpaper(showing main: NSWindow) {
        guard wallpaperOn else { return }
        for win in wallpaperWindows { win.orderOut(nil); win.contentView = nil }
        wallpaperWindows = []
        removeStatusItem()
        guard !NotchOnlyMode.isOn else { return }
        main.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Hides the visualiser window without closing it (used by Notch Only mode)
    func hideMain() {
        mainWindow?.orderOut(nil)
    }

    private func addStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Murmur")
        item.button?.toolTip = "Murmur wallpaper"

        let menu = NSMenu()
        menu.delegate = self

        // Switch which look is the wallpaper without leaving it
        let header = NSMenuItem(title: "Wallpaper Look", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for look in Look.wallpaperLooks {
            let entry = NSMenuItem(title: look.name, action: #selector(pickLook(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = look.rawValue
            entry.image = NSImage(systemSymbolName: look.symbol, accessibilityDescription: nil)
            menu.addItem(entry)
        }
        menu.addItem(.separator())

        let back = NSMenuItem(title: "Back to Window", action: #selector(backToWindow), keyEquivalent: "")
        back.target = self
        menu.addItem(back)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Murmur", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    private func removeStatusItem() {
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
    }

    /// Tick the look that's currently the wallpaper each time the menu opens
    func menuNeedsUpdate(_ menu: NSMenu) {
        let current = UserDefaults.standard.integer(forKey: "look")
        for entry in menu.items where entry.action == #selector(pickLook(_:)) {
            entry.state = entry.tag == current ? .on : .off
        }
    }

    @objc private func pickLook(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "look")
    }

    @objc private func backToWindow() {
        leaveWallpaper()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: Mini player

    private func setTrafficLights(_ w: NSWindow, hidden: Bool) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            w.standardWindowButton(kind)?.isHidden = hidden
        }
    }

    private func enterMini(_ w: NSWindow) {
        guard let screen = w.screen ?? NSScreen.main else { return }
        if w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        savedFrame = w.frame
        savedBehavior = w.collectionBehavior

        let size = NSSize(width: 460, height: 112)
        w.contentMinSize = NSSize(width: 360, height: 96)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isMovableByWindowBackground = true
        setTrafficLights(w, hidden: true)
        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.maxX - size.width - 20, y: visible.minY + 20,
                           width: size.width, height: size.height)
        w.setFrame(frame, display: true, animate: true)
    }

    private func leaveMini(_ w: NSWindow) {
        setTrafficLights(w, hidden: false)
        w.isMovableByWindowBackground = false
        if let behavior = savedBehavior { w.collectionBehavior = behavior }
        w.contentMinSize = NSSize(width: 880, height: 680)
        if let frame = savedFrame { w.setFrame(frame, display: true, animate: true) }
    }
}

// Reports the window a SwiftUI view ends up in
final class WindowReporter: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let w = window { onWindow?(w) }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowReporter {
        let view = WindowReporter()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: WindowReporter, context: Context) {
        view.onWindow = onWindow
    }
}

// MARK: - Mosaic look: the cover split into tiles that lift with their own frequency band

struct MosaicStage: View {
    @ObservedObject var tap: AudioTap
    let ramp: Ramp
    let range: Float
    let artwork: NSImage?
    let title: String
    let artist: String
    let active: Bool

    @State private var processor = BandProcessor(particles: false)
    @State private var fader = RampFader()

    private static let grid = 8

    /// Tiles ordered from the centre outward, so bass lifts the middle and treble the edges
    private static let bandForTile: [Int] = {
        let n = MosaicStage.grid
        let centre = Double(n - 1) / 2
        let tiles = (0..<(n * n)).sorted { a, b in
            func key(_ t: Int) -> (Double, Double) {
                let dx = Double(t % n) - centre
                let dy = Double(t / n) - centre
                return ((dx * dx + dy * dy).squareRoot(), atan2(dy, dx))
            }
            let ka = key(a), kb = key(b)
            return ka.0 != kb.0 ? ka.0 < kb.0 : ka.1 < kb.1
        }
        var map = [Int](repeating: 0, count: n * n)
        for (rank, tile) in tiles.enumerated() { map[tile] = rank }
        return map
    }()

    @State private var onScreen = true
    @ObservedObject private var pacing = FramePacing.shared

    var body: some View {
        visuals.background(OnScreenReader(onScreen: $onScreen))
    }

    /// Redraws only while its window can be seen, at the chosen frame rate
    @ViewBuilder private var visuals: some View {
        TimelineView(.animation(minimumInterval: pacing.interval,
                                paused: !onScreen || tap.status != .running)) { timeline in
            let visual = processor.step(tap.snapshot(), now: timeline.date, range: range)
            let shown = fader.ramp(target: ramp, now: timeline.date)

            GeometryReader { geo in
                let side = max(200, min(geo.size.width * 0.7, (geo.size.height - 140) * 0.95))
                VStack(spacing: 26) {
                    Spacer(minLength: 0)
                    Canvas { ctx, size in
                        drawMosaic(&ctx, size, visual: visual, ramp: shown)
                    }
                    .frame(width: side, height: side)
                    .scaleEffect(1 + 0.015 * CGFloat(visual.beat))

                    VStack(spacing: 4) {
                        MarqueeText(text: title, font: .system(size: 22, weight: .bold),
                                    color: .white, height: 28)
                        MarqueeText(text: artist, font: .system(size: 14, weight: .medium),
                                    color: .white.opacity(0.65), height: 18)
                    }
                    .frame(width: min(side, 520))
                    .opacity(active ? 1 : 0.6)
                    Spacer(minLength: 0)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    private func drawMosaic(_ ctx: inout GraphicsContext, _ size: CGSize, visual: VisualFrame, ramp: Ramp) {
        let n = Self.grid
        let cell = size.width / CGFloat(n)
        let gap = max(2, cell * 0.06)
        let full = CGRect(origin: .zero, size: size)
        let lut = ramp.lut()
        let image = artwork.map { Image(nsImage: $0) }
        let levels = visual.levels

        func level(_ tile: Int) -> Double {
            let band = Self.bandForTile[tile]
            return band < levels.count ? Double(levels[band]) : 0
        }
        func rect(_ tile: Int) -> CGRect {
            CGRect(x: CGFloat(tile % n) * cell, y: CGFloat(tile / n) * cell, width: cell, height: cell)
                .insetBy(dx: gap / 2, dy: gap / 2)
        }

        // Coloured light under the tiles that are lifting
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: cell * 0.35))
            for tile in 0..<(n * n) {
                let v = level(tile)
                guard v > 0.08 else { continue }
                let glow = rect(tile).insetBy(dx: -cell * 0.12 * v, dy: -cell * 0.12 * v)
                let colour = lut[min(lut.count - 1, Self.bandForTile[tile] * lut.count / (n * n))]
                layer.fill(Path(roundedRect: glow, cornerRadius: cell * 0.1), with: .color(colour.opacity(0.85 * v)))
            }
        }

        // Quiet tiles first, so the lifted ones sit on top of their neighbours
        let order = (0..<(n * n)).sorted { level($0) < level($1) }
        for tile in order {
            let v = level(tile)
            let r = rect(tile)
            let shape = Path(roundedRect: r, cornerRadius: cell * 0.08)

            var c = ctx
            let s = 1 + 0.18 * v
            c.translateBy(x: r.midX, y: r.midY)
            c.scaleBy(x: s, y: s)
            c.translateBy(x: -r.midX, y: -r.midY)

            if v > 0.05 {
                c.fill(shape.offsetBy(dx: 0, dy: cell * 0.08 * v), with: .color(Color.black.opacity(0.5 * v)))
            }

            var tileCtx = c
            tileCtx.clip(to: shape)
            if let image = image {
                tileCtx.draw(image, in: full)
            } else {
                let t = Double(Self.bandForTile[tile]) / Double(n * n - 1)
                tileCtx.fill(shape, with: .color(ramp.color(t).opacity(0.35 + 0.65 * v)))
            }
            // Lifted tiles catch the light
            tileCtx.fill(shape, with: .color(Color.white.opacity(0.2 * v)))

            c.stroke(shape, with: .color(ramp.color(0).opacity(0.15 + 0.7 * v)), lineWidth: 1)
        }
    }
}

// MARK: - Notch Only: no window, no Dock icon, just the island and a menu-bar icon

@MainActor
final class NotchOnlyMode: NSObject {
    static let shared = NotchOnlyMode()
    private var item: NSStatusItem?
    private var on = false

    static var isOn: Bool { UserDefaults.standard.bool(forKey: "notchOnly") }

    func apply(_ enable: Bool) {
        guard enable != on else { return }
        on = enable
        if enable {
            // An "accessory" app has no Dock icon and no menu bar of its own, like NotchNook
            NSApp.setActivationPolicy(.accessory)
            WindowModes.shared.hideMain()
            addItem()
        } else {
            removeItem()
            NSApp.setActivationPolicy(.regular)
        }
    }

    private func addItem() {
        guard item == nil else { return }
        let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        i.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                                  accessibilityDescription: "Murmur")
        i.button?.toolTip = "Murmur (Notch Only)"

        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Murmur", action: #selector(showWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Murmur", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        i.menu = menu
        item = i
    }

    private func removeItem() {
        if let i = item { NSStatusBar.system.removeStatusItem(i) }
        item = nil
    }

    @objc private func showWindow() { WindowModes.shared.showMainWindow() }
    @objc private func showSettings() { SettingsWindow.shared.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}
