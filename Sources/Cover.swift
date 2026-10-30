import SwiftUI

// MARK: - Record motion: spins up when music plays, coasts to a stop when it pauses

final class Spinner {
    private(set) var angle: Double = 0
    private(set) var slide: Double = 0.1          // how far the record sticks out, as a fraction of the cover
    private var speed: Double = 0
    private var last: Date?

    func update(now: Date, playing: Bool) {
        let dt = min(0.1, max(0, now.timeIntervalSince(last ?? now)))
        last = now
        let target = playing ? 200.0 : 0          // about 33⅓ rpm, in degrees per second
        speed += (target - speed) * min(1, dt * (playing ? 1.5 : 0.8))
        angle = (angle + speed * dt).truncatingRemainder(dividingBy: 360)
        let slideTarget = playing ? 0.42 : 0.1
        slide += (slideTarget - slide) * min(1, dt * 2.5)
    }
}

// MARK: - The vinyl record

struct Vinyl: View {
    let art: NSImage?
    let angle: Double
    let accent: Color

    var body: some View {
        GeometryReader { g in
            let d = min(g.size.width, g.size.height)
            ZStack {
                Circle().fill(Color(white: 0.05))

                // Grooves: concentric, so they look the same however the record turns
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    let r = min(size.width, size.height) / 2
                    var fine = Path()
                    var bold = Path()
                    var rr = r * 0.37
                    var i = 0
                    while rr < r * 0.97 {
                        let ring = Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
                        if i % 3 == 0 { bold.addPath(ring) } else { fine.addPath(ring) }
                        rr += 2.2
                        i += 1
                    }
                    ctx.stroke(fine, with: .color(Color.white.opacity(0.03)), lineWidth: 0.6)
                    ctx.stroke(bold, with: .color(Color.white.opacity(0.07)), lineWidth: 0.6)
                }

                // The label is the album art; it's the only part you can see turning
                Group {
                    if let art = art {
                        Image(nsImage: art).resizable().scaledToFill()
                    } else {
                        accent.opacity(0.6)
                    }
                }
                .frame(width: d * 0.34, height: d * 0.34)
                .clipShape(Circle())
                .rotationEffect(.degrees(angle))

                Circle().fill(Color.black).frame(width: d * 0.03, height: d * 0.03)

                // Light reflecting off the vinyl stays still while the record spins under it
                Circle()
                    .fill(AngularGradient(gradient: Gradient(colors: [
                        Color.clear, Color.white.opacity(0.10), Color.clear, Color.clear,
                        Color.white.opacity(0.07), Color.clear, Color.clear
                    ]), center: .center))
                Circle().stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
            .frame(width: d, height: d)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Cover look

struct CoverStage: View {
    @ObservedObject var tap: AudioTap
    let style: VisualStyle
    let ramp: Ramp
    let range: Float
    let artwork: NSImage?
    let title: String
    let artist: String
    let album: String
    let isPlaying: Bool
    let showPeaks: Bool
    let trails: Bool
    let motionBlur: Int
    let idleEnabled: Bool
    @ObservedObject var np: NowPlaying
    let showLyrics: Bool

    @State private var processor = BandProcessor()
    @State private var fader = RampFader()
    @State private var spinner = Spinner()
    @State private var tilt = CGSize.zero

    // RADIAL draws its own album art in the middle, which would repeat the cover; use BARS instead
    private var stripStyle: VisualStyle { style == .radial ? .bars : style }

    @State private var onScreen = true
    @ObservedObject private var pacing = FramePacing.shared

    var body: some View {
        visuals.background(OnScreenReader(onScreen: $onScreen))
    }

    /// Redraws only while its window can be seen, at the chosen frame rate
    @ViewBuilder private var visuals: some View {
        TimelineView(.animation(minimumInterval: pacing.interval,
                                paused: !onScreen || !(isPlaying || tap.status == .running))) { timeline in
            let visual = processor.step(tap.snapshot(), now: timeline.date, range: range)
            let shown = fader.ramp(target: ramp, now: timeline.date)
            let bass = Double(visual.levels.prefix(16).reduce(0, +)) / 16
            let beat = Double(visual.beat)
            let soundOn = tap.status == .running && visual.idle < 0.5
            let _ = spinner.update(now: timeline.date, playing: isPlaying || soundOn)

            GeometryReader { geo in
                let side = max(160, min(geo.size.height * 0.6, geo.size.width * 0.36))

                HStack(spacing: side * 0.16) {
                    ZStack {
                        // Light spilling out from behind the cover, breathing with the bass
                        Circle()
                            .fill(RadialGradient(colors: [shown.color(0).opacity(0.6), Color.clear],
                                                 center: .center, startRadius: 0, endRadius: side * 0.95))
                            .frame(width: side * 1.9, height: side * 1.9)
                            .opacity(0.35 + 0.55 * bass + 0.3 * beat)

                        Vinyl(art: artwork, angle: spinner.angle, accent: shown.color(0))
                            .frame(width: side * 0.94, height: side * 0.94)
                            .offset(x: side * CGFloat(spinner.slide))
                            .shadow(color: .black.opacity(0.5), radius: 16, y: 8)

                        cover(side: side, ramp: shown)
                            .scaleEffect(1 + 0.025 * CGFloat(beat))
                    }
                    .frame(width: side, height: side)
                    .rotation3DEffect(.degrees(Double(-tilt.height) * 10), axis: (x: 1, y: 0, z: 0))
                    .rotation3DEffect(.degrees(Double(tilt.width) * 12), axis: (x: 0, y: 1, z: 0))
                    .animation(.spring(response: 0.6, dampingFraction: 0.8), value: tilt)
                    .frame(width: side * 1.45, alignment: .leading)      // room for the record

                    VStack(alignment: .leading, spacing: 8) {
                        MarqueeText(text: title, font: .system(size: 34, weight: .bold),
                                    color: .white, height: 42)
                        MarqueeText(text: artist, font: .system(size: 20, weight: .semibold),
                                    color: .white.opacity(0.72), height: 26)
                        if !album.isEmpty {
                            MarqueeText(text: album, font: .system(size: 14, weight: .medium),
                                        color: .white.opacity(0.45), height: 18)
                        }

                        let lyricsShown = showLyrics && !np.lyrics.isEmpty
                        if lyricsShown {
                            LyricsView(np: np, accent: shown.color(0), size: 30)
                                .padding(.top, 18)
                        }

                        Group {
                            if tap.status == .running {
                                SpectrumView(visual: visual, style: stripStyle, ramp: shown, artwork: nil,
                                             showPeaks: showPeaks, trails: trails, motionBlur: motionBlur,
                                             idleEnabled: idleEnabled)
                                    .id(stripStyle)
                                    .transition(.visualSwap)
                            } else {
                                StatusOverlay(status: tap.status, accent: shown.color(0))
                                    .scaleEffect(0.8)
                            }
                        }
                        .frame(height: lyricsShown ? 70 : 110)
                        .padding(.top, lyricsShown ? 14 : 22)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(isPlaying || soundOn ? 1 : 0.6)
                }
                .padding(.horizontal, 64)
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        tilt = CGSize(width: p.x / max(1, geo.size.width) - 0.5,
                                      height: p.y / max(1, geo.size.height) - 0.5)
                    case .ended:
                        tilt = .zero
                    }
                }
            }
        }
    }

    private func cover(side: CGFloat, ramp: Ramp) -> some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.03)
        return Group {
            if let art = artwork {
                Image(nsImage: art).resizable().interpolation(.high).scaledToFill()
            } else {
                // No artwork: a gradient sleeve in the current colours
                ZStack {
                    LinearGradient(colors: [ramp.color(0), ramp.color(1)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: side * 0.3, weight: .light))
                        .foregroundStyle(Color.white.opacity(0.85))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 1))
        // A faint sheen across the sleeve
        .overlay(
            LinearGradient(colors: [Color.white.opacity(0.14), Color.clear, Color.clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .clipShape(shape)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.55), radius: 30, y: 18)
    }
}
