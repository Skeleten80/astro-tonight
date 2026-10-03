import Foundation

/// Swift port of `astrocapture.catalog.tonight_best`.
///
/// For every catalog object the peak altitude and the hours spent above
/// `minAlt` are computed over a 24 h window centred on `now`, in 10-minute
/// steps. Objects are ranked by peak altitude first, then by time above the
/// threshold — exactly the CLI's ordering, so the app and
/// `astrocapture tonight` always agree.
enum Ranker {
    static let stepMinutes = 10.0
    static let windowHours = 24.0

    struct Result {
        let targets: [RankedTarget]
        let moon: MoonInfo
        let windowStart: Date
        let step: TimeInterval
        let rankedAt: Date
        let darkStart: Date?
        let darkEnd: Date?
    }

    static func rank(catalog: [CatalogObject],
                     lat: Double, lon: Double,
                     now: Date,
                     minAlt: Double,
                     limit: Int) -> Result {
        let step: TimeInterval = stepMinutes * 60.0
        let half = windowHours * 3600.0 / 2.0
        let windowStart = now.addingTimeInterval(-half)
        let nSteps = Int(windowHours * 3600.0 / step) + 1

        var times = [Date]()
        times.reserveCapacity(nSteps)
        var jds = [Double]()
        jds.reserveCapacity(nSteps)
        var dark = [Bool]()
        dark.reserveCapacity(nSteps)
        for i in 0..<nSteps {
            let t = windowStart.addingTimeInterval(Double(i) * step)
            times.append(t)
            let jd = AstroMath.julianDate(t)
            jds.append(jd)
            let sun = AstroMath.sunRaDec(julianDate: jd)
            let sunAlt = AstroMath.altAz(ra: sun.ra, dec: sun.dec,
                                         julianDate: jd,
                                         lat: lat, lon: lon).alt
            dark.append(sunAlt <= -18.0)
        }
        let (darkStart, darkEnd) = AstroMath.darkHours(lat: lat, lon: lon,
                                                       now: now)

        let moonJD = AstroMath.julianDate(now)
        let moonPos = AstroMath.moonPosition(julianDate: moonJD)
        let moonIllum = AstroMath.moonIllumination(julianDate: moonJD)
        let moon = MoonInfo(ra: moonPos.ra, dec: moonPos.dec,
                            illumination: moonIllum.fraction,
                            waxing: moonIllum.waxing)

        var ranked = [RankedTarget]()
        ranked.reserveCapacity(catalog.count)

        for obj in catalog {
            var peakAlt = -90.0
            var peakIdx = 0
            var aboveCount = 0
            var darkAboveCount = 0
            var firstAbove: Int? = nil
            var lastAbove: Int? = nil
            var profile = [Double]()
            profile.reserveCapacity(nSteps)

            for i in 0..<nSteps {
                let alt = AstroMath.altAz(ra: obj.ra, dec: obj.dec,
                                          julianDate: jds[i],
                                          lat: lat, lon: lon).alt
                profile.append(alt)
                if alt > peakAlt {
                    peakAlt = alt
                    peakIdx = i
                }
                if alt >= minAlt {
                    aboveCount += 1
                    if dark[i] { darkAboveCount += 1 }
                    if firstAbove == nil { firstAbove = i }
                    lastAbove = i
                }
            }

            guard peakAlt >= minAlt else { continue }

            // Round before ranking, exactly like the CLI, so the returned
            // order matches the displayed numbers.
            let score = (peakAlt * 100).rounded() / 100
            let hours = (Double(aboveCount) * stepMinutes / 60.0 * 100)
                .rounded() / 100
            let darkHours = (Double(darkAboveCount) * stepMinutes / 60.0 * 100)
                .rounded() / 100
            let moonSep = AstroMath.angularSeparation(
                ra1: moon.ra, dec1: moon.dec, ra2: obj.ra, dec2: obj.dec)

            ranked.append(RankedTarget(
                object: obj,
                peakAlt: score,
                peakTime: times[peakIdx],
                hoursAbove: hours,
                rise: firstAbove.map { times[$0] },
                set: lastAbove.map { times[$0] },
                moonSep: moonSep,
                profile: profile,
                darkHoursAbove: darkHours,
                moonIllumination: moonIllum.fraction))
        }

        ranked.sort {
            if $0.peakAlt != $1.peakAlt { return $0.peakAlt > $1.peakAlt }
            return $0.hoursAbove > $1.hoursAbove
        }

        return Result(targets: Array(ranked.prefix(max(limit, 0))),
                      moon: moon,
                      windowStart: windowStart,
                      step: step,
                      rankedAt: now,
                      darkStart: darkStart,
                      darkEnd: darkEnd)
    }
}
