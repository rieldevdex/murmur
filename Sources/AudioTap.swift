import ScreenCaptureKit
import AVFoundation
import Accelerate
import AppKit
import CoreGraphics
import CoreAudio

// What the renderer reads each frame: band levels in dB plus raw samples for the scope.
struct AudioSnapshot {
    var db: [Float]
    var scope: [Float]
    var seq: Int
    var rms: Float = 0          // loudness of the latest ~50 ms, full scale = 1

    static func silent(seq: Int) -> AudioSnapshot {
        AudioSnapshot(db: [Float](repeating: -140, count: AudioTap.bandCount),
                      scope: [Float](repeating: 0, count: AudioTap.scopeLength),
                      seq: seq)
    }
}

enum AudioSource: Int, CaseIterable {
    case spotify = 0, system

    var name: String {
        switch self {
        case .spotify: return "SPOTIFY"
        case .system: return "SYSTEM"
        }
    }
}

enum TapStatus: Equatable {
    case starting
    case waitingForSpotify
    case needsPermission
    case running
    case failed(String)
}

// One preallocated FFT. Magnitudes are scaled so a sine of amplitude A reads about A/2
// once divided by n, whatever n is, so two sizes can be mixed in one display.
final class FFTBank {
    let n: Int
    var input: [Float]                 // filled by the caller, oldest sample first
    private(set) var mags: [Float]

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]

    init(n: Int) {
        self.n = n
        log2n = vDSP_Length(n.trailingZeroBitCount)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                             count: n, isHalfWindow: false)
        input = [Float](repeating: 0, count: n)
        windowed = [Float](repeating: 0, count: n)
        real = [Float](repeating: 0, count: n / 2)
        imag = [Float](repeating: 0, count: n / 2)
        mags = [Float](repeating: 0, count: n / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func run() {
        let half = n / 2
        vDSP_vmul(input, 1, window, 1, &windowed, 1, vDSP_Length(n))
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                windowed.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                i[0] = 0        // zrip packs the Nyquist value here; drop it so bin 0 is pure DC
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
    }
}

final class AudioTap: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    static let spotifyID = "com.spotify.client"
    static let bandCount = 64
    static let scopeLength = 1024

    @Published private(set) var status: TapStatus = .starting
    /// How many times capture had to be restarted, and why (shown in Settings › Advanced)
    @Published private(set) var recoveries = 0
    @Published private(set) var lastRecovery: String?
    /// Whether the music should be audible right now (set by the app from Spotify's state)
    var isPlayingHint: (() -> Bool)?

    // Main-thread state
    private(set) var source: AudioSource = .spotify
    private var stream: SCStream?
    private var isStarting = false
    private var retryPending = false
    private var askedForPermission = false
    private var began = false
    private var observers: [NSObjectProtocol] = []
    private var watchdog: Timer?
    private var restartTask: Task<Void, Never>?
    private var outputListener: AudioObjectPropertyListenerBlock?

    // Audio-queue state (only touched on audioQueue)
    private let audioQueue = DispatchQueue(label: "audio.tap", qos: .userInteractive)
    private let videoQueue = DispatchQueue(label: "audio.tap.video", qos: .utility)
    private var sampleRate: Float = 44100
    private let shortFFT = FFTBank(n: 2048)    // treble and mids: fast response
    private let longFFT = FFTBank(n: 4096)     // bass: about 10.8 Hz per bin instead of 21.5
    private var ring = [Float](repeating: 0, count: 4096)
    private var writeIndex = 0
    private var pending = 0
    private let hop = 512                      // analyse roughly 86 times a second
    private var scope = [Float](repeating: 0, count: AudioTap.scopeLength)
    private var seq = 0

    private let fMin: Float = 50
    private let fMax: Float = 16000
    private let crossover: Float = 300          // bands centred below this use the long FFT

    // Shared between the audio queue and the renderer
    private let lock = NSLock()
    private var latest = AudioSnapshot.silent(seq: 0)
    private var lastAudio = CFAbsoluteTimeGetCurrent()     // when the last audio buffer arrived
    private var energySum = 0.0                            // Σ sample², since last taken
    private var energyCount = 0

    /// The mean square of all audio since the last call (nil if none arrived), and resets it
    func takeEnergy() -> Double? {
        lock.lock()
        defer { energySum = 0; energyCount = 0; lock.unlock() }
        return energyCount > 0 ? energySum / Double(energyCount) : nil
    }

    func snapshot() -> AudioSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    private static var spotifyIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: spotifyID).isEmpty
    }

    // MARK: - Lifecycle (main thread)

    /// Call once. In Spotify mode, capture follows Spotify launching and quitting;
    /// in System mode it captures every app except this one.
    /// The app's one tap, for Settings to read its health
    static weak var current: AudioTap?

    func begin(source: AudioSource) {
        guard !began else { return }
        began = true
        Self.current = self
        self.source = source

        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                        object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == AudioTap.spotifyID,
                  self?.source == .spotify else { return }
            // Give Spotify a moment to register before asking ScreenCaptureKit for it
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.startCapture() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                        object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == AudioTap.spotifyID,
                  self?.source == .spotify else { return }
            self?.stopCapture()
            self?.status = .waitingForSpotify
        })

        // ScreenCaptureKit streams can go quiet without reporting an error after these events,
        // so capture is restarted after each of them
        let nc = NotificationCenter.default
        let triggers: [(NotificationCenter, Notification.Name, String)] = [
            (ws, NSWorkspace.didWakeNotification, "waking from sleep"),
            (ws, NSWorkspace.screensDidWakeNotification, "the display waking"),
            (ws, NSWorkspace.sessionDidBecomeActiveNotification, "unlocking"),
            (nc, NSApplication.didChangeScreenParametersNotification, "a display change")
        ]
        for (center, name, reason) in triggers {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.restartSoon(reason)
            })
        }
        watchOutputDevice()

        // And in case it goes quiet for any other reason: if no audio has arrived for a few seconds
        // while something is playing, start again
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.checkForStall()
        }
        watchdog?.tolerance = 1

        startCapture()
    }

    // MARK: - Recovery (main thread)

    /// Restarts capture shortly (several triggers often fire together, e.g. on waking)
    private func restartSoon(_ reason: String, after seconds: Double = 1.5) {
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self = self else { return }
            self.restartCapture(reason)
        }
    }

    private func restartCapture(_ reason: String) {
        guard began, !isStarting else { return }
        if let old = stream {
            stream = nil
            Task { try? await old.stopCapture() }
        } else if status == .running {
            return
        }
        recoveries += 1
        lastRecovery = "after \(reason) at " + Self.clock.string(from: Date())
        markAudio()
        startCapture()          // keeps showing the visuals; only a failure changes the status
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private func markAudio() {
        lock.lock()
        lastAudio = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    private func checkForStall() {
        guard status == .running, stream != nil, !isStarting else { return }
        lock.lock()
        let quiet = CFAbsoluteTimeGetCurrent() - lastAudio
        lock.unlock()
        guard quiet > 4 else { return }
        // Only when sound is actually expected: the Mac's output is busy, and in Spotify mode,
        // Spotify says it's playing (so a paused song, or one playing on your phone, doesn't count)
        guard Self.outputIsBusy() else { return }
        if source == .spotify, let playing = isPlayingHint, !playing() { return }
        restartCapture("the audio stopped arriving")
    }

    /// True while any app is sending sound to the current output device
    private static func outputIsBusy() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &device) == noErr, device != 0 else { return true }
        var running = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return true }
        return running != 0
    }

    /// Switching to AirPods or speakers can leave the stream silent; restart when it happens
    private func watchOutputDevice() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.restartSoon("switching audio output", after: 1.0) }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                               DispatchQueue.main, block) == noErr {
            outputListener = block
        }
    }

    /// Switch between Spotify only and all system audio
    func setSource(_ newSource: AudioSource) {
        guard newSource != source else { return }
        source = newSource
        guard began else { return }
        stopCapture()
        status = .starting
        startCapture()        // if a start is already in flight, it restarts itself with the new source
    }

    private func startCapture() {
        guard stream == nil, !isStarting else { return }
        if source == .spotify && !Self.spotifyIsRunning {
            status = .waitingForSpotify
            return
        }

        if !CGPreflightScreenCaptureAccess() {
            if !askedForPermission {
                askedForPermission = true
                CGRequestScreenCaptureAccess()          // shows the system prompt once
            }
            status = .needsPermission
            scheduleRetry()
            return
        }

        isStarting = true
        let wanted = source
        Task { @MainActor in
            do {
                let made = try await self.makeStream(for: wanted)
                self.isStarting = false

                // The source changed while this was starting: throw it away and start the new one
                guard wanted == self.source else {
                    if let made = made { try? await made.stopCapture() }
                    self.startCapture()
                    return
                }
                guard let s = made else {
                    self.status = wanted == .spotify ? .waitingForSpotify : .failed("No display found")
                    self.scheduleRetry()
                    return
                }
                self.stream = s
                self.markAudio()
                self.status = .running
            } catch {
                self.isStarting = false
                guard wanted == self.source else { self.startCapture(); return }
                self.status = CGPreflightScreenCaptureAccess() ? .failed(error.localizedDescription) : .needsPermission
                self.scheduleRetry()
            }
        }
    }

    /// Builds and starts a stream for the source. Returns nil if Spotify isn't available to capture.
    @MainActor
    private func makeStream(for source: AudioSource) async throws -> SCStream? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { return nil }

        let filter: SCContentFilter
        switch source {
        case .spotify:
            guard let spotify = content.applications.first(where: { $0.bundleIdentifier == Self.spotifyID })
            else { return nil }
            filter = SCContentFilter(display: display, including: [spotify], exceptingWindows: [])
        case .system:
            // Every app's audio except our own
            let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        }

        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 44100
        cfg.channelCount = 1
        cfg.width = 2; cfg.height = 2                   // video is unused
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        // A screen output that ignores its frames keeps ScreenCaptureKit from logging dropped frames
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try await s.startCapture()
        return s
    }

    private func stopCapture() {
        let s = stream
        stream = nil
        if let s = s { Task { try? await s.stopCapture() } }
        lock.lock()
        latest = AudioSnapshot.silent(seq: latest.seq + 1)
        lock.unlock()
    }

    private func scheduleRetry() {
        guard !retryPending else { return }
        retryPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.retryPending = false
            self?.startCapture()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            guard self.stream === stream else { return }      // an old stream we already replaced
            self.stream = nil
            let spotifyGone = self.source == .spotify && !Self.spotifyIsRunning
            self.status = spotifyGone ? .waitingForSpotify : .failed(error.localizedDescription)
            self.scheduleRetry()
        }
    }

    // MARK: - Audio (audio queue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid else { return }
        lock.lock()
        lastAudio = CFAbsoluteTimeGetCurrent()
        lock.unlock()
        if let asbd = sb.formatDescription?.audioStreamBasicDescription, asbd.mSampleRate > 0 {
            sampleRate = Float(asbd.mSampleRate)
        }
        try? sb.withAudioBufferList { abl, _ in
            guard let buf = abl.first,
                  let p = buf.mData?.assumingMemoryBound(to: Float.self) else { return }
            let channels = max(1, Int(buf.mNumberChannels))
            let frames = Int(buf.mDataByteSize) / MemoryLayout<Float>.size / channels
            push(p, frames: frames, step: channels)
        }
    }

    private func push(_ p: UnsafeMutablePointer<Float>, frames: Int, step: Int) {
        let cap = ring.count
        var squares = 0.0
        for i in 0..<frames {
            let v = p[i * step]
            // One corrupt sample would otherwise turn the whole spectrum into NaN
            let clean = v.isFinite ? max(-4, min(4, v)) : 0
            ring[writeIndex] = clean
            squares += Double(clean) * Double(clean)
            writeIndex += 1
            if writeIndex == cap { writeIndex = 0 }
        }
        // Every sample counts towards loudness (not just snapshots), like a sound level meter
        lock.lock()
        energySum += squares
        energyCount += frames
        lock.unlock()
        pending += frames
        if pending >= hop {
            pending %= hop
            analyse()
        }
    }

    private func copyLatest(into out: inout [Float]) {
        let cap = ring.count
        let count = out.count
        var idx = (writeIndex - count + cap) % cap
        for i in 0..<count {
            out[i] = ring[idx]
            idx += 1
            if idx == cap { idx = 0 }
        }
    }

    private func analyse() {
        copyLatest(into: &longFFT.input)
        copyLatest(into: &shortFFT.input)
        longFFT.run()
        shortFFT.run()

        // Log-spaced bands from 50 Hz to 16 kHz, in dB, tilted so treble isn't tiny
        let count = Self.bandCount
        let ratio = fMax / fMin
        var db = [Float](repeating: -140, count: count)
        for b in 0..<count {
            let f0 = fMin * pow(ratio, Float(b) / Float(count))
            let f1 = fMin * pow(ratio, Float(b + 1) / Float(count))
            let centre = (f0 * f1).squareRoot()
            let fft = centre < crossover ? longFFT : shortFFT
            let m = magnitude(fft, f0, f1)
            let tilt = 3.5 * log2(centre / 1000)          // about +3.5 dB per octave above 1 kHz
            let value = 20 * log10(m / Float(fft.n) + 1e-7) + tilt
            db[b] = value.isFinite ? value : -140
        }

        copyLatest(into: &scope)
        seq &+= 1
        var rms: Float = 0
        vDSP_rmsqv(shortFFT.input, 1, &rms, vDSP_Length(shortFFT.n))
        let snap = AudioSnapshot(db: db, scope: scope, seq: seq, rms: rms.isFinite ? rms : 0)
        lock.lock()
        latest = snap
        lock.unlock()
    }

    private func magnitude(_ fft: FFTBank, _ f0: Float, _ f1: Float) -> Float {
        let mags = fft.mags
        let half = mags.count
        let binHz = sampleRate / Float(fft.n)
        let e0 = f0 / binHz
        let e1 = f1 / binHz

        if e1 - e0 < 1 {
            // Band narrower than one bin: interpolate so neighbours differ
            let c = (e0 + e1) / 2
            let i = max(0, min(Int(c), half - 2))
            let frac = max(0, min(1, c - Float(i)))
            return mags[i] * (1 - frac) + mags[i + 1] * frac
        }
        let lo = min(Int(e0.rounded(.up)), half - 1)
        let hi = max(lo, min(Int(e1.rounded(.down)), half - 1))
        return mags[lo...hi].max() ?? 0
    }
}
