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

    /// The best contiguous stretch where the target is above the minimum
    /// (surveyed horizon at the target's azimuth when one exists, else the
    /// flat `minAlt`) AND the Sun is below −18° (astronomical dark).
    struct ImagingWindow: Hashable {
        let start: Date
        let end: Date
        var durationHours: Double { end.timeIntervalSince(start) / 3600 }
    }

    /// Samples target + Sun altitude every 10 min over the same
    /// −12 h..+24 h window the dark scan uses, keeps the samples that are
    /// both above the minimum and in astronomical darkness, then picks the
    /// best contiguous run: the longest run overlapping the next 12 h if
    /// any, otherwise the longest run overall. Nil when the target gets no
    /// dark-sky time above the minimum.
    static func imagingWindow(object: CatalogObject,
                              lat: Double, lon: Double,
                              minAlt: Double,
                              now: Date,
                              horizon: HorizonProfile = .init()) -> ImagingWindow?
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
            let aa = AstroMath.altAz(ra: object.ra, dec: object.dec,
                                     julianDate: jd,
                                     lat: lat, lon: lon)
            let threshold = horizon.minAlt(forAzimuth: aa.az) ?? minAlt
            let sun = AstroMath.sunRaDec(julianDate: jd)
            let sunAlt = AstroMath.altAz(ra: sun.ra, dec: sun.dec,
                                         julianDate: jd,
                                         lat: lat, lon: lon).alt
            if aa.alt >= threshold && sunAlt <= -18.0 {
                if runStart == nil { runStart = i }
                prev = i
            } else if let rs = runStart {
                runs.append((rs, prev))
                runStart = nil
            }
        }
        if let rs = runStart { runs.append((rs, prev)) }
        guard !runs.isEmpty else { return nil }

        let horizon12 = now.addingTimeInterval(12 * 3600)
        let overlapping = runs.filter { r in
            let s = t0.addingTimeInterval(Double(r.0) * step)
            let e = t0.addingTimeInterval(Double(r.1) * step)
            return e >= now && s <= horizon12
        }
        let candidates = overlapping.isEmpty ? runs : overlapping
        guard let best = candidates.max(by: { ($0.1 - $0.0) < ($1.1 - $1.0) })
        else { return nil }
        return ImagingWindow(
            start: t0.addingTimeInterval(Double(best.0) * step),
            end: t0.addingTimeInterval(Double(best.1) * step))
    }

    // MARK: - Top pick ("image this now")

    /// The heuristic answer to "what should I image right now".
    ///
    /// Score (higher is better) — deliberately simple and documented:
    ///   base  = 100 − rank index              (the app's own ranking)
    ///   + 50  if the imaging window is open right now
    ///   + 25  if a window opens within the next 2 h
    ///   − cloud cover % at the current hour   (forecast; no penalty if nil)
    ///   − 30  if the Moon is a glare risk for this target
    ///   − 5 × (seeing − 3), floored at 0      (7Timer forecast; no penalty
    ///                                          if nil — deliberately small
    ///                                          so seeing can't dominate
    ///                                          rank/window)
    /// Targets with no imaging window tonight are skipped entirely.
    /// This is a heuristic, not a measurement — the detail view carries
    /// the real numbers behind it.
    struct TopPick {
        let target: RankedTarget
        let window: ImagingWindow
        let openNow: Bool
        let cloudCover: Double?
        let seeing: Int?
        let score: Double
    }

    static func topPick(ranked: [RankedTarget],
                        lat: Double, lon: Double,
                        horizon: HorizonProfile,
                        minAlt: Double,
                        now: Date,
                        cloud: [WeatherService.HourSample]?,
                        seeing: [WeatherService.SeeingSample]? = nil) -> TopPick?
    {
        var best: TopPick? = nil
        for (index, target) in ranked.enumerated() {
            guard let window = imagingWindow(
                object: target.object, lat: lat, lon: lon,
                minAlt: minAlt, now: now, horizon: horizon)
            else { continue }
            let openNow = now >= window.start && now <= window.end
            let opensSoon = !openNow && window.start > now &&
                window.start.timeIntervalSince(now) <= 2 * 3600
            let cover = cloud.flatMap { cloudCover(at: now, in: $0) }
            let see = seeing.flatMap { seeing(at: now, in: $0)?.seeing }
            var score = 100.0 - Double(index)
            if openNow { score += 50 }
            else if opensSoon { score += 25 }
            if let c = cover { score -= c }
            if !target.moonOK { score -= 30 }
            if let s = see { score -= max(0, 5.0 * (Double(s) - 3.0)) }
            let pick = TopPick(target: target, window: window,
                               openNow: openNow, cloudCover: cover,
                               seeing: see, score: score)
            if best == nil || pick.score > best!.score { best = pick }
        }
        return best
    }

    /// Soonest imaging window starting after `now` — for the "nothing
    /// imageable right now" empty state.
    static func nextUpcomingWindow(ranked: [RankedTarget],
                                   lat: Double, lon: Double,
                                   horizon: HorizonProfile,
                                   minAlt: Double,
                                   now: Date)
        -> (target: RankedTarget, window: ImagingWindow)?
    {
        var best: (RankedTarget, ImagingWindow)? = nil
        for target in ranked {
            guard let window = imagingWindow(
                object: target.object, lat: lat, lon: lon,
                minAlt: minAlt, now: now, horizon: horizon),
                window.start > now
            else { continue }
            if best == nil || window.start < best!.1.start {
                best = (target, window)
            }
        }
        return best
    }

    /// Cloud cover % at the hour containing `date`, from cached forecast
    /// samples; nil when no sample is within 90 minutes.
    static func cloudCover(at date: Date,
                           in samples: [WeatherService.HourSample]) -> Double?
    {
        let nearest = samples.min(by: {
            abs($0.date.timeIntervalSince(date))
                < abs($1.date.timeIntervalSince(date))
        })
        guard let n = nearest,
              abs(n.date.timeIntervalSince(date)) <= 5400
        else { return nil }
        return n.cover
    }

    /// The 7Timer sample nearest `date` (3-hour blocks); nil when no
    /// sample is within 90 minutes.
    static func seeing(at date: Date,
                       in samples: [WeatherService.SeeingSample])
        -> WeatherService.SeeingSample?
    {
        let nearest = samples.min(by: {
            abs($0.date.timeIntervalSince(date))
                < abs($1.date.timeIntervalSince(date))
        })
        guard let n = nearest,
              abs(n.date.timeIntervalSince(date)) <= 5400
        else { return nil }
        return n
    }

    // MARK: - Field-ready observing plan (Markdown)

    /// A Markdown observing plan for tonight, ready to copy into notes or
    /// print for the field. Uses the observing list when it's non-empty,
    /// otherwise the top 20 ranked targets — stated in the output.
    static func observingPlanText(
        savedIDs: Set<String>,
        ranked: [RankedTarget],
        lat: Double, lon: Double,
        siteLabel: String,
        minAlt: Double,
        horizon: HorizonProfile,
        darkStart: Date?,
        darkEnd: Date?,
        cloud: [WeatherService.HourSample]?,
        seeing: [WeatherService.SeeingSample]?,
        dewSpread: Double?,
        moonIllumination: Double,
        waxing: Bool,
        rig: RigPreset,
        imagedIDs: Set<String>,
        now: Date) -> String
    {
        let usingList = !savedIDs.isEmpty
        let list = usingList
            ? ranked.filter { savedIDs.contains($0.id) }
            : Array(ranked.prefix(20))
        var lines = [String]()
        lines.append("# Observing plan — \(Fmt.weekday.string(from: now))")
        lines.append("")
        lines.append("Site: \(siteLabel) " +
                     "(\(String(format: "%.4f, %.4f", lat, lon)))")
        if let ds = darkStart, let de = darkEnd {
            lines.append("Dark: \(Fmt.time.string(from: ds)) → " +
                         "\(Fmt.time.string(from: de)) " +
                         "(\(Fmt.dur(de.timeIntervalSince(ds) / 3600)))")
        }
        lines.append("Moon: \(Int(moonIllumination * 100))% " +
                     (waxing ? "waxing" : "waning"))
        lines.append("Horizon: " + (horizon.isEmpty
            ? "flat \(Fmt.deg(minAlt)) minimum"
            : "custom profile (\(horizon.points.count) points)"))
        lines.append("Rig: \(rig.name) — \(rig.specLine)")
        lines.append("Cloud: \(cloudSummary(cloud, now: now))")
        if let s = seeing.flatMap({ seeing(at: now, in: $0) }) {
            lines.append("Seeing: \(s.seeing) " +
                         "(\(WeatherService.seeingLabel(s.seeing))) · " +
                         "transparency \(s.transparency)/8 (7Timer forecast)")
        } else {
            lines.append("Seeing: forecast unavailable")
        }
        if let d = dewSpread {
            lines.append("Dew spread: \(String(format: "%.1f°C", d))" +
                         (d < 1.5 ? " — heater on" : ""))
        } else {
            lines.append("Dew spread: forecast unavailable")
        }
        lines.append("")
        lines.append(usingList
            ? "Targets: observing list (\(list.count))"
            : "Targets: top \(list.count) ranked (observing list empty)")
        for (i, t) in list.enumerated() {
            lines.append("")
            lines.append("## \(i + 1). \(t.object.name) — " +
                         t.object.type.replacingOccurrences(of: "_",
                                                            with: " "))
            if let w = imagingWindow(object: t.object, lat: lat, lon: lon,
                                     minAlt: minAlt, now: now,
                                     horizon: horizon)
            {
                var status = ""
                if now < w.start {
                    status = " — opens in " +
                        Fmt.countdown(w.start.timeIntervalSince(now))
                } else if now <= w.end {
                    status = " — OPEN NOW, closes in " +
                        Fmt.countdown(w.end.timeIntervalSince(now))
                }
                lines.append("Window: \(Fmt.time.string(from: w.start)) → " +
                             "\(Fmt.time.string(from: w.end)) " +
                             "(\(Fmt.dur(w.durationHours)))\(status)")
            } else {
                lines.append("Window: none tonight")
            }
            lines.append("Peak: \(Fmt.deg(t.peakAlt)) at " +
                         "\(Fmt.time.string(from: t.peakTime))")
            lines.append("Moon: \(Fmt.deg(t.moonSep)) separation — " +
                         (t.moonOK ? "Moon OK" : "glare risk"))
            let size = t.object.sizeArcmin
                .map { String(format: "%.1f′", $0) } ?? "size unknown"
            lines.append("Framing (\(rig.name)): " +
                         "\(rig.framingLabel(sizeArcmin: t.object.sizeArcmin))" +
                         " — target \(size) vs frame " +
                         String(format: "%.2f° × %.2f°",
                                rig.fieldWidthDeg, rig.fieldHeightDeg))
            if imagedIDs.contains(t.id) {
                lines.append("Imaged: ✓ already logged")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One-line cloud summary for the coming hours, or an honest
    /// unavailable note when there's no forecast.
    static func cloudSummary(_ cloud: [WeatherService.HourSample]?,
                             now: Date) -> String
    {
        guard let cloud, !cloud.isEmpty else {
            return "forecast unavailable"
        }
        let upcoming = cloud
            .filter { $0.date >= now.addingTimeInterval(-1800) }
            .prefix(8)
        guard !upcoming.isEmpty else { return "forecast unavailable" }
        let covers = upcoming.map(\.cover)
        let avg = covers.reduce(0, +) / Double(covers.count)
        let maxC = covers.max() ?? 0
        return String(format: "%.0f%% avg, %.0f%% max over next %dh",
                      avg, maxC, upcoming.count)
    }

    // MARK: - Session-log export (Markdown)

    /// The imaged session log as Markdown, ready to paste into notes —
    /// one section per target with dates, per-session exposure, notes,
    /// and the running total. `nameFor` resolves catalogue ids to
    /// display names (falls back to the id itself).
    static func sessionLogMarkdown(sessions: SessionStore,
                                   nameFor: (String) -> String,
                                   now: Date) -> String
    {
        var lines = [String]()
        lines.append("# Session log — \(Fmt.weekday.string(from: now))")
        lines.append("")
        let ids = sessions.entries.keys.sorted {
            nameFor($0).localizedStandardCompare(nameFor($1))
                == .orderedAscending
        }
        guard !ids.isEmpty else {
            lines.append("No sessions logged yet.")
            return lines.joined(separator: "\n") + "\n"
        }
        for id in ids {
            let list = sessions.sessions(for: id)
            let total = sessions.totalExposureMinutes(for: id)
            lines.append("## \(nameFor(id)) — " +
                         "\(Fmt.exposure(total)) over \(list.count) " +
                         "night\(list.count == 1 ? "" : "s")")
            for s in list {
                var row = "- \(Fmt.dayMonth.string(from: s.dateImaged))"
                if s.exposureMinutes > 0 {
                    row += " · \(Fmt.exposure(s.exposureMinutes))"
                }
                if !s.notes.isEmpty {
                    row += " · \(s.notes)"
                }
                lines.append(row)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
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
