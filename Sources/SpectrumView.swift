import SwiftUI

enum VisualStyle: Int, CaseIterable {
    case pixel = 0, bars, wave, radial, scope, waterfall, ridge, particles

    var name: String {
        switch self {
        case .pixel: return "PIXEL"
        case .bars: return "BARS"
        case .wave: return "WAVE"
        case .radial: return "RADIAL"
        case .scope: return "SCOPE"
        case .waterfall: return "WATERFALL"
        case .ridge: return "RIDGE"
        case .particles: return "PARTICLES"
        }
    }

    /// Styles that can draw fading afterimages of earlier frames
    var supportsTrails: Bool {
        self == .bars || self == .wave || self == .radial
    }
}

// MARK: - Per-frame processing (runs on the render clock, not the audio clock)

struct VisualFrame {
    var levels: [Float]
    var lagged: [Float]      // levels trailing about 60 ms behind, for motion blur
    var peaks: [Float]
    var beat: Float          // 1 on a detected beat, decaying towards 0
    var scope: [Float]
    var scopeScale: Float
    var history: [[Float]]   // newest first, sampled 30 times a second
    var particles: [Particle]
    var idle: Float          // 0 while music plays, eases towards 1 after a quiet spell
    var time: Double
}

final class BandProcessor {
    private let count = AudioTap.bandCount
    private let bassBands = 20                   // roughly 50–300 Hz, where kicks live
    private var smoothed: [Float]
    private var lagged: [Float]
    private var peaks: [Float]
    private var peakHold: [Float]
    private var lastVals: [Float]
    private var refDb: Float = -40
    private var scopeRef: Float = 0.05
    private var lastSeq = -1
    private var lastTime: Date?
    private var fluxAverage: Float = 0
    private var sinceBeat: Float = 1
    private var beat: Float = 0

    private let historyLength = 120              // 4 seconds at 30 rows per second
    private var history: [[Float]]
    private var historyHead = 0
    private var historyClock: Float = 0
    private var quietFor: Float = 0
    private var idle: Float = 0
    private let field = ParticleField()
    private let simulateParticles: Bool

    /// Pass `particles: false` where only levels and beats are needed, to skip the dot simulation
    init(particles: Bool = true) {
        simulateParticles = particles
        smoothed = [Float](repeating: 0, count: count)
        lagged = [Float](repeating: 0, count: count)
        peaks = [Float](repeating: 0, count: count)
        peakHold = [Float](repeating: 0, count: count)
        lastVals = [Float](repeating: 0, count: count)
        history = [[Float]](repeating: [Float](repeating: 0, count: count), count: historyLength)
    }

    /// `range` is how many dB below the recent peak reach the bottom of the display.
    func step(_ snap: AudioSnapshot, now: Date, range: Float) -> VisualFrame {
        let dt = Float(min(0.1, max(0, now.timeIntervalSince(lastTime ?? now))))
        lastTime = now
        // Never let one bad value stick: NaN feeds on itself in the smoothing below
        if !refDb.isFinite { refDb = -40 }
        if !fluxAverage.isFinite { fluxAverage = 0 }
        if !scopeRef.isFinite { scopeRef = 0.05 }
        guard snap.db.count == count else {
            return frame(scope: snap.scope, scopeScale: 1, now: now)
        }

        // 1. Auto-gain reference: jumps up to new peaks, sinks about 3.5 dB per second
        let frameMax = snap.db.max() ?? -140
        refDb = max(frameMax, refDb - 3.5 * dt)
        refDb = max(refDb, -45)

        // 2. Normalise to 0...1 and blend neighbouring bands a little
        var vals = [Float](repeating: 0, count: count)
        for b in 0..<count {
            let v = max(0, min(1, (snap.db[b] - (refDb - range)) / range))
            vals[b] = pow(v, 1.4)
        }
        var blended = vals
        for b in 1..<(count - 1) {
            blended[b] = vals[b - 1] * 0.2 + vals[b] * 0.6 + vals[b + 1] * 0.2
        }

        // 3. Fast attack, slow fall, both timed in seconds so frame rate doesn't change the feel
        let attack = 1 - exp(-dt / 0.012)
        let fall = exp(-dt / 0.15)
        for b in 0..<count {
            let target = blended[b] * 0.92
            if target > smoothed[b] {
                smoothed[b] += (target - smoothed[b]) * attack
            } else {
                smoothed[b] = max(target, smoothed[b] * fall)
            }
        }

        // Where the bars were a moment ago: the far end of the motion-blur smear
        let lagK = 1 - exp(-dt / 0.06)
        for b in 0..<count {
            if !smoothed[b].isFinite { smoothed[b] = 0 }
            if !lagged[b].isFinite { lagged[b] = smoothed[b] }
            lagged[b] += (smoothed[b] - lagged[b]) * lagK
        }

        // 4. Peak markers: hold briefly, then drift down
        for b in 0..<count {
            if smoothed[b] >= peaks[b] {
                peaks[b] = smoothed[b]
                peakHold[b] = 0.4
            } else if peakHold[b] > 0 {
                peakHold[b] -= dt
            } else {
                peaks[b] = max(smoothed[b], peaks[b] - 0.8 * dt)
            }
        }

        // 5. Beat detection: spectral flux in the bass against a running average
        sinceBeat += dt
        var beatHit = false
        if snap.seq != lastSeq {
            lastSeq = snap.seq
            var flux: Float = 0
            for b in 0..<bassBands { flux += max(0, vals[b] - lastVals[b]) }
            flux /= Float(bassBands)
            lastVals = vals
            if flux > fluxAverage * 1.6 + 0.04, sinceBeat > 0.2 {
                beat = 1
                sinceBeat = 0
                beatHit = true
            }
            fluxAverage += (flux - fluxAverage) * 0.08
        }
        beat *= exp(-dt / 0.16)

        // 6. History for the waterfall and ghost trails, at a steady 30 rows per second
        historyClock += dt
        let rowTime: Float = 1.0 / 30
        if historyClock >= rowTime {
            historyClock = min(historyClock - rowTime, rowTime)
            history[historyHead] = smoothed
            historyHead = (historyHead + 1) % historyLength
        }

        // 7. Idle: after 1.5 s of near-silence, ease the breathing animation in
        let loudest = smoothed.max() ?? 0
        quietFor = loudest < 0.04 ? quietFor + dt : 0
        let idleTarget: Float = quietFor > 1.5 ? 1 : 0
        idle += (idleTarget - idle) * min(1, dt * 2)

        if simulateParticles { field.step(dt: dt, levels: smoothed, beat: beatHit) }

        // 8. Scope auto-scale
        let scopePeak = snap.scope.reduce(Float(0)) { max($0, abs($1)) }
        scopeRef = max(scopePeak, scopeRef * exp(-dt / 1.2), 0.02)

        return frame(scope: snap.scope, scopeScale: 1 / scopeRef, now: now)
    }

    private func frame(scope: [Float], scopeScale: Float, now: Date) -> VisualFrame {
        var ordered: [[Float]] = []
        ordered.reserveCapacity(historyLength)
        for k in 0..<historyLength {
            ordered.append(history[(historyHead - 1 - k + historyLength * 2) % historyLength])
        }
        return VisualFrame(levels: smoothed, lagged: lagged, peaks: peaks, beat: beat,
                           scope: scope, scopeScale: scopeScale,
                           history: ordered, particles: field.particles, idle: idle,
                           time: now.timeIntervalSinceReferenceDate)
    }
}

// Crossfades between palettes when the track or colour setting changes
final class RampFader {
    private var from: Ramp?
    private var to: Ramp?
    private var start = Date.distantPast
    private let duration = 0.9

    func ramp(target: Ramp, now: Date) -> Ramp {
        guard let current = to else {
            from = target; to = target
            return target
        }
        if target != current {
            from = value(now)
            to = target
            start = now
        }
        return value(now)
    }

    private func value(_ now: Date) -> Ramp {
        guard let from = from, let to = to else { return .ember }
        let t = min(1, max(0, now.timeIntervalSince(start) / duration))
        let s = t * t * (3 - 2 * t)
        return s >= 1 ? to : Ramp.mix(from, to, s)
    }
}

// MARK: - The live screen: the only part of the window that redraws every frame

struct LiveScreen: View {
    @ObservedObject var tap: AudioTap
    let style: VisualStyle
    let ramp: Ramp
    let range: Float
    let artwork: NSImage?
    let showPeaks: Bool
    let trails: Bool
    let motionBlur: Int
    let idleEnabled: Bool
    let look: Look

    @State private var processor = BandProcessor()
    @State private var fader = RampFader()

    @State private var onScreen = true
    @ObservedObject private var pacing = FramePacing.shared

    var body: some View {
        visuals.background(OnScreenReader(onScreen: $onScreen))
    }

    /// Redraws only while its window can be seen, at the chosen frame rate
    @ViewBuilder private var visuals: some View {
        let running = tap.status == .running
        let framed = look.framedScreen
        TimelineView(.animation(minimumInterval: pacing.interval, paused: !running || !onScreen)) { timeline in
            let visual = processor.step(tap.snapshot(), now: timeline.date, range: range)
            let shown = fader.ramp(target: ramp, now: timeline.date)
            let beat = Double(visual.beat)

            ZStack {
                if framed && look == .crafted {
                    // A dark recess around the screen so the bezel reads as a separate part
                    ScreenShape()
                        .stroke(Color.black.opacity(0.85), style: StrokeStyle(lineWidth: 12, lineJoin: .round))
                }

                ZStack {
                    if framed {
                        ScreenShape().fill(Color.black.opacity(look == .ambient ? 0.55 : 1))
                    }
                    if running {
                        SpectrumView(visual: visual, style: style, ramp: shown, artwork: artwork,
                                     showPeaks: showPeaks, trails: trails, motionBlur: motionBlur,
                                     idleEnabled: idleEnabled)
                            .id(style)
                            .transition(.visualSwap)
                            .padding(.horizontal, framed ? 26 : 0)
                            .padding(.vertical, framed ? 28 : 0)
                    } else {
                        StatusOverlay(status: tap.status, accent: shown.color(0))
                    }
                    if look == .crafted {
                        ScreenGlass()
                    }
                }
                .clipShape(framed ? AnyShape(ScreenShape()) : AnyShape(Rectangle()))

                if framed {
                    ScreenShape()
                        .stroke(shown.color(0).opacity(0.7 + 0.3 * beat),
                                style: StrokeStyle(lineWidth: 5, lineJoin: .round))
                        .shadow(color: shown.color(0).opacity((look == .crafted ? 0.35 : 0) + 0.6 * beat),
                                radius: look == .crafted ? 18 : 14)
                }
            }
        }
    }
}

struct StatusOverlay: View {
    let status: TapStatus
    let accent: Color

    private var headline: String {
        switch status {
        case .starting: return "TUNING IN…"
        case .waitingForSpotify: return "WAITING FOR SPOTIFY"
        case .needsPermission: return "SCREEN RECORDING ACCESS NEEDED"
        case .running: return ""
        case .failed: return "SIGNAL LOST"
        }
    }

    private var detail: String? {
        switch status {
        case .waitingForSpotify:
            return "Open Spotify and press play."
        case .needsPermission:
            return "Turn on Murmur under Privacy & Security › Screen Recording, then reopen the app."
        case .failed(let message):
            return "\(message)\nRetrying…"
        default:
            return nil
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(headline)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
            if let detail = detail {
                Text(detail)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(accent.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            if status == .needsPermission {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("OPEN SETTINGS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .overlay(Capsule().stroke(accent.opacity(0.7), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(30)
    }
}

// MARK: - Spectrum drawing (six styles)

struct SpectrumView: View {
    let visual: VisualFrame
    let style: VisualStyle
    let ramp: Ramp
    let artwork: NSImage?
    let showPeaks: Bool
    let trails: Bool
    let motionBlur: Int          // 0 off, 1 light, 2 strong
    let idleEnabled: Bool

    var body: some View {
        let lut = ramp.lut()
        GeometryReader { geo in
            ZStack {
                Canvas { ctx, size in
                    if trails && style.supportsTrails {
                        // Older frames first, fainter the older they are
                        let h = visual.history
                        for (k, alpha) in [(8, 0.07), (6, 0.12), (4, 0.18), (2, 0.26)] where k < h.count {
                            var ghost = ctx
                            ghost.opacity = alpha
                            draw(&ghost, size, lut, h[k].map { Double($0) }, glow: false)
                        }
                    }
                    let current = visual.levels.map { Double($0) }
                    if motionBlur > 0 && style.supportsTrails {
                        // Smear each bar back towards where it was a moment ago,
                        // fainter the further back, like a camera shutter left open
                        let lag = visual.lagged.map { Double($0) }
                        let strength = motionBlur == 1 ? 1.0 : 2.2
                        let samples = motionBlur == 1 ? 5 : 8
                        for i in stride(from: samples, through: 1, by: -1) {
                            let t = Double(i) / Double(samples)
                            let lv = zip(current, lag).map { pair in
                                max(0, min(1, pair.0 + (pair.1 - pair.0) * t * strength))
                            }
                            var smear = ctx
                            smear.opacity = 0.32 * (1 - t) + 0.06
                            draw(&smear, size, lut, lv, glow: false)
                        }
                    }
                    draw(&ctx, size, lut, current, glow: true)
                    if idleEnabled && visual.idle > 0.01 {
                        drawIdle(&ctx, size)
                    }
                }

                if style == .radial {
                    let d = min(geo.size.width, geo.size.height) * 0.38
                    Group {
                        if let art = artwork {
                            Image(nsImage: art).resizable().scaledToFill()
                        } else {
                            Color.white.opacity(0.08)
                        }
                    }
                    .frame(width: d, height: d)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(ramp.color(0).opacity(0.7), lineWidth: 2))
                    .scaleEffect(1 + 0.06 * CGFloat(visual.beat))
                }
            }
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ lut: [Color],
                      _ lv: [Double], glow: Bool) {
        switch style {
        case .pixel:     drawPixels(&ctx, size, lut, lv)
        case .bars:      drawBars(&ctx, size, lv, glow: glow)
        case .wave:      drawWave(&ctx, size, lv, glow: glow)
        case .radial:    drawRadial(&ctx, size, lut, lv, glow: glow)
        case .scope:     drawScope(&ctx, size)
        case .waterfall: drawWaterfall(&ctx, size)
        case .ridge:     drawRidge(&ctx, size, lut)
        case .particles: drawParticles(&ctx, size, lut)
        }
    }

    private func pick(_ lut: [Color], _ t: Double) -> Color {
        lut[Int((min(1, max(0, t)) * Double(lut.count - 1)).rounded())]
    }

    private func mirroredShading(vertical: Bool, _ size: CGSize) -> GraphicsContext.Shading {
        .linearGradient(
            Gradient(colors: [ramp.color(1), ramp.color(0), ramp.color(1)]),
            startPoint: .zero,
            endPoint: vertical ? CGPoint(x: 0, y: size.height) : CGPoint(x: size.width, y: 0))
    }

    // PIXEL: the LED matrix
    private func drawPixels(_ ctx: inout GraphicsContext, _ size: CGSize, _ lut: [Color], _ lv: [Double]) {
        let cols = max(lv.count, 1)
        let side = 9
        let rows = side * 2
        let cw = size.width / CGFloat(cols)
        let ch = size.height / CGFloat(rows)
        let inset: CGFloat = 1.2

        var dim = Path()
        var lit: [(CGRect, Color)] = []

        for c in 0..<lv.count {
            let lights = max(1, Int((lv[c] * Double(side)).rounded()))
            for r in 0..<rows {
                let rect = CGRect(x: CGFloat(c) * cw + inset, y: CGFloat(r) * ch + inset,
                                  width: cw - inset * 2, height: ch - inset * 2)
                let d = r < side ? side - 1 - r : r - side
                if d < lights {
                    lit.append((rect, pick(lut, Double(d) / Double(side - 1))))
                } else {
                    dim.addRoundedRect(in: rect, cornerSize: CGSize(width: 1.5, height: 1.5))
                }
            }
        }

        ctx.fill(dim, with: .color(Color.white.opacity(0.04)))
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 6))
            for (rect, color) in lit {
                layer.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color.opacity(0.7)))
            }
        }
        for (rect, color) in lit {
            ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color))
        }
    }

    // BARS: rounded bars growing from the centre, with optional falling peak caps
    private func drawBars(_ ctx: inout GraphicsContext, _ size: CGSize, _ lv: [Double], glow: Bool) {
        let cols = max(lv.count, 1)
        let cw = size.width / CGFloat(cols)
        let bw = cw * 0.58
        let midY = size.height / 2
        let usable = showPeaks ? size.height - 14 : size.height    // leave room for the caps

        var bars = Path()
        for (c, v) in lv.enumerated() {
            let h = max(bw, CGFloat(v) * usable)
            let rect = CGRect(x: CGFloat(c) * cw + (cw - bw) / 2, y: midY - h / 2, width: bw, height: h)
            bars.addRoundedRect(in: rect, cornerSize: CGSize(width: bw / 2, height: bw / 2))
        }

        let shading = mirroredShading(vertical: true, size)
        if glow {
            ctx.drawLayer { layer in
                layer.opacity = 0.6
                layer.addFilter(.blur(radius: 8))
                layer.fill(bars, with: shading)
            }
        }
        ctx.fill(bars, with: shading)

        // Caps belong to the live frame only, not to its ghosts
        guard glow && showPeaks else { return }
        var caps = Path()
        for (c, p) in visual.peaks.enumerated() where p > 0.03 {
            let h = max(bw, CGFloat(p) * usable)
            let x = CGFloat(c) * cw + (cw - bw) / 2
            let corner = CGSize(width: 1.25, height: 1.25)
            caps.addRoundedRect(in: CGRect(x: x, y: midY - h / 2 - 5, width: bw, height: 2.5), cornerSize: corner)
            caps.addRoundedRect(in: CGRect(x: x, y: midY + h / 2 + 2.5, width: bw, height: 2.5), cornerSize: corner)
        }
        ctx.fill(caps, with: .color(ramp.color(1).opacity(0.9)))
    }

    // WAVE: a smooth mirrored outline of the spectrum
    private func drawWave(_ ctx: inout GraphicsContext, _ size: CGSize, _ lv: [Double], glow: Bool) {
        let n = lv.count
        guard n > 2 else { return }
        let midY = size.height / 2
        let step = size.width / CGFloat(n - 1)

        var top: [CGPoint] = []
        var bottom: [CGPoint] = []
        for (i, v) in lv.enumerated() {
            let off = CGFloat(max(v, 0.02)) * midY
            top.append(CGPoint(x: CGFloat(i) * step, y: midY - off))
            bottom.append(CGPoint(x: CGFloat(i) * step, y: midY + off))
        }

        var path = Path()
        path.move(to: top[0])
        addSmooth(&path, top)
        path.addLine(to: bottom[n - 1])
        addSmooth(&path, Array(bottom.reversed()))
        path.closeSubpath()

        let shading = mirroredShading(vertical: false, size)
        if glow {
            ctx.drawLayer { layer in
                layer.opacity = 0.55
                layer.addFilter(.blur(radius: 10))
                layer.fill(path, with: shading)
            }
            ctx.fill(path, with: shading)
        }
        ctx.stroke(path, with: .color(ramp.color(0).opacity(0.9)), lineWidth: 1.5)
    }

    private func addSmooth(_ p: inout Path, _ pts: [CGPoint]) {
        guard pts.count > 2 else {
            for pt in pts.dropFirst() { p.addLine(to: pt) }
            return
        }
        for i in 1..<(pts.count - 1) {
            let end = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            p.addQuadCurve(to: end, control: pts[i])
        }
        p.addLine(to: pts[pts.count - 1])
    }

    // RADIAL: a ring of bars around the album art (bass at the bottom, treble at the top)
    private func drawRadial(_ ctx: inout GraphicsContext, _ size: CGSize, _ lut: [Color],
                            _ lv: [Double], glow: Bool) {
        let n = max(lv.count, 1)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let base = min(size.width, size.height)
        let grow = 1 + 0.06 * CGFloat(visual.beat)          // matches the artwork's pulse
        let r0 = base * 0.19 * grow + 10
        let maxLen = max(10, base / 2 - r0 - 2)
        let lineWidth = max(2.5, 2 * CGFloat.pi * r0 / CGFloat(n * 2) * 0.6)

        var lines: [(Path, Color)] = []
        for (i, v) in lv.enumerated() {
            let t = (Double(i) + 0.5) / Double(n)
            let len = max(3, CGFloat(v) * maxLen)
            let color = pick(lut, t)
            for dir in [1.0, -1.0] {
                let a = Double.pi / 2 - dir * t * Double.pi
                let dx = CGFloat(cos(a))
                let dy = CGFloat(sin(a))
                var line = Path()
                line.move(to: CGPoint(x: center.x + dx * r0, y: center.y + dy * r0))
                line.addLine(to: CGPoint(x: center.x + dx * (r0 + len), y: center.y + dy * (r0 + len)))
                lines.append((line, color))
            }
        }

        let stroke = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        if glow {
            ctx.drawLayer { layer in
                layer.opacity = 0.6
                layer.addFilter(.blur(radius: 6))
                for (line, color) in lines { layer.stroke(line, with: .color(color), style: stroke) }
            }
        }
        for (line, color) in lines { ctx.stroke(line, with: .color(color), style: stroke) }
    }

    // SCOPE: the actual waveform, locked to a rising zero crossing so it holds still
    private func drawScope(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let s = visual.scope
        let show = 512
        guard s.count >= show * 2 else { return }

        var start = 0
        for i in 1..<(s.count - show) where s[i - 1] < 0 && s[i] >= 0 {
            start = i
            break
        }

        let midY = size.height / 2
        let amp = midY * 0.9
        let step = size.width / CGFloat(show - 1)
        var path = Path()
        for i in 0..<show {
            let v = CGFloat(max(-1, min(1, s[start + i] * visual.scopeScale)))
            let p = CGPoint(x: CGFloat(i) * step, y: midY - v * amp)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }

        var axis = Path()
        axis.move(to: CGPoint(x: 0, y: midY))
        axis.addLine(to: CGPoint(x: size.width, y: midY))
        ctx.stroke(axis, with: .color(Color.white.opacity(0.06)), lineWidth: 1)

        let shading = mirroredShading(vertical: false, size)
        ctx.drawLayer { layer in
            layer.opacity = 0.7
            layer.addFilter(.blur(radius: 8))
            layer.stroke(path, with: shading, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
        }
        ctx.stroke(path, with: shading, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    // WATERFALL: a spectrogram. Pitch runs left to right (bass on the left), time runs top to
    // bottom (newest at the top), brightness is loudness. Drawn as crisp cells so it reads clearly.
    private func drawWaterfall(_ ctx: inout GraphicsContext, _ size: CGSize) {
        // Every other history row: 60 rows covering about 4 seconds
        let rows = stride(from: 0, to: visual.history.count, by: 2).map { visual.history[$0] }
        guard let bands = rows.first?.count, bands > 0 else { return }

        let buckets = 14
        let heat = heatColors(buckets)
        var paths = [Path](repeating: Path(), count: buckets)

        let cw = size.width / CGFloat(bands)
        let ch = size.height / CGFloat(rows.count)
        let gapX = min(2, cw * 0.15)
        let gapY = min(2, ch * 0.25)

        for (r, row) in rows.enumerated() {
            // Older rows dim as they fall, which gives the picture depth
            let age = Double(r) / Double(max(1, rows.count - 1))
            let fade = 1 - 0.55 * age
            for b in 0..<min(bands, row.count) {
                // A noise floor so quiet sound goes properly black, then a curve for contrast
                let raw = Double(row[b])
                let v = pow(max(0, (raw - 0.1) / 0.9), 1.5) * fade
                guard v > 0.02 else { continue }
                let k = min(buckets - 1, Int(v * Double(buckets)))
                paths[k].addRect(CGRect(x: CGFloat(b) * cw + gapX / 2, y: CGFloat(r) * ch + gapY / 2,
                                        width: cw - gapX, height: ch - gapY))
            }
        }

        ctx.drawLayer { layer in
            layer.opacity = 0.55
            layer.addFilter(.blur(radius: 7))
            for k in 0..<buckets where !paths[k].isEmpty {
                layer.fill(paths[k], with: .color(heat[k]))
            }
        }
        for k in 0..<buckets where !paths[k].isEmpty {
            ctx.fill(paths[k], with: .color(heat[k]))
        }
    }

    /// Black, then the secondary colour, then the main colour, then white-hot for the loudest moments
    private func heatColors(_ n: Int) -> [Color] {
        (0..<n).map { k in
            let t = (Double(k) + 0.5) / Double(n)
            let rgb: SIMD3<Double>
            if t < 0.45 {
                rgb = OKLab.mix(SIMD3(0.02, 0.02, 0.03), ramp.outer, t / 0.45)
            } else if t < 0.85 {
                rgb = OKLab.mix(ramp.outer, ramp.inner, (t - 0.45) / 0.4)
            } else {
                rgb = OKLab.mix(ramp.inner, SIMD3(1, 1, 1), (t - 0.85) / 0.15 * 0.6)
            }
            return Color(red: rgb.x, green: rgb.y, blue: rgb.z)
        }
    }

    // RIDGE: the last few seconds as stacked ridgelines, newest at the front, older ones receding
    // into the distance. Mirrored, so the bass forms the peak in the middle.
    private func drawRidge(_ ctx: inout GraphicsContext, _ size: CGSize, _ lut: [Color]) {
        let h = visual.history
        let lines = 28
        let step = max(1, h.count / lines)

        // Back to front, so each nearer ridge covers the ones behind it
        for i in stride(from: lines - 1, through: 0, by: -1) {
            let idx = i * step
            guard idx < h.count else { continue }
            let row = i == 0 ? visual.levels : h[idx]
            let n = row.count
            guard n > 1 else { continue }

            let z = Double(i) / Double(lines - 1)             // 0 = front, 1 = far back
            let w = size.width * CGFloat(1 - 0.45 * z)
            let x0 = (size.width - w) / 2
            let baseY = size.height * CGFloat(0.95 - 0.78 * pow(z, 0.8))
            let amp = size.height * CGFloat(0.42 * (1 - 0.65 * z))

            let total = n * 2 - 1
            var pts: [CGPoint] = []
            pts.reserveCapacity(total)
            for j in 0..<total {
                let band = j < n ? n - 1 - j : j - n + 1
                // Taper towards the edges so every ridge settles onto its own baseline
                let edge = CGFloat(sin(Double(j) / Double(total - 1) * Double.pi))
                let v = CGFloat(row[band])
                pts.append(CGPoint(x: x0 + w * CGFloat(j) / CGFloat(total - 1), y: baseY - v * amp * edge))
            }

            var line = Path()
            line.move(to: pts[0])
            addSmooth(&line, pts)

            var cover = line
            cover.addLine(to: CGPoint(x: x0 + w, y: baseY + 2))
            cover.addLine(to: CGPoint(x: x0, y: baseY + 2))
            cover.closeSubpath()
            ctx.fill(cover, with: .color(Color.black.opacity(0.92)))

            let color = pick(lut, z).opacity(1 - 0.75 * z)
            if i == 0 {
                ctx.drawLayer { layer in
                    layer.addFilter(.blur(radius: 6))
                    layer.stroke(line, with: .color(color), lineWidth: 5)
                }
            }
            ctx.stroke(line, with: .color(color), lineWidth: i == 0 ? 2 : 1.2)
        }
    }

    // PARTICLES: glowing dots coloured by their frequency band, added together so crowds glow brighter
    private func drawParticles(_ ctx: inout GraphicsContext, _ size: CGSize, _ lut: [Color]) {
        let cx = size.width / 2
        let cy = size.height / 2
        let buckets = lut.count
        let levels = visual.levels
        var cores = [Path](repeating: Path(), count: buckets)
        var halos = [Path](repeating: Path(), count: buckets)

        for p in visual.particles {
            let level = CGFloat(p.band < levels.count ? levels[p.band] : 0)
            let r = CGFloat(p.size) * (1.2 + 3.5 * level)
            let x = cx + CGFloat(p.x) * cx
            let y = cy + CGFloat(p.y) * cy
            let k = min(buckets - 1, p.band * buckets / AudioTap.bandCount)
            cores[k].addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            let hr = r * 3
            halos[k].addEllipse(in: CGRect(x: x - hr, y: y - hr, width: hr * 2, height: hr * 2))
        }

        ctx.drawLayer { layer in
            layer.blendMode = .plusLighter
            layer.opacity = 0.5
            layer.addFilter(.blur(radius: 6))
            for k in 0..<buckets where !halos[k].isEmpty {
                layer.fill(halos[k], with: .color(lut[k]))
            }
        }
        var core = ctx
        core.blendMode = .plusLighter
        for k in 0..<buckets where !cores[k].isEmpty {
            core.fill(cores[k], with: .color(lut[k]))
        }
    }

    // IDLE: a slow breathing line while the music is paused
    private func drawIdle(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let t = visual.time
        let breath = 0.55 + 0.45 * sin(t * 1.4)
        let alpha = Double(visual.idle) * breath
        let midY = size.height / 2
        let steps = 120

        var path = Path()
        for i in 0...steps {
            let x = size.width * CGFloat(i) / CGFloat(steps)
            let phase = Double(i) / Double(steps) * Double.pi * 4 + t * 0.8
            let y = midY + CGFloat(sin(phase) * 6 * breath)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }

        let shading = mirroredShading(vertical: false, size)
        ctx.drawLayer { layer in
            layer.opacity = alpha * 0.8
            layer.addFilter(.blur(radius: 14))
            layer.stroke(path, with: shading, lineWidth: 10)
        }
        var line = ctx
        line.opacity = alpha
        line.stroke(path, with: shading, lineWidth: 2)
    }
}
