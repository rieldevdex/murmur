import SwiftUI
import AppKit

// MARK: - OKLab
// Blending in OKLab keeps the midpoint between two saturated colours bright:
// orange to pink stays vivid instead of passing through a dull salmon.

enum OKLab {
    static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func gamma(_ c: Double) -> Double {
        let v = min(1, max(0, c))
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    static func fromSRGB(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let r = linear(rgb.x), g = linear(rgb.y), b = linear(rgb.z)
        let l: Double = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m: Double = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s: Double = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L: Double = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let A: Double = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let B: Double = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        return SIMD3(L, A, B)
    }

    static func toSRGB(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        let l0: Double = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
        let m0: Double = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
        let s0: Double = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
        let l = l0 * l0 * l0
        let m = m0 * m0 * m0
        let s = s0 * s0 * s0
        let r: Double = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g: Double = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let b: Double = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        return SIMD3(gamma(r), gamma(g), gamma(b))
    }

    static func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> {
        let la = fromSRGB(a)
        let lb = fromSRGB(b)
        return toSRGB(la + (lb - la) * t)
    }
}

// MARK: - Colour ramp (inner = main colour, outer = secondary colour)

struct Ramp: Equatable {
    var inner: SIMD3<Double>
    var outer: SIMD3<Double>

    func color(_ t: Double) -> Color {
        let c = OKLab.mix(inner, outer, min(1, max(0, t)))
        return Color(red: c.x, green: c.y, blue: c.z)
    }

    /// A small table of precomputed colours, so drawing doesn't convert per pixel
    func lut(_ steps: Int = 32) -> [Color] {
        (0..<steps).map { color(Double($0) / Double(steps - 1)) }
    }

    /// The same table as raw sRGB values, for building bitmaps
    func rgbLUT(_ steps: Int = 64) -> [SIMD3<Double>] {
        (0..<steps).map { OKLab.mix(inner, outer, Double($0) / Double(steps - 1)) }
    }

    static func mix(_ a: Ramp, _ b: Ramp, _ t: Double) -> Ramp {
        Ramp(inner: OKLab.mix(a.inner, b.inner, t), outer: OKLab.mix(a.outer, b.outer, t))
    }

    static let ember   = Ramp(inner: SIMD3(1.00, 0.66, 0.16), outer: SIMD3(0.95, 0.22, 0.50))
    static let ice     = Ramp(inner: SIMD3(0.55, 0.95, 1.00), outer: SIMD3(0.35, 0.45, 1.00))
    static let matrix  = Ramp(inner: SIMD3(0.70, 1.00, 0.45), outer: SIMD3(0.05, 0.75, 0.40))
    static let neutral = Ramp(inner: SIMD3(0.95, 0.95, 0.95), outer: SIMD3(0.55, 0.62, 0.78))
}

enum Palette: Int, CaseIterable {
    case art = 0, ember, ice, matrix

    var name: String {
        switch self {
        case .art: return "ART"
        case .ember: return "EMBER"
        case .ice: return "ICE"
        case .matrix: return "MATRIX"
        }
    }

    func ramp(art: Ramp) -> Ramp {
        switch self {
        case .art:    return art
        case .ember:  return .ember
        case .ice:    return .ice
        case .matrix: return .matrix
        }
    }
}

// MARK: - Pull the main colours out of the album art

private func vivid(_ rgb: [Double], _ w: Double, hueShift: Double = 0) -> SIMD3<Double> {
    let c = NSColor(srgbRed: CGFloat(rgb[0] / w), green: CGFloat(rgb[1] / w), blue: CGFloat(rgb[2] / w), alpha: 1)
    var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
    c.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
    let hue = (Double(h) + hueShift).truncatingRemainder(dividingBy: 1)
    let boosted = NSColor(hue: CGFloat(hue),
                          saturation: CGFloat(min(1, max(Double(s), 0.6))),
                          brightness: CGFloat(max(Double(v), 0.9)),
                          alpha: 1)
    guard let rgbColor = boosted.usingColorSpace(.sRGB) else { return SIMD3(1, 1, 1) }
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
    rgbColor.getRed(&r, green: &g, blue: &b, alpha: &a)
    return SIMD3(Double(r), Double(g), Double(b))
}

extension NSImage {
    func dominantRamp() -> Ramp {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .neutral }

        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        }

        // Group colourful pixels into 12 hue buckets, weighted by saturation x brightness
        let buckets = 12
        var weight = [Double](repeating: 0, count: buckets)
        var sum = [[Double]](repeating: [0, 0, 0], count: buckets)
        for i in 0..<(size * size) {
            let r = Double(pixels[i * 4]) / 255
            let g = Double(pixels[i * 4 + 1]) / 255
            let b = Double(pixels[i * 4 + 2]) / 255
            let c = NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            guard s > 0.25, v > 0.2 else { continue }
            let w = Double(s * v)
            let k = min(buckets - 1, Int(Double(h) * Double(buckets)))
            weight[k] += w
            sum[k][0] += r * w
            sum[k][1] += g * w
            sum[k][2] += b * w
        }

        // Mostly grey artwork: use a neutral ramp
        guard let first = weight.indices.max(by: { weight[$0] < weight[$1] }),
              weight[first] > 6 else { return .neutral }

        // Second colour: the strongest hue that is clearly different from the first
        var second: Int? = nil
        for k in 0..<buckets where k != first {
            let d = abs(k - first)
            let dist = min(d, buckets - d)
            let best = second.map { weight[$0] } ?? 0
            if dist >= 2, weight[k] > weight[first] * 0.25, weight[k] > best { second = k }
        }

        let inner = vivid(sum[first], weight[first])
        let outer: SIMD3<Double>
        if let second = second {
            outer = vivid(sum[second], weight[second])
        } else {
            outer = vivid(sum[first], weight[first], hueShift: 0.09)
        }
        return Ramp(inner: inner, outer: outer)
    }
}
