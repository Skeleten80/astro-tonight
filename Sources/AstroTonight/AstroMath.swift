import Foundation

/// Spherical astronomy for AstroTonight: sidereal time, RA/Dec -> alt/az,
/// and a low-precision lunar position + illumination model.
///
/// All angles are decimal degrees unless noted. RA/Dec are treated as J2000
/// mean coordinates (the catalog's frame); precession/nutation to the
/// current epoch are deliberately skipped — the residual is ~+/-0.5 deg,
/// which cannot change a ranking and is removed by plate solving at the
/// scope anyway.
///
/// The algorithms here were prototyped in Python and cross-checked against
/// astropy: altitude within 0.16 deg, azimuth within ~1.4 deg worst case
/// (near the zenith, where azimuth is ill-conditioned), lunar position
/// within ~0.8 deg.
enum AstroMath {
    static let deg2rad = Double.pi / 180.0
    static let rad2deg = 180.0 / Double.pi

    // MARK: - Time

    /// Julian date for a `Date`.
    static func julianDate(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86400.0 + 2440587.5
    }

    /// Greenwich mean sidereal time, degrees in [0, 360).
    static func gmstDegrees(julianDate jd: Double) -> Double {
        let t = (jd - 2451545.0) / 36525.0
        let g = 280.46061837
            + 360.98564736629 * (jd - 2451545.0)
            + 0.000387933 * t * t
            - t * t * t / 38710000.0
        return g.truncatingRemainder(dividingBy: 360.0)
            .remainderNormalized()
    }

    /// Local mean sidereal time, degrees in [0, 360).
    /// - Parameter lon: observer longitude, east-positive (west is negative).
    static func lstDegrees(julianDate jd: Double, lon: Double) -> Double {
        (gmstDegrees(julianDate: jd) + lon)
            .truncatingRemainder(dividingBy: 360.0)
            .remainderNormalized()
    }

    // MARK: - Alt/az

    /// Altitude and azimuth (eastward from north) for J2000 RA/Dec.
    static func altAz(ra: Double, dec: Double, julianDate jd: Double,
                      lat: Double, lon: Double) -> (alt: Double, az: Double) {
        let h = norm180(lstDegrees(julianDate: jd, lon: lon) - ra) * deg2rad
        let decR = dec * deg2rad
        let latR = lat * deg2rad
        let sinAlt = sin(decR) * sin(latR)
            + cos(decR) * cos(latR) * cos(h)
        let alt = asin(min(1.0, max(-1.0, sinAlt))) * rad2deg
        // Azimuth measured eastward from north.
        let y = sin(h)
        let x = cos(h) * sin(latR) - tan(decR) * cos(latR)
        let az = (atan2(y, x) * rad2deg + 180.0)
            .truncatingRemainder(dividingBy: 360.0)
            .remainderNormalized()
        return (alt, az)
    }

    /// Great-circle separation between two RA/Dec points, degrees.
    static func angularSeparation(ra1: Double, dec1: Double,
                                  ra2: Double, dec2: Double) -> Double {
        let r1 = ra1 * deg2rad, d1 = dec1 * deg2rad
        let r2 = ra2 * deg2rad, d2 = dec2 * deg2rad
        let c = sin(d1) * sin(d2) + cos(d1) * cos(d2) * cos(r1 - r2)
        return acos(min(1.0, max(-1.0, c))) * rad2deg
    }

    // MARK: - Moon (low precision, ~+/-1 deg)
    /// Geocentric lunar RA/Dec plus ecliptic lon/lat, degrees.
    /// Truncated Meeus/Schlyter series — good to about a degree.
    static func moonPosition(julianDate jd: Double)
        -> (ra: Double, dec: Double, eclLon: Double, eclLat: Double)
    {
        let d = jd - 2451543.5
        let n = (125.1228 - 0.0529538083 * d) * deg2rad
        let i = 5.1454 * deg2rad
        let w = (318.0634 + 0.1643573223 * d) * deg2rad
        let a = 60.2666            // Earth radii
        let e = 0.054900
        let m = (115.3654 + 13.0649929509 * d) * deg2rad

        var E = m + e * sin(m) * (1.0 + e * cos(m))
        for _ in 0..<2 {
            E -= (E - e * sin(E) - m) / (1.0 - e * cos(E))
        }
        let xv = a * (cos(E) - e)
        let yv = a * (sqrt(1.0 - e * e) * sin(E))
        let v = atan2(yv, xv)
        let r = hypot(xv, yv)

        let xh = r * (cos(n) * cos(v + w) - sin(n) * sin(v + w) * cos(i))
        let yh = r * (sin(n) * cos(v + w) + cos(n) * sin(v + w) * cos(i))
        let zh = r * (sin(v + w) * sin(i))
        let lon = atan2(yh, xh)
        let lat = atan2(zh, hypot(xh, yh))

        let oblecl = (23.4393 - 3.563e-7 * d) * deg2rad
        let x = r * cos(lon) * cos(lat)
        let y = r * (sin(lon) * cos(lat) * cos(oblecl)
                     - sin(lat) * sin(oblecl))
        let z = r * (sin(lon) * cos(lat) * sin(oblecl)
                     + sin(lat) * cos(oblecl))
        let ra = (atan2(y, x) * rad2deg)
            .truncatingRemainder(dividingBy: 360.0)
            .remainderNormalized()
        let dec = atan2(z, hypot(x, y)) * rad2deg
        return (ra, dec, lon * rad2deg, lat * rad2deg)
    }

    /// Geocentric ecliptic longitude of the Sun, degrees (low precision).
    static func sunEclipticLongitude(julianDate jd: Double) -> Double {
        let d = jd - 2451543.5
        let w = (282.9404 + 4.70935e-5 * d) * deg2rad
        let e = 0.016709 - 1.151e-9 * d
        let m = (356.0470 + 0.9856002585 * d) * deg2rad
        var E = m + e * sin(m) * (1.0 + e * cos(m))
        for _ in 0..<2 {
            E -= (E - e * sin(E) - m) / (1.0 - e * cos(E))
        }
        let xv = cos(E) - e
        let yv = sqrt(1.0 - e * e) * sin(E)
        let v = atan2(yv, xv) * rad2deg
        return (v + w * rad2deg)
            .truncatingRemainder(dividingBy: 360.0)
            .remainderNormalized()
    }

    /// Illuminated fraction of the lunar disk (0...1) and waxing/waning.
    static func moonIllumination(julianDate jd: Double)
        -> (fraction: Double, waxing: Bool)
    {
        let moon = moonPosition(julianDate: jd)
        let sunLon = sunEclipticLongitude(julianDate: jd)
        let elong = angularSeparation(ra1: sunLon, dec1: 0.0,
                                      ra2: moon.eclLon, dec2: moon.eclLat)
        let fraction = (1.0 - cos(elong * deg2rad)) / 2.0
        let waxing = norm180(moon.eclLon - sunLon) > 0
        return (fraction, waxing)
    }

    /// Plain-language moon phase from illumination fraction + waxing flag.
    /// Boundaries (approximate, documented): <0.03 new, >0.97 full,
    /// within ±0.07 of half-lit the quarters, otherwise crescent below
    /// half and gibbous above.
    static func moonPhaseName(illumination: Double, waxing: Bool) -> String {
        if illumination < 0.03 { return "New Moon" }
        if illumination > 0.97 { return "Full Moon" }
        if abs(illumination - 0.5) < 0.07 {
            return waxing ? "First Quarter" : "Last Quarter"
        }
        if illumination < 0.5 {
            return waxing ? "Waxing Crescent" : "Waning Crescent"
        }
        return waxing ? "Waxing Gibbous" : "Waning Gibbous"
    }

    /// Moonrise/moonset: the upward/downward horizon crossings of the
    /// Moon nearest to `now`, found by scanning lunar altitude every
    /// 10 min over the same −12 h..+24 h window as the dark scan, with
    /// linear interpolation of the crossings (mirrors `darkHours`).
    /// Either may be nil when there is no crossing in the window; when
    /// BOTH are nil the Moon is up (or down) all night — check the
    /// altitude at `now` to tell which. Uses the low-precision moon
    /// model (±1°), so times are good to ~±10 min.
    static func moonRiseSet(lat: Double, lon: Double, now: Date)
        -> (rise: Date?, set: Date?)
    {
        let step: TimeInterval = 600
        let t0 = now.addingTimeInterval(-12 * 3600)
        let t1 = now.addingTimeInterval(24 * 3600)
        let nSteps = Int(t1.timeIntervalSince(t0) / step) + 1
        var crossings = [(date: Date, rising: Bool)]()
        var prevAlt: Double? = nil
        for i in 0..<nSteps {
            let t = t0.addingTimeInterval(Double(i) * step)
            let jd = julianDate(t)
            let mp = moonPosition(julianDate: jd)
            let alt = altAz(ra: mp.ra, dec: mp.dec, julianDate: jd,
                            lat: lat, lon: lon).alt
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
            .min(by: { abs($0.date.timeIntervalSince(now))
                < abs($1.date.timeIntervalSince(now)) })?.date
        let set = crossings.filter { !$0.rising }
            .min(by: { abs($0.date.timeIntervalSince(now))
                < abs($1.date.timeIntervalSince(now)) })?.date
        return (rise, set)
    }

    /// Lunar altitude at a moment, degrees. Convenience for "up all
    /// night / down all night" checks.
    static func moonAltitude(julianDate jd: Double,
                             lat: Double, lon: Double) -> Double
    {
        let mp = moonPosition(julianDate: jd)
        return altAz(ra: mp.ra, dec: mp.dec, julianDate: jd,
                     lat: lat, lon: lon).alt
    }

    /// Airmass via the simple sec(z) approximation (z = zenith angle).
    /// Honest limits: sec(z) diverges at the horizon while the true
    /// airmass caps near ~38, so this is only meaningful above ~10°;
    /// nil at or below the horizon.
    static func airmass(altitude: Double) -> Double? {
        guard altitude > 0 else { return nil }
        return 1.0 / cos((90.0 - altitude) * deg2rad)
    }

    // MARK: - Sun & darkness

    /// Sun's geocentric RA/Dec (degrees), low precision.
    static func sunRaDec(julianDate jd: Double) -> (ra: Double, dec: Double) {
        let lon = sunEclipticLongitude(julianDate: jd) * deg2rad
        let d = jd - 2451543.5
        let oblecl = (23.4393 - 3.563e-7 * d) * deg2rad
        // The Sun's ecliptic latitude is ~0.
        let ra = atan2(sin(lon) * cos(oblecl), cos(lon)) * rad2deg
        let dec = asin(min(1.0, max(-1.0, sin(lon) * sin(oblecl)))) * rad2deg
        return (ra.truncatingRemainder(dividingBy: 360.0).remainderNormalized(),
                dec)
    }

    /// Astronomical dark window (Sun below -18°). Scanned from 12 h ago
    /// to 24 h ahead so "tonight's" dark is always found, with linear
    /// interpolation of the crossings. Either end may be nil.
    static func darkHours(lat: Double, lon: Double, now: Date)
        -> (start: Date?, end: Date?)
    {
        let step: TimeInterval = 600
        let t0 = now.addingTimeInterval(-12 * 3600)
        let t1 = now.addingTimeInterval(24 * 3600)
        let nSteps = Int(t1.timeIntervalSince(t0) / step) + 1
        var start: Date? = nil
        var end: Date? = nil
        var prevAlt: Double? = nil
        for i in 0..<nSteps {
            let t = t0.addingTimeInterval(Double(i) * step)
            let jd = julianDate(t)
            let sun = sunRaDec(julianDate: jd)
            let alt = altAz(ra: sun.ra, dec: sun.dec, julianDate: jd,
                            lat: lat, lon: lon).alt
            if let pa = prevAlt {
                let pt = t.addingTimeInterval(-step)
                if start == nil, pa > -18, alt <= -18 {
                    let f = (pa + 18) / (pa - alt)
                    start = pt.addingTimeInterval(f * step)
                } else if start != nil, end == nil, pa < -18, alt >= -18 {
                    let f = (-18 - pa) / (alt - pa)
                    end = pt.addingTimeInterval(f * step)
                }
            }
            prevAlt = alt
        }
        return (start, end)
    }

    // MARK: - Alt-az field rotation

    /// Field rotation rate in degrees per hour for an alt-az mount at the
    /// given position. Standard approximation:
    /// ω = 15.041°/h · cos(az) · cos(lat) / cos(alt).
    /// It blows up near the zenith — which is exactly when it matters.
    static func fieldRotationRateDegPerHour(alt: Double, az: Double,
                                            lat: Double) -> Double {
        let cosAlt = cos(alt * deg2rad)
        guard abs(cosAlt) > 1e-6 else { return .infinity }
        return 15.0410686 * cos(az * deg2rad) * cos(lat * deg2rad) / cosAlt
    }

    // MARK: - Helpers

    /// Normalize to (-180, 180].
    static func norm180(_ x: Double) -> Double {
        var v = x.truncatingRemainder(dividingBy: 360.0)
        if v <= -180.0 { v += 360.0 } else if v > 180.0 { v -= 360.0 }
        return v
    }

    /// RA in degrees -> "13h 29m 53s" (hand-controller friendly).
    static func raToHMS(_ raDeg: Double) -> String {
        let hours = raDeg / 15.0
        let h = Int(hours)
        let m = Int((hours - Double(h)) * 60.0)
        let s = (hours - Double(h) - Double(m) / 60.0) * 3600.0
        return String(format: "%dh %02dm %04.1fs", h, m, s)
    }

    /// Dec in degrees -> "+47° 11' 43\"".
    static func decToDMS(_ decDeg: Double) -> String {
        let sign = decDeg < 0 ? "-" : "+"
        let a = abs(decDeg)
        let d = Int(a)
        let m = Int((a - Double(d)) * 60.0)
        let s = (a - Double(d) - Double(m) / 60.0) * 3600.0
        return String(format: "%@%d° %02d' %04.1f\"", sign, d, m, s)
    }
}

private extension Double {
    /// Normalize to [0, 360).
    func remainderNormalized() -> Double {
        var v = self.truncatingRemainder(dividingBy: 360.0)
        if v < 0 { v += 360.0 }
        return v
    }
}
