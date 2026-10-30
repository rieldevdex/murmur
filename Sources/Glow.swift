import SwiftUI

/// Light that washes in from the edges of the window and blooms in the middle on each beat,
/// so the whole background (or the wallpaper) breathes with the music.
struct BeatGlow: View {
    @ObservedObject var tap: AudioTap
    let ramp: Ramp
    let range: Float
    var strength: Double = 1

    @State private var processor = BandProcessor(particles: false)

    @State private var onScreen = true
    @ObservedObject private var pacing = FramePacing.shared

    var body: some View {
        visuals.background(OnScreenReader(onScreen: $onScreen))
    }

    /// Redraws only while its window can be seen, at the chosen frame rate
    @ViewBuilder private var visuals: some View {
        TimelineView(.animation(minimumInterval: pacing.interval, paused: tap.status != .running || !onScreen)) { timeline in
            let visual = processor.step(tap.snapshot(), now: timeline.date, range: range)
            let bass = Double(visual.levels.prefix(14).reduce(0, +)) / 14
            let calm = A11y.reduceMotion ? 0.35 : 1.0
            let energy = min(1, (0.3 * bass + 0.85 * Double(visual.beat)) * strength * calm)
            let inner = ramp.color(0)
            let outer = ramp.color(1)

            GeometryReader { geo in
                let edge = min(geo.size.width, geo.size.height) * 0.28
                ZStack {
                    // Edges: four soft gradients, cheap to draw every frame at full screen size
                    VStack(spacing: 0) {
                        LinearGradient(colors: [outer, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: edge)
                        Spacer(minLength: 0)
                        LinearGradient(colors: [.clear, outer], startPoint: .top, endPoint: .bottom)
                            .frame(height: edge)
                    }
                    HStack(spacing: 0) {
                        LinearGradient(colors: [inner, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: edge)
                        Spacer(minLength: 0)
                        LinearGradient(colors: [.clear, inner], startPoint: .leading, endPoint: .trailing)
                            .frame(width: edge)
                    }
                    .opacity(0.8)

                    // Centre bloom
                    RadialGradient(colors: [inner.opacity(0.55), .clear], center: .center,
                                   startRadius: 0, endRadius: max(geo.size.width, geo.size.height) * 0.55)
                }
                .opacity(0.65 * energy)
            }
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
