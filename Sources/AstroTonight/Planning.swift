import Foundation

/// Week-ahead planning and AstroCapture export.
enum Planning {
    // MARK: - Best night this week

    struct NightScore: Hashable {
        /// Local noon-anchored date for the night.
        let date: Date
        let peakAlt: Double
        let peakTime: Date
        let moonIllumination: Double
        let moonSeparation: Double

        var moonOK: Bool {
            moonIllumination < 0.5 || moonSeparation > 40
        }
    }

    /// For each of the next 7 nights (tonight + 6), the target's peak
    /// altitude in a 24 h window around that night, plus the Moon at peak.
    /// 7 × 145 altitude evaluations — effectively instant.
    static func weekScores(object: CatalogObject,
                           lat: Double, lon: Double,
                           now: Date) -> [NightScore]
    {
        let step: TimeInterval = 600
        let nSteps = 145
        return (0..<7).map { day in
            let anchor = now.addingTimeInterval(Double(day) * 86400)
            let t0 = anchor.addingTimeInterval(-12 * 3600)
            var peakAlt = -90.0
            var peakTime = anchor
            for i in 0..<nSteps {
                let t = t0.addingTimeInterval(Double(i) * step)
                let alt = AstroMath.altAz(
                    ra: object.ra, dec: object.dec,
                    julianDate: AstroMath.julianDate(t),
                    lat: lat, lon: lon).alt
                if alt > peakAlt {
                    peakAlt = alt
                    peakTime = t
                }
            }
            let jd = AstroMath.julianDate(peakTime)
            let moon = AstroMath.moonPosition(julianDate: jd)
            let illum = AstroMath.moonIllumination(julianDate: jd).fraction
            let sep = AstroMath.angularSeparation(
                ra1: moon.ra, dec1: moon.dec, ra2: object.ra, dec2: object.dec)
            // Day label anchored at local noon so the date is unambiguous.
            let noon = Calendar.current.startOfDay(for: anchor)
                .addingTimeInterval(12 * 3600)
            return NightScore(date: noon,
                              peakAlt: (peakAlt * 10).rounded() / 10,
                              peakTime: peakTime,
                              moonIllumination: illum,
                              moonSeparation: sep)
        }
    }

    /// The week's best night: moon-clear first, then highest peak.
    static func bestNight(_ scores: [NightScore]) -> NightScore? {
        scores.sorted {
            if $0.moonOK != $1.moonOK { return $0.moonOK && !$1.moonOK }
            return $0.peakAlt > $1.peakAlt
        }.first
    }

    // MARK: - AstroCapture export

    /// The given targets as a `targets:` block for an AstroCapture plan
    /// YAML (e.g. `examples/night_queue.yaml`). Names resolve through the
    /// night-sky catalogue, so no coordinates are needed; priority carries
    /// the app's ranking (top pick first).
    static func schedulerYAML(targets: [RankedTarget],
                              lat: Double, lon: Double,
                              minAlt: Double,
                              date: Date) -> String
    {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate]
        var lines = [
            "# AstroTonight export — paste under `targets:` in your plan YAML",
            "# Site: \(String(format: "%.4f", lat)), \(String(format: "%.4f", lon))" +
                " · ranked \(iso.string(from: date))",
        ]
        for (i, t) in targets.enumerated() {
            let priority: Double = i == 0 ? 3.0 : (i == 1 ? 2.0 : 1.0)
            let name = t.object.name
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            lines.append(
                "- name: \"\(name)\"  # peak \(Fmt.deg(t.peakAlt))" +
                " · \(Fmt.hours(t.hoursAbove)) above \(Fmt.deg(minAlt))")
            lines.append("  priority: \(String(format: "%.1f", priority))")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
