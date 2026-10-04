import SwiftUI

struct TargetDetailView: View {
    let target: RankedTarget
    @ObservedObject var store: TargetStore
    @ObservedObject var sessions: SessionStore
    @ObservedObject var notifications: NotificationService
    /// Passed through (not observed here — only `SessionLogSection`
    /// subscribes, so the whole detail view doesn't re-render every
    /// timer tick).
    let timer: SessionTimer
    let rig: RigPreset
    /// Corner-trailing tolerance (px) for the max-sub recommendation.
    /// Same key as the site-settings slider.
    @AppStorage("AstroTonight.trailTolerancePx") private var trailTolerancePx = 2.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                thumbnailSection
                finderSection
                tonightSection
                    .padding(14)
                    .glassPanel()
                AltitudeChartView(target: target,
                                  windowStart: store.windowStart,
                                  step: store.step,
                                  now: store.now,
                                  minThresholds: horizonThresholds,
                                  darkStart: store.darkStart,
                                  darkEnd: store.darkEnd)
                framingSection
                    .padding(14)
                    .glassPanel()
                targetSection
                    .padding(14)
                    .glassPanel()
                moonSection
                    .padding(14)
                    .glassPanel()
                bestNightSection
                    .padding(14)
                    .glassPanel()
                sessionSection
                    .padding(14)
                    .glassPanel()
                copyButtons
            }
            .padding(20)
            .frame(maxWidth: 680, alignment: .leading)
            .id(target.id)
            .transition(.opacity)
        }
        .navigationTitle(target.object.name)
        .animation(.easeInOut(duration: 0.22), value: target.id)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(target.object.name)
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                    .foregroundStyle(LinearGradient(
                        colors: [.white, .white.opacity(0.72)],
                        startPoint: .top, endPoint: .bottom))
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) {
                        store.toggleSaved(id: target.object.id)
                    }
                } label: {
                    let saved = store.savedIDs.contains(target.object.id)
                    Image(systemName: saved ? "star.fill" : "star")
                        .symbolEffect(.bounce, value: saved)
                        .foregroundStyle(saved ? .yellow : .secondary)
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help("Toggle observing list")
                .accessibilityLabel(
                    store.savedIDs.contains(target.object.id)
                    ? "Remove from observing list"
                    : "Add to observing list")
                Button {
                    Task {
                        await notifications.toggleReminder(
                            for: target.object.id)
                    }
                } label: {
                    let on = notifications.notifyIDs
                        .contains(target.object.id)
                    Image(systemName: on ? "bell.fill" : "bell")
                        .foregroundStyle(on ? .orange : .secondary)
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help("Notify 30 min before this target's imaging window " +
                      "opens (needs the master switch in Site settings)")
                .accessibilityLabel(
                    notifications.notifyIDs.contains(target.object.id)
                    ? "Disable window-open reminder"
                    : "Notify 30 minutes before the imaging window opens")
                if let rank = store.targets.firstIndex(of: target) {
                    Text("#\(rank + 1) tonight")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Text(target.object.ids.joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                kindChip
                if let c = target.object.constellation {
                    Text(c).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var kindChip: some View {
        Text(ObjectKind.of(target.object.type).rawValue)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.blue.opacity(0.15))
            .foregroundStyle(.blue)
            .clipShape(Capsule())
    }

    // MARK: - Tonight

    /// DSS survey cutout for the target, fetched on demand and cached on
    /// disk by `ThumbnailService`. The night-vision red overlay sits above
    /// everything at the top level, so no extra work is needed for it here.
    private var thumbnailSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Preview · DSS2 Red")
            ThumbnailView(object: target.object, kind: .closeup)
                .frame(width: 300, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .glassPanel(radius: 10)
            Text("Digitized Sky Survey via NASA SkyView — cached after the " +
                 "first view, needs internet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Wide-field context for star-hopping: ~3° DSS2-color cutout from
    /// CDS hips2fits, same disk cache (separate `-finder` file, shared
    /// 200 MB cap) and the same quiet-failure behaviour as the preview.
    private var finderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Finder · 3° DSS2 color")
            ThumbnailView(object: target.object, kind: .finder)
                .frame(width: 300, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .glassPanel(radius: 10)
            Text("Wide-field context for star-hopping — cached after the " +
                 "first view, needs internet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var tonightSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Tonight")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                factRow("Peak altitude",
                        "\(Fmt.deg(target.peakAlt)) at \(Fmt.time.string(from: target.peakTime))")
                factRow(store.horizonProfile.isEmpty
                            ? "Above \(Fmt.deg(store.settings.minAlt))"
                            : "Above horizon",
                        Fmt.hours(target.hoursAbove))
                factRow("Rises above min",
                        target.rise.map { Fmt.time.string(from: $0) } ?? "—")
                factRow("Sets below min",
                        target.set.map { Fmt.time.string(from: $0) } ?? "—")
                factRow("Right now",
                        "\(Fmt.deg(store.altNow(for: target))) alt · \(Fmt.deg(store.azNow(for: target))) az")
                factRow("Airmass", airmassText)
                factRow("Dark window", darkWindowText)
                factRow("Dark time above min", Fmt.hours(target.darkHoursAbove))
                factRow("Imaging window", imagingWindowText)
                factRow("Window status", imagingWindowStatus)
                factRow("Field rotation at peak", fieldRotationText)
                factRow("Max sub", maxSubText)
            }
        }
    }

    /// Best contiguous stretch where the target is above the minimum
    /// altitude AND the Sun is below −18° (astronomical dark).
    private var imagingWindow: Planning.ImagingWindow? {
        Planning.imagingWindow(object: target.object,
                               lat: store.settings.lat, lon: store.settings.lon,
                               minAlt: store.settings.minAlt,
                               now: store.now,
                               horizon: store.horizonProfile)
    }

    /// Per-step minimum altitude for the chart's threshold line: the
    /// surveyed horizon traced over the night, or the flat minimum when
    /// no profile is surveyed (identical rendering to before).
    private var horizonThresholds: [Double] {
        let n = target.profile.count
        return (0..<n).map { i in
            let t = store.windowStart.addingTimeInterval(Double(i) * store.step)
            let jd = AstroMath.julianDate(t)
            let az = AstroMath.altAz(ra: target.object.ra, dec: target.object.dec,
                                     julianDate: jd,
                                     lat: store.settings.lat,
                                     lon: store.settings.lon).az
            return store.horizonProfile.minAlt(forAzimuth: az)
                ?? store.settings.minAlt
        }
    }

    private var imagingWindowText: String {
        guard let w = imagingWindow else { return "—" }
        return "\(Fmt.time.string(from: w.start)) → " +
            "\(Fmt.time.string(from: w.end)) (\(Fmt.dur(w.durationHours)))"
    }

    private var imagingWindowStatus: String {
        guard let w = imagingWindow else { return "no window tonight" }
        let now = store.now
        if now < w.start {
            return "opens in \(Fmt.countdown(w.start.timeIntervalSince(now)))"
        }
        if now <= w.end {
            return "open now · closes in " +
                "\(Fmt.countdown(w.end.timeIntervalSince(now)))"
        }
        return "closed for tonight"
    }

    private var darkWindowText: String {
        if let ds = store.darkStart, let de = store.darkEnd {
            return "\(Fmt.time.string(from: ds)) → \(Fmt.time.string(from: de))"
        }
        return "—"
    }

    /// Alt-az field rotation at the target's peak, plus the estimated star
    /// trailing at the frame corners in a 30 s sub. Centre of frame is
    /// unaffected; it grows linearly toward the corners.
    private var fieldRotationText: String {
        let aa = AstroMath.altAz(ra: target.object.ra, dec: target.object.dec,
                                 julianDate: AstroMath.julianDate(target.peakTime),
                                 lat: store.settings.lat, lon: store.settings.lon)
        let rate = AstroMath.fieldRotationRateDegPerHour(
            alt: aa.alt, az: aa.az, lat: store.settings.lat)
        guard rate.isFinite else { return "extreme — passes near the zenith" }
        let rotatedDeg = abs(rate) / 3600 * 30
        let arcSec = rotatedDeg * .pi / 180 * rig.cornerRadiusDeg * 3600
        let px = arcSec / rig.pixelScaleArcsecPerPx
        return String(format: "≈ %.0f°/hr · ~%.0f px corner trailing in 30 s",
                      abs(rate), px)
    }

    /// Current airmass via sec(z). Nil (shown as "—") at/below the
    /// horizon; the approximation degrades below ~10° but stays
    /// monotonic, which is all a planning number needs.
    private var airmassText: String {
        guard let am = AstroMath.airmass(altitude: store.altNow(for: target))
        else { return "—" }
        return String(format: "%.1f", am)
    }

    /// Recommended maximum sub-exposure from field rotation alone: the
    /// time for a corner star to trail `trailTolerancePx` pixels at the
    /// peak rotation rate.
    /// Formula mirrors `fieldRotationText` exactly: corner arcsec/sec =
    /// |rate|/3600 · (π/180) · cornerRadiusDeg · 3600; then
    /// seconds = tolerancePx · pixelScale / cornerArcsecPerSec.
    /// Rotation-only — ignores periodic error, wind, and seeing.
    private var maxSubText: String {
        let aa = AstroMath.altAz(ra: target.object.ra, dec: target.object.dec,
                                 julianDate: AstroMath.julianDate(target.peakTime),
                                 lat: store.settings.lat, lon: store.settings.lon)
        let rate = AstroMath.fieldRotationRateDegPerHour(
            alt: aa.alt, az: aa.az, lat: store.settings.lat)
        guard rate.isFinite, abs(rate) > 1e-9 else {
            return "negligible rotation"
        }
        let cornerArcsecPerSec = abs(rate) / 3600 * .pi / 180
            * rig.cornerRadiusDeg * 3600
        guard cornerArcsecPerSec > 1e-9 else {
            return "negligible rotation"
        }
        let seconds = trailTolerancePx * rig.pixelScaleArcsecPerPx
            / cornerArcsecPerSec
        return "≈ \(Int(seconds.rounded())) s " +
            "(≤ \(String(format: "%.1f", trailTolerancePx)) px trailing)"
    }

    // MARK: - Framing (fits my rig?)

    private var framingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Framing · \(rig.name)")
            HStack(alignment: .top, spacing: 16) {
                FramingCanvas(sizeArcmin: target.object.sizeArcmin, rig: rig)
                    .frame(width: 220, height: 150)
                VStack(alignment: .leading, spacing: 6) {
                    framingBadge
                    Text(rig.specLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if let s = target.object.sizeArcmin {
                        Text(String(format: "Target ≈ %.1f′ across", s))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            Text("Frame vs target, to scale, for the selected rig. " +
                 "Change rigs in Site settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var framingBadge: some View {
        let (text, color): (String, Color)
        switch rig.framing(sizeArcmin: target.object.sizeArcmin) {
        case .unknown: text = "size unknown"; color = .gray
        case .small: text = "small in frame"; color = .blue
        case .fits: text = "fits with room"; color = .green
        case .fills: text = "fills the frame"; color = .green
        case .tight: text = "tight — consider a mosaic"; color = .orange
        case .mosaic: text = "mosaic target"; color = .orange
        }
        return Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    // MARK: - Target facts

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Target · J2000")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                factRow("RA",
                        "\(AstroMath.raToHMS(target.object.ra))  (\(String(format: "%.4f°", target.object.ra)))")
                factRow("Dec",
                        "\(AstroMath.decToDMS(target.object.dec))  (\(String(format: "%.4f°", target.object.dec)))")
                factRow("Magnitude", Fmt.mag(target.object.mag))
                factRow("Size", target.object.sizeArcmin.map { String(format: "%.1f′", $0) } ?? "—")
                factRow("Type", target.object.type.replacingOccurrences(of: "_", with: " "))
            }
            Text("Coordinates are J2000 mean place (catalogue frame) — about ±0.5° from tonight's apparent place. Fine for GoTo; plate solving removes the rest.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Moon

    private var moonSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Moon")
            HStack(spacing: 10) {
                Text("Separation \(Fmt.deg(target.moonSep))")
                Spacer()
                moonVerdict
            }
            .font(.callout)
            Text("Rule of thumb: with the Moon more than half lit, keep 40° or more away from it for broadband imaging; narrowband doesn't care.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var moonVerdict: some View {
        let ok = target.moonOK
        return Text(ok ? "Moon OK" : "Moon glare risk")
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((ok ? Color.green : Color.orange).opacity(0.15))
            .foregroundStyle(ok ? .green : .orange)
            .clipShape(Capsule())
    }

    // MARK: - Best night this week

    private var bestNightSection: some View {
        let scores = Planning.weekScores(object: target.object,
                                         lat: store.settings.lat,
                                         lon: store.settings.lon,
                                         now: store.now)
        let best = Planning.bestNight(scores)
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Best night this week")
            if let best {
                Text("\(Fmt.weekday.string(from: best.date)) — peak " +
                     "\(Fmt.deg(best.peakAlt)) at " +
                     "\(Fmt.time.string(from: best.peakTime)), moon " +
                     "\(Int(best.moonIllumination * 100))%")
                    .font(.callout)
                    .monospacedDigit()
            }
            HStack(spacing: 6) {
                ForEach(scores, id: \.date) { s in
                    VStack(spacing: 2) {
                        Text(Fmt.weekdayNarrow.string(from: s.date))
                        Text("\(Int(s.peakAlt))°")
                        Text("\(Int(s.moonIllumination * 100))%")
                            .foregroundStyle(s.moonOK ? .green : .orange)
                    }
                    .font(.caption2)
                    .monospacedDigit()
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(s.date == best?.date
                                ? Color.accentColor.opacity(0.18)
                                : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            Text("Ranked moon-clear first, then highest peak. " +
                 "Green % = moon is dim or well away from the target.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Session log

    private var sessionSection: some View {
        SessionLogSection(targetID: target.object.id, sessions: sessions,
                          store: store, timer: timer)
    }

    // MARK: - Copy buttons

    private var copyButtons: some View {
        HStack(spacing: 12) {
            Button("Copy coordinates") {
                copyToClipboard(
                    "\(target.object.name): RA \(String(format: "%.5f", target.object.ra))°, " +
                    "Dec \(String(format: "%+.5f", target.object.dec))° (J2000)")
            }
            Button("Copy scheduler YAML") {
                copyToClipboard(Planning.schedulerYAML(
                    targets: [target],
                    lat: store.settings.lat, lon: store.settings.lon,
                    minAlt: store.settings.minAlt,
                    date: store.now))
            }
            Button("Copy for NexStar hand controller") {
                copyToClipboard(
                    "\(AstroMath.raToHMS(target.object.ra))  \(AstroMath.decToDMS(target.object.dec))")
            }
            .buttonStyle(.link)
        }
    }

    // MARK: - Pieces

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
                .textSelection(.enabled)
                .gridColumnAlignment(.leading)
        }
        .font(.callout)
    }

    private func copyToClipboard(_ s: String) {
        PlatformPasteboard.copy(s)
    }
}

// MARK: - Session log section

/// Per-session logging for one target: each night gets its own entry
/// with exposure minutes and optional notes, so multi-night integration
/// builds up a running total. The enclosing `TargetDetailView` content
/// carries `.id(target.id)`, so this view (and its drafts) is recreated
/// whenever the selection changes.
struct SessionLogSection: View {
    let targetID: String
    @ObservedObject var sessions: SessionStore
    @ObservedObject var store: TargetStore
    @ObservedObject var timer: SessionTimer
    @State private var notesDraft = ""
    @State private var exposureDraft = 60.0
    @State private var showSwitchAlert = false

    private var sessionCount: Int {
        sessions.sessionCount(for: targetID)
    }

    /// Integration goal: a per-target hour target with a progress bar
    /// fed by the session log. The stepper is always visible; the bar
    /// appears only when a goal is set.
    private var goalRow: some View {
        Group {
            HStack {
                Text("Goal")
                    .foregroundStyle(.secondary)
                Spacer()
                Stepper(value: Binding(
                    get: { sessions.goalHours(for: targetID) },
                    set: { sessions.setGoalHours(id: targetID,
                                                 hours: $0) }
                ), in: 0...40, step: 0.5) {
                    let g = sessions.goalHours(for: targetID)
                    Text(g > 0 ? Fmt.exposure(g * 60) : "none")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Integration goal in hours")
            }
            .font(.callout)
            if sessions.goalHours(for: targetID) > 0 {
                let goal = sessions.goalHours(for: targetID)
                let total = sessions.totalExposureMinutes(for: targetID)
                let goalMin = goal * 60
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(
                        value: min(total, goalMin),
                        total: goalMin)
                    {
                        Text("\(Fmt.exposure(total)) / " +
                             "\(Fmt.exposure(goalMin))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .tint(.green)
                    .accessibilityLabel(
                        "Integration goal progress: " +
                        "\(Fmt.exposure(total)) of \(Fmt.exposure(goalMin))")
                    if total >= goalMin {
                        Text("Goal reached ✓")
                            .font(.callout)
                            .foregroundStyle(.green)
                    }
                }
            }
        }
    }

    /// Name of the other target a timer is running on, if any.
    private var otherRunningName: String? {
        guard let id = timer.targetID, id != targetID else { return nil }
        return store.targets.first(where: { $0.id == id })?.object.name
            ?? id
    }

    /// Live imaging timer: start/stop for this target, with a switch
    /// flow when another target's timer is running. Stopping always
    /// logs the elapsed time as a session (rounded to whole minutes).
    private var timerRow: some View {
        Group {
            if timer.targetID == targetID {
                HStack(spacing: 8) {
                    Image(systemName: "timer")
                    Text("\(Fmt.hms(timer.elapsed)) elapsed")
                        .monospacedDigit()
                    Spacer()
                    Button("Stop & log") {
                        if let (_, e) = timer.stop() {
                            sessions.logSession(
                                id: targetID,
                                exposureMinutes: max(
                                    1, (e / 60).rounded()))
                        }
                    }
                    .buttonStyle(.link)
                }
                .foregroundStyle(.green)
                .font(.callout)
                .accessibilityLabel(
                    "Timer running: \(Fmt.hms(timer.elapsed)) elapsed")
            } else {
                HStack(spacing: 8) {
                    Button(timer.isRunning ? "Switch timer here"
                                           : "Start imaging")
                    {
                        if timer.isRunning {
                            showSwitchAlert = true
                        } else {
                            timer.start(targetID: targetID)
                        }
                    }
                    .buttonStyle(.link)
                    if let other = otherRunningName {
                        Text("Timer running on \(other)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .alert("Timer already running",
                       isPresented: $showSwitchAlert)
                {
                    Button("Log & switch") {
                        if let (oldID, e) = timer.stop() {
                            sessions.logSession(
                                id: oldID,
                                exposureMinutes: max(
                                    1, (e / 60).rounded()))
                        }
                        timer.start(targetID: targetID)
                    }
                    Button("Discard & switch", role: .destructive) {
                        timer.stop()
                        timer.start(targetID: targetID)
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("A timer is already running on " +
                         "\(otherRunningName ?? "another target").")
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session log")
                .font(.headline)
                .foregroundStyle(.secondary)
            timerRow
            if sessionCount > 0 {
                Text("Total: " +
                     "\(Fmt.exposure(sessions.totalExposureMinutes(for: targetID))) " +
                     "over \(sessionCount) night\(sessionCount == 1 ? "" : "s")")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .monospacedDigit()
                goalRow
                ForEach(sessions.sessions(for: targetID)) { s in
                    HStack(spacing: 8) {
                        Text(Fmt.dayMonth.string(from: s.dateImaged))
                            .monospacedDigit()
                        Stepper(value: Binding(
                            get: { s.exposureMinutes },
                            set: { sessions.updateExposure(
                                id: targetID, sessionID: s.sessionID,
                                minutes: $0) }
                        ), in: 0...600, step: 15) {
                            Text(Fmt.exposure(s.exposureMinutes))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .help("Edit this session's exposure")
                        if !s.notes.isEmpty {
                            Text(s.notes)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            sessions.removeSession(id: targetID,
                                                   sessionID: s.sessionID)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Delete this session")
                        .accessibilityLabel("Delete this session")
                    }
                    .font(.callout)
                }
                Divider()
            }
            HStack {
                Text("Exposure")
                    .foregroundStyle(.secondary)
                Spacer()
                Stepper(value: $exposureDraft, in: 0...600, step: 15) {
                    Text(Fmt.exposure(exposureDraft))
                        .monospacedDigit()
                }
            }
            .font(.callout)
            TextField("Notes (optional)", text: $notesDraft)
                .textFieldStyle(.roundedBorder)
            Button("Log session") {
                sessions.logSession(
                    id: targetID,
                    notes: notesDraft.trimmingCharacters(
                        in: .whitespacesAndNewlines),
                    exposureMinutes: exposureDraft)
                notesDraft = ""
            }
        }
    }
}

// MARK: - DSS thumbnail

/// On-demand Digitized Sky Survey imagery. Fetches once per target
/// (disk-cached by `ThumbnailService`); `.task(id:)` re-triggers when the
/// selection changes. Failures stay quiet — a subtle placeholder, never
/// an error state — so the rest of the detail view is never blocked.
struct ThumbnailView: View {
    enum Kind {
        /// 300×300 DSS2-Red close-up (NASA SkyView).
        case closeup
        /// ~3° DSS2-color wide field (CDS hips2fits), for star-hopping.
        case finder
    }

    let object: CatalogObject
    let kind: Kind
    @State private var image: PlatformImage? = nil
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if failed {
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                        .font(.title2)
                    Text("Preview unavailable")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(object.id)-\(kind)") {
            image = nil
            failed = false
            let data: Data?
            switch kind {
            case .closeup:
                data = await ThumbnailService.data(for: object)
            case .finder:
                data = await ThumbnailService.finderData(for: object)
            }
            if let data {
                image = platformImage(from: data)
            } else {
                failed = true
            }
        }
    }
}

// MARK: - Framing canvas (sensor rect vs target, to scale)

struct FramingCanvas: View {
    let sizeArcmin: Double?
    let rig: RigPreset

    var body: some View {
        Canvas { ctx, size in
            let w = rig.fieldWidthDeg
            let targetD = (sizeArcmin ?? 0) / 60.0
            let span = max(w, targetD) * 1.15
            let s = size.width / span
            let fw = w * s
            let fh = rig.fieldHeightDeg * s
            let frame = CGRect(x: (size.width - fw) / 2,
                               y: (size.height - fh) / 2,
                               width: fw, height: fh)
            ctx.stroke(Path(frame), with: .color(.accentColor), lineWidth: 1.5)
            if let sa = sizeArcmin {
                let r = sa / 60.0 / 2 * s
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r,
                                                 width: 2 * r, height: 2 * r)),
                           with: .color(.green), lineWidth: 1.5)
            } else {
                ctx.draw(Text("?")
                    .font(.title)
                    .foregroundStyle(.secondary),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
            }
        }
        .glassPanel(radius: 8)
    }
}

// MARK: - Altitude chart

struct AltitudeChartView: View {
    let target: RankedTarget
    let windowStart: Date
    let step: TimeInterval
    let now: Date
    /// Per-step minimum altitude: the surveyed horizon traced over the
    /// night, or the flat minimum repeated when no profile is surveyed.
    let minThresholds: [Double]
    let darkStart: Date?
    let darkEnd: Date?

    /// Draw-in progress 0...1, animated on appear and on target change.
    @State private var drawProgress = 0.0
    /// Hover/drag scrubber x in points, nil when the pointer leaves.
    @State private var hoverX: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Altitude · 24 h window")
                .font(.headline)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                Canvas { ctx, size in
                    draw(in: ctx, size: size)
                }
                #if os(macOS)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): hoverX = location.x
                    case .ended: hoverX = nil
                    }
                }
                #endif
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { hoverX = $0.location.x }
                        .onEnded { _ in hoverX = nil }
                )
            }
            .frame(height: 170)
            .glassPanel(radius: 10)
            .onAppear { animateIn() }
            .onChange(of: target.id) { _, _ in animateIn() }
            HStack {
                Text(Fmt.dayTime.string(from: windowStart))
                Spacer()
                Text("now")
                Spacer()
                Text(Fmt.dayTime.string(from: windowStart.addingTimeInterval(step * Double(max(target.profile.count - 1, 0)))))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func animateIn() {
        drawProgress = 0
        withAnimation(.easeOut(duration: 1.3)) { drawProgress = 1 }
    }

    /// Altitude at a fractional profile position by linear interpolation.
    private func altAt(_ t: Double) -> Double {
        let p = target.profile
        guard p.count > 1 else { return -90 }
        let tc = min(max(t, 0), Double(p.count - 1))
        let i = Int(tc)
        let f = tc - Double(i)
        return p[i] * (1 - f) + p[min(i + 1, p.count - 1)] * f
    }

    private func draw(in ctx: GraphicsContext, size: CGSize) {
        let profile = target.profile
        guard profile.count > 1,
              minThresholds.count == profile.count else { return }
        let yMin = -15.0, yMax = 90.0
        let shown = max(2, Int(Double(profile.count) * drawProgress))

        func x(_ i: Int) -> Double {
            size.width * Double(i) / Double(profile.count - 1)
        }
        func y(_ alt: Double) -> Double {
            let f = (alt - yMin) / (yMax - yMin)
            return size.height * (1.0 - f)
        }

        // Horizon line.
        var horizon = Path()
        horizon.move(to: CGPoint(x: 0, y: y(0)))
        horizon.addLine(to: CGPoint(x: size.width, y: y(0)))
        ctx.stroke(horizon, with: .color(.gray.opacity(0.5)), lineWidth: 1)

        // Minimum-altitude line: flat when no horizon is surveyed,
        // otherwise the surveyed profile traced over the night.
        var minPath = Path()
        minPath.move(to: CGPoint(x: 0, y: y(minThresholds[0])))
        for i in 1..<profile.count {
            minPath.addLine(to: CGPoint(x: x(i), y: y(minThresholds[i])))
        }
        ctx.stroke(minPath, with: .color(.orange.opacity(0.7)),
                   style: StrokeStyle(lineWidth: 1, dash: [6, 4]))

        // Astronomical-dark band behind the curve: the part of the night
        // where the target can actually be imaged dark-sky.
        if let ds = darkStart, let de = darkEnd {
            let n = Double(profile.count - 1)
            let t0 = ds.timeIntervalSince(windowStart) / step
            let t1 = de.timeIntervalSince(windowStart) / step
            let x0 = size.width * min(max(t0, 0), n) / n
            let x1 = size.width * min(max(t1, 0), n) / n
            if x1 > x0 {
                ctx.fill(Path(CGRect(x: x0, y: 0,
                                     width: x1 - x0, height: size.height)),
                         with: .color(.indigo.opacity(0.14)))
            }
        }

        // Altitude curve (drawn in) + fill down to the horizon.
        var curve = Path()
        curve.move(to: CGPoint(x: x(0), y: y(profile[0])))
        for i in 1..<shown {
            curve.addLine(to: CGPoint(x: x(i), y: y(profile[i])))
        }
        var fill = curve
        fill.addLine(to: CGPoint(x: x(shown - 1), y: y(0)))
        fill.addLine(to: CGPoint(x: x(0), y: y(0)))
        fill.closeSubpath()
        ctx.fill(fill, with: .color(.accentColor.opacity(0.15 * drawProgress)))
        ctx.stroke(curve, with: .linearGradient(
            Gradient(colors: [.accentColor, .purple]),
            startPoint: .zero,
            endPoint: CGPoint(x: size.width, y: 0)), lineWidth: 2)

        // Peak marker.
        if drawProgress > 0.95,
           let peakIdx = profile.indices.max(by: { profile[$0] < profile[$1] })
        {
            let c = CGPoint(x: x(peakIdx), y: y(profile[peakIdx]))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7,
                                            width: 14, height: 14)),
                     with: .color(.accentColor.opacity(0.25)))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4,
                                            width: 8, height: 8)),
                     with: .color(.accentColor))
        }

        // Now line.
        let t = now.timeIntervalSince(windowStart) / step
        if t >= 0 && t <= Double(profile.count - 1) {
            let nx = size.width * t / Double(profile.count - 1)
            var nowLine = Path()
            nowLine.move(to: CGPoint(x: nx, y: 0))
            nowLine.addLine(to: CGPoint(x: nx, y: size.height))
            ctx.stroke(nowLine, with: .color(.white.opacity(0.6)), lineWidth: 1)
        }

        // Hover scrubber: readout of time + altitude under the pointer.
        if let hx = hoverX {
            let xc = min(max(hx, 0), size.width)
            let tp = xc / size.width * Double(profile.count - 1)
            let alt = altAt(tp)
            var line = Path()
            line.move(to: CGPoint(x: xc, y: 0))
            line.addLine(to: CGPoint(x: xc, y: size.height))
            ctx.stroke(line, with: .color(.white.opacity(0.45)), lineWidth: 1)
            let dot = CGPoint(x: xc, y: y(alt))
            ctx.fill(Path(ellipseIn: CGRect(x: dot.x - 4, y: dot.y - 4,
                                            width: 8, height: 8)),
                     with: .color(.white))
            let date = windowStart.addingTimeInterval(tp * step)
            let label = Text("\(Fmt.time.string(from: date)) · \(Fmt.deg(alt))")
                .font(.caption)
                .foregroundStyle(.white)
            let lp = CGPoint(x: min(max(xc, 70), size.width - 70), y: 14)
            // Pill backdrop behind the label: GraphicsContext can't fill a
            // path with a material, so a dark translucent rounded rect
            // stands in for the glass pill. (ctx.draw only takes Text —
            // padding/background modifiers change the type and won't compile.)
            let pill = Path(roundedRect: CGRect(x: lp.x - 78, y: lp.y - 12,
                                                width: 156, height: 24),
                            cornerRadius: 7)
            ctx.fill(pill, with: .color(.black.opacity(0.55)))
            ctx.draw(label, at: lp)
        }
    }
}
