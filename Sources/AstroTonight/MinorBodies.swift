import Foundation
import Combine

// MARK: - Models

/// One comet's Keplerian elements, exactly as stored in
/// `Resources/comets.json` (built by `tools/build_minor_bodies.py` from
/// the MPC's Soft03Cmt.txt feed). Property names match the JSON keys
/// verbatim — including `q_au` / `tp_jd` — so the synthesized
/// `Decodable` conformance needs no key mapping.
///
/// All angles are decimal degrees; distances AU; times Julian dates.
/// `H`/`G` are the MPC total-magnitude parameters (nil when the MPC
/// record did not carry them).
struct CometElements: Codable, Identifiable, Hashable {
    let name: String
    /// Julian date of the element epoch.
    let epochJD: Double
    /// Eccentricity (may exceed 1 for hyperbolic comets).
    let e: Double
    /// Perihelion distance, AU.
    let q_au: Double
    /// Julian date of perihelion passage.
    let tp_jd: Double
    let node_deg: Double
    let peri_deg: Double
    let incl_deg: Double
    let H: Double?
    let G: Double?

    var id: String { name }
}

/// Geocentric position of a minor body at a moment.
struct MinorBodyPosition {
    /// Right ascension, decimal degrees, J2000 mean equator/equinox.
    let ra: Double
    /// Declination, decimal degrees, J2000 mean equator/equinox.
    let dec: Double
    /// Estimated total visual magnitude from the standard comet law
    /// `H + 5*log10(Delta) + 2.5*G*log10(r)`. APPROXIMATE by
    /// construction: MPC magnitude parameters are uncertain, comets
    /// outburst, and the law ignores phase and coma morphology.
    /// Nil when the elements lack H or G.
    let mag: Double?
}

/// The vendored snapshot file: provenance + element list.
struct CometCatalog: Codable {
    let source_url: String
    let fetched_utc: String
    let objects: [CometElements]
}

// MARK: - Kepler solver

/// Two-body propagation of cometary elements to geocentric RA/Dec.
///
/// Validated on the build VM (`tools/validate_kepler.py`) against JPL
/// Horizons: with JPL's own full-precision elements on both sides the
/// residual is <= 8.9 arcsec (12P/Pons-Brooks: 2.7"; 3I/ATLAS
/// hyperbolic: 8.9"), plus exact self-consistency (circular e=0 gives
/// v=90 deg at quarter period; Newton residuals ~1e-15).
///
/// Residuals against the sky are dominated by the ELEMENTS, not this
/// math: a 1-day-old MPC snapshot already differs from JPL's fit by
/// ~34" for 161P near perihelion, and 341-day-old 3I/ATLAS elements
/// are 151" off. That is why the bundled elements carry their epoch
/// and the UI warns when they go stale.
enum MinorBodies {
    /// Gaussian gravitational constant, rad/day (AU/day/solar-mass).
    private static let kGauss = 0.01720209895
    /// |e - 1| at or below this takes the parabolic (Barker) branch.
    private static let parabolicEps = 1e-6

    /// Geocentric J2000 RA/Dec and an approximate total magnitude.
    static func position(of elements: CometElements, at date: Date)
        -> MinorBodyPosition
    {
        let jd = AstroMath.julianDate(date)
        let g = geocentric(jd: jd, elements: elements)
        var mag: Double? = nil
        if let h = elements.H, let gg = elements.G {
            mag = h + 5.0 * log10(g.delta) + 2.5 * gg * log10(g.r)
        }
        return MinorBodyPosition(ra: g.ra, dec: g.dec, mag: mag)
    }

    // MARK: Solver internals (mirrors tools/build_minor_bodies.py)

    /// True anomaly (rad) and heliocentric distance (AU) at `jd`.
    /// Three explicit branches:
    /// - e < 1: elliptic Kepler E - e*sinE = M, Newton-Raphson.
    /// - |e-1| <= 1e-6: near-parabolic, Barker's equation
    ///   S + S^3/3 = 2*k*(t-Tp)/(2q)^1.5 with S = tan(v/2). The
    ///   elliptic form goes singular as e -> 1 (a -> infinity), so
    ///   this branch is the guard, not an optimization.
    /// - e > 1: hyperbolic Kepler e*sinhF - F = M, Newton-Raphson.
    private static func solveOrbit(e: Double, q: Double,
                                   tpJD: Double, jd: Double)
        -> (v: Double, r: Double)
    {
        if abs(e - 1.0) <= parabolicEps {
            let b = 2.0 * kGauss * (jd - tpJD) / pow(2.0 * q, 1.5)
            var s = b
            for _ in 0..<50 {
                let step = (s + s * s * s / 3.0 - b) / (1.0 + s * s)
                s -= step
                if abs(step) < 1e-13 { break }
            }
            return (2.0 * atan(s), q * (1.0 + s * s))
        } else if e < 1.0 {
            let a = q / (1.0 - e)
            let n = kGauss / pow(a, 1.5)
            var m = (n * (jd - tpJD))
                .truncatingRemainder(dividingBy: 2.0 * Double.pi)
            if m < -Double.pi {
                m += 2.0 * Double.pi
            } else if m >= Double.pi {
                m -= 2.0 * Double.pi
            }
            let eAnom = solveElliptic(meanAnomaly: m, e: e)
            let v = 2.0 * atan2(sqrt(1.0 + e) * sin(eAnom / 2.0),
                                sqrt(1.0 - e) * cos(eAnom / 2.0))
            return (v, a * (1.0 - e * cos(eAnom)))
        } else {
            let a = q / (1.0 - e)  // negative for e > 1
            let n = kGauss / pow(abs(a), 1.5)
            let m = n * (jd - tpJD)
            let f = solveHyperbolic(meanAnomaly: m, e: e)
            let v = 2.0 * atan2(sqrt(e + 1.0) * sinh(f / 2.0),
                                sqrt(e - 1.0) * cosh(f / 2.0))
            return (v, abs(a) * (e * cosh(f) - 1.0))
        }
    }

    /// Newton-Raphson for E - e*sinE = M (elliptic).
    private static func solveElliptic(meanAnomaly m: Double, e: Double)
        -> Double
    {
        var eAnom = m + e * sin(m)
        for _ in 0..<50 {
            let step = (eAnom - e * sin(eAnom) - m)
                / (1.0 - e * cos(eAnom))
            eAnom -= step
            if abs(step) < 1e-13 { break }
        }
        return eAnom
    }

    /// Newton-Raphson for e*sinhF - F = M (hyperbolic).
    private static func solveHyperbolic(meanAnomaly m: Double, e: Double)
        -> Double
    {
        var f = asinh(m / e)
        for _ in 0..<50 {
            let step = (e * sinh(f) - f - m) / (e * cosh(f) - 1.0)
            f -= step
            if abs(step) < 1e-13 { break }
        }
        return f
    }

    /// Earth's heliocentric J2000-ecliptic position (AU), low-precision
    /// solar theory. Same constants as `AstroMath.sunEclipticLongitude`,
    /// but those constants yield the Sun's longitude in the
    /// mean-equinox-OF-DATE frame (the w rate folds in general
    /// precession) — mixing that with J2000 comet elements cost 0.37
    /// deg by 2026 when measured against JPL Horizons vectors. The
    /// of-date longitude is therefore precessed back to J2000 by
    /// subtracting the accumulated precession in longitude
    /// p_A = 5028.796195*T + 1.1054348*T^2 arcsec. Exact for this model
    /// because Earth's ecliptic latitude is identically 0 here.
    private static func earthHeliocentric(jd: Double)
        -> (x: Double, y: Double, z: Double)
    {
        let d = jd - 2451543.5
        let w = (282.9404 + 4.70935e-5 * d) * AstroMath.deg2rad
        let ecc = 0.016709 - 1.151e-9 * d
        var m = ((356.0470 + 0.9856002585 * d) * AstroMath.deg2rad)
            .truncatingRemainder(dividingBy: 2.0 * Double.pi)
        if m < 0 { m += 2.0 * Double.pi }
        let eAnom = solveElliptic(meanAnomaly: m, e: ecc)
        let xv = cos(eAnom) - ecc
        let yv = sqrt(1.0 - ecc * ecc) * sin(eAnom)
        let v = atan2(yv, xv)
        let r = hypot(xv, yv)
        let lamSunDate = v + w
        let t = (jd - 2451545.0) / 36525.0
        let pA = (5028.796195 * t + 1.1054348 * t * t) / 3600.0
            * AstroMath.deg2rad
        let lamEarthJ2000 = lamSunDate + Double.pi - pA
        return (r * cos(lamEarthJ2000), r * sin(lamEarthJ2000), 0.0)
    }

    /// Geocentric J2000 RA/Dec (deg), heliocentric r (AU), Delta (AU).
    private static func geocentric(jd: Double, elements: CometElements)
        -> (ra: Double, dec: Double, r: Double, delta: Double)
    {
        let (v, r) = solveOrbit(e: elements.e, q: elements.q_au,
                                tpJD: elements.tp_jd, jd: jd)
        let om = elements.node_deg * AstroMath.deg2rad
        let wp = elements.peri_deg * AstroMath.deg2rad
        let incl = elements.incl_deg * AstroMath.deg2rad
        let u = wp + v
        let x = r * (cos(om) * cos(u)
                     - sin(om) * sin(u) * cos(incl))
        let y = r * (sin(om) * cos(u)
                     + cos(om) * sin(u) * cos(incl))
        let z = r * sin(u) * sin(incl)
        let earth = earthHeliocentric(jd: jd)
        let xg = x - earth.x
        let yg = y - earth.y
        let zg = z - earth.z
        // J2000 obliquity — the whole computation is J2000 now.
        let eps = 23.4392911 * AstroMath.deg2rad
        let yq = yg * cos(eps) - zg * sin(eps)
        let zq = yg * sin(eps) + zg * cos(eps)
        var ra = atan2(yq, xg) * AstroMath.rad2deg
        ra = ra.truncatingRemainder(dividingBy: 360.0)
        if ra < 0 { ra += 360.0 }
        let dec = atan2(zq, hypot(xg, yq)) * AstroMath.rad2deg
        let delta = sqrt(xg * xg + yg * yg + zg * zg)
        return (ra, dec, r, delta)
    }

    // MARK: MPC text parsing (for on-device refresh)

    /// Parse a Soft03Cmt.txt feed into elements. Mirrors
    /// `tools/build_minor_bodies.py::parse_mpc`, including the
    /// non-obvious field order (`Incl,Node,Peri` first) and the n == 0
    /// ultra-long-period records (epoch IS the perihelion there).
    static func parseMPC(_ text: String) -> [CometElements] {
        var out = [CometElements]()
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let f = line.split(separator: ",",
                               omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 10 else { continue }
            let name = String(f[0])
            if f[1] == "e", f.count >= 13,
               let incl = Double(f[2]), let node = Double(f[3]),
               let peri = Double(f[4]), let a = Double(f[5]),
               let n = Double(f[6]), let ecc = Double(f[7]),
               let mAnom = Double(f[8]),
               let epochJD = epochStringToJD(String(f[9]))
            {
                let hRaw = f[11].hasPrefix("g ")
                    ? String(f[11].dropFirst(2)) : String(f[11])
                guard let h = Double(hRaw) else { continue }
                let g = Double(f[12])
                let q = a * (1.0 - ecc)
                let tpJD: Double
                if n != 0 {
                    tpJD = epochJD - mAnom / n
                } else if mAnom == 0 {
                    tpJD = epochJD
                } else {
                    continue
                }
                out.append(CometElements(
                    name: name, epochJD: epochJD, e: ecc, q_au: q,
                    tp_jd: tpJD, node_deg: node, peri_deg: peri,
                    incl_deg: incl, H: h, G: g))
            } else if f[1] == "h", f.count >= 10,
                      let tpJD = epochStringToJD(String(f[2])),
                      let incl = Double(f[3]), let node = Double(f[4]),
                      let peri = Double(f[5]), let ecc = Double(f[6]),
                      let q = Double(f[7]),
                      let h = Double(f[9])
            {
                let g = f.count >= 11 ? Double(f[10]) : nil
                out.append(CometElements(
                    name: name, epochJD: tpJD, e: ecc, q_au: q,
                    tp_jd: tpJD, node_deg: node, peri_deg: peri,
                    incl_deg: incl, H: h, G: g))
            }
        }
        return out
    }

    /// `10/04.0/2026` -> Julian date (Meeus). Nil when malformed.
    static func epochStringToJD(_ s: String) -> Double? {
        let parts = s.split(separator: "/")
        guard parts.count == 3,
              let mo = Int(parts[0]),
              let day = Double(parts[1]),
              let yr = Int(parts[2])
        else { return nil }
        var y = yr
        var m = mo
        if m <= 2 { y -= 1; m += 12 }
        let a = y / 100
        let b = 2 - a + a / 4
        return Double(Int(365.25 * Double(y + 4716))
                      + Int(30.6001 * Double(m + 1)))
            + day + Double(b) - 1524.5
    }

    /// The pipeline's selection rule, mirrored on-device: element epoch
    /// within 400 days of now, estimated current total magnitude <= 16,
    /// keep the 10 brightest. Needs H and G for the magnitude estimate.
    static func selectBright(_ elements: [CometElements],
                             now: Date) -> [CometElements]
    {
        let jdNow = AstroMath.julianDate(now)
        var scored = [(mag: Double, el: CometElements)]()
        for el in elements {
            guard abs(jdNow - el.epochJD) <= 400.0 else { continue }
            let pos = MinorBodies.position(of: el, at: now)
            guard let m = pos.mag, m <= 16.0 else { continue }
            scored.append((m, el))
        }
        return scored.sorted { $0.mag < $1.mag }
            .prefix(10)
            .map { $0.el }
    }
}

// MARK: - Service

/// Holds the vendored comet list, its provenance, and staleness state.
///
/// Loads the bundled `comets.json` snapshot at init; a successful
/// `refreshFromNetwork()` replaces it with freshly parsed MPC elements
/// persisted to Application Support (the app bundle is read-only).
///
/// Staleness: comet osculating elements decay fast — planetary
/// perturbations plus non-gravitational (outgassing) forces, worst near
/// perihelion. Measured on the build VM: 1-day-old MPC elements were
/// already 34" off JPL's fit for 161P at perihelion approach, and
/// 341-day-old 3I/ATLAS elements were 151" off. The MPC itself issues
/// fresh elements on roughly a monthly cycle, so **30 days** is the
/// warning threshold: beyond one MPC element cycle the positions are no
/// longer trustworthy for finding.
@MainActor
final class MinorBodyService: ObservableObject {
    /// Days of element age at which positions are flagged unreliable.
    static let staleThresholdDays = 30.0

    private static let mpcURL = URL(string:
        "https://www.minorplanetcenter.net/iau/Ephemerides/Comets/Soft03Cmt.txt")!
    private static let cacheFileName = "comets.json"

    @Published private(set) var comets: [CometElements] = []
    /// ISO-8601 UTC instant the current list was fetched/built.
    @Published private(set) var fetchedUTC: String? = nil
    @Published private(set) var isRefreshing = false
    /// Last refresh failure, human-readable. Nil after a success.
    @Published private(set) var lastError: String? = nil

    /// Age of the OLDEST element epoch in the list, days. Nil if empty.
    /// The oldest drives the warning: a list is only as fresh as its
    /// stalest orbit.
    var epochAgeDays: Double? {
        guard let oldest = comets.map(\.epochJD).min() else { return nil }
        return AstroMath.julianDate(Date()) - oldest
    }

    /// Age of one object's element epoch, days. Shown per row.
    func ageDays(of comet: CometElements) -> Double {
        AstroMath.julianDate(Date()) - comet.epochJD
    }

    /// True when any elements are older than the stale threshold.
    var isStale: Bool {
        guard let age = epochAgeDays else { return false }
        return age > Self.staleThresholdDays
    }

    init() {
        load()
    }

    /// Refetch the MPC feed (~10 s timeout) and rebuild the bright list.
    /// Graceful offline: any failure only sets `lastError` and keeps
    /// the previous list.
    func refreshFromNetwork() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let request = URLRequest(url: Self.mpcURL, timeoutInterval: 10)
            let (data, response) =
                try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                lastError = "MPC feed returned HTTP \(code)."
                return
            }
            guard let text = String(data: data, encoding: .utf8) else {
                lastError = "MPC feed was not readable text."
                return
            }
            let now = Date()
            let bright = MinorBodies.selectBright(
                MinorBodies.parseMPC(text), now: now)
            guard !bright.isEmpty else {
                lastError = "MPC feed parsed but yielded no bright comets."
                return
            }
            let stamp = Self.iso8601(now)
            saveCache(CometCatalog(source_url: Self.mpcURL.absoluteString,
                                   fetched_utc: stamp, objects: bright))
            comets = bright
            fetchedUTC = stamp
            lastError = nil
        } catch {
            // Offline, DNS, TLS, timeout — keep the old list.
            lastError = error.localizedDescription
        }
    }

    // MARK: Loading

    private func load() {
        if let cached = loadCache() {
            comets = cached.objects
            fetchedUTC = cached.fetched_utc
        } else if let bundled = loadBundled() {
            comets = bundled.objects
            fetchedUTC = bundled.fetched_utc
        }
    }

    private func loadBundled() -> CometCatalog? {
        // SwiftPM builds use the processed-resources bundle; when the
        // sources are dragged into a plain Xcode iOS project (see
        // docs/iOS-setup.md) the resource lands in the main bundle.
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "comets",
                                   withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(CometCatalog.self, from: data)
    }

    private static func cacheFileURL() -> URL? {
        guard let dir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
        else { return nil }
        return dir.appendingPathComponent("AstroTonight",
                                          isDirectory: true)
            .appendingPathComponent(cacheFileName)
    }

    private func loadCache() -> CometCatalog? {
        guard let url = Self.cacheFileURL(),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(CometCatalog.self, from: data)
    }

    private func saveCache(_ catalog: CometCatalog) {
        guard let url = Self.cacheFileURL(),
              let data = try? JSONEncoder().encode(catalog)
        else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
