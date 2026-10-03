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
        let header = [
            "# AstroTonight export — paste under `targets:` in your plan YAML",
            "# Site: \(siteComment(lat: lat, lon: lon))" +
                " · ranked \(dayStamp(date))",
        ]
        return (header + targetLines(targets: targets, minAlt: minAlt))
            .joined(separator: "\n") + "\n"
    }

    /// The user's whole starred observing list as ONE multi-target
    /// `targets:` block, in the app's current rank order. Paste under
    /// `targets:` in an AstroCapture night plan YAML (e.g.
    /// `examples/night_queue.yaml`); names resolve through the catalogue,
    /// so no coordinates are needed.
    static func nightPlanYAML(savedIDs: Set<String>,
                              ranked: [RankedTarget],
                              lat: Double, lon: Double,
                              minAlt: Double,
                              date: Date) -> String
    {
        let list = ranked.filter { savedIDs.contains($0.id) }
        let header = [
            "# AstroTonight observing-list export — paste under `targets:` in your plan YAML",
            "# Site: \(siteComment(lat: lat, lon: lon))" +
                " · \(list.count) starred, rank order, \(dayStamp(date))",
        ]
        return (header + targetLines(targets: list, minAlt: minAlt))
            .joined(separator: "\n") + "\n"
    }

    // MARK: - Imaging window

    /// The best contiguous stretch where the target is above `minAlt`
    /// AND the Sun is below −18° (astronomical dark).
    struct ImagingWindow: Hashable {
        let start: Date
        let end: Date
        var durationHours: Double { end.timeIntervalSince(start) / 3600 }
    }

    /// Samples target + Sun altitude every 10 min over the same
    /// −12 h..+24 h window the dark scan uses, keeps the samples that are
    /// both above `minAlt` and in astronomical darkness, then picks the
    /// best contiguous run: the longest run overlapping the next 12 h if
    /// any, otherwise the longest run overall. Nil when the target gets no
    /// dark-sky time above the minimum.
    static func imagingWindow(object: CatalogObject,
                              lat: Double, lon: Double,
                              minAlt: Double,
                              now: Date) -> ImagingWindow?
    {
        let step: TimeInterval = 600
        let t0 = now.addingTimeInterval(-12 * 3600)
        let t1 = now.addingTimeInterval(24 * 3600)
        let nSteps = Int(t1.timeIntervalSince(t0) / step) + 1

        var runs = [(Int, Int)]()
        var runStart: Int? = nil
        var prev = -1
        for i in 0..<nSteps {
            let t = t0.addingTimeInterval(Double(i) * step)
            let jd = AstroMath.julianDate(t)
            let alt = AstroMath.altAz(ra: object.ra, dec: object.dec,
                                      julianDate: jd,
                                      lat: lat, lon: lon).alt
            let sun = AstroMath.sunRaDec(julianDate: jd)
            let sunAlt = AstroMath.altAz(ra: sun.ra, dec: sun.dec,
                                         julianDate: jd,
                                         lat: lat, lon: lon).alt
            if alt >= minAlt && sunAlt <= -18.0 {
                if runStart == nil { runStart = i }
                prev = i
            } else if let rs = runStart {
                runs.append((rs, prev))
                runStart = nil
            }
        }
        if let rs = runStart { runs.append((rs, prev)) }
        guard !runs.isEmpty else { return nil }

        let horizon = now.addingTimeInterval(12 * 3600)
        let overlapping = runs.filter { r in
            let s = t0.addingTimeInterval(Double(r.0) * step)
            let e = t0.addingTimeInterval(Double(r.1) * step)
            return e >= now && s <= horizon
        }
        let candidates = overlapping.isEmpty ? runs : overlapping
        guard let best = candidates.max(by: { ($0.1 - $0.0) < ($1.1 - $1.0) })
        else { return nil }
        return ImagingWindow(
            start: t0.addingTimeInterval(Double(best.0) * step),
            end: t0.addingTimeInterval(Double(best.1) * step))
    }

    // MARK: - Private helpers

    /// One `- name:` / `priority:` pair per target, top pick first.
    /// Priority tiers mirror the single-target export (3.0 / 2.0 / 1.0).
    private static func targetLines(targets: [RankedTarget],
                                    minAlt: Double) -> [String]
    {
        var lines = [String]()
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
        return lines
    }

    private static func siteComment(lat: Double, lon: Double) -> String {
        "\(String(format: "%.4f", lat)), \(String(format: "%.4f", lon))"
    }

    private static func dayStamp(_ date: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate]
        return iso.string(from: date)
    }
}
