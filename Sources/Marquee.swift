import SwiftUI

/// One line of text that scrolls sideways when it's too long to fit, pausing at the start of each loop.
struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    var height: CGFloat = 16
    var glow: Bool = false

    @State private var textWidth: CGFloat = 0
    @State private var start = Date()

    private let gap: CGFloat = 48
    private let speed: CGFloat = 30          // points per second
    private let hold = 2.0                   // seconds to rest before each scroll

    var body: some View {
        GeometryReader { geo in
            let boxWidth = geo.size.width
            let overflow = textWidth > boxWidth + 0.5
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !overflow)) { timeline in
                let cycle = textWidth + gap
                let travel = Double(cycle / speed)
                let elapsed = max(0, timeline.date.timeIntervalSince(start))
                let t = elapsed.truncatingRemainder(dividingBy: travel + hold)
                let x = overflow ? -CGFloat(max(0, t - hold) / travel) * cycle : 0
                HStack(spacing: gap) {
                    label
                    if overflow { label }
                }
                .offset(x: x)
                .frame(width: boxWidth, height: height, alignment: .leading)
            }
            .mask(edgeFade(overflow))
        }
        .frame(height: height)
        .clipped()
        .background(
            label.hidden().background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { textWidth = g.size.width }
                        .onChange(of: g.size.width) { textWidth = $0 }
                }
            )
        )
        .onChange(of: text) { _ in start = Date() }
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .shadow(color: glow ? color.opacity(0.8) : Color.clear, radius: glow ? 6 : 0)
    }

    private func edgeFade(_ on: Bool) -> LinearGradient {
        let stops: [Gradient.Stop]
        if on {
            stops = [
                Gradient.Stop(color: Color.clear, location: 0),
                Gradient.Stop(color: Color.black, location: 0.04),
                Gradient.Stop(color: Color.black, location: 0.92),
                Gradient.Stop(color: Color.clear, location: 1)
            ]
        } else {
            stops = [
                Gradient.Stop(color: Color.black, location: 0),
                Gradient.Stop(color: Color.black, location: 1)
            ]
        }
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }
}
