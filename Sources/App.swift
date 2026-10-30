import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the last window only quits the app if the notch island isn't running
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let d = UserDefaults.standard
        return !(d.bool(forKey: "notchEnabled") || d.bool(forKey: "notchOnly"))
    }

    /// Opening the app while it's already running (from Finder, Spotlight, Launchpad or the Dock)
    /// brings the window back, even from Notch Only mode
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in WindowModes.shared.showMainWindow() }
        return false
    }
}

@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("look") private var lookIndex = 0
    @AppStorage("styleIndex") private var styleIndex = 1
    @AppStorage("colourIndex") private var colourIndex = 0
    @AppStorage("ampKnob") private var ampKnob = 0.5
    @AppStorage("floating") private var floating = false
    @AppStorage("peakCaps") private var showPeaks = false
    @AppStorage("trails") private var trails = false
    @AppStorage("idleGlow") private var idleGlow = true
    @AppStorage("motionBlur") private var motionBlur = 0
    @AppStorage("source") private var sourceIndex = 0
    @AppStorage("lastLook") private var lastLook = 0
    @AppStorage("wallpaper") private var wallpaper = false
    @AppStorage("notchEnabled") private var notchEnabled = false
    @AppStorage("seeThrough") private var seeThrough = false
    @AppStorage("notchOnly") private var notchOnly = false

    // One audio capture and one now-playing reader, shared by the main window and the wallpaper
    @StateObject private var tap = AudioTap()
    @StateObject private var np = NowPlaying()

    init() {
        // Brings over settings and data from when the app was called Visualiser (once)
        Migration.run()
        // Needed when launched with `swift run`; harmless inside the .app bundle
        let startInNotch = UserDefaults.standard.bool(forKey: "notchOnly")
        NSApplication.shared.setActivationPolicy(startInNotch ? .accessory : .regular)
        if !startInNotch { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    private var look: Look { Look(rawValue: lookIndex) ?? .classic }

    /// A menu item with a tick beside the current choice
    private func choice(_ title: String, _ selected: Bool, _ pick: @escaping () -> Void) -> Toggle<Text> {
        Toggle(title, isOn: Binding(get: { selected }, set: { _ in pick() }))
    }

    var body: some Scene {
        // A single window, so ⌘N can't start a second audio capture
        Window("Murmur", id: "main") { ContentView(tap: tap, np: np) }
            .windowStyle(.hiddenTitleBar)
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { SettingsWindow.shared.show() }
                        .keyboardShortcut(",", modifiers: .command)
                }

                // View menu: what the visualiser looks like
                CommandGroup(before: .toolbar) {
                    Menu("Look") {
                        ForEach(Array(Look.allCases.enumerated()), id: \.offset) { i, l in
                            choice(l.name, lookIndex == l.rawValue) { lookIndex = l.rawValue }
                                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
                        }
                    }
                    Menu("Style") {
                        ForEach(VisualStyle.allCases, id: \.self) { s in
                            choice(s.title, styleIndex == s.rawValue) { styleIndex = s.rawValue }
                                .keyboardShortcut(KeyEquivalent(Character("\(s.rawValue + 1)")), modifiers: .command)
                        }
                    }
                    Menu("Colour") {
                        ForEach(Palette.allCases, id: \.self) { p in
                            choice(p.title, colourIndex == p.rawValue) { colourIndex = p.rawValue }
                        }
                        Divider()
                        Button("Next Colour") { colourIndex = (colourIndex + 1) % Palette.allCases.count }
                            .keyboardShortcut("k", modifiers: .command)
                    }
                    Menu("Effects") {
                        Picker("Motion Blur", selection: $motionBlur) {
                            Text("Off").tag(0)
                            Text("Light").tag(1)
                            Text("Strong").tag(2)
                        }
                        Toggle("Ghost Trails", isOn: $trails)
                            .keyboardShortcut("g", modifiers: [.command, .option])
                        Toggle("Peak Caps", isOn: $showPeaks)
                            .keyboardShortcut("p", modifiers: [.command, .option])
                        Toggle("Breathing Line When Paused", isOn: $idleGlow)
                        Toggle("See-Through Background", isOn: $seeThrough)
                    }
                    Divider()
                    Toggle("Notch Island", isOn: $notchEnabled)
                        .keyboardShortcut("n", modifiers: [.command, .option])
                    Toggle("Notch Only", isOn: $notchOnly)
                    Toggle("Use as Wallpaper", isOn: $wallpaper)
                        .keyboardShortcut("w", modifiers: [.command, .option])
                        .disabled(!look.supportsWallpaper)
                    Button("Back to Window") {
                        if wallpaper { WindowModes.shared.leaveWallpaper() } else { lookIndex = lastLook }
                    }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                    .disabled(!(wallpaper || look.isWindowMode))
                    Toggle("Keep on Top", isOn: $floating)
                        .keyboardShortcut("t", modifiers: [.command, .option])
                    Divider()
                }

                // Controls menu, like Apple Music's
                CommandMenu("Controls") {
                    Button(np.isPlaying ? "Pause" : "Play") { np.playPause() }
                        .keyboardShortcut(.space, modifiers: [])
                    Button("Next") { np.nextTrack() }
                        .keyboardShortcut(.rightArrow, modifiers: .command)
                    Button("Previous") { np.previousTrack() }
                        .keyboardShortcut(.leftArrow, modifiers: .command)
                    Divider()
                    Button("Increase Amplitude") { ampKnob = min(1, ampKnob + 0.05) }
                        .keyboardShortcut(.upArrow, modifiers: .command)
                    Button("Decrease Amplitude") { ampKnob = max(0, ampKnob - 0.05) }
                        .keyboardShortcut(.downArrow, modifiers: .command)
                    Divider()
                    Picker("Listen To", selection: $sourceIndex) {
                        Text("Spotify").tag(AudioSource.spotify.rawValue)
                        Text("All System Audio").tag(AudioSource.system.rawValue)
                    }
                }
            }
    }
}
