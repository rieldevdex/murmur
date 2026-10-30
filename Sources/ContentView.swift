import SwiftUI

struct ContentView: View {
    enum Role { case window, wallpaper }

    @ObservedObject private var tap: AudioTap
    @ObservedObject private var np: NowPlaying
    private let role: Role

    init(tap: AudioTap, np: NowPlaying, role: Role = .window) {
        _tap = ObservedObject(wrappedValue: tap)
        _np = ObservedObject(wrappedValue: np)
        self.role = role
    }

    // Saved between launches; the settings panel and the Display menu edit the same keys
    @AppStorage("look") private var lookIndex = 0
    @AppStorage("styleIndex") private var styleIndex = 1      // see VisualStyle
    @AppStorage("colourIndex") private var colourIndex = 0    // 0 = follow the album art
    @AppStorage("ampKnob") private var ampKnob = 0.5
    @AppStorage("floating") private var floating = false
    @AppStorage("peakCaps") private var showPeaks = false
    @AppStorage("trails") private var trails = false
    @AppStorage("idleGlow") private var idleGlow = true
    @AppStorage("motionBlur") private var motionBlur = 0      // 0 off, 1 light, 2 strong
    @AppStorage("source") private var sourceIndex = 0         // see AudioSource
    @AppStorage("lastLook") private var lastLook = 0          // the last ordinary look, for "Back to Window"
    @AppStorage("wallpaper") private var wallpaper = false    // show the current look behind the desktop icons
    @AppStorage("wallpaperScreen") private var wallpaperScreen = "all"
    @AppStorage("seeThrough") private var seeThrough = false  // no background: the desktop shows through
    @AppStorage("beatPulse") private var beatPulse = true     // the background lights up on each beat
    @AppStorage("coverLyrics") private var lyricsOn = true
    @AppStorage("notchEnabled") private var notchEnabled = false
    @AppStorage("notchOnly") private var notchOnly = false     // just the island: the window draws nothing

    @Environment(\.openWindow) private var openWindow
    @State private var artRamp = Ramp.ember
    @State private var backdrop: NSImage?
    @State private var hudVisible = true
    @State private var hideTask: Task<Void, Never>?

    private var look: Look { Look(rawValue: lookIndex) ?? .classic }
    private var style: VisualStyle { VisualStyle(rawValue: styleIndex) ?? .bars }
    private var palette: Palette { Palette(rawValue: colourIndex) ?? .art }
    private var ramp: Ramp { palette.ramp(art: artRamp) }
    private var accent: Color { ramp.color(0) }
    private var source: AudioSource { AudioSource(rawValue: sourceIndex) ?? .spotify }

    // In System mode there's no track info unless Spotify happens to be playing
    private var systemLabel: Bool { source == .system && !np.isPlaying }
    private var trackTitle: String { systemLabel ? "System audio" : np.title }
    private var trackArtist: String { systemLabel ? "All apps" : np.artist }
    private var trackActive: Bool { np.isPlaying || source == .system }

    // The knob sets how many dB below the recent peak are shown:
    // 0% = 60 dB (calm, detailed), 50% = 45 dB (the original look), 100% = 30 dB (punchy)
    private var range: Float { Float(60 - 30 * ampKnob) }

    /// True inside the wallpaper window, and in the main window while it's hidden behind one
    private var asWallpaper: Bool { role == .wallpaper || (wallpaper && look.supportsWallpaper) }

    var body: some View {
        Group {
            if role == .window && (asWallpaper || notchOnly) {
                // The window is hidden (wallpaper or Notch Only): draw nothing, so it costs nothing
                Color.black
            } else {
                stage
            }
        }
        .background {
            if role == .window {
                WindowAccessor { window in
                    WindowModes.shared.attach(main: window, tap: tap, nowPlaying: np)
                    applyWindowMode()
                }
            }
        }
        .frame(minWidth: look == .mini && role == .window ? 360 : 880,
               minHeight: look == .mini && role == .window ? 96 : 680)
        .preferredColorScheme(.dark)
        .environment(\.craftedHardware, look == .crafted)
        .animation(Motion.spring(0.6, 0.9), value: lookIndex)
        .animation(Motion.spring(0.55, 0.9), value: styleIndex)
        .onAppear {
            tap.begin(source: source)
            let player = np
            tap.isPlayingHint = { [weak player] in player?.isPlaying ?? true }
            guard role == .window else { return }
            let reopen = openWindow
            WindowModes.shared.openMain = { reopen(id: "main") }
            // Never reopen as the wallpaper: it can't be clicked, so it would be easy to get stuck
            if wallpaper { wallpaper = false }
            if lookIndex == 6 { lookIndex = Look.borderless.rawValue }     // the old Wallpaper look
            if !look.isWindowMode { lastLook = lookIndex }
            if notchOnly {
                notchEnabled = true
                NotchOnlyMode.shared.apply(true)
            }
            if notchEnabled { NotchController.shared.setEnabled(true, tap: tap, np: np) }
        }
        .onChange(of: notchOnly) { on in
            guard role == .window else { return }
            if on {
                wallpaper = false
                notchEnabled = true
            }
            NotchOnlyMode.shared.apply(on)
            if !on { WindowModes.shared.showMainWindow() }
        }
        .onChange(of: floating) { _ in applyWindowMode() }
        .onChange(of: seeThrough) { _ in applyWindowMode() }
        .onChange(of: wallpaperScreen) { _ in
            if role == .window { WindowModes.shared.refreshWallpaper() }
        }
        .onChange(of: notchEnabled) { on in
            if role == .window { NotchController.shared.setEnabled(on, tap: tap, np: np) }
        }
        .onChange(of: lookIndex) { _ in
            guard role == .window else { return }
            if !look.isWindowMode { lastLook = lookIndex }
            if wallpaper && !look.supportsWallpaper { wallpaper = false }
            applyWindowMode()
        }
        .onChange(of: wallpaper) { _ in applyWindowMode() }
        .onChange(of: sourceIndex) { _ in
            if role == .window { tap.setSource(source) }
        }
        .onReceive(np.$artwork) { img in
            // Nothing to colour while the window is hidden in Notch Only mode
            if role == .window && notchOnly { return }
            if let img = img {
                artRamp = img.dominantRamp()
                backdrop = ArtBackdrop.make(from: img)
            } else {
                // Keep the old backdrop briefly, so skipping tracks doesn't flash to black
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if np.artwork == nil { backdrop = nil }
                }
            }
        }
    }

    private var stage: some View {
        stageLayers
            .onContinuousHover { phase in
                guard role == .window, look == .cover || look == .mosaic else { return }
                switch phase {
                case .active: showHUD()
                case .ended: scheduleHide()
                }
            }
    }

    private var stageLayers: some View {
        ZStack {
            if seeThrough {
                Color.clear
            } else {
                backdropLayer
            }

            if beatPulse && look != .mini {
                BeatGlow(tap: tap, ramp: ramp, range: range, strength: role == .wallpaper ? 1 : 0.8)
            }

            Group {
                switch look {
                case .classic, .crafted:
                    VStack(spacing: 0) {
                        antennas
                        device
                    }
                    .padding(40)
                case .ambient:
                    device.padding(40)
                case .cover:
                    CoverStage(tap: tap, style: style, ramp: ramp, range: range, artwork: np.artwork,
                               title: trackTitle, artist: trackArtist, album: systemLabel ? "" : np.album,
                               isPlaying: np.isPlaying, showPeaks: showPeaks, trails: trails,
                               motionBlur: motionBlur, idleEnabled: idleGlow,
                               np: np, showLyrics: lyricsOn && !systemLabel)
                case .mosaic:
                    MosaicStage(tap: tap, ramp: ramp, range: range, artwork: np.artwork,
                                title: trackTitle, artist: trackArtist, active: trackActive)
                case .borderless:
                    if asWallpaper {
                        // No controls: the window can't be clicked while it sits behind the desktop icons
                        liveScreen
                            .padding(.horizontal, 80)
                            .padding(.top, 80)
                            .padding(.bottom, 60)
                    } else {
                        borderless
                    }
                case .mini:
                    mini
                }
            }
            .transition(.visualSwap)

            // Cover and Mosaic: a glass control strip that appears when the pointer moves
            if !asWallpaper && (look == .cover || look == .mosaic) {
                ControlStrip()
                    .opacity(hudVisible ? 1 : 0)
                    .offset(y: hudVisible ? 0 : 12)
                    .animation(Motion.spring(0.4, 0.85), value: hudVisible)
                    .allowsHitTesting(hudVisible)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 22)
            }

            // The wallpaper can't receive clicks, so there's no gear there
            if !asWallpaper {
                GearCorner { SettingsWindow.shared.show() }
                .padding(.top, look == .mini ? 0 : 6)
                .padding(.trailing, look == .mini ? 0 : 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    @MainActor
    private func applyWindowMode() {
        guard role == .window else { return }
        WindowModes.shared.update(look: look, wallpaper: wallpaper && look.supportsWallpaper,
                                  floating: floating, seeThrough: seeThrough)
    }

    // MARK: Backgrounds

    @ViewBuilder
    private var backdropLayer: some View {
        switch look {
        case .classic:
            RadialGradient(colors: [Color(white: 0.16), Color(white: 0.03)],
                           center: .center, startRadius: 50, endRadius: 700)
                .ignoresSafeArea()
        case .crafted:
            ZStack {
                RadialGradient(colors: [Color(white: 0.19), Color(white: 0.03)],
                               center: .center, startRadius: 50, endRadius: 750)
                // The device's light spilling onto the wall behind it
                RadialGradient(colors: [accent.opacity(0.10), Color.clear],
                               center: .center, startRadius: 0, endRadius: 520)
            }
            .ignoresSafeArea()
        case .ambient:
            AmbientBackground(backdrop: backdrop, ramp: ramp, dim: 0.4)
        case .cover:
            AmbientBackground(backdrop: backdrop, ramp: ramp, dim: 0.5)
        case .mosaic:
            AmbientBackground(backdrop: backdrop, ramp: ramp, dim: 0.6)
        case .borderless:
            AmbientBackground(backdrop: backdrop, ramp: ramp, dim: 0.78)
        case .mini:
            AmbientBackground(backdrop: backdrop, ramp: ramp, dim: 0.55)
        }
    }

    // MARK: Classic / Crafted / Ambient

    @ViewBuilder
    private var antennas: some View {
        if look == .crafted {
            CraftedAntennas(accent: accent)
        } else {
            HStack(spacing: 0) {
                Spacer().frame(maxWidth: .infinity)
                antenna
                Spacer().frame(maxWidth: .infinity)
                antenna
                Spacer().frame(maxWidth: .infinity)
            }
            .frame(height: 110)
        }
    }

    private var antenna: some View {
        Capsule()
            .fill(LinearGradient(colors: [Color(white: 0.75), Color(white: 0.25), Color(white: 0.6)],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(width: 5)
    }

    private var device: some View {
        VStack(spacing: 18) {
            liveScreen
                .frame(height: 300)

            controls
                .animation(.easeInOut(duration: 0.8), value: ramp)
        }
        .padding(28)
        .background(deviceBody)
        .shadow(color: .black.opacity(look == .ambient ? 0.35 : 0.6), radius: 30, y: 20)
    }

    @ViewBuilder
    private var deviceBody: some View {
        let shape = RoundedRectangle(cornerRadius: 34)
        switch look {
        case .crafted:
            BrushedMetal()
                .clipShape(shape)
                .overlay(shape.stroke(LinearGradient(colors: [Color.white.opacity(0.28), Color.black.opacity(0.6)],
                                                     startPoint: .top, endPoint: .bottom),
                                      lineWidth: 2))
        case .ambient:
            Color.black.opacity(0.18)
                .clipShape(shape)
                .glassSurface(in: RoundedRectangle(cornerRadius: 34, style: .continuous))
                .environment(\.colorScheme, .dark)
        default:
            shape
                .fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.08)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(shape.stroke(Color.white.opacity(0.06), lineWidth: 1))
        }
    }

    private var liveScreen: some View {
        LiveScreen(tap: tap, style: style, ramp: ramp, range: range, artwork: np.artwork,
                   showPeaks: showPeaks, trails: trails, motionBlur: motionBlur,
                   idleEnabled: idleGlow, look: look)
    }

    private var titleFont: Font {
        look == .ambient
            ? .system(size: 13, weight: .semibold)
            : .system(size: 12, weight: .semibold, design: .monospaced)   // the radios keep their LCD labels
    }

    private func display(_ s: String) -> String {
        look == .ambient ? s : s.uppercased()
    }

    private var controls: some View {
        HStack(alignment: .center, spacing: 20) {
            Grille(accent: accent)

            HStack(spacing: 12) {
                artworkThumb(size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    MarqueeText(text: display(trackTitle), font: titleFont, color: accent,
                                height: 17, glow: look == .crafted)
                    MarqueeText(text: display(trackArtist), font: titleFont, color: accent.opacity(0.6),
                                height: 17)
                }
                .opacity(trackActive ? 1 : 0.5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            knobs

            Grille(accent: accent)
        }
    }

    private var knobs: some View {
        HStack(spacing: 12) {
            SelectorKnob(label: "STYLE", options: VisualStyle.allCases.map { $0.name },
                         index: $styleIndex, accent: accent)
            SelectorKnob(label: "COLOUR", options: Palette.allCases.map { $0.name },
                         index: $colourIndex, accent: accent)
            DragKnob(label: "AMPLITUDE", value: $ampKnob, accent: accent)
            ToggleSwitch(label: "CAPS", isOn: $showPeaks, accent: accent)
                .help("Peak caps on the BARS style")
        }
    }

    private func artworkThumb(size: CGFloat) -> some View {
        Group {
            if systemLabel {
                Color.white.opacity(0.06)
                    .overlay(Image(systemName: "waveform").font(.system(size: size * 0.38)).foregroundStyle(accent))
            } else if let art = np.artwork {
                Image(nsImage: art).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.06)
                    .overlay(Text("\u{266A}").foregroundStyle(accent))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.12))
        .overlay(RoundedRectangle(cornerRadius: size * 0.12).stroke(accent.opacity(0.7), lineWidth: 1.5))
    }

    // MARK: Mini player

    // Styles that need room (or draw their own artwork) show as bars in the small strip
    private var miniStyle: VisualStyle {
        switch style {
        case .radial, .ridge, .particles: return .bars
        default: return style
        }
    }

    private var mini: some View {
        HStack(spacing: 12) {
            artworkThumb(size: 64)
            VStack(alignment: .leading, spacing: 3) {
                MarqueeText(text: trackTitle, font: .system(size: 13, weight: .semibold),
                            color: .white, height: 17)
                MarqueeText(text: trackArtist, font: .system(size: 11, weight: .medium),
                            color: .white.opacity(0.6), height: 15)
                LiveScreen(tap: tap, style: miniStyle, ramp: ramp, range: range, artwork: nil,
                           showPeaks: false, trails: trails, motionBlur: motionBlur,
                           idleEnabled: idleGlow, look: .mini)
                    .frame(height: 30)
            }
            .opacity(trackActive ? 1 : 0.6)
        }
        .padding(.leading, 16)
        .padding(.trailing, 40)          // keep clear of the gear's corner
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { lookIndex = lastLook }
        .help("Double-click to go back to the full window")
    }

    // MARK: Borderless

    private var borderless: some View {
        ZStack(alignment: .bottom) {
            liveScreen
                .padding(48)

            hud
                .opacity(hudVisible ? 1 : 0)
                .offset(y: hudVisible ? 0 : 20)
                .animation(.easeInOut(duration: 0.5), value: hudVisible)
                .allowsHitTesting(hudVisible)
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active: showHUD()
            case .ended: scheduleHide()
            }
        }
        .onAppear { showHUD() }
        .onDisappear { hideTask?.cancel() }
    }

    private var hud: some View {
        HStack(spacing: 20) {
            artworkThumb(size: 64)
            VStack(alignment: .leading, spacing: 6) {
                MarqueeText(text: trackTitle, font: .system(size: 22, weight: .bold),
                            color: .white, height: 28)
                MarqueeText(text: trackArtist, font: .system(size: 14, weight: .medium),
                            color: .white.opacity(0.65), height: 18)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(trackActive ? 1 : 0.6)

            ControlStrip()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .glassSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .environment(\.colorScheme, .dark)
        .padding(24)
        .animation(.easeInOut(duration: 0.8), value: ramp)
    }

    /// Show the controls, then hide them (and the pointer) after 2.5 s without movement
    @MainActor
    private func showHUD() {
        if !hudVisible { hudVisible = true }
        scheduleHide()
    }

    @MainActor
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            hudVisible = false
            if look == .borderless { NSCursor.setHiddenUntilMouseMoves(true) }
        }
    }
}
