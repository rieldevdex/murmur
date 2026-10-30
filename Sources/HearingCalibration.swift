import SwiftUI
import AppKit
import AVFoundation
import CoreAudio

// MARK: - Measuring the AirPods' volume curve with the Mac's own microphone
// A 1 kHz tone plays through one AirPod pressed against the Mac. At each volume step the Mac's
// microphone measures how loud the tone arrives, listening only at exactly 1 kHz, so room noise
// barely matters. The microphone isn't calibrated, but it doesn't need to be: only the
// differences between steps are used, and those come out the same on any microphone.

@MainActor
final class CurveCalibrator: ObservableObject {
    static let shared = CurveCalibrator()

    enum Phase: Equatable {
        case idle
        case positioning            // tone playing; move the AirPod until the signal is strong
        case measuring(Int, Int)    // step, of
        case done(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var signal: Double = 0      // dB above the room's noise, while positioning
    /// What the microphone hears, for the readout under the bar
    @Published private(set) var roomLevel: Double?
    @Published private(set) var toneLevel: Double?
    @Published private(set) var micName = ""
    @Published private(set) var progressText = ""
    /// Per-step results of the last measurement, for the summary
    @Published private(set) var summary: [(volume: Float, db: Double, spread: Double)] = []

    /// While measuring, the volume indicator in the notch stays quiet
    static var running = false

    private let steps: [Float] = [1.0, 0.875, 0.75, 0.625, 0.5, 0.375, 0.25, 0.1875, 0.125, 0.0625]
    private var player: AVAudioPlayer?
    private var session: AVCaptureSession?
    private var sink: MicSink?
    private var previousInput: AudioDeviceID?
    private var previousVolume: Float?
    private var floor: Double = -140
    private var meterTimer: Timer?
    private let meter = ToneMeter()
    private var cancelled = false

    // MARK: Saved curve

    /// (volume, dB relative to full volume), loudest first
    static var curve: [(Float, Double)]? {
        guard let raw = UserDefaults.standard.array(forKey: "hearingCurve") as? [[Double]], raw.count >= 2 else { return nil }
        return raw.compactMap { $0.count == 2 ? (Float($0[0]), $0[1]) : nil }
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: "hearingCurve")
        UserDefaults.standard.removeObject(forKey: "hearingCurveRuns")
    }

    /// How many measurements the saved curve is based on
    static var runCount: Int { (UserDefaults.standard.array(forKey: "hearingCurveRuns") as? [[[Double]]])?.count ?? 0 }

    /// The measured gain at a volume, in between steps by straight lines
    static func gain(at volume: Float) -> Double? {
        guard let c = curve?.sorted(by: { $0.0 < $1.0 }), let first = c.first, let last = c.last else { return nil }
        if volume <= first.0 {
            // Below the quietest step, continue the last slope (in dB per halving of volume)
            guard c.count >= 2 else { return first.1 }
            let next = c[1]
            let slope = (next.1 - first.1) / log2(Double(next.0 / first.0))
            return first.1 - slope * log2(Double(first.0 / max(0.001, volume)))
        }
        if volume >= last.0 { return last.1 }
        for i in 1..<c.count where volume <= c[i].0 {
            let a = c[i - 1], b = c[i]
            let t = Double((volume - a.0) / (b.0 - a.0))
            return a.1 + (b.1 - a.1) * t
        }
        return last.1
    }

    // MARK: Running it

    func begin() {
        guard phase == .idle || isFinished else { return }
        guard OutputRoute.shared.isHeadphones else {
            phase = .failed("Connect your AirPods and choose them as the sound output first.")
            return
        }
        // macOS closes any app that asks for the microphone without saying why in its Info.plist
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            phase = .failed("This build is missing the microphone permission text. Copy the new Info.plist into the project folder, rebuild, and try again.")
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                let me = CurveCalibrator.shared
                guard granted else {
                    me.phase = .failed("Murmur needs the microphone for this. Allow it in System Settings › Privacy & Security › Microphone.")
                    return
                }
                me.startTone()
            }
        }
    }

    private var isFinished: Bool {
        switch phase {
        case .done, .failed: return true
        default: return false
        }
    }

    private func startTone() {
        Self.running = true
        cancelled = false
        previousVolume = SystemVolume.volume()

        // The tone: a short, seamlessly looping 1 kHz file played by the standard player
        do {
            let p = try AVAudioPlayer(data: Self.toneWAV())
            p.numberOfLoops = -1
            p.volume = 0                                              // silent while the room is measured
            guard p.play() else { throw CalibrationError.noTone }
            player = p
        } catch {
            finish(.failed("Couldn't play the tone (\(error.localizedDescription))."))
            return
        }

        // The Mac's own microphone, opened directly (the system's input setting is left alone)
        micName = Self.microphone()?.localizedName ?? ""
        guard let mic = Self.microphone() else {
            finish(.failed("Couldn't find your Mac's microphone."))
            return
        }
        do {
            let session = AVCaptureSession()
            let input = try AVCaptureDeviceInput(device: mic)
            guard session.canAddInput(input) else { throw CalibrationError.noMicrophone }
            session.addInput(input)
            let output = AVCaptureAudioDataOutput()
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1
            ]
            let sink = MicSink(meter: meter)
            output.setSampleBufferDelegate(sink, queue: DispatchQueue(label: "calibration.mic"))
            guard session.canAddOutput(output) else { throw CalibrationError.noMicrophone }
            session.addOutput(output)
            session.startRunning()
            self.session = session
            self.sink = sink
        } catch {
            finish(.failed("Couldn't start the microphone (\(error.localizedDescription))."))
            return
        }

        SystemVolume.setVolume(0.75)
        phase = .positioning
        Task { @MainActor in
            // The room on its own first, then the tone
            try? await Task.sleep(nanoseconds: 500_000_000)
            meter.reset()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            floor = meter.level()
            roomLevel = floor
            player?.volume = 1
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                Task { @MainActor in CurveCalibrator.shared.updateSignal() }
            }
        }
    }

    private func updateSignal() {
        let level = meter.level()
        meter.reset()
        signal = max(0, level - floor)
        toneLevel = level
    }

    /// Strong enough to measure all the way down
    var signalGood: Bool { signal >= 25 }

    func measure() {
        guard phase == .positioning else { return }
        meterTimer?.invalidate()
        meterTimer = nil
        Task { @MainActor in await self.runRounds() }
    }

    /// Three rounds. In each, every step is read between two full-volume readings, in a random
    /// order: full, 75%, full, 25%, full, 50%, … Each step is compared with the average of the two
    /// full-volume readings around it, taken seconds apart, so slow changes in how the AirPod sits
    /// cancel out. If those two disagree, the AirPod moved: that step is thrown away and read again.
    private func runRounds() async {
        let others = Array(steps.dropFirst())
        let rounds = 3
        var results: [Float: [Double]] = [:]
        floorPower = pow(10, floor / 10)

        for round in 1...rounds {
            var queue = others.shuffled()
            var retried = Set<Float>()
            progressText = "Round \(round) of \(rounds): starting"
            phase = .measuring(round, rounds)
            guard var before = await read(1.0) else {
                if !cancelled {
                    finish(.failed("The microphone can't hear the tone at full volume. Check you can hear it from the AirPod you're holding (Automatic Ear Detection off), and that it's at the spot where the bar went green."))
                }
                return
            }
            var i = 0
            while i < queue.count {
                guard !cancelled else { return }
                let v = queue[i]
                progressText = "Round \(round) of \(rounds): step \(min(i + 1, queue.count)) of \(queue.count) (\(Int((v * 100).rounded()))%)"
                let reading = await read(v)
                guard let after = await read(1.0) else {
                    if !cancelled { finish(.failed("Lost the tone partway through. Keep the AirPod still at the spot and try again.")) }
                    return
                }
                if abs(after - before) > 1.5 {
                    // Moved during this step: read it again at the end of the round (once)
                    if !retried.contains(v) { retried.insert(v); queue.append(v) }
                } else if let x = reading {
                    results[v, default: []].append(x - (before + after) / 2)
                }
                before = after
                i += 1
            }
            // The room again between rounds, in case it got louder or quieter
            if round < rounds {
                progressText = "Round \(round) of \(rounds): checking the room"
                player?.volume = 0
                try? await Task.sleep(nanoseconds: 500_000_000)
                meter.reset()
                try? await Task.sleep(nanoseconds: 1_050_000_000)
                if let p = meter.medianPower() { floorPower = p }
                player?.volume = 1
            }
        }
        guard !cancelled else { return }
        save(results)
    }

    private var floorPower: Double = 1e-14

    /// One reading at a volume: wait for the AirPods to change, then the middle of four
    /// quarter-second samples (so a sudden noise doesn't count), minus the room's own sound.
    /// Nil when the tone is too close to the noise to trust.
    private func read(_ volume: Float) async -> Double? {
        guard !cancelled else { return nil }
        SystemVolume.setVolume(volume)
        try? await Task.sleep(nanoseconds: 600_000_000)
        meter.reset()
        try? await Task.sleep(nanoseconds: 1_050_000_000)
        guard !cancelled, let p = meter.medianPower() else { return nil }
        let tone = p - floorPower
        guard tone > floorPower * 3 else { return nil }              // at least about 5 dB above the room
        let db = 10 * log10(tone)
        toneLevel = db
        return db
    }

    private func save(_ results: [Float: [Double]]) {
        // This run: each step's middle value, if its rounds agree within 2 dB
        var run: [[Double]] = [[1.0, 0]]
        var spreads: [Double] = []
        for v in steps.dropFirst() {
            guard let values = results[v], values.count >= 2 else { continue }
            let spread = (values.max() ?? 0) - (values.min() ?? 0)
            guard spread <= 2 else { continue }
            run.append([Double(v), Self.median(values)])
            spreads.append(spread)
        }
        guard run.count >= 4 else {
            finish(.failed("Not enough steady readings this time (\(run.count - 1) of \(steps.count - 1) steps). Rest the AirPod so it can't move, cover it to block room noise, and try again."))
            return
        }

        // Keep the last five runs, and use the middle value of each step across them
        var runs = UserDefaults.standard.array(forKey: "hearingCurveRuns") as? [[[Double]]] ?? []
        runs.append(Self.monotonic(run))
        runs = Array(runs.suffix(5))
        UserDefaults.standard.set(runs, forKey: "hearingCurveRuns")

        var combined: [[Double]] = []
        var acrossRuns: [Double] = []
        var rows: [(volume: Float, db: Double, spread: Double)] = []
        for v in steps {
            let values = runs.compactMap { r in r.first { abs($0[0] - Double(v)) < 0.001 }?[1] }
            guard !values.isEmpty else { continue }
            let mid = Self.median(values)
            combined.append([Double(v), mid])
            let spread = values.count >= 2 ? (values.max() ?? 0) - (values.min() ?? 0) : 0
            if values.count >= 2 { acrossRuns.append(spread) }
            rows.append((v, mid, spread))
        }
        combined = Self.monotonic(combined)
        UserDefaults.standard.set(combined, forKey: "hearingCurve")
        UserDefaults.standard.set(0.0, forKey: "hearingOffset")      // the old adjustment made up for the old curve
        summary = rows

        let within = (spreads.max() ?? 0) / 2
        var text = "Run \(runs.count) saved: \(run.count - 1) steps, rounds agreed within ±\(String(format: "%.1f", within)) dB."
        if let worst = acrossRuns.max() {
            text += " Across your \(runs.count) runs, steps agree within ±\(String(format: "%.1f", worst / 2)) dB"
            text += worst <= 2 ? ", so the curve has settled." : "; another run or two will steady it."
        } else {
            text += " Run it once or twice more to confirm the curve."
        }
        finish(.done(text))
    }

    private static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// A lower volume can't be louder than a higher one: smooth out any reading that says so
    private static func monotonic(_ points: [[Double]]) -> [[Double]] {
        var sorted = points.sorted { $0[0] > $1[0] }            // loudest first
        for i in 1..<max(1, sorted.count) {
            sorted[i][1] = min(sorted[i][1], sorted[i - 1][1])
        }
        return sorted
    }

    func cancel() {
        cancelled = true
        finish(.idle)
    }

    private func finish(_ result: Phase) {
        meterTimer?.invalidate()
        meterTimer = nil
        session?.stopRunning()
        player?.stop()
        session = nil
        sink = nil
        player = nil
        if let v = previousVolume { SystemVolume.setVolume(v) }
        previousVolume = nil
        phase = result
        // Let the volume restore settle before the notch shows volume changes again
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            CurveCalibrator.running = false
        }
    }

    // MARK: Input device

    private enum CalibrationError: LocalizedError {
        case noMicrophone, noTone
        var errorDescription: String? { self == .noTone ? "the player didn't start" : "no microphone found" }
    }

    /// The built-in microphone (never the AirPods' own, which would lower their sound quality)
    private static func microphone() -> AVCaptureDevice? {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone], mediaType: .audio,
                                                     position: .unspecified).devices
        return found.first { $0.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn) }
            ?? found.first
            ?? AVCaptureDevice.default(for: .audio)
    }

    /// Two seconds of a 1 kHz sine at −10 dBFS, exactly 2000 cycles so it loops without a click
    private static func toneWAV() -> Data {
        let rate = 48000, seconds = 2
        let frames = rate * seconds
        var samples = Data(capacity: frames * 2)
        for i in 0..<frames {
            let v = Int16((sin(2 * Double.pi * 1000 * Double(i) / Double(rate)) * 0.447 * 32767).rounded())
            withUnsafeBytes(of: v.littleEndian) { samples.append(contentsOf: $0) }
        }
        var wav = Data()
        func text(_ s: String) { wav.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36 + samples.count)); text("WAVE")
        text("fmt "); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        text("data"); u32(UInt32(samples.count))
        wav.append(samples)
        return wav
    }

    private static func defaultInput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr
            ? id : nil
    }

    private static func setDefaultInput(_ id: AudioDeviceID) {
        var device = id
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &device)
    }

    /// The Mac's own microphone (so the AirPods' microphone, which lowers their sound quality,
    /// is never used)
    private static func builtInMic() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return nil }
        for id in ids {
            var transport = UInt32(0)
            var tSize = UInt32(MemoryLayout<UInt32>.size)
            var tAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &tAddr, 0, nil, &tSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }
            var sAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                   mScope: kAudioDevicePropertyScopeInput,
                                                   mElement: kAudioObjectPropertyElementMain)
            var sSize = UInt32(0)
            if AudioObjectGetPropertyDataSize(id, &sAddr, 0, nil, &sSize) == noErr, sSize > 0 { return id }
        }
        return nil
    }
}

private final class ToneState { var phase = 0.0 }

/// Measures the power at exactly 1 kHz (a Goertzel filter), averaged over whatever arrives
/// between resets. Fed from the microphone's audio thread.
final class ToneMeter {
    var sampleRate: Double = 48000
    private let lock = NSLock()
    private var powers: [Double] = []
    private var block: [Double] = []

    /// Samples are gathered into quarter-second blocks before measuring: the longer the block,
    /// the narrower the slice of sound around 1 kHz that's measured (about 4 Hz here), so most
    /// background noise falls outside it
    func add(_ data: UnsafePointer<Float>, count n: Int, step: Int = 1) {
        guard n > 0 else { return }
        let size = max(1024, Int(sampleRate / 4))
        block.reserveCapacity(size)
        for i in 0..<n {
            block.append(Double(data[i * step]))
            if block.count >= size {
                let p = Self.goertzel(block, rate: sampleRate)
                block.removeAll(keepingCapacity: true)
                lock.lock()
                powers.append(p)
                lock.unlock()
            }
        }
    }

    private static func goertzel(_ x: [Double], rate: Double) -> Double {
        let n = x.count
        let k = 2 * cos(2 * Double.pi * 1000 / rate)
        var s1 = 0.0, s2 = 0.0
        for v in x {
            let s = v + k * s1 - s2
            s2 = s1
            s1 = s
        }
        return max(0, s1 * s1 + s2 * s2 - k * s1 * s2) / Double(n * n)
    }

    func reset() {
        lock.lock()
        powers = []
        lock.unlock()
    }

    /// The middle of the samples since the last reset (ignores a sudden noise in one of them)
    func medianPower() -> Double? {
        lock.lock()
        let p = powers.sorted()
        lock.unlock()
        guard !p.isEmpty else { return nil }
        return p.count % 2 == 1 ? p[p.count / 2] : (p[p.count / 2 - 1] + p[p.count / 2]) / 2
    }

    /// dB of the 1 kHz tone (relative, not calibrated)
    func level() -> Double {
        guard let p = medianPower(), p > 0 else { return -140 }
        return 10 * log10(p)
    }
}

/// Receives the microphone's audio and hands it to the meter
private final class MicSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let meter: ToneMeter
    init(meter: ToneMeter) { self.meter = meter }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let asbd = sb.formatDescription?.audioStreamBasicDescription,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 else { return }
        meter.sampleRate = asbd.mSampleRate
        try? sb.withAudioBufferList { list, _ in
            guard let buf = list.first, let p = buf.mData?.assumingMemoryBound(to: Float.self) else { return }
            let channels = max(1, Int(buf.mNumberChannels))
            let frames = Int(buf.mDataByteSize) / MemoryLayout<Float>.size / channels
            meter.add(p, count: frames, step: channels)
        }
    }
}

// MARK: - The window

@MainActor
final class CalibrationWindow: NSObject, NSWindowDelegate {
    static let shared = CalibrationWindow()
    private var window: NSWindow?

    func show() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: CalibrationView()))
        w.styleMask = [.titled, .closable]
        w.title = "Measure Your AirPods"
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = self
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        CurveCalibrator.shared.cancel()
        Task { @MainActor in self.window = nil }
    }
}

struct CalibrationView: View {
    @ObservedObject private var cal = CurveCalibrator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Measure your AirPods' volume curve")
                .font(.title3.weight(.semibold))
            Text("This teaches Murmur how much quieter each volume step really is on your AirPods, using your Mac's microphone. Each run takes about two minutes; two or three runs on different occasions make it reliable.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                step(1, "Turn off **Automatic Ear Detection** (System Settings › your AirPods), so they keep playing outside your ears.")
                step(2, "Set **Noise Control** to **Off** (Control Center › Sound).")
                step(3, "Press **Play Tone**, take out one AirPod, and find the spot where the bar is highest: start just above the Esc key, by the hinge, with the ear tip against the gap.")
                step(4, "Rest it there rather than holding it, and lay something soft over it (a folded cloth or a sock) so it can't move and room noise is muffled. Then press **Measure** and leave it alone.")
            }

            meterView

            HStack {
                statusText
                Spacer()
                buttons
            }
        }
        .padding(22)
        .frame(width: 500)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.secondary.opacity(0.2)))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var meterView: some View {
        let fraction = min(1, cal.signal / 50)
        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(cal.signalGood ? Color.green : Color.orange)
                        .frame(width: max(6, g.size.width * fraction))
                        .animation(.easeOut(duration: 0.2), value: fraction)
                }
            }
            .frame(height: 10)
            Text(cal.phase == .positioning
                 ? (cal.signalGood ? "Strong signal: hold it there" : "Move the AirPod closer to the microphone")
                 : "Signal")
                .font(.caption)
                .foregroundStyle(.secondary)
            // The numbers behind the bar: tone should be at least 25 dB above room
            if cal.phase == .positioning || cal.roomLevel != nil {
                Text(readout)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var readout: String {
        let room = cal.roomLevel.map { String(format: "%.0f dB", $0) } ?? "measuring…"
        let tone = cal.toneLevel.map { String(format: "%.0f dB", $0) } ?? "–"
        let gap = cal.roomLevel != nil && cal.toneLevel != nil ? String(format: " (%.0f dB above)", cal.signal) : ""
        return "Microphone: \(cal.micName.isEmpty ? "unknown" : cal.micName) · room \(room) · tone \(tone)\(gap)"
    }

    @ViewBuilder
    private var statusText: some View {
        switch cal.phase {
        case .idle:
            Text(CurveCalibrator.curve == nil ? "Not measured yet"
                 : "Saved from \(CurveCalibrator.runCount) run\(CurveCalibrator.runCount == 1 ? "" : "s"); another run refines it")
                .foregroundStyle(.secondary)
        case .positioning:
            Text("Playing a 1 kHz tone").foregroundStyle(.secondary)
        case .measuring:
            Text(cal.progressText).foregroundStyle(.secondary).monospacedDigit()
        case .done(let text):
            VStack(alignment: .leading, spacing: 6) {
                Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                Text(cal.summary.map { row in
                    "\(Int((row.volume * 100).rounded()))%: \(String(format: "%.1f", row.db)) dB" + (row.spread > 0 ? String(format: " (±%.1f)", row.spread / 2) : "")
                }.joined(separator: " · "))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        case .failed(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch cal.phase {
        case .idle, .done, .failed:
            Button("Play Tone") { cal.begin() }
                .keyboardShortcut(.defaultAction)
        case .positioning:
            Button("Cancel") { cal.cancel() }
            Button("Measure") { cal.measure() }
                .keyboardShortcut(.defaultAction)
                .disabled(!cal.signalGood)
        case .measuring:
            Button("Cancel") { cal.cancel() }
        }
    }
}
