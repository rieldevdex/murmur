import Foundation

/// One glowing dot. Positions are in a -1...1 space centred on the screen.
struct Particle {
    var x: Float
    var y: Float
    var vx: Float
    var vy: Float
    var life: Float
    var band: Int            // which frequency band drives its size, colour and push
    var size: Float
}

/// Hundreds of dots that swirl slowly, are pushed outward by their own frequency band,
/// and burst outward together on each detected beat.
final class ParticleField {
    private(set) var particles: [Particle] = []
    private let count = 360

    init() {
        particles = (0..<count).map { _ in ParticleField.spawn(scattered: true) }
    }

    private static func spawn(scattered: Bool) -> Particle {
        let a = Float.random(in: 0..<(2 * Float.pi))
        let r = scattered ? Float.random(in: 0...1) : Float.random(in: 0...0.12)
        let speed = Float.random(in: 0.02...0.08)
        return Particle(x: cos(a) * r, y: sin(a) * r,
                        vx: cos(a) * speed, vy: sin(a) * speed,
                        life: Float.random(in: 2...6),
                        band: Int.random(in: 0..<AudioTap.bandCount),
                        size: Float.random(in: 0.6...1.4))
    }

    func step(dt: Float, levels: [Float], beat: Bool) {
        guard dt > 0 else { return }
        let drag = exp(-dt * 1.2)
        let burst = beat && !A11y.reduceMotion
        for i in particles.indices {
            var p = particles[i]
            let level = p.band < levels.count ? levels[p.band] : 0
            let r = max(0.001, (p.x * p.x + p.y * p.y).squareRoot())
            let ox = p.x / r
            let oy = p.y / r

            // Outward push from this dot's band, plus a gentle swirl around the centre
            let push = level * 0.9
            p.vx += (ox * push - oy * 0.25) * dt
            p.vy += (oy * push + ox * 0.25) * dt

            // A kick drum throws everything outward at once
            if burst {
                let k = Float.random(in: 0.4...1.0)
                p.vx += ox * k
                p.vy += oy * k
            }

            p.vx *= drag
            p.vy *= drag
            p.x += p.vx * dt
            p.y += p.vy * dt
            p.life -= dt

            if p.life <= 0 || r > 1.35 {
                p = ParticleField.spawn(scattered: false)
            }
            particles[i] = p
        }
    }
}
