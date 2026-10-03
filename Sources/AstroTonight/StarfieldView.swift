import SwiftUI

/// Animated deep-space backdrop: two drifting star layers with twinkle,
/// a faint nebula wash, and an occasional shooting star.
///
/// Deterministic (seeded) so the layout is stable across frames — every
/// pixel is a pure function of time, no stored animation state.
struct StarfieldView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            Canvas { ctx, size in
                draw(in: ctx, size: size,
                     at: context.date.timeIntervalSinceReferenceDate)
            }
        }
        .ignoresSafeArea()
    }

    private func draw(in ctx: GraphicsContext, size: CGSize, at t: Double) {
        // Deep-space gradient.
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(
                    Gradient(colors: [Color(red: 0.025, green: 0.035, blue: 0.10),
                                      Color(red: 0.008, green: 0.010, blue: 0.035)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)))

        nebula(in: ctx, size: size, t: t)
        starLayer(in: ctx, size: size, t: t, stars: Self.farStars)
        starLayer(in: ctx, size: size, t: t, stars: Self.nearStars)
        shootingStar(in: ctx, size: size, t: t)
    }

    // MARK: - Nebula wash

    private func nebula(in ctx: GraphicsContext, size: CGSize, t: Double) {
        let blobs: [(x: Double, y: Double, r: Double, color: Color)] = [
            (0.20, 0.28, 0.42, .purple),
            (0.80, 0.60, 0.48, .blue),
            (0.55, 0.12, 0.32, .indigo),
        ]
        let m = min(size.width, size.height)
        for (i, b) in blobs.enumerated() {
            let cx = (b.x + 0.015 * sin(t * 0.05 + Double(i))) * size.width
            let cy = (b.y + 0.015 * cos(t * 0.04 + Double(i) * 2)) * size.height
            let rr = b.r * m
            ctx.fill(
                Path(ellipseIn: CGRect(x: cx - rr, y: cy - rr,
                                       width: 2 * rr, height: 2 * rr)),
                with: .radialGradient(
                    Gradient(colors: [b.color.opacity(0.14), .clear]),
                    center: CGPoint(x: cx, y: cy),
                    startRadius: 0, endRadius: rr))
        }
    }

    // MARK: - Stars

    private func starLayer(in ctx: GraphicsContext, size: CGSize, t: Double,
                           stars: [Star])
    {
        for s in stars {
            let x = (s.x + t * s.drift).truncatingRemainder(dividingBy: 1)
                * size.width
            let y = s.y * size.height
            let tw = 0.55 + 0.45 * sin(t * s.twinkleSpeed + s.twinklePhase)
            let a = s.baseAlpha * tw
            let c = CGPoint(x: x, y: y)
            // Soft halo + bright core.
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - s.size * 2.6,
                                            y: c.y - s.size * 2.6,
                                            width: s.size * 5.2,
                                            height: s.size * 5.2)),
                     with: .color(.white.opacity(a * 0.18)))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - s.size / 2,
                                            y: c.y - s.size / 2,
                                            width: s.size, height: s.size)),
                     with: .color(.white.opacity(a)))
        }
    }

    // MARK: - Shooting star

    private func shootingStar(in ctx: GraphicsContext, size: CGSize, t: Double) {
        let cycle = 12.0
        let ct = t.truncatingRemainder(dividingBy: cycle)
        guard ct < 1.1 else { return }
        let p = ct / 1.1
        let sx = size.width * 0.72, sy = size.height * 0.16
        let dx = -size.width * 0.30, dy = size.height * 0.17
        let head = CGPoint(x: sx + dx * p, y: sy + dy * p)
        let q = max(0, p - 0.22)
        let tail = CGPoint(x: sx + dx * q, y: sy + dy * q)
        var path = Path()
        path.move(to: tail)
        path.addLine(to: head)
        let fade = sin(p * .pi)
        ctx.stroke(path, with: .linearGradient(
            Gradient(colors: [.clear, .white.opacity(0.85 * fade)]),
            startPoint: tail, endPoint: head), lineWidth: 2)
    }

    // MARK: - Model

    private struct Star: Hashable {
        /// Normalised position (0...1); x wraps as it drifts.
        let x, y: Double
        let size: Double
        let baseAlpha: Double
        let twinkleSpeed: Double
        let twinklePhase: Double
        /// Fraction of the width per second.
        let drift: Double
    }

    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x853c49e6748fea9b : seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private static func makeStars(count: Int, seed: UInt64,
                                  drift: ClosedRange<Double>) -> [Star]
    {
        var rng = SeededRNG(seed: seed)
        return (0..<count).map { _ in
            Star(x: Double.random(in: 0...1, using: &rng),
                 y: Double.random(in: 0...1, using: &rng),
                 size: Double.random(in: 0.6...2.2, using: &rng),
                 baseAlpha: Double.random(in: 0.25...0.9, using: &rng),
                 twinkleSpeed: Double.random(in: 0.6...2.6, using: &rng),
                 twinklePhase: Double.random(in: 0...(2 * .pi), using: &rng),
                 drift: Double.random(in: drift, using: &rng))
        }
    }

    private static let farStars = makeStars(count: 140, seed: 0xC0FFEE,
                                            drift: 0.0012...0.0025)
    private static let nearStars = makeStars(count: 55, seed: 0x5EED,
                                             drift: 0.003...0.006)
}
