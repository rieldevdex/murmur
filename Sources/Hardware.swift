import SwiftUI

// MARK: - Hardware pieces

struct ScreenShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - r.height * 0.18))
        p.addLine(to: CGPoint(x: r.maxX - r.width * 0.06, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.06, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - r.height * 0.18))
        p.closeSubpath()
        return p
    }
}

struct Grille: View {
    let accent: Color
    @Environment(\.craftedHardware) private var crafted

    var body: some View {
        Group {
            if crafted {
                // Perforated speaker cover
                Canvas { ctx, size in
                    var dots = Path()
                    let step: CGFloat = 5.5
                    var y: CGFloat = 1
                    var row = 0
                    while y + 3 <= size.height {
                        var x: CGFloat = row % 2 == 0 ? 1 : 1 + step / 2
                        while x + 3 <= size.width {
                            dots.addEllipse(in: CGRect(x: x, y: y, width: 3, height: 3))
                            x += step
                        }
                        y += step * 0.87
                        row += 1
                    }
                    ctx.fill(dots, with: .color(accent.opacity(0.55)))
                }
            } else {
                VStack(spacing: 4) {
                    ForEach(0..<6, id: \.self) { _ in
                        Capsule().fill(accent.opacity(0.7)).frame(height: 3)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 90, height: 56)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.5), lineWidth: 1.5))
    }
}

struct KnobFace: View {
    let angle: Double
    @Environment(\.craftedHardware) private var crafted

    var body: some View {
        ZStack {
            if crafted {
                // Scale markings around the knob
                ForEach(0..<11, id: \.self) { i in
                    Capsule()
                        .fill(Color.white.opacity(i % 5 == 0 ? 0.45 : 0.2))
                        .frame(width: 1.5, height: i % 5 == 0 ? 5 : 3)
                        .offset(y: -25)
                        .rotationEffect(.degrees(-135 + 27 * Double(i)))
                }
            }
            Circle().fill(LinearGradient(colors: [Color(white: 0.26), Color(white: 0.05)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().stroke(Color.black, lineWidth: 2)
            if crafted {
                // Knurled grip edge and a machined cap
                Circle()
                    .strokeBorder(Color.white.opacity(0.12),
                                  style: StrokeStyle(lineWidth: 3, dash: [1, 2]))
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.32), Color(white: 0.12)],
                                         center: .topLeading, startRadius: 0, endRadius: 22))
                    .frame(width: 26, height: 26)
            }
            ZStack {
                Capsule().fill(Color.white.opacity(0.85))
                    .frame(width: 2.5, height: 10)
                    .offset(y: -11)
            }
            .frame(width: 40, height: 40)
            .rotationEffect(.degrees(angle))
        }
        .frame(width: 40, height: 40)
        .shadow(color: .black.opacity(0.6), radius: 4, y: 3)
    }
}

// Click to step through the options
struct SelectorKnob: View {
    let label: String
    let options: [String]
    @Binding var index: Int
    let accent: Color

    private var safeIndex: Int { min(max(0, index), options.count - 1) }

    var body: some View {
        VStack(spacing: 4) {
            Button {
                index = (safeIndex + 1) % options.count
            } label: {
                KnobFace(angle: -135 + 270 * Double(safeIndex) / Double(max(1, options.count - 1)))
            }
            .buttonStyle(.plain)
            .help("Click to change \(label.lowercased())")

            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(accent.opacity(0.6))
            Text(options[safeIndex])
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
        }
        .frame(width: 70)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: index)
    }
}

// Click to flip, like a toggle switch on the front panel
struct ToggleSwitch: View {
    let label: String
    @Binding var isOn: Bool
    let accent: Color

    var body: some View {
        VStack(spacing: 4) {
            Button {
                isOn.toggle()
            } label: {
                ZStack(alignment: isOn ? .top : .bottom) {
                    Capsule()
                        .fill(Color.black.opacity(0.6))
                        .overlay(Capsule().stroke(accent.opacity(isOn ? 0.7 : 0.25), lineWidth: 1.5))
                    Circle()
                        .fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.4)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 14, height: 14)
                        .padding(3)
                        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                }
                .frame(width: 20, height: 40)
            }
            .buttonStyle(.plain)

            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(accent.opacity(0.6))
            Text(isOn ? "ON" : "OFF")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
        }
        .frame(width: 50)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isOn)
    }
}

// Drag up or down to turn
struct DragKnob: View {
    let label: String
    @Binding var value: Double          // 0...1
    let accent: Color
    @State private var start: Double?

    var body: some View {
        VStack(spacing: 4) {
            KnobFace(angle: -135 + 270 * value)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if start == nil { start = value }
                            value = min(1, max(0, (start ?? value) - Double(g.translation.height) / 120))
                        }
                        .onEnded { _ in start = nil }
                )
                .help("Drag up or down")

            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(accent.opacity(0.6))
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
        }
        .frame(width: 70)
    }
}
