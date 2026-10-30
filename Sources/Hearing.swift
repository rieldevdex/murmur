import SwiftUI
import AppKit
import CoreAudio
import IOBluetooth

// MARK: - Headphone level (an estimate)
// The level in your ears is: how loud the music is + the volume you've set + how loud the
// headphones themselves play. The first two are measured exactly; the third isn't published by
// Apple, so a typical figure for AirPods is used, which you can adjust to match your iPhone.
//
// Cost: one small sum on the audio already being analysed, and a check twice a second that
// stops early unless music is playing through headphones.

@MainActor
final class HearingMonitor: ObservableObject {
    static let shared = HearingMonitor()

    /// Estimated level in your ears, dB SPL; nil when not listening on headphones
    @Published private(set) var level: Double?
    /// What went into it, for Settings: the music's own level and the volume, in dB
    @Published private(set) var parts: (music: Double, volume: Double)?
    /// The unrounded estimate, for calibrating (not published, so nothing redraws for it)
    private(set) var exact: Double?
    /// Share of this week's safe listening already used (1 = all of it), by the WHO guideline
    @Published private(set) var weekUsed: Double = 0

    var onWarning: ((String, String) -> Void)?       // title, subtitle

    /// dB SPL a full-scale signal reaches at full volume (AirPods Pro 2 play loud music at about
    /// 100 dB at maximum volume)
    private let fullScale: Double = 108
    private var timer: Timer?
    private var power: Double = 0                  // smoothed, in linear power
    private var lastSeq = -1
    private var loudSince: Date?
    private var lastLoudWarning = Date.distantPast
    private var lastSave = Date()
    private var lastStep = Date()
    private var recent: [Double] = []

    /// Every day you've listened, kept on this Mac (a few kilobytes a year)
    private(set) var days: [String: HearingDay] = [:]
    /// Goes up when the history is saved, so open charts know to redraw
    @Published private(set) var revision = 0

    private static let file: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Murmur", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hearing.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode([HearingDay].self, from: data) {
            days = Dictionary(saved.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        }
        weekUsed = weekTotal()
    }

    static var enabled: Bool { UserDefaults.standard.object(forKey: "funHearing") as? Bool ?? true }

    func start() {
        guard timer == nil else { return }
        lastStep = Date()
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in HearingMonitor.shared.step() }
        }
        t.tolerance = 0.15
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        level = nil
        save()
    }

    private func step() {
        guard OutputRoute.shared.isHeadphones, IslandExtras.musicActive,
              let tap = AudioTap.current, tap.status == .running,
              let gain = Self.volumeDecibels() else {
            if level != nil { level = nil }
            loudSince = nil
            _ = AudioTap.current?.takeEnergy()        // don't let sound from speakers count later
            power = 0
            recent = []
            return
        }
        // Every sample since the last check (half a second of audio), not a snapshot.
        // The level shown is the average of the last second exactly (two of these halves), so it
        // stays steady on steady sound but follows the music within a second, silence included.
        let p = tap.takeEnergy() ?? 0
        recent.append(p)
        if recent.count > 2 { recent.removeFirst(recent.count - 2) }
        power = recent.reduce(0, +) / Double(recent.count)

        // Below about −70 dBFS there's nothing to hear (a gap between songs, a fade-out's end)
        guard power > 1e-7 else {
            if level != nil { level = nil }
            exact = nil
            return
        }
        let offset = UserDefaults.standard.double(forKey: "hearingOffset")
        let music = 10 * log10(power)
        let spl = music + fullScale + gain + offset
        parts = ((music * 10).rounded() / 10, (gain * 10).rounded() / 10)
        // Only change the number shown once it's clearly moved, so it doesn't flicker between two
        exact = spl
        if level == nil || abs(spl - (level ?? 0)) >= 0.7 { level = spl.rounded() }

        record(spl)
        if Date().timeIntervalSince(lastSave) > 30 { save() }

        warnIfNeeded(spl)
    }

    private func warnIfNeeded(_ spl: Double) {
        guard UserDefaults.standard.object(forKey: "hearingWarn") as? Bool ?? true else { return }
        if spl >= 90 {
            let since = loudSince ?? Date()
            loudSince = since
            if Date().timeIntervalSince(since) > 120, Date().timeIntervalSince(lastLoudWarning) > 3600 {
                lastLoudWarning = Date()
                onWarning?("It's been loud for a while", "About \(Int(spl)) dB · a few steps quieter makes a big difference")
            }
        } else {
            loudSince = nil
        }
        // Once a day, when the week's safe amount is used up
        let key = "hearingWeekWarned"
        if weekUsed >= 1, UserDefaults.standard.string(forKey: key) != Self.today {
            UserDefaults.standard.set(Self.today, forKey: key)
            onWarning?("This week's safe listening is used up", "Lower volume from here on keeps your hearing safe")
        }
    }

    /// Adds the last half second to today's record
    private func record(_ spl: Double) {
        let now = Date()
        let dt = min(1.5, max(0.1, now.timeIntervalSince(lastStep)))
        lastStep = now
        let key = HearingDay.key(now)
        var day = days[key] ?? HearingDay(day: key)
        // Sound dose: 80 dB is safe for 40 hours a week; every 3 dB louder halves that time
        let allowed = 40 * 3600 * pow(2, (80 - spl) / 3)
        day.add(level: spl, seconds: dt, dose: dt / allowed,
                hour: Calendar.current.component(.hour, from: now))
        days[key] = day
        // Published only when the shown percentage changes, so nothing redraws twice a second
        let week = weekTotal()
        if Int(week * 100) != Int(weekUsed * 100) { weekUsed = week }
    }

    func weekTotal() -> Double {
        HearingDay.lastDays(7).compactMap { days[$0]?.dose }.reduce(0, +)
    }

    func save() {
        let list = Array(days.values).sorted { $0.day < $1.day }.suffix(400)
        let url = Self.file
        if let data = try? JSONEncoder().encode(Array(list)) {
            DispatchQueue.global(qos: .utility).async { try? data.write(to: url, options: .atomic) }
        }
        lastSave = Date()
        revision += 1
    }

    func clearHistory() {
        days = [:]
        weekUsed = 0
        save()
    }

    private static var today: String { HearingDay.key(Date()) }

    /// The output's current gain in dB (0 at full volume), from macOS's own volume curve
    static func volumeDecibels() -> Double? {
        guard let device = SystemVolume.outputDevice() else { return nil }
        var mute = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = SystemVolume.muteAddress
        if AudioObjectHasProperty(device, &addr),
           AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &mute) == noErr, mute != 0 { return nil }

        guard let scalar = SystemVolume.volume(), scalar > 0.001 else { return nil }
        // Measured on your own AirPods (Settings › Extras › Measure My AirPods), when available
        if let measured = CurveCalibrator.gain(at: scalar) { return measured }
        // The volume slider is already "perceptual" (half way sounds about half as loud). The
        // device's own dB table can't be used with it: for Bluetooth headphones it reports
        // mid-volume as 50–60 dB down, which made the estimate far too low. This curve puts half
        // volume about 12 dB below full, close to how AirPods actually behave.
        return 40 * log10(Double(scalar))
    }

    // MARK: Presentation

    static func colour(_ spl: Double) -> Color {
        spl < 80 ? Color(red: 0.36, green: 0.86, blue: 0.5)
            : spl < 85 ? .yellow
            : spl < 90 ? .orange
            : .red
    }

    var weekText: String {
        "\(Int((weekUsed * 100).rounded()))% of this week's safe listening"
    }
}

/// "≈ 78 dB", coloured from green (comfortable) to red (too loud)
struct HearingChip: View {
    @ObservedObject private var hearing = HearingMonitor.shared

    var body: some View {
        if let l = hearing.level {
            Button {
                NotchController.shared.collapse()
                HearingWindow.shared.show()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "ear")
                        .font(.system(size: 8.5, weight: .bold))
                    Text("\(Int(l)) dB")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(HearingMonitor.colour(l))
                .fixedSize()
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .help("Estimated level in your ears · \(hearing.weekText) · click for your listening history")
            .transition(.opacity)
        }
    }
}

// MARK: - AirPods listening mode
// macOS has no public way to read noise control, but the Bluetooth framework's device objects
// answer "listeningMode" (the same way apps like NoiseBuddy do). Checked once a second, and only
// while headphones that support it are connected.

enum ListeningMode: Int {
    case off = 1, noiseCancellation = 2, transparency = 3, adaptive = 4

    var title: String {
        switch self {
        case .off: return "Off"
        case .noiseCancellation: return "Noise Cancellation"
        case .transparency: return "Transparency"
        case .adaptive: return "Adaptive"
        }
    }
}

@MainActor
final class ListeningModeWatcher {
    static let shared = ListeningModeWatcher()
    var onChange: ((ListeningMode) -> Void)?
    private var timer: Timer?
    private var devices: [IOBluetoothDevice] = []
    private var last: [String: Int] = [:]
    private var lastScan = Date.distantPast

    static var enabled: Bool { UserDefaults.standard.object(forKey: "funListening") as? Bool ?? true }

    func start() {
        guard timer == nil else { return }
        rescan()
        let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in ListeningModeWatcher.shared.poll() }
        }
        t.tolerance = 0.3
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        devices = []
    }

    /// Called when Bluetooth devices connect or disconnect
    func rescan() {
        lastScan = Date()
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        devices = paired.filter { $0.isConnected() && $0.responds(to: Selector(("listeningMode"))) }
    }

    private func poll() {
        // The list is refreshed now and then in case a connection was missed
        if Date().timeIntervalSince(lastScan) > 15 { rescan() }
        for d in devices where d.isConnected() {
            guard let raw = (d.value(forKey: "listeningMode") as? NSNumber)?.intValue,
                  let mode = ListeningMode(rawValue: raw) else { continue }
            let key = d.addressString ?? d.name ?? "headphones"
            if let previous = last[key], previous != raw { onChange?(mode) }
            last[key] = raw
        }
    }

    /// A plain answer for Settings: can this Mac read and change noise control for your headphones?
    static func diagnosis() -> String {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let connected = paired.filter { $0.isConnected() }
        guard !connected.isEmpty else { return "No Bluetooth headphones connected" }
        for d in connected where d.responds(to: Selector(("listeningMode"))) {
            let name = d.name ?? "Your headphones"
            let raw = (d.value(forKey: "listeningMode") as? NSNumber)?.intValue ?? -1
            let canSet = d.responds(to: Selector(("setListeningMode:")))
            if let mode = ListeningMode(rawValue: raw) {
                return "\(name): \(mode.title)" + (canSet ? "" : " (can't be changed from here)")
            }
            return "\(name) doesn't share its noise control mode with other apps on this macOS"
        }
        return "\(connected.first?.name ?? "Your headphones") don't share noise control with other apps on this macOS"
    }

    /// The current mode of the connected headphones, if they report one
    var current: ListeningMode? {
        for d in devices where d.isConnected() {
            if let raw = (d.value(forKey: "listeningMode") as? NSNumber)?.intValue,
               let mode = ListeningMode(rawValue: raw) { return mode }
        }
        return nil
    }

    var supportsAdaptive: Bool {
        devices.contains { $0.name?.contains("Pro 2") == true || $0.name?.contains("Pro 3") == true }
    }

    /// Switches mode (from the island's output menu)
    func set(_ mode: ListeningMode) {
        for d in devices where d.isConnected() && d.responds(to: Selector(("setListeningMode:"))) {
            d.setValue(NSNumber(value: UInt8(mode.rawValue)), forKey: "listeningMode")
        }
    }

    var canSet: Bool {
        current != nil
            && devices.contains { $0.isConnected() && $0.responds(to: Selector(("setListeningMode:"))) }
    }
}

/// Rings around a head: they spread out for Transparency, close in for Noise Cancellation,
/// settle halfway for Adaptive, and fade for Off. Plays once and stops.
struct ListeningRings: View {
    let mode: ListeningMode
    @State private var go = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(Color.white.opacity(ringOpacity(i)), lineWidth: 1.4)
                    .scaleEffect(ringScale(i))
                    .animation(.easeOut(duration: 0.75).delay(Double(i) * 0.12), value: go)
            }
            Circle()
                .fill(Color.white.opacity(mode == .off ? 0.5 : 1))
                .frame(width: 6, height: 6)
        }
        .frame(width: 20, height: 20)
        .onAppear { go = true }
    }

    private func ringScale(_ i: Int) -> CGFloat {
        let step = CGFloat(i) / 2           // 0, 0.5, 1
        switch mode {
        case .transparency: return go ? 0.55 + step * 0.45 : 0.3
        case .noiseCancellation: return go ? 0.42 + step * 0.12 : 1.0
        case .adaptive: return go ? 0.5 + step * 0.25 : 0.3
        case .off: return 0.5 + step * 0.4
        }
    }

    private func ringOpacity(_ i: Int) -> Double {
        switch mode {
        case .transparency: return go ? 0.9 - Double(i) * 0.3 : 0
        case .noiseCancellation: return go ? 0.95 : 0.2
        case .adaptive: return go ? 0.8 - Double(i) * 0.2 : 0
        case .off: return go ? 0.12 : 0.5
        }
    }
}
