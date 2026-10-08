import Foundation

// MARK: - Planets (Paul Schlyter's algorithm)
//
// Geocentric RA/Dec for the eight major planets, computed from
// Paul Schlyter's "How to compute planetary positions"
// (http://stjarnhimlen.se/comp/ppcomp.html, public domain):
// Keplerian orbital elements (section 4) -> Kepler's equation (6)
// -> heliocentric ecliptic position (7) -> the Jupiter/Saturn/Uranus
// perturbation terms (10) -> geocentric ecliptic (11) -> equatorial (12).
//
// Honest accuracy: the algorithm claims a fraction of an arcminute for
// the Sun and inner planets and about one arcminute for the outer
// planets, and it deliberately ignores light-travel time, aberration and
// nutation. Validated against JPL Horizons apparent RA/Dec at three
// 2026 timestamps with tools/validate_planets.py: every body agrees to
// better than 2 arcminutes (worst case: Uranus at 1.52'). That is plenty
// for chart markers and "is Jupiter up tonight?", and not for precise
// astrometry or occultation work.
//
// Pluto is deliberately excluded: Schlyter treats it with a separate
// Fourier fit (section 14), not the orbital-element path below, and at
// V~15 it is not a visual/imaging target for this app's audience.
//
// Pure Foundation: this file imports nothing else, so the math is usable
// from any layer without pulling in SwiftUI.

/// The eight major planets. Earth is included because the geocentric
/// reduction needs Earth's orbit (the Sun's apparent position); the UI
/// filters it out of planet lists via `isDisplayable`.
enum Planet: String, CaseIterable, Identifiable {
    case mercury
    case venus
    case earth
    case mars
    case jupiter
    case saturn
    case uranus
    case neptune

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mercury: return "Mercury"
        case .venus: return "Venus"
        case .earth: return "Earth"
        case .mars: return "Mars"
        case .jupiter: return "Jupiter"
        case .saturn: return "Saturn"
        case .uranus: return "Uranus"
        case .neptune: return "Neptune"
        }
    }

    var symbol: String {
        switch self {
        case .mercury: return "☿"
        case .venus: return "♀"
        case .earth: return "♁"
        case .mars: return "♂"
        case .jupiter: return "♃"
        case .saturn: return "♄"
        case .uranus: return "♅"
        case .neptune: return "♆"
        }
    }

    /// Earth has no geocentric planet position; the UI shows the other
    /// seven.
    var isDisplayable: Bool { self != .earth }
}

/// Geocentric right ascension and declination, decimal degrees.
struct PlanetPosition {
    let ra: Double
    let dec: Double
}

/// Keplerian orbital elements with their linear time dependence.
/// Angles in degrees; `d` is days since 2000 Jan 0.0 (d = JD - 2451543.5).
private struct PlanetElements {
    let n0: Double
    let nDot: Double
    let i0: Double
    let iDot: Double
    let w0: Double
    let wDot: Double
    let a0: Double
    let aDot: Double
    let e0: Double
    let eDot: Double
    let m0: Double
    let mDot: Double
}

private enum Schlyter {
    static let deg2rad = Double.pi / 180.0

    static func norm360(_ x: Double) -> Double {
        var v = x.truncatingRemainder(dividingBy: 360.0)
        if v < 0 { v += 360.0 }
        return v
    }

    /// Newton-Raphson solution of Kepler's equation, section 6.
    /// M and the return value are in radians.
    static func eccentricAnomaly(meanAnomaly m: Double,
                                 eccentricity e: Double) -> Double {
        var E = m + e * sin(m) * (1.0 + e * cos(m))
        for _ in 0..<25 {
            let E1 = E - (E - e * sin(E) - m) / (1.0 - e * cos(E))
            if abs(E1 - E) < 1e-11 { return E1 }
            E = E1
        }
        return E
    }

    /// Heliocentric ecliptic position, sections 6-7.
    /// Returns (xh, yh, zh, r, ecliptic longitude deg, ecliptic latitude
    /// deg, mean anomaly deg). For the "sun" pseudo-body (Earth's orbit,
    /// N=0, i=0) the longitude is the Sun's apparent ecliptic longitude.
    static func helio(_ el: PlanetElements, d: Double)
        -> (Double, Double, Double, Double, Double, Double, Double)
    {
        let N = norm360(el.n0 + el.nDot * d) * deg2rad
        let inc = norm360(el.i0 + el.iDot * d) * deg2rad
        let w = norm360(el.w0 + el.wDot * d) * deg2rad
        let a = el.a0 + el.aDot * d
        let e = el.e0 + el.eDot * d
        let M = norm360(el.m0 + el.mDot * d)
        let E = eccentricAnomaly(meanAnomaly: M * deg2rad, eccentricity: e)
        let xv = a * (cos(E) - e)
        let yv = a * (sqrt(1.0 - e * e) * sin(E))
        let v = atan2(yv, xv)
        let r = hypot(xv, yv)
        let vw = v + w
        let xh = r * (cos(N) * cos(vw)
                      - sin(N) * sin(vw) * cos(inc))
        let yh = r * (sin(N) * cos(vw)
                      + cos(N) * sin(vw) * cos(inc))
        let zh = r * sin(vw) * sin(inc)
        let lon = norm360(atan2(yh, xh) / deg2rad)
        let lat = atan2(zh, hypot(xh, yh)) / deg2rad
        return (xh, yh, zh, r, lon, lat, M)
    }

    /// Section 10: longitude/latitude perturbation terms for Jupiter,
    /// Saturn and Uranus. mj/ms/mu are the mean anomalies of Jupiter,
    /// Saturn and Uranus in degrees.
    static func perturb(body: Planet, lon: Double, lat: Double,
                        mj: Double, ms: Double, mu: Double)
        -> (Double, Double)
    {
        var lonOut = lon
        var latOut = lat
        switch body {
        case .jupiter:
            lonOut += (-0.332 * sin(deg2rad * (2 * mj - 5 * ms - 67.6))
                - 0.056 * sin(deg2rad * (2 * mj - 2 * ms + 21.0))
                + 0.042 * sin(deg2rad * (3 * mj - 5 * ms + 21.0))
                - 0.036 * sin(deg2rad * (mj - 2 * ms))
                + 0.022 * cos(deg2rad * (mj - ms))
                + 0.023 * sin(deg2rad * (2 * mj - 3 * ms + 52.0))
                - 0.016 * sin(deg2rad * (mj - 5 * ms - 69.0)))
        case .saturn:
            lonOut += (0.812 * sin(deg2rad * (2 * mj - 5 * ms - 67.6))
                - 0.229 * cos(deg2rad * (2 * mj - 4 * ms - 2.0))
                + 0.119 * sin(deg2rad * (mj - 2 * ms - 3.0))
                + 0.046 * sin(deg2rad * (2 * mj - 6 * ms - 69.0))
                + 0.014 * sin(deg2rad * (mj - 3 * ms + 32.0)))
            latOut += (-0.020 * cos(deg2rad * (2 * mj - 4 * ms - 2.0))
                + 0.018 * sin(deg2rad * (2 * mj - 6 * ms - 49.0)))
        case .uranus:
            lonOut += (0.040 * sin(deg2rad * (ms - 2 * mu + 6.0))
                + 0.035 * sin(deg2rad * (ms - 3 * mu + 33.0))
                - 0.015 * sin(deg2rad * (mj - mu + 20.0)))
        default:
            break
        }
        return (lonOut, latOut)
    }
}

enum PlanetMath {
    /// The seven planets shown in the UI (Earth excluded).
    static var displayPlanets: [Planet] {
        Planet.allCases.filter { $0.isDisplayable }
    }

    private static func elements(for planet: Planet) -> PlanetElements {
        switch planet {
        case .mercury:
            return PlanetElements(n0: 48.3313, nDot: 3.24587e-5,
                                  i0: 7.0047, iDot: 5.00e-8,
                                  w0: 29.1241, wDot: 1.01444e-5,
                                  a0: 0.387098, aDot: 0.0,
                                  e0: 0.205635, eDot: 5.59e-10,
                                  m0: 168.6562, mDot: 4.0923344368)
        case .venus:
            return PlanetElements(n0: 76.6799, nDot: 2.46590e-5,
                                  i0: 3.3946, iDot: 2.75e-8,
                                  w0: 54.8910, wDot: 1.38374e-5,
                                  a0: 0.723330, aDot: 0.0,
                                  e0: 0.006773, eDot: -1.302e-9,
                                  m0: 48.0052, mDot: 1.6021302244)
        case .earth:
            // Earth's orbital elements; section 5 treats these as the
            // Sun's apparent position.
            return PlanetElements(n0: 0.0, nDot: 0.0,
                                  i0: 0.0, iDot: 0.0,
                                  w0: 282.9404, wDot: 4.70935e-5,
                                  a0: 1.000000, aDot: 0.0,
                                  e0: 0.016709, eDot: -1.151e-9,
                                  m0: 356.0470, mDot: 0.9856002585)
        case .mars:
            return PlanetElements(n0: 49.5574, nDot: 2.11081e-5,
                                  i0: 1.8497, iDot: -1.78e-8,
                                  w0: 286.5016, wDot: 2.92961e-5,
                                  a0: 1.523688, aDot: 0.0,
                                  e0: 0.093405, eDot: 2.516e-9,
                                  m0: 18.6021, mDot: 0.5240207766)
        case .jupiter:
            return PlanetElements(n0: 100.4542, nDot: 2.76854e-5,
                                  i0: 1.3030, iDot: -1.557e-7,
                                  w0: 273.8777, wDot: 1.64505e-5,
                                  a0: 5.20256, aDot: 0.0,
                                  e0: 0.048498, eDot: 4.469e-9,
                                  m0: 19.8950, mDot: 0.0830853001)
        case .saturn:
            return PlanetElements(n0: 113.6634, nDot: 2.38980e-5,
                                  i0: 2.4886, iDot: -1.081e-7,
                                  w0: 339.3939, wDot: 2.97661e-5,
                                  a0: 9.55475, aDot: 0.0,
                                  e0: 0.055546, eDot: -9.499e-9,
                                  m0: 316.9670, mDot: 0.0334442282)
        case .uranus:
            return PlanetElements(n0: 74.0005, nDot: 1.3978e-5,
                                  i0: 0.7733, iDot: 1.9e-8,
                                  w0: 96.6612, wDot: 3.0565e-5,
                                  a0: 19.18171, aDot: -1.55e-8,
                                  e0: 0.047318, eDot: 7.45e-9,
                                  m0: 142.5905, mDot: 0.011725806)
        case .neptune:
            return PlanetElements(n0: 131.7806, nDot: 3.0173e-5,
                                  i0: 1.7700, iDot: -2.55e-7,
                                  w0: 272.8461, wDot: -6.027e-6,
                                  a0: 30.05826, aDot: 3.313e-8,
                                  e0: 0.008606, eDot: 2.15e-9,
                                  m0: 260.2471, mDot: 0.005995147)
        }
    }

    private static func julianDate(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86400.0 + 2440587.5
    }

    /// Geocentric RA/Dec (degrees) for `planet` at `date`, sections
    /// 6-7 and 10-12. Positions are for the equinox of the day — no
    /// precession correction, which is exactly what rise/set and the
    /// chart need.
    ///
    /// For `.earth` this returns the Sun's geocentric RA/Dec (the same
    /// math, via Earth's orbital elements); the UI never asks for it.
    static func position(of planet: Planet, at date: Date) -> PlanetPosition {
        let d = julianDate(date) - 2451543.5
        let ecl = (23.4393 - 3.563e-7 * d) * Schlyter.deg2rad
        // Sun's geocentric ecliptic position (Earth's orbit elements).
        let sun = Schlyter.helio(elements(for: .earth), d: d)
        let rs = sun.3
        let lonsun = sun.4 * Schlyter.deg2rad
        let xs = rs * cos(lonsun)
        let ys = rs * sin(lonsun)
        let xg: Double
        let yg: Double
        let zg: Double
        if planet == .earth {
            xg = xs
            yg = ys
            zg = 0.0
        } else {
            let el = elements(for: planet)
            let h = Schlyter.helio(el, d: d)
            let mj = Schlyter.helio(elements(for: .jupiter), d: d).6
            let ms = Schlyter.helio(elements(for: .saturn), d: d).6
            let mu = Schlyter.helio(elements(for: .uranus), d: d).6
            let pl = Schlyter.perturb(body: planet, lon: h.4, lat: h.5,
                                      mj: mj, ms: ms, mu: mu)
            let lonR = pl.0 * Schlyter.deg2rad
            let latR = pl.1 * Schlyter.deg2rad
            let xh = h.3 * cos(lonR) * cos(latR)
            let yh = h.3 * sin(lonR) * cos(latR)
            let zh = h.3 * sin(latR)
            xg = xh + xs
            yg = yh + ys
            zg = zh
        }
        // Section 12: ecliptic -> equatorial.
        let xe = xg
        let ye = yg * cos(ecl) - zg * sin(ecl)
        let ze = yg * sin(ecl) + zg * cos(ecl)
        let ra = Schlyter.norm360(atan2(ye, xe) / Schlyter.deg2rad)
        let dec = atan2(ze, hypot(xe, ye)) / Schlyter.deg2rad
        return PlanetPosition(ra: ra, dec: dec)
    }

    // MARK: - Rise/set

    /// Altitude of a geocentric RA/Dec, degrees. Kept local so this
    /// file stays Foundation-only.
    private static func altitude(ra: Double, dec: Double,
                                 julianDate jd: Double,
                                 lat: Double, lon: Double) -> Double {
        let gmst = PlanetMath.gmstDegrees(julianDate: jd)
        let lst = (gmst + lon).truncatingRemainder(dividingBy: 360.0)
        let h = (lst - ra).truncatingRemainder(dividingBy: 360.0)
            * Schlyter.deg2rad
        let decR = dec * Schlyter.deg2rad
        let latR = lat * Schlyter.deg2rad
        let sinAlt = sin(decR) * sin(latR)
            + cos(decR) * cos(latR) * cos(h)
        return asin(min(1.0, max(-1.0, sinAlt))) / Schlyter.deg2rad
    }

    private static func gmstDegrees(julianDate jd: Double) -> Double {
        let t = (jd - 2451545.0) / 36525.0
        let g = 280.46061837
            + 360.98564736629 * (jd - 2451545.0)
            + 0.000387933 * t * t
            - t * t * t / 38710000.0
        var v = g.truncatingRemainder(dividingBy: 360.0)
        if v < 0 { v += 360.0 }
        return v
    }

    /// Rise/set nearest `date`, found by scanning altitude every 10 min
    /// over -12 h..+24 h with linear interpolation of the horizon
    /// crossings (same pattern as AstroMath.moonRiseSet). Either may be
    /// nil when there is no crossing in the window; when both are nil
    /// the planet is up (or down) all night — check the altitude.
    /// Times are good to a few minutes given the ~1' position model.
    static func riseSet(of planet: Planet, at date: Date,
                        lat: Double, lon: Double)
        -> (rise: Date?, set: Date?)
    {
        let step: TimeInterval = 600
        let t0 = date.addingTimeInterval(-12 * 3600)
        let t1 = date.addingTimeInterval(24 * 3600)
        let nSteps = Int(t1.timeIntervalSince(t0) / step) + 1
        var crossings = [(date: Date, rising: Bool)]()
        var prevAlt: Double? = nil
        for i in 0..<nSteps {
            let t = t0.addingTimeInterval(Double(i) * step)
            let jd = julianDate(t)
            let pos = position(of: planet, at: t)
            let alt = altitude(ra: pos.ra, dec: pos.dec,
                               julianDate: jd, lat: lat, lon: lon)
            if let pa = prevAlt {
                let pt = t.addingTimeInterval(-step)
                if pa <= 0, alt > 0 {
                    let f = (0 - pa) / (alt - pa)
                    crossings.append(
                        (pt.addingTimeInterval(f * step), true))
                } else if pa >= 0, alt < 0 {
                    let f = (0 - pa) / (alt - pa)
                    crossings.append(
                        (pt.addingTimeInterval(f * step), false))
                }
            }
            prevAlt = alt
        }
        let rise = crossings.filter { $0.rising }
            .min(by: { abs($0.date.timeIntervalSince(date))
                < abs($1.date.timeIntervalSince(date)) })?.date
        let set = crossings.filter { !$0.rising }
            .min(by: { abs($0.date.timeIntervalSince(date))
                < abs($1.date.timeIntervalSince(date)) })?.date
        return (rise, set)
    }
}
