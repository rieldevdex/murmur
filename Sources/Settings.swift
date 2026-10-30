import SwiftUI
import AppKit

// MARK: - The hidden gear in the main window

/// An invisible patch in the corner: hover it and a gear fades in; click it to open Settings.
struct GearCorner: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: 32, height: 32)
                .glassSurface(in: Circle())
                .environment(\.colorScheme, .dark)
                .rotationEffect(.degrees(hovering ? 0 : -60))
                .scaleEffect(hovering ? 1 : 0.7)
                .opacity(hovering ? 1 : 0)
                .frame(width: 72, height: 72)          // the invisible hover zone
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.spring(0.3, 0.75), value: hovering)
        .help("Settings")
    }
}

// MARK: - Settings window: native tabs and grouped forms, like System Settings

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private var tabs: NSTabViewController?

    /// Opens Settings on a particular tab ("Timer", "Notch", …)
    func show(tab label: String) {
        show()
        guard let t = tabs, let i = t.tabViewItems.firstIndex(where: { $0.label == label }) else { return }
        t.selectedTabViewItemIndex = i
    }

    func toggle() {
        if window?.isVisible == true { window?.close() } else { show() }
    }

    func show() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }

        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        tabs.addTabViewItem(item("General", "gearshape", GeneralSettings(), height: 330))
        tabs.addTabViewItem(item("Appearance", "paintbrush", AppearanceSettings(), height: 560))
        tabs.addTabViewItem(item("Notch", "rectangle.topthird.inset.filled", NotchSettings(), height: 780))
        tabs.addTabViewItem(item("Wallpaper", "photo.on.rectangle", WallpaperSettings(), height: 280))
        tabs.addTabViewItem(item("Timer", "timer", TimerSettings(), height: 640))
        tabs.addTabViewItem(item("Extras", "sparkles", ExtrasSettings(), height: 720))
        tabs.addTabViewItem(item("System", "cpu", SystemSettings(), height: 740))
        tabs.addTabViewItem(item("Advanced", "slider.horizontal.3", AdvancedSettings(), height: 570))

        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        w.delegate = self

        // Centred under the notch, just below the menu bar
        if let screen = NotchMetrics.notchScreen {
            let size = w.frame.size
            w.setFrameTopLeftPoint(NSPoint(x: screen.frame.midX - size.width / 2,
                                           y: screen.visibleFrame.maxY - 8))
        } else {
            w.center()
        }

        window = w
        self.tabs = tabs
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func item<V: View>(_ title: String, _ symbol: String, _ view: V, height: CGFloat) -> NSTabViewItem {
        let host = NSHostingController(rootView: view.frame(width: 680, height: height))
        host.sizingOptions = [.preferredContentSize]
        let tab = NSTabViewItem(viewController: host)
        tab.label = title
        tab.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return tab
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "notchTuning")   // never leave the tuning outline on
        window = nil
    }
}

// MARK: - General

struct GeneralSettings: View {
    @AppStorage("source") private var sourceIndex = 0
    @AppStorage("notchOnly") private var notchOnly = false
    @AppStorage("floating") private var floating = false

    var body: some View {
        Form {
            Section {
                Picker("Listen to", selection: $sourceIndex) {
                    Text("Spotify").tag(AudioSource.spotify.rawValue)
                    Text("All system audio").tag(AudioSource.system.rawValue)
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Audio")
            } footer: {
                Text(sourceIndex == AudioSource.system.rawValue
                     ? "Everything your Mac plays, except this app. Track details still come from Spotify."
                     : "Only Spotify, even when other apps are playing.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Notch only", isOn: $notchOnly)
                Toggle("Keep window on top", isOn: $floating)
                    .disabled(notchOnly)
            } header: {
                Text("Window")
            } footer: {
                Text("Notch only hides the window and Dock icon and runs just the island, which uses far less CPU and memory. Use the icon in the menu bar to bring the window back.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance

struct AppearanceSettings: View {
    @AppStorage("look") private var lookIndex = 0
    @AppStorage("styleIndex") private var styleIndex = 1
    @AppStorage("colourIndex") private var colourIndex = 0
    @AppStorage("ampKnob") private var ampKnob = 0.5
    @AppStorage("seeThrough") private var seeThrough = false
    @AppStorage("beatPulse") private var beatPulse = true
    @AppStorage("coverLyrics") private var coverLyrics = true

    var body: some View {
        Form {
            Section {
                Picker("Look", selection: $lookIndex) {
                    ForEach(Look.allCases, id: \.self) { l in
                        Label(l.name, systemImage: l.symbol).tag(l.rawValue)
                    }
                }
                Picker("Style", selection: $styleIndex) {
                    ForEach(VisualStyle.allCases, id: \.self) { s in
                        Label(s.title, systemImage: s.symbol).tag(s.rawValue)
                    }
                }
                Picker("Colour", selection: $colourIndex) {
                    ForEach(Palette.allCases, id: \.self) { p in
                        Text(p.title).tag(p.rawValue)
                    }
                }
                Slider(value: $ampKnob, in: 0...1) {
                    Text("Amplitude")
                } minimumValueLabel: {
                    Text("Calm")
                } maximumValueLabel: {
                    Text("Punchy")
                }
            } header: {
                Text("Visualiser")
            } footer: {
                Text((Look(rawValue: lookIndex) ?? .classic).blurb)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Light up with the beat", isOn: $beatPulse)
                Toggle("See-through background", isOn: $seeThrough)
            } header: {
                Text("Background")
            } footer: {
                Text("See-through removes the background, so your desktop or the windows behind show through.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Synced lyrics in Cover", isOn: $coverLyrics)
            } header: {
                Text("Lyrics")
            } footer: {
                Text("Time-stamped lyrics from LRCLIB, a free public database. Not every song has them.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Enter Full Screen") { WindowModes.shared.toggleMainFullScreen() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Notch

struct NotchSettings: View {
    @AppStorage("notchEnabled") private var notchEnabled = false
    @AppStorage("notchAnnounce") private var announce = true
    @AppStorage("notchHaptics") private var haptics = true
    @AppStorage("notchLyrics") private var lyrics = true
    @AppStorage("notchTabsAlways") private var tabsAlways = true
    @AppStorage("notchAllSpaces") private var allSpaces = true
    @AppStorage("timerTab") private var timerTab = true
    @AppStorage("timerPauseMusic") private var timerPauseMusic = true
    @AppStorage("timerSound") private var timerSound = true
    @AppStorage("clipHistory") private var clipHistory = true
    @AppStorage("clipDefine") private var clipDefine = true
    @AppStorage("notchPower") private var power = true
    @AppStorage("notchSwipe") private var swipe = true
    @AppStorage("notchScrollVolume") private var scrollVolume = true
    @AppStorage("notchDevices") private var devices = true
    @AppStorage("notchHUD") private var hud = true
    @AppStorage("notchReplaceHUD") private var replaceHUD = false
    @AppStorage("notchShelf") private var shelf = true
    @AppStorage("notchTuning") private var tuning = false
    @AppStorage("notchWidthAdjust") private var width = NotchDefaults.widthAdjust
    @AppStorage("notchHeightAdjust") private var height = NotchDefaults.heightAdjust
    @AppStorage("notchShift") private var shift = NotchDefaults.shift
    @AppStorage("notchRadius") private var radius = NotchDefaults.radius
    @AppStorage("notchEar") private var ear = NotchDefaults.ear

    var body: some View {
        Form {
            Section {
                Toggle("Show the notch island", isOn: $notchEnabled)
            } footer: {
                Text("Artwork and a small waveform beside the notch while music plays. Click it for the player; hover the artwork for a quick look at the song.")
                    .foregroundStyle(.secondary)
            }

            Group {
                Section("Behaviour") {
                    Toggle("Announce new songs", isOn: $announce)
                    Toggle("Swipe sideways to skip", isOn: $swipe)
                    Toggle("Scroll up and down for volume", isOn: $scrollVolume)
                    Toggle("Show lyrics", isOn: $lyrics)
                    Toggle(isOn: $allSpaces) {
                        Text("Stay put when switching Spaces, and on the Lock Screen")
                        Text("Keeps the island still during three-finger swipes and shows it while your Mac is locked. Turning this off takes effect the next time Visualiser opens.")
                    }
                    .onChange(of: allSpaces) { on in
                        if on { NotchController.shared.adoptSkyLight() }
                    }
                    Toggle(isOn: $tabsAlways) {
                        Text("Always show the tab switcher")
                        Text("When off, Music, Shelf and System appear on the player only when you hover its top-right corner.")
                    }
                    Toggle("Haptic feedback", isOn: $haptics)
                }

                Section {
                    Toggle("Clipboard history in the Shelf", isOn: $clipHistory)
                    Toggle(isOn: $clipDefine) {
                        Text("Look up copied words")
                        Text("Copy a word, then point at the notch to see what it means.")
                    }
                    if !ClipboardStore.shared.items.isEmpty {
                        Button("Clear Clipboard History") { ClipboardStore.shared.clear() }
                    }
                } header: {
                    Text("Tools")
                } footer: {
                    Text("Copied words also appear in the clipboard as dictionary cards: click the book on one to read it. Clipboard history keeps your last 20 copies on this Mac only. Passwords copied from password managers are never kept. Definitions come from the dictionaries turned on in the Dictionary app (Dictionary › Settings), so any bilingual dictionaries you turn on there are used too.")
                        .foregroundStyle(.secondary)
                }
                .onChange(of: clipHistory) { _ in ClipboardStore.shared.refresh() }
                .onChange(of: clipDefine) { _ in ClipboardStore.shared.refresh() }

                Section {
                    Toggle("Bluetooth devices connecting", isOn: $devices)
                    Toggle("Plugging in and unplugging the charger", isOn: $power)
                        .onChange(of: power) { _ in NotchController.shared.refreshOptions() }
                    Toggle("Volume and brightness", isOn: $hud)
                    Toggle("Hide the macOS volume indicator", isOn: $replaceHUD)
                        .disabled(!hud)
                    Toggle("File shelf", isOn: $shelf)
                } header: {
                    Text("Activities")
                } footer: {
                    if hud && replaceHUD && !MediaKeyTap.trusted {
                        Text("Hiding the macOS indicator needs Accessibility permission. Turn on Visualiser in System Settings › Privacy & Security › Accessibility; it starts working straight away.")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Drag files onto the notch to keep them on the shelf. Nothing is copied or moved.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    if let screen = NotchMetrics.notchScreen {
                        let d = NotchMetrics.detectedSize(of: screen)
                        LabeledContent("Detected notch", value: "\(Int(d.width)) × \(Int(d.height)) pt")
                    }
                    tuner("Width", $width, -60...60, signed: true)
                    tuner("Height", $height, -12...12, signed: true)
                    tuner("Position", $shift, -40...40, signed: true)
                    tuner("Corner roundness", $radius, 0...24)
                    tuner("Reach while playing", $ear, 0...90)
                    Button("Reset to Detected Size") {
                        width = NotchDefaults.widthAdjust
                        height = NotchDefaults.heightAdjust
                        shift = NotchDefaults.shift
                        radius = NotchDefaults.radius
                        ear = NotchDefaults.ear
                    }
                } header: {
                    Text("Size")
                } footer: {
                    Text("The island is outlined while this tab is open, so you can line it up with the real notch.")
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!notchEnabled)
        }
        .formStyle(.grouped)
        .onAppear { tuning = notchEnabled }
        .onDisappear { tuning = false }
        .onChange(of: notchEnabled) { on in tuning = on }
        .onChange(of: hud) { _ in NotchController.shared.refreshOptions() }
        .onChange(of: replaceHUD) { _ in NotchController.shared.refreshOptions() }
        .onChange(of: devices) { _ in NotchController.shared.refreshOptions() }
    }

    private func tuner(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                       signed: Bool = false) -> some View {
        let v = Int(value.wrappedValue.rounded())
        return LabeledContent {
            HStack {
                Slider(value: value, in: range, step: 1)
                    .frame(width: 180)
                Text(signed && v > 0 ? "+\(v)" : "\(v)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
        } label: {
            Text(title)
        }
    }
}

// MARK: - Wallpaper

struct WallpaperSettings: View {
    @AppStorage("look") private var lookIndex = 0
    @AppStorage("wallpaper") private var wallpaper = false
    @AppStorage("wallpaperScreen") private var wallpaperScreen = "all"

    private var look: Look { Look(rawValue: lookIndex) ?? .classic }

    var body: some View {
        Form {
            Section {
                Toggle("Use as desktop wallpaper", isOn: $wallpaper)
                    .disabled(!look.supportsWallpaper)
                if NSScreen.screens.count > 1 {
                    Picker("Display", selection: $wallpaperScreen) {
                        Text("All displays").tag("all")
                        ForEach(NSScreen.screens, id: \.self) { screen in
                            Text(screen.localizedName).tag(WindowModes.displayID(screen))
                        }
                    }
                }
            } footer: {
                Text(look.supportsWallpaper
                     ? "Shows the \(look.name) look behind your desktop icons. To leave, click the waveform icon in the menu bar."
                     : "Works with the Ambient, Cover, Mosaic and Borderless looks. Choose one in Appearance.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advanced

struct AdvancedSettings: View {
    @AppStorage("motionBlur") private var motionBlur = 0
    @AppStorage("trails") private var trails = false
    @AppStorage("peakCaps") private var peakCaps = false
    @AppStorage("idleGlow") private var idleGlow = true
    @AppStorage("frameRate") private var frameRate = "auto"
    @State private var refresh = 0

    var body: some View {
        Form {
            Section {
                Picker("Frame rate", selection: $frameRate) {
                    Text("Automatic").tag("auto")
                    Text("60 fps").tag("60")
                    Text("30 fps").tag("30")
                }
                .pickerStyle(.segmented)
                .onChange(of: frameRate) { _ in FramePacing.shared.update() }
            } header: {
                Text("Performance")
            } footer: {
                Text("Automatic uses 60 fps when plugged in, and 30 fps on battery or in Low Power Mode, which roughly halves the work. The visuals stop drawing completely whenever their window is hidden, minimised or covered.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Motion blur", selection: $motionBlur) {
                    Text("Off").tag(0)
                    Text("Light").tag(1)
                    Text("Strong").tag(2)
                }
                .pickerStyle(.segmented)
                Toggle("Ghost trails", isOn: $trails)
                Toggle("Peak caps on Bars", isOn: $peakCaps)
                Toggle("Breathing line when paused", isOn: $idleGlow)
            } header: {
                Text("Effects")
            } footer: {
                Text("Motion blur and ghost trails apply to the Bars, Wave and Radial styles.")
                    .foregroundStyle(.secondary)
            }

            Section {
                permission("Screen Recording", "Needed to hear the music",
                           granted: CGPreflightScreenCaptureAccess(), pane: "Privacy_ScreenCapture")
                permission("Automation", "Lets the island control Spotify",
                           granted: nil, pane: "Privacy_Automation")
                permission("Accessibility", "Only for hiding the macOS volume indicator",
                           granted: MediaKeyTap.trusted, pane: "Privacy_Accessibility")
                permission("Bluetooth", "For the devices-connecting animation",
                           granted: nil, pane: "Privacy_Bluetooth")
            } header: {
                Text("Permissions")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("After rebuilding the app, macOS may forget these. If something stops working, switch Visualiser off and on again in that list.")
                    if let tap = AudioTap.current, tap.recoveries > 0 {
                        Text("Audio capture restarted itself \(tap.recoveries) time\(tap.recoveries == 1 ? "" : "s") since launch (last \(tap.lastRecovery ?? "")).")
                    }
                }
                .foregroundStyle(.secondary)
            }
            .id(refresh)
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh += 1      // re-check the permissions when coming back from System Settings
        }
    }

    private func permission(_ title: String, _ detail: String, granted: Bool?, pane: String) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                if let g = granted {
                    Label(g ? "Allowed" : "Not allowed",
                          systemImage: g ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(g ? Color.green : Color.orange)
                        .font(.callout)
                }
                Button("Open…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - System (monitoring and alerts)

struct SystemSettings: View {
    @AppStorage("sysTab") private var systemTab = true
    @AppStorage("sysAlerts") private var alerts = true
    @AppStorage("sysAlertCPU") private var cpuAlert = true
    @AppStorage("sysCPUThreshold") private var threshold = 80.0
    @AppStorage("sysCPUDuration") private var duration = 60.0
    @AppStorage("sysAlertMemory") private var memoryAlert = true
    @AppStorage("sysAlertBattery") private var batteryAlert = true
    @AppStorage("sysAlertHeat") private var heatAlert = true
    @State private var ignored: [String] = UserDefaults.standard.stringArray(forKey: "ignoredApps") ?? []
    @AppStorage("usageLog") private var usageLog = false
    @AppStorage("usageLogSites") private var usageLogSites = false
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $usageLog) {
                    Text("Keep a usage log")
                    Text("A snapshot once a minute of the apps using noticeable memory or CPU, their bigger processes (each Safari website, for example) and memory pressure.")
                }
                Toggle(isOn: $usageLogSites) {
                    Text("Include which sites are open in Safari")
                    Text("Every 5 minutes, just the site names (like notion.so), never full addresses. macOS asks once to let Visualiser read Safari.")
                }
                .disabled(!usageLog)
                HStack {
                    Button(copied ? "Copied" : "Copy Report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(UsageLog.shared.report(), forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    }
                    Button("Show Log Files") { NSWorkspace.shared.open(UsageLog.folder) }
                    Spacer()
                    Button("Delete Log", role: .destructive) { UsageLog.shared.deleteAll() }
                }
            } header: {
                Text("Usage log")
            } footer: {
                Text("Copy Report puts a summary of the last 7 days on the clipboard, ready to paste into a chat. The full log is plain CSV files (kept 14 days, on this Mac only) if you want to attach them instead.")
                    .foregroundStyle(.secondary)
            }
            .onChange(of: usageLog) { _ in NotchController.shared.refreshOptions() }

            Section {
                Toggle("System tab in the island", isOn: $systemTab)
            } footer: {
                Text("CPU, GPU, memory, temperature, battery and network at a glance. Click a gauge to see which apps use the most of it. Click \u{201C}System\u{201D} at the top of the tab for a full-screen view with graphs.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Alert me about problems", isOn: $alerts)
                Group {
                    Toggle("An app using a lot of CPU", isOn: $cpuAlert)
                    LabeledContent("When it uses more than") {
                        HStack {
                            Slider(value: $threshold, in: 50...300, step: 10).frame(width: 170)
                            Text("\(Int(threshold))%").monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    .disabled(!cpuAlert)
                    LabeledContent("For at least") {
                        HStack {
                            Slider(value: $duration, in: 30...300, step: 30).frame(width: 170)
                            Text(duration < 60 ? "\(Int(duration)) s" : "\(Int(duration / 60)) min")
                                .monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    .disabled(!cpuAlert)
                    Toggle("Memory running low", isOn: $memoryAlert)
                    Toggle("Battery at 20% and 10%", isOn: $batteryAlert)
                    Toggle("Mac running hot", isOn: $heatAlert)
                }
                .disabled(!alerts)
            } header: {
                Text("Alerts")
            } footer: {
                Text("Alerts appear in the notch with Quit and Ignore buttons. Nothing is ever quit without you clicking Quit. 100% means one full CPU core, as in Activity Monitor, so busy apps can go well above 100%.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if ignored.isEmpty {
                    Text("None. Choose \u{201C}Don\u{2019}t Warn Again\u{201D} on an alert to add an app here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ignored, id: \.self) { id in
                        HStack {
                            Text(name(for: id))
                            Spacer()
                            Button("Remove") {
                                ignored.removeAll { $0 == id }
                                UserDefaults.standard.set(ignored, forKey: "ignoredApps")
                            }
                        }
                    }
                }
            } header: {
                Text("Never warn me about")
            }
        }
        .formStyle(.grouped)
        .onChange(of: alerts) { _ in NotchController.shared.refreshOptions() }
        .onAppear { ignored = UserDefaults.standard.stringArray(forKey: "ignoredApps") ?? [] }
    }

    private func name(for id: String) -> String {
        if id.hasPrefix("proc:") { return String(id.dropFirst(5)) }
        return ((id as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

// MARK: - Timer

struct TimerSettings: View {
    @ObservedObject private var timer = IslandTimer.shared
    @AppStorage("timerTab") private var timerTab = true
    @AppStorage("timerPauseMusic") private var pauseMusic = true
    @AppStorage("timerSound") private var sound = true

    var body: some View {
        Form {
            Section {
                Toggle("Timer tab in the island", isOn: $timerTab)
                Toggle("Pause music during breaks (repeating presets)", isOn: $pauseMusic)
                Toggle("Play a sound when time's up", isOn: $sound)
            }

            ForEach($timer.presets) { $preset in
                Section {
                    TextField("Name", text: $preset.title)
                    ForEach($preset.phases) { $phase in
                        HStack(spacing: 10) {
                            TextField("Part", text: $phase.name)
                                .labelsHidden()
                                .frame(width: 120)
                            Stepper(value: minutes($phase), in: 1...240) {
                                Text("\(minutes($phase).wrappedValue) min").monospacedDigit()
                                    .frame(width: 56, alignment: .trailing)
                            }
                            Toggle("Break", isOn: $phase.isBreak)
                                .toggleStyle(.checkbox)
                            Spacer()
                            Button {
                                let id = phase.id
                                Task { @MainActor in
                                    if let p = timer.presets.firstIndex(where: { $0.id == preset.id }) {
                                        timer.presets[p].phases.removeAll { $0.id == id }
                                    }
                                }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .disabled(preset.phases.count <= 1)
                            .help("Remove this part")
                        }
                    }
                    HStack {
                        Button("Add Part") {
                            preset.phases.append(TimerPhase(name: "Part \(preset.phases.count + 1)", seconds: 5 * 60))
                        }
                        .disabled(preset.phases.count >= 6)
                        Toggle("Repeat", isOn: $preset.repeats)
                            .toggleStyle(.checkbox)
                        Spacer()
                        Button("Delete Preset", role: .destructive) {
                            let id = preset.id
                            Task { @MainActor in timer.presets.removeAll { $0.id == id } }
                        }
                    }
                } header: {
                    Text(preset.title.isEmpty ? "Untitled" : preset.title)
                }
            }

            Section {
                HStack {
                    Button("Add Preset") {
                        timer.presets.append(TimerPreset(title: "New timer",
                                                         phases: [TimerPhase(name: "Timer", seconds: 10 * 60)]))
                    }
                    .disabled(timer.presets.count >= IslandTimer.maxPresets)
                    Spacer()
                    Button("Restore Defaults") { timer.restoreDefaultPresets() }
                }
            } footer: {
                Text("Up to \(IslandTimer.maxPresets) presets show in the island, in this order, next to Custom. Parts run one after another; with Repeat on they loop, like Pomodoro. Parts marked Break show in green and pause the music if that's on above.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func minutes(_ phase: Binding<TimerPhase>) -> Binding<Int> {
        Binding(get: { max(1, Int((phase.wrappedValue.seconds / 60).rounded())) },
                set: { phase.wrappedValue.seconds = Double($0) * 60 })
    }
}

// MARK: - Extras (the island's little touches)

struct ExtrasSettings: View {
    @AppStorage("funPulse") private var pulse = true
    @AppStorage("funFlip") private var flip = true
    @AppStorage("funSplit") private var split = true
    @AppStorage("funJelly") private var jelly = true
    @AppStorage("funEyes") private var eyes = false
    @AppStorage("funInput") private var input = true
    @AppStorage("funShots") private var shots = true
    @AppStorage("funGreeting") private var greeting = true
    @AppStorage("greetName") private var name = Greeter.name
    @AppStorage("greetCity") private var city = ""
    @AppStorage("greetEvents") private var events = false
    @State private var calendarDenied = false
    @State private var hideSystemIndicator = SystemInputIndicator.hidden
    @AppStorage("funHearing") private var hearing = true
    @AppStorage("hearingWarn") private var hearingWarn = true
    @AppStorage("hearingOffset") private var hearingOffset = 0.0
    @AppStorage("funListening") private var listening = true
    @ObservedObject private var hearingNow = HearingMonitor.shared
    @State private var iphoneValue = ""
    @State private var noiseStatus = ListeningModeWatcher.diagnosis()
    @State private var indicatorChanged = false

    var body: some View {
        Form {
            Section {
                Toggle("Pulse and glow on the beat", isOn: $pulse)
                Toggle("Flip the cover when the song changes", isOn: $flip)
                Toggle("Split the timer into its own bubble", isOn: $split)
                Toggle(isOn: $jelly) {
                    Text("Jelly motion")
                    Text("Squashes a little when you point at it, stretches when you swipe, and opens when you pull it down.")
                }
                Toggle(isOn: $eyes) {
                    Text("Eyes when nothing is playing")
                    Text("They follow your pointer, blink, fall asleep after two quiet minutes, and jump when something happens.")
                }
            } header: {
                Text("Motion")
            } footer: {
                Text("These only move when something happens (a beat, a new song, your pointer); none of them keeps drawing in the background.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $input) {
                    Text("Keyboard language and Caps Lock")
                    Text("Shows EN, VI and so on when you switch input source, and ⇪ when Caps Lock changes.")
                }
                Toggle(isOn: $hideSystemIndicator) {
                    Text("Hide macOS's own language bubble")
                    Text(indicatorChanged
                         ? "Done. Log out and back in (or restart) for macOS to pick it up."
                         : "The small blue \u{201C}US\u{201D} or \u{201C}VI\u{201D} that appears by the text cursor.")
                }
                .onChange(of: hideSystemIndicator) { hide in
                    SystemInputIndicator.setHidden(hide)
                    indicatorChanged = true
                }
                Toggle(isOn: $shots) {
                    Text("Catch screenshots")
                    Text("New screenshots drop into the notch, ready to drag into any app or keep in the Shelf.")
                }
            } header: {
                Text("Helpers")
            } footer: {
                Text("Typing tools that switch Vietnamese on and off by themselves (like EVKey or UniKey) don't tell macOS, so only macOS's own input sources show. Screenshots appear once macOS has saved them; turn off \u{201C}Show Floating Thumbnail\u{201D} in the Screenshot app's Options for them to arrive straight away.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $hearing) {
                    Text("Show how loud it is in my ears")
                    Text("An estimate in dB beside the waveform on the player, while listening on headphones.")
                }
                Toggle("Tell me when it's been loud for a while", isOn: $hearingWarn)
                    .disabled(!hearing)
                LabeledContent("Right now") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(hearingNow.level.map { "about \(Int($0)) dB" } ?? "play music on headphones to see it")
                            .foregroundStyle(hearingNow.level.map { HearingMonitor.colour($0) } ?? Color.secondary)
                        if let p = hearingNow.parts {
                            Text("music \(String(format: "%.1f", p.music)) dBFS · volume \(String(format: "%.1f", p.volume)) dB · adjustment \(String(format: "%+.1f", hearingOffset))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .monospacedDigit()
                }
                LabeledContent("Volume curve") {
                    HStack {
                        Text(CurveCalibrator.curve == nil ? "Standard estimate"
                             : CurveCalibrator.runCount == 0 ? "Measured on your AirPods"
                             : "Measured on your AirPods (\(CurveCalibrator.runCount) run\(CurveCalibrator.runCount == 1 ? "" : "s"))")
                            .foregroundStyle(.secondary)
                        if CurveCalibrator.curve != nil {
                            Button("Forget") { CurveCalibrator.forget() }
                        }
                        Button("Measure My AirPods…") { CalibrationWindow.shared.show() }
                    }
                }
                LabeledContent("Calibrate") {
                    HStack(spacing: 6) {
                        Text("My iPhone shows")
                        TextField("", text: $iphoneValue, prompt: Text("—"))
                            .frame(width: 44)
                            .multilineTextAlignment(.trailing)
                        Text("dB")
                        Button("Match") {
                            guard let target = Double(iphoneValue.replacingOccurrences(of: ",", with: ".")),
                                  let now = hearingNow.level else { return }
                            hearingOffset = max(-40, min(40, ((hearingOffset + target - (hearingNow.exact ?? now)) * 10).rounded() / 10))
                            iphoneValue = ""
                        }
                        .disabled(hearingNow.level == nil || Double(iphoneValue) == nil)
                    }
                }
                .disabled(!hearing)
                LabeledContent("Fine-tune") {
                    HStack {
                        Slider(value: $hearingOffset, in: -40...40, step: 0.5).frame(width: 180)
                        Text(String(format: "%+.1f dB", hearingOffset)).monospacedDigit()
                            .foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                    }
                }
                .disabled(!hearing)
                HStack {
                    Text("Used so far: " + hearingNow.weekText)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Hearing History…") { HearingWindow.shared.show() }
                }
                Toggle(isOn: $listening) {
                    Text("Noise control animation")
                    Text("Plays beside the notch when your AirPods switch between Noise Cancellation, Transparency, Adaptive and Off. You can also switch from the output menu on the player.")
                }
                LabeledContent("Noise control") {
                    HStack {
                        Text(noiseStatus).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                        Button("Check") { noiseStatus = ListeningModeWatcher.diagnosis() }
                    }
                }
            } header: {
                Text("Headphones")
            } footer: {
                Text("To calibrate: play a song on your Mac through your AirPods at the volume you usually use, play the same song on your iPhone through the same AirPods at a similar volume, and type the number its Hearing control shows (Control Center › the ear button). Calibrating at your usual volume matters, because the error isn't quite the same at every volume. The level is an estimate either way: the music and your volume are measured exactly, but how loud AirPods play isn't published. The guide is the WHO's: 80 dB is safe for 40 hours a week, and every 3 dB louder halves that.")
                    .foregroundStyle(.secondary)
            }
            .onChange(of: hearing) { _ in NotchController.shared.refreshOptions() }
            .onChange(of: listening) { _ in NotchController.shared.refreshOptions() }

            Section {
                Toggle("Greet me the first time I use my Mac each day", isOn: $greeting)
                Group {
                    TextField("Your name", text: $name)
                    TextField("City for the weather", text: $city, prompt: Text("e.g. Ho Chi Minh City"))
                    Toggle("Include my next event today", isOn: $events)
                        .onChange(of: events) { on in
                            guard on, !Greeter.calendarAllowed else { return }
                            Greeter.shared.requestCalendar { ok in
                                if !ok { events = false; calendarDenied = true }
                            }
                        }
                    Button("Show the Greeting Now") {
                        Task { @MainActor in await Greeter.shared.greet() }
                    }
                }
                .disabled(!greeting)
            } header: {
                Text("Greeting")
            } footer: {
                Text(calendarDenied
                     ? "Calendar access was turned down. You can allow it in System Settings › Privacy & Security › Calendars."
                     : "Weather comes from Open-Meteo (free, no account), one request a day. Events come from the Calendar app, including any Google calendars added there.")
                    .foregroundStyle(calendarDenied ? Color.orange : Color.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: input) { _ in NotchController.shared.refreshOptions() }
        .onChange(of: shots) { _ in NotchController.shared.refreshOptions() }
        .onChange(of: greeting) { _ in NotchController.shared.refreshOptions() }
    }
}
