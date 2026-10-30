import SwiftUI

/// Heights of the lyric rows, measured after layout, keyed by line number
private struct LyricRowHeights: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Synced lyrics as a column that scrolls upwards, like Apple Music. Long lines wrap instead of
/// being cut off; each row's real height is measured, so the column always lands the current
/// line in the same place, however long the lines around it are.
struct LyricsView: View {
    @ObservedObject var np: NowPlaying
    let accent: Color
    var size: CGFloat = 30
    var showNeighbours = true
    var alignment: HorizontalAlignment = .leading

    @State private var heights: [Int: CGFloat] = [:]

    private var spacing: CGFloat { showNeighbours ? (size * 0.5).rounded() : 0 }
    private var lineHeight: CGFloat { (size * 1.25).rounded() }
    /// The visible window: about five lines tall with neighbours, one line without
    private var boxHeight: CGFloat { showNeighbours ? lineHeight * 5.6 : lineHeight }
    /// Where the current line's top sits inside the window
    private var anchor: CGFloat { showNeighbours ? lineHeight * 1.35 : 0 }

    var body: some View {
        if !np.lyrics.isEmpty {
            TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                let current = np.lineIndex(at: timeline.date) ?? -1
                column(current: current)
            }
            .frame(height: boxHeight, alignment: .top)
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
            .clipped()
            .mask(edgeFade)
            .onPreferenceChange(LyricRowHeights.self) { new in
                heights.merge(new) { $1 }
            }
            .onChange(of: np.lyrics) { _ in heights = [:] }
        }
    }

    private func column(current: Int) -> some View {
        let before = showNeighbours ? 3 : 1
        let after = showNeighbours ? 5 : 1
        let first = current - before
        let last = current + after

        // Move the column up by the height of everything above the current line
        var above: CGFloat = 0
        for i in first..<current { above += (heights[i] ?? lineHeight) + spacing }

        return VStack(alignment: alignment, spacing: spacing) {
            ForEach(first...last, id: \.self) { i in
                row(i, isCurrent: i == current, distance: abs(i - current))
                    .background(GeometryReader { g in
                        Color.clear.preference(key: LyricRowHeights.self, value: [i: g.size.height])
                    })
            }
        }
        .offset(y: anchor - above)
        .animation(Motion.spring(0.7, 0.9), value: current)
    }

    private func row(_ i: Int, isCurrent: Bool, distance d: Int) -> some View {
        let text = i >= 0 && i < np.lyrics.count ? np.lyrics[i].text : ""
        // Empty lines are instrumental breaks
        let shown = text.isEmpty ? (isCurrent && i >= 0 ? "♪" : " ") : text

        return Text(shown)
            .font(.system(size: size, weight: .bold))
            .lineLimit(showNeighbours ? 3 : 1)
            .minimumScaleFactor(showNeighbours ? 1 : 0.7)
            .multilineTextAlignment(alignment == .center ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
            .foregroundStyle(isCurrent ? accent : Color.white)
            .opacity(isCurrent ? 1 : (d == 1 ? 0.45 : 0.22))
            .blur(radius: isCurrent ? 0 : (d == 1 ? 0.5 : 1.5))
    }

    private var edgeFade: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: showNeighbours ? 0.14 : 0),
            .init(color: .black, location: showNeighbours ? 0.8 : 1),
            .init(color: .clear, location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }
}

/// One line of lyrics for the island: the current line slides up and away as the next one
/// rises in. Simple and fixed-height, so it never shows a sliver of the line below.
struct IslandLyric: View {
    @ObservedObject var np: NowPlaying
    let colour: Color
    var size: CGFloat = 14

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            let index = np.lineIndex(at: timeline.date)
            let text: String = {
                guard let i = index, i >= 0, i < np.lyrics.count else { return " " }
                let t = np.lyrics[i].text
                return t.isEmpty ? "♪" : t          // empty lines are instrumental breaks
            }()
            ZStack(alignment: .leading) {
                Text(text)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(colour)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(index ?? -1)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)))
            }
            .animation(Motion.spring(0.45, 0.9), value: index)
        }
        .frame(height: (size * 1.4).rounded())
        .clipped()
    }
}
