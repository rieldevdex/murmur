import SwiftUI
import AppKit

// MARK: - Accessibility: follow the Mac's own settings, as Apple's apps do

enum A11y {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
}

enum Motion {
    /// A spring, or a short plain fade when Reduce Motion is on
    static func spring(_ response: Double, _ damping: Double) -> Animation {
        A11y.reduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(response: response, dampingFraction: damping)
    }
}

// MARK: - Liquid Glass on Tahoe, frosted glass before it, solid with Reduce Transparency

#if compiler(>=6.2)
private struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}
#else
private struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    func body(content: Content) -> some View {
        content.background(.ultraThinMaterial, in: shape)
    }
}
#endif

extension View {
    /// Puts this view on glass in the given shape
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S) -> some View {
        if A11y.reduceTransparency {
            self.background(shape.fill(Color(white: 0.14)))
        } else {
            self.modifier(GlassSurface(shape: shape))
        }
    }

    /// SF Symbols swap with Apple's replace animation (macOS 14 and later)
    @ViewBuilder
    func symbolReplace() -> some View {
        if #available(macOS 14.0, *) {
            self.contentTransition(.symbolEffect(.replace))
        } else {
            self
        }
    }

    /// SF Symbols bounce once whenever the value changes (macOS 14 and later)
    @ViewBuilder
    func symbolBounce<V: Equatable>(_ value: V) -> some View {
        if A11y.reduceMotion {
            self
        } else if #available(macOS 14.0, *) {
            self.symbolEffect(.bounce, value: value)
        } else {
            self
        }
    }
}

// MARK: - Plain names for menus and settings

extension VisualStyle {
    var title: String { name.capitalized }

    var symbol: String {
        switch self {
        case .pixel: return "square.grid.4x3.fill"
        case .bars: return "chart.bar.fill"
        case .wave: return "water.waves"
        case .radial: return "circle.dashed"
        case .scope: return "waveform.path"
        case .waterfall: return "square.stack.3d.down.forward"
        case .ridge: return "mountain.2.fill"
        case .particles: return "sparkles"
        }
    }
}

extension Palette {
    var title: String {
        switch self {
        case .art: return "Album Art"
        case .ember: return "Ember"
        case .ice: return "Ice"
        case .matrix: return "Matrix"
        }
    }
}

// MARK: - The glass control strip (replaces the knobs outside the radio looks)

struct ControlStrip: View {
    @AppStorage("styleIndex") private var styleIndex = 1
    @AppStorage("colourIndex") private var colourIndex = 0
    @AppStorage("ampKnob") private var ampKnob = 0.5

    private var style: VisualStyle { VisualStyle(rawValue: styleIndex) ?? .bars }
    private var palette: Palette { Palette(rawValue: colourIndex) ?? .art }

    var body: some View {
        HStack(spacing: 14) {
            Menu {
                Picker("Style", selection: $styleIndex) {
                    ForEach(VisualStyle.allCases, id: \.self) { s in
                        Label(s.title, systemImage: s.symbol).tag(s.rawValue)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(style.title, systemImage: style.symbol)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            separator

            Menu {
                Picker("Colour", selection: $colourIndex) {
                    ForEach(Palette.allCases, id: \.self) { p in
                        Text(p.title).tag(p.rawValue)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(palette.title, systemImage: "paintpalette")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            separator

            HStack(spacing: 6) {
                Image(systemName: "dial.low")
                    .foregroundStyle(.secondary)
                Slider(value: $ampKnob, in: 0...1)
                    .controlSize(.small)
                    .frame(width: 110)
                Image(systemName: "dial.high")
                    .foregroundStyle(.secondary)
            }
            .help("Amplitude: calm on the left, punchy on the right")

            separator

            Button {
                SettingsWindow.shared.show()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .glassSurface(in: Capsule())
        .environment(\.colorScheme, .dark)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(width: 1, height: 16)
    }
}

// MARK: - Switching styles and looks: the old one zooms past and blurs away as the new one focuses in

private struct FocusShift: ViewModifier {
    let blur: CGFloat
    let scale: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .scaleEffect(scale)
            .opacity(opacity)
    }
}

extension AnyTransition {
    static var visualSwap: AnyTransition {
        if A11y.reduceMotion { return .opacity }
        let settled = FocusShift(blur: 0, scale: 1, opacity: 1)
        return .asymmetric(
            insertion: .modifier(active: FocusShift(blur: 16, scale: 0.9, opacity: 0), identity: settled),
            removal: .modifier(active: FocusShift(blur: 16, scale: 1.1, opacity: 0), identity: settled)
        )
    }
}
