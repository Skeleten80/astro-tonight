import SwiftUI

// MARK: - Public API (the coordinator wires SkyChartView into a sheet)

/// A deep-sky target to mark on the chart. RA/Dec in degrees, J2000-ish
/// like the catalog (precession to the current epoch is skipped
/// app-wide; see AstroMath).
struct SkyChartTarget {
    let id: String
    let name: String
    let ra: Double
    let dec: Double
    let mag: Double?
}

enum SkyChartSelectionKind {
    case star
    case target
    case planet
}

struct SkyChartSelection {
    let name: String
    let ra: Double
    let dec: Double
    let kind: SkyChartSelectionKind
}

// MARK: - Binary readers (little-endian, alignment-safe)

private func skyReadU32(_ d: Data, _ off: Int) -> UInt32 {
    (UInt32(d[off]) | (UInt32(d[off + 1]) << 8)
        | (UInt32(d[off + 2]) << 16) | (UInt32(d[off + 3]) << 24))
}

private func skyReadI16(_ d: Data, _ off: Int) -> Int16 {
    Int16(bitPattern: UInt16(d[off]) | (UInt16(d[off + 1]) << 8))
}

private func skyReadF32(_ d: Data, _ off: Int) -> Float {
    Float(bitPattern: skyReadU32(d, off))
}

// MARK: - StarStore

/// Loads Resources/stars.bin (written by tools/tycho2_pipeline.py).
/// Binary format, all little-endian:
///   6 bytes  magic "TYCH2\0"
///   4 bytes  uint32 star count N
///   N x 10 bytes: float32 RA deg [0,360), float32 Dec deg [-90,90],
///                 int16 round(V*100); records sorted by ascending V.
///
/// Thread-safety: call loadIfNeeded() once, then refreshAltAz() (async,
/// idempotent, 2-minute quantized) before reading. After refreshAltAz()
/// returns, the arrays are never mutated again, so the view's lock-free
/// reads on the main thread are safe.
final class StarStore {
    /// One catalog star: RA/Dec in degrees (J2000), V magnitude.
    struct Star {
        let ra: Float
        let dec: Float
        let mag: Float
    }

    private let lock = NSLock()
    private var blob: Data?
    private var altCache: [Float] = []
    private var azCache: [Float] = []
    private var cachedKey: String?
    private(set) var count: Int = 0

    /// Faintest V in the file (records are magnitude-sorted ascending).
    var faintestMag: Float {
        guard count > 0 else { return 0 }
        return star(at: count - 1).mag
    }

    var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return blob != nil
    }

    /// Loads stars.bin once; safe to call repeatedly. Uses the same
    /// bundle pattern as the catalog loader in Models.swift: SwiftPM
    /// builds read Bundle.module, the hand-built Xcode iOS project
    /// (docs/iOS-setup.md) reads Bundle.main.
    func loadIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard blob == nil else { return }
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "stars",
                                   withExtension: "bin"),
              let data = try? Data(contentsOf: url),
              data.count >= 10,
              data[0] == 0x54, data[1] == 0x59, data[2] == 0x43,
              data[3] == 0x48, data[4] == 0x32, data[5] == 0x00
        else { return }
        let n = Int(skyReadU32(data, 6))
        guard n > 0, data.count == 10 + n * 10 else { return }
        blob = data
        count = n
    }

    func star(at index: Int) -> Star {
        guard let d = blob, index >= 0, index < count else {
            return Star(ra: 0, dec: 0, mag: 99)
        }
        let off = 10 + index * 10
        return Star(ra: skyReadF32(d, off),
                    dec: skyReadF32(d, off + 4),
                    mag: Float(skyReadI16(d, off + 8)) / 100)
    }

    /// Number of stars with V <= limit. The file is magnitude-sorted, so
    /// the renderer iterates only this prefix (binary search, O(log n)).
    func prefixCount(magLimit limit: Float) -> Int {
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if star(at: mid).mag <= limit {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    /// Cached alt/az in degrees for a star (call after refreshAltAz()
    /// completes; alt is -90 for stars culled below the horizon).
    func altAz(at index: Int) -> (alt: Float, az: Float) {
        guard index >= 0, index < altCache.count else { return (-90, 0) }
        return (altCache[index], azCache[index])
    }

    /// Recomputes per-star alt/az for the given epoch on a background
    /// thread (about 0.2 s per million stars; the view shows a loader
    /// meanwhile). Same math as AstroMath.altAz (which stays the readable
    /// reference); the loop here is inlined for speed. Quantized to
    /// 2 minutes: calls within a quantum are no-ops.
    func refreshAltAz(julianDate jd: Double, lat: Double,
                      lon: Double) async {
        let key = "\(Int((jd * 720).rounded())),\(lat),\(lon)"
        lock.lock()
        let same = (cachedKey == key)
        let data = blob
        let n = count
        lock.unlock()
        if same { return }
        guard let d = data, n > 0 else { return }
        let lst = AstroMath.lstDegrees(julianDate: jd, lon: lon)
            * Double.pi / 180
        let latR = lat * Double.pi / 180
        let sinLat = sin(latR)
        let cosLat = cos(latR)
        let twoPi = 2 * Double.pi
        let (alts, azs) = await Task.detached(priority: .userInitiated) {
            () -> ([Float], [Float]) in
            var outAlt = [Float](repeating: -90, count: n)
            var outAz = [Float](repeating: 0, count: n)
            let horizon = sin(-1.0 * Double.pi / 180)
            for i in 0..<n {
                let base = 10 + i * 10
                let raRad = Double(skyReadF32(d, base)) * Double.pi / 180
                let decRad = Double(skyReadF32(d, base + 4))
                    * Double.pi / 180
                let sinDec = sin(decRad)
                let cosDec = cos(decRad)
                var h = (lst - raRad)
                    .truncatingRemainder(dividingBy: twoPi)
                if h > Double.pi {
                    h -= twoPi
                } else if h < -Double.pi {
                    h += twoPi
                }
                let sinAlt = sinDec * sinLat
                    + cosDec * cosLat * cos(h)
                if sinAlt > horizon {
                    let alt = asin(sinAlt)
                    let y = sin(h)
                    // Matches AstroMath.altAz: atan2(y, x) + 180,
                    // normalized to [0, 360).
                    let x = cos(h) * sinLat
                        - (sinDec / cosDec) * cosLat
                    var az = atan2(y, x) * 180 / Double.pi + 180
                    az = az.truncatingRemainder(dividingBy: 360)
                    if az < 0 { az += 360 }
                    outAlt[i] = Float(alt * 180 / Double.pi)
                    outAz[i] = Float(az)
                }
            }
            return (outAlt, outAz)
        }.value
        lock.lock()
        altCache = alts
        azCache = azs
        cachedKey = key
        lock.unlock()
    }
}

// MARK: - Constellation lines

/// One constellation's line segments, degrees. Decoded from
/// Resources/constellations.json (see tools/constellation_pipeline.py).
/// Provenance: d3-celestial by Olaf Frohn, BSD 2-clause
/// (https://github.com/ofrohn/d3-celestial) — permissive, not copyleft;
/// bundled with attribution here to satisfy the license.
private struct SkyConstellation: Decodable {
    let name: String
    let lines: [[Double]]
}

private final class ConstellationCache {
    static let shared = ConstellationCache()
    private let lock = NSLock()
    private var cached: [SkyConstellation]?

    func all() -> [SkyConstellation] {
        lock.lock()
        defer { lock.unlock() }
        if let c = cached { return c }
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        var loaded: [SkyConstellation] = []
        if let url = bundle.url(forResource: "constellations",
                                withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            loaded = (try? JSONDecoder().decode([SkyConstellation].self,
                                                from: data)) ?? []
        }
        cached = loaded
        return loaded
    }
}

// MARK: - Stereographic projection

/// Stereographic projection of the alt/az sky onto the view.
/// Convention: the zenith-centered all-sky view has north up, east
/// right (the standard star-chart orientation); panning moves the
/// center with a grab-the-sky feel. Points on the far side
/// (angular distance > ~177 deg from the center) project to nil.
private struct SkyProjection {
    var centerX: Double
    var centerY: Double
    var scale: Double // pixels per stereographic unit radius
    var centerAltDeg: Double
    var centerAzDeg: Double

    func point(altDeg: Double, azDeg: Double) -> CGPoint? {
        let d2r = Double.pi / 180
        let alt = altDeg * d2r
        let dAz = (azDeg - centerAzDeg) * d2r
        let alt0 = centerAltDeg * d2r
        let cosC = sin(alt0) * sin(alt)
            + cos(alt0) * cos(alt) * cos(dAz)
        guard cosC > -0.999 else { return nil }
        let k = 1 / (1 + cosC)
        let x = k * cos(alt) * sin(dAz)
        let y = k * (cos(alt0) * sin(alt)
            - sin(alt0) * cos(alt) * cos(dAz))
        // +y is south in these tangent-plane coordinates, so adding it
        // to the downward-growing screen y keeps north up.
        return CGPoint(x: centerX + x * scale, y: centerY + y * scale)
    }
}

// MARK: - SkyChartView

/// Interactive planetarium chart: Tycho-2 stars (magnitude-limited by
/// zoom), constellation lines, alt-az grid, and target crosshairs.
/// Drag to pan, pinch to zoom, tap a star or target to select it.
///
/// Night vision: ContentView's red multiply overlay lives in its own
/// root ZStack, which sheets render ABOVE — so this view applies the
/// identical overlay itself (same AppStorage key, color, opacity and
/// blend mode) and stays dark-adaptation safe when shown in a sheet.
struct SkyChartView: View {
    let starStore: StarStore
    let lat: Double
    let lon: Double
    let date: Date
    let targets: [SkyChartTarget]
    let onSelect: ((SkyChartSelection) -> Void)? = nil
    /// Planet markers (Schlyter positions, Planets.swift). Defaulted so
    /// existing call sites compile unchanged.
    let showPlanets: Bool = true

    @AppStorage("AstroTonight.nightVision") private var nightVision = false
    @State private var centerAltDeg: Double = 90
    @State private var centerAzDeg: Double = 0
    @State private var zoom: Double = 1
    @State private var lastDrag: CGSize = .zero
    @State private var starsReady = false
    @GestureState private var pinchScale: CGFloat = 1

    private var julianDate: Double { AstroMath.julianDate(date) }

    /// 2-minute quantization, matching StarStore.refreshAltAz: the sky
    /// doesn't visibly move faster than that on this chart.
    private var skyEpochKey: String {
        let q = Int((julianDate * 720).rounded())
        return "\(q):\(lat):\(lon)"
    }

    private var effectiveZoom: Double {
        let z = zoom * Double(pinchScale)
        if z < 1 { return 1 }
        if z > 32 { return 32 }
        return z
    }

    /// One extra magnitude per octave of zoom from a 6.5 base, capped by
    /// the catalog's faint end (~V 11): whole-sky overviews stay fast,
    /// deep zooms reveal the full catalog depth for star-hopping.
    private var magnitudeLimit: Double {
        let m = 6.5 + log2(max(1, effectiveZoom))
        return min(m, Double(starStore.faintestMag))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                chartContent(size: geo.size)
                if nightVision {
                    Color(red: 1, green: 0, blue: 0).opacity(0.35)
                        .blendMode(.multiply)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func chartContent(size: CGSize) -> some View {
        ZStack {
            if !starsReady {
                ProgressView("Loading star catalog…")
            } else if starStore.count == 0 {
                Text("Star catalog (stars.bin) is missing from the bundle.")
                    .foregroundStyle(.secondary)
            } else {
                Canvas { ctx, _ in
                    drawChart(in: ctx, size: size)
                }
                .gesture(panGesture(size: size)
                    .simultaneously(with: zoomGesture))
                .onTapGesture { location in
                    hitTest(at: location, size: size)
                }
                .accessibilityLabel("Interactive sky chart")
            }
        }
        .task(id: skyEpochKey) {
            starStore.loadIfNeeded()
            await starStore.refreshAltAz(julianDate: julianDate,
                                         lat: lat, lon: lon)
            starsReady = starStore.isLoaded
        }
    }

    // MARK: - Gestures

    private func panGesture(size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let dx = Double(value.translation.width - lastDrag.width)
                let dy = Double(value.translation.height - lastDrag.height)
                lastDrag = value.translation
                panBy(dx: dx, dy: dy, size: size)
            }
            .onEnded { _ in
                lastDrag = .zero
            }
    }

    /// Grab-the-sky panning: the sky follows the finger.
    private func panBy(dx: Double, dy: Double, size: CGSize) {
        let minDim = max(1, min(size.width, size.height))
        let ppd = effectiveZoom * minDim / 2 * Double.pi / 360
        guard ppd > 0 else { return }
        var alt = centerAltDeg - dy / ppd
        var az = centerAzDeg - dx / ppd
        if alt < 0 { alt = 0 }
        if alt > 90 { alt = 90 }
        az = az.truncatingRemainder(dividingBy: 360)
        if az < 0 { az += 360 }
        centerAltDeg = alt
        centerAzDeg = az
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .updating($pinchScale) { value, state, _ in
                state = value
            }
            .onEnded { value in
                let z = zoom * Double(value)
                if z < 1 {
                    zoom = 1
                } else if z > 32 {
                    zoom = 32
                } else {
                    zoom = z
                }
            }
    }

    // MARK: - Projection

    private func projection(size: CGSize) -> SkyProjection {
        let minDim = max(1, min(size.width, size.height))
        return SkyProjection(
            centerX: Double(size.width) / 2,
            centerY: Double(size.height) / 2,
            scale: effectiveZoom * minDim / 2,
            centerAltDeg: centerAltDeg,
            centerAzDeg: centerAzDeg)
    }

    // MARK: - Drawing

    private struct PlottedStar {
        let point: CGPoint
        let mag: Float
        let ra: Double
        let dec: Double
    }

    private func drawChart(in ctx: GraphicsContext, size: CGSize) {
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.020, green: 0.030, blue: 0.080),
                        Color(red: 0.005, green: 0.008, blue: 0.020)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)))
        let proj = projection(size: size)
        drawGrid(in: ctx, proj: proj)
        drawConstellations(in: ctx, proj: proj)
        drawStars(in: ctx, stars: projectedStars(proj: proj, size: size))
        drawTargets(in: ctx, proj: proj)
        drawPlanets(in: ctx, proj: proj)
        drawCardinals(in: ctx, proj: proj)
    }

    /// Stars brighter than the zoom's magnitude limit, above the horizon
    /// and inside the viewport. The store's alt/az cache makes this a
    /// trig-free scan over the magnitude-sorted prefix.
    private func projectedStars(proj: SkyProjection,
                                size: CGSize) -> [PlottedStar] {
        let n = starStore.prefixCount(magLimit: Float(magnitudeLimit))
        var out: [PlottedStar] = []
        out.reserveCapacity(min(n, 200_000))
        let w = Double(size.width) + 20
        let h = Double(size.height) + 20
        for i in 0..<n {
            let cached = starStore.altAz(at: i)
            if cached.alt < -1 { continue }
            guard let p = proj.point(altDeg: Double(cached.alt),
                                     azDeg: Double(cached.az)) else {
                continue
            }
            let x = Double(p.x)
            let y = Double(p.y)
            if x < -20 || y < -20 || x > w || y > h { continue }
            let s = starStore.star(at: i)
            out.append(PlottedStar(point: p, mag: s.mag,
                                   ra: Double(s.ra), dec: Double(s.dec)))
        }
        return out
    }

    private func starRadius(mag: Float) -> CGFloat {
        let r = 3.2 - 0.5 * Double(mag)
        if r < 0.55 { return 0.55 }
        if r > 3.4 { return 3.4 }
        return CGFloat(r)
    }

    private func drawStars(in ctx: GraphicsContext,
                           stars: [PlottedStar]) {
        for s in stars {
            let r = starRadius(mag: s.mag)
            ctx.fill(Path(ellipseIn: CGRect(x: s.point.x - r,
                                            y: s.point.y - r,
                                            width: r * 2, height: r * 2)),
                     with: .color(.white.opacity(0.92)))
        }
    }

    private func drawConstellations(in ctx: GraphicsContext,
                                    proj: SkyProjection) {
        var path = Path()
        for c in ConstellationCache.shared.all() {
            for seg in c.lines {
                guard seg.count == 4 else { continue }
                // Re-wrap the far endpoint toward the near one so
                // RA=0 crossings draw as short segments, not streaks.
                let ra1 = seg[0]
                var d = (seg[2] - ra1)
                    .truncatingRemainder(dividingBy: 360)
                if d > 180 {
                    d -= 360
                } else if d < -180 {
                    d += 360
                }
                let a1 = AstroMath.altAz(ra: ra1, dec: seg[1],
                                         julianDate: julianDate,
                                         lat: lat, lon: lon)
                if a1.alt < -0.5 { continue }
                let a2 = AstroMath.altAz(ra: ra1 + d, dec: seg[3],
                                         julianDate: julianDate,
                                         lat: lat, lon: lon)
                if a2.alt < -0.5 { continue }
                guard let p1 = proj.point(altDeg: a1.alt, azDeg: a1.az),
                      let p2 = proj.point(altDeg: a2.alt, azDeg: a2.az)
                else { continue }
                path.move(to: p1)
                path.addLine(to: p2)
            }
        }
        ctx.stroke(path,
                   with: .color(Color(red: 0.45, green: 0.55, blue: 0.85)
                    .opacity(0.5)),
                   lineWidth: 1)
    }

    /// Horizon circle plus 30°/60° altitude circles.
    private func drawGrid(in ctx: GraphicsContext, proj: SkyProjection) {
        for alt in [0.0, 30.0, 60.0] {
            var path = Path()
            var started = false
            var az = 0.0
            while az < 360.0 {
                if let p = proj.point(altDeg: alt, azDeg: az) {
                    if started {
                        path.addLine(to: p)
                    } else {
                        path.move(to: p)
                        started = true
                    }
                } else {
                    started = false
                }
                az += 2.0
            }
            path.closeSubpath()
            let isHorizon = alt == 0.0
            ctx.stroke(path,
                       with: .color(.white.opacity(isHorizon ? 0.35 : 0.12)),
                       lineWidth: isHorizon ? 1.5 : 0.75)
        }
    }

    private func drawCardinals(in ctx: GraphicsContext,
                               proj: SkyProjection) {
        let labels: [(String, Double)] = [("N", 0), ("E", 90),
                                          ("S", 180), ("W", 270)]
        for (name, az) in labels {
            if let p = proj.point(altDeg: 3, azDeg: az) {
                // Plain Text only: GraphicsContext.draw takes Text
                // without modifiers.
                ctx.draw(Text(name),
                         at: CGPoint(x: p.x, y: p.y - 12))
            }
        }
    }

    private func drawTargets(in ctx: GraphicsContext,
                             proj: SkyProjection) {
        for t in targets {
            let a = AstroMath.altAz(ra: t.ra, dec: t.dec,
                                    julianDate: julianDate,
                                    lat: lat, lon: lon)
            if a.alt < 0 { continue }
            guard let p = proj.point(altDeg: a.alt, azDeg: a.az) else {
                continue
            }
            let r: CGFloat = 8
            let mark = Color.orange
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r,
                                              width: r * 2, height: r * 2)),
                       with: .color(mark), lineWidth: 1.5)
            var ticks = Path()
            ticks.move(to: CGPoint(x: p.x - r - 5, y: p.y))
            ticks.addLine(to: CGPoint(x: p.x - r + 2, y: p.y))
            ticks.move(to: CGPoint(x: p.x + r - 2, y: p.y))
            ticks.addLine(to: CGPoint(x: p.x + r + 5, y: p.y))
            ticks.move(to: CGPoint(x: p.x, y: p.y - r - 5))
            ticks.addLine(to: CGPoint(x: p.x, y: p.y - r + 2))
            ticks.move(to: CGPoint(x: p.x, y: p.y + r - 2))
            ticks.addLine(to: CGPoint(x: p.x, y: p.y + r + 5))
            ctx.stroke(ticks, with: .color(mark), lineWidth: 1.5)
            ctx.draw(Text(t.name),
                     at: CGPoint(x: p.x + r + 8, y: p.y - r - 6))
        }
    }

    /// Planets as small filled pale-gold discs — visually distinct from
    /// the DSO crosshair circles — with plain-text name labels. Positions
    /// from PlanetMath (Schlyter, ~1' accuracy); skipped below the
    /// horizon.
    private func drawPlanets(in ctx: GraphicsContext,
                             proj: SkyProjection) {
        guard showPlanets else { return }
        let gold = Color(red: 1.0, green: 0.82, blue: 0.45)
        for planet in PlanetMath.displayPlanets {
            let pos = PlanetMath.position(of: planet, at: date)
            let a = AstroMath.altAz(ra: pos.ra, dec: pos.dec,
                                    julianDate: julianDate,
                                    lat: lat, lon: lon)
            if a.alt < 0 { continue }
            guard let p = proj.point(altDeg: a.alt, azDeg: a.az) else {
                continue
            }
            let r: CGFloat = 4.5
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r,
                                            width: r * 2, height: r * 2)),
                     with: .color(gold.opacity(0.95)))
            // Plain Text only: GraphicsContext.draw takes Text without
            // modifiers.
            ctx.draw(Text(planet.symbol + " " + planet.displayName),
                     at: CGPoint(x: p.x + r + 8, y: p.y - r - 6))
        }
    }

    // MARK: - Hit testing

    /// Tap: nearest target within 20 pt wins, else nearest planet within
    /// 18 pt, else nearest drawn star within 12 pt. Reports through
    /// onSelect; no selection when the tap hits empty sky.
    private func hitTest(at location: CGPoint, size: CGSize) {
        let proj = projection(size: size)
        var hitTarget: SkyChartTarget?
        var hitDist = 20.0
        for t in targets {
            let a = AstroMath.altAz(ra: t.ra, dec: t.dec,
                                    julianDate: julianDate,
                                    lat: lat, lon: lon)
            if a.alt < 0 { continue }
            guard let p = proj.point(altDeg: a.alt, azDeg: a.az) else {
                continue
            }
            let d = hypot(Double(location.x - p.x),
                          Double(location.y - p.y))
            if d < hitDist {
                hitDist = d
                hitTarget = t
            }
        }
        if let t = hitTarget {
            onSelect?(SkyChartSelection(name: t.name, ra: t.ra, dec: t.dec,
                                        kind: .target))
            return
        }
        var hitPlanet: Planet?
        var planetDist = 18.0
        for planet in PlanetMath.displayPlanets {
            let pos = PlanetMath.position(of: planet, at: date)
            let a = AstroMath.altAz(ra: pos.ra, dec: pos.dec,
                                    julianDate: julianDate,
                                    lat: lat, lon: lon)
            if a.alt < 0 { continue }
            guard let p = proj.point(altDeg: a.alt, azDeg: a.az) else {
                continue
            }
            let d = hypot(Double(location.x - p.x),
                          Double(location.y - p.y))
            if d < planetDist {
                planetDist = d
                hitPlanet = planet
            }
        }
        if let planet = hitPlanet {
            let pos = PlanetMath.position(of: planet, at: date)
            onSelect?(SkyChartSelection(name: planet.displayName,
                                        ra: pos.ra, dec: pos.dec,
                                        kind: .planet))
            return
        }
        var hitStar: PlottedStar?
        var starDist = 12.0
        for s in projectedStars(proj: proj, size: size) {
            let d = hypot(Double(location.x - s.point.x),
                          Double(location.y - s.point.y))
            if d < starDist {
                starDist = d
                hitStar = s
            }
        }
        if let s = hitStar {
            let label = String(format: "Star · V %.1f", Double(s.mag))
            onSelect?(SkyChartSelection(name: label, ra: s.ra, dec: s.dec,
                                        kind: .star))
        }
    }
}
