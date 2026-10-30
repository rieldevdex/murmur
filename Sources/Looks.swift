import SwiftUI
import AppKit
import CoreImage

// MARK: - The four looks

enum Look: Int, CaseIterable {
    // Raw values are what's saved, so looks added later keep their own numbers
    // (6 was the old standalone Wallpaper look; wallpaper is now a switch on these looks)
    case classic = 0, crafted = 1, ambient = 2, cover = 4, mosaic = 5, borderless = 3, mini = 7

    var name: String {
        switch self {
        case .classic: return "Classic"
        case .crafted: return "Crafted"
        case .ambient: return "Ambient"
        case .cover: return "Cover"
        case .mosaic: return "Mosaic"
        case .borderless: return "Borderless"
        case .mini: return "Mini"
        }
    }

    var symbol: String {
        switch self {
        case .classic: return "radio"
        case .crafted: return "sparkles"
        case .ambient: return "photo"
        case .cover: return "opticaldisc"
        case .mosaic: return "square.grid.3x3.fill"
        case .borderless: return "rectangle.dashed"
        case .mini: return "pip"
        }
    }

    var blurb: String {
        switch self {
        case .classic: return "The original radio."
        case .crafted: return "The radio in brushed metal and glass, with scanlines."
        case .ambient: return "The radio floating on blurred, drifting album art."
        case .cover: return "Big album art, a spinning record and large type."
        case .mosaic: return "The cover split into tiles that lift and glow with the music."
        case .borderless: return "Just the visuals; the controls hide when the mouse is still."
        case .mini: return "A small always-on-top player in the corner. Drag to move, double-click to go back."
        }
    }

    /// Looks that draw the visualiser inside the radio's screen shape
    var framedScreen: Bool {
        switch self {
        case .borderless, .mini: return false
        default: return true
        }
    }

    /// Looks that change the window itself rather than what's drawn in it
    var isWindowMode: Bool { self == .mini }

    /// Looks that can be sent behind the desktop icons as a live wallpaper.
    /// The radios are left out because their knobs couldn't be clicked there.
    var supportsWallpaper: Bool {
        switch self {
        case .ambient, .cover, .mosaic, .borderless: return true
        default: return false
        }
    }

    static var wallpaperLooks: [Look] { allCases.filter { $0.supportsWallpaper } }
}

// Lets knobs and grilles switch to their detailed versions in the Crafted look
private struct CraftedHardwareKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var craftedHardware: Bool {
        get { self[CraftedHardwareKey.self] }
        set { self[CraftedHardwareKey.self] = newValue }
    }
}

// MARK: - Album art backdrop (blurred once with Core Image, then only moved around)

enum ArtBackdrop {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func make(from image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let sigma = Double(max(input.extent.width, input.extent.height)) * 0.06
        let output = input
            .clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.35,
                kCIInputBrightnessKey: -0.04
            ])
            .cropped(to: input.extent)
        guard let result = context.createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: result, size: NSSize(width: result.width, height: result.height))
    }
}

struct AmbientBackground: View {
    let backdrop: NSImage?
    let ramp: Ramp
    var dim: Double = 0.4

    @State private var onScreen = true
    @ObservedObject private var pacing = FramePacing.shared

    var body: some View {
        visuals.background(OnScreenReader(onScreen: $onScreen))
    }

    /// Redraws only while its window can be seen, at the chosen frame rate
    @ViewBuilder private var visuals: some View {
        GeometryReader { geo in
            ZStack {
                // Shown when there's no artwork, and underneath while art fades in
                LinearGradient(colors: [ramp.color(1).opacity(0.35), Color.black],
                               startPoint: .topLeading, endPoint: .bottomTrailing)

                if let art = backdrop {
                    TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !onScreen)) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        Image(nsImage: art)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .scaleEffect(1.3 + 0.05 * sin(t * 0.07))
                            .offset(x: 30 * sin(t * 0.05), y: 20 * cos(t * 0.04))
                    }
                    .id(ObjectIdentifier(art))
                    .transition(.opacity)
                }

                Color.black.opacity(dim)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .animation(.easeInOut(duration: 1.2), value: backdrop.map { ObjectIdentifier($0) })
        }
        .ignoresSafeArea()
    }
}

// MARK: - Crafted hardware

struct BrushedMetal: View {
    var body: some View {
        Canvas { ctx, size in
            let full = Path(CGRect(origin: .zero, size: size))
            ctx.fill(full, with: .linearGradient(
                Gradient(colors: [Color(white: 0.24), Color(white: 0.11)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

            // Fine horizontal grain with repeatable pseudo-random strength
            var light = Path()
            var dark = Path()
            var y: CGFloat = 0
            var i = 0
            while y < size.height {
                let n = abs(sin(Double(i) * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
                let rect = CGRect(x: 0, y: y, width: size.width, height: 0.75)
                if n > 0.55 { light.addRect(rect) } else if n < 0.3 { dark.addRect(rect) }
                y += 1.5
                i += 1
            }
            ctx.fill(light, with: .color(Color.white.opacity(0.035)))
            ctx.fill(dark, with: .color(Color.black.opacity(0.10)))

            // A soft diagonal sheen
            ctx.fill(full, with: .linearGradient(
                Gradient(colors: [Color.white.opacity(0), Color.white.opacity(0.07), Color.white.opacity(0)]),
                startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
        }
    }
}

/// Scanlines, vignette and a glass glint, laid over the screen in the Crafted look
struct ScreenGlass: View {
    var body: some View {
        ZStack {
            Canvas { ctx, size in
                var lines = Path()
                var y: CGFloat = 0
                while y < size.height {
                    lines.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                    y += 3
                }
                ctx.fill(lines, with: .color(Color.black.opacity(0.22)))
            }
            RadialGradient(colors: [Color.clear, Color.black.opacity(0.55)],
                           center: .center, startRadius: 140, endRadius: 560)
            LinearGradient(stops: [
                Gradient.Stop(color: Color.white.opacity(0.10), location: 0),
                Gradient.Stop(color: Color.white.opacity(0.03), location: 0.45),
                Gradient.Stop(color: Color.clear, location: 0.46)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .allowsHitTesting(false)
    }
}

/// Telescoping antennas with ball tips, tilted apart like a real set
struct CraftedAntennas: View {
    let accent: Color

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            antenna.rotationEffect(.degrees(-14), anchor: .bottom)
            Spacer().frame(width: 360)
            antenna.rotationEffect(.degrees(10), anchor: .bottom)
            Spacer()
        }
        .frame(height: 110)
    }

    private var metal: LinearGradient {
        LinearGradient(colors: [Color(white: 0.85), Color(white: 0.3), Color(white: 0.65)],
                       startPoint: .leading, endPoint: .trailing)
    }

    private var antenna: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.95), Color(white: 0.35)],
                                     center: .topLeading, startRadius: 0, endRadius: 9))
                .frame(width: 10, height: 10)
            Capsule().fill(metal).frame(width: 2.5, height: 30)
            Capsule().fill(metal).frame(width: 3.5, height: 30)
            Capsule().fill(metal).frame(width: 4.5, height: 30)
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.12))
                Circle().fill(accent).frame(width: 3, height: 3).shadow(color: accent, radius: 3)
            }
            .frame(width: 16, height: 8)
        }
        .frame(height: 110, alignment: .bottom)
    }
}
