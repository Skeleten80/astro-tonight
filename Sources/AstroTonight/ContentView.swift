import SwiftUI
import UniformTypeIdentifiers

// MARK: - Formatters

enum Fmt {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
    static let dayTime: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .short
        return f
    }()
    static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f
    }()
    static let weekdayNarrow: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEEE"
        return f
    }()

    static func deg(_ v: Double) -> String { String(format: "%.1f°", v) }
    static func hours(_ v: Double) -> String { String(format: "%.1fh", v) }

    /// "45m" or "3.2h" for exposure minutes.
    static func exposure(_ minutes: Double) -> String {
        if minutes >= 60 { return String(format: "%.1fh", minutes / 60) }
        return String(format: "%.0fm", minutes)
    }
    static func mag(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.1f", v)
    }

    /// "5h 30m" for a duration in hours.
    static func dur(_ hours: Double) -> String {
        let h = Int(hours)
        let m = Int((hours - Double(h)) * 60.0)
        return "\(h)h \(m)m"
    }

    /// "21.5°C" or "70.7°F" for a Celsius temperature, per the user's
    /// unit preference. Thresholds stay in Celsius — physics doesn't
    /// convert, only the display does.
    static func temperature(_ celsius: Double, fahrenheit: Bool) -> String {
        if fahrenheit {
            return String(format: "%.1f°F", celsius * 9 / 5 + 32)
        }
        return String(format: "%.1f°C", celsius)
    }

    /// "02:14:33" for an elapsed timer in seconds.
    static func hms(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d",
                      s / 3600, (s % 3600) / 60, s % 60)
    }

    /// "2h 14m" (or "14m" under an hour) for a countdown in seconds.
    static func countdown(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600
        let m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    static let hour24: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH"
        return f
    }()
}

/// One-shot CSV import result, shown in an alert.
struct ImportAlert: Identifiable {
    let id = UUID()
    let message: String
}

// MARK: - Main view

struct ContentView: View {
    @StateObject private var store = TargetStore()
    @StateObject private var location = LocationProvider()
    @StateObject private var sessions = SessionStore()
    @StateObject private var weather = WeatherService()
    @StateObject private var horizonStore = HorizonStore()
    @StateObject private var rigStore = RigStore()
    @StateObject private var notifications = NotificationService()
    @StateObject private var sessionTimer = SessionTimer()
    @StateObject private var checklist = ChecklistStore()
    @AppStorage("AstroTonight.nightVision") private var nightVision = false
    @AppStorage("AstroTonight.didOnboard") private var didOnboard = false
    @AppStorage("AstroTonight.useFahrenheit") private var useFahrenheit = false
    @AppStorage("AstroTonight.trailTolerancePx") private var trailTolerancePx = 2.0
    @State private var selection: RankedTarget?
    @State private var searchText = ""
    @State private var kind: ObjectKind = .all
    @State private var sortMode: SortMode = .rank
    @State private var listOnly = false
    @State private var hideImaged = false
    @State private var showSettings = false
    @State private var showTimeline = true
    @State private var showChecklist = true
    @State private var showOnboarding = false
    @State private var showImporter = false
    @State private var checklistDraft = ""
    @State private var importAlert: ImportAlert?
    @StateObject private var slewService = SlewService()
    @StateObject private var satelliteTracker = SatelliteTracker()
    @State private var starStore = StarStore()
    @State private var showSkyChart = false
    @State private var showSatellites = false
    @State private var showComets = false
    @State private var showSchedule = false
    @State private var chartSelection: SkyChartSelection?

    /// Shown in the detail pane when nothing is selected. Extracted from
    /// `body` so the type-checker doesn't have to chew through the whole
    /// NavigationSplitView expression at once.
    private var emptyDetailView: some View {
        ContentUnavailableView(
            "Select a target",
            systemImage: "telescope",
            description: Text("Ranked for your site — same ordering as `astrocapture tonight`."))
    }

    /// Sky-chart sheet content. Extracted for the same type-checker reason.
    /// ScopePilot's /api/goto wants RA in hours; the catalog stores degrees.
    private var skyChartSheet: some View {
        SkyChartView(
            starStore: starStore,
            lat: store.settings.lat,
            lon: store.settings.lon,
            date: store.now,
            targets: filtered.map {
                SkyChartTarget(id: $0.id, name: $0.object.name,
                               ra: $0.object.ra, dec: $0.object.dec,
                               mag: $0.object.mag)
            },
            onSelect: { chartSelection = $0 })
            .overlay(alignment: .bottom) {
                if let sel = chartSelection {
                    chartSelectionCard(sel)
                }
            }
    }

    /// Tap-selection card over the sky chart, with the ScopePilot slew action.
    private func chartSelectionCard(_ sel: SkyChartSelection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(sel.name)
                    .font(.headline)
                Spacer()
                Button {
                    chartSelection = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text(String(format: "RA %.2f° · Dec %+.2f°",
                       sel.ra, sel.dec))
                .font(.caption)
                .foregroundStyle(.secondary)
            SlewButton(ra: sel.ra / 15.0, dec: sel.dec,
                       name: sel.name, slewService: slewService)
        }
        .padding(12)
        .glassPanel()
        .padding()
    }

    var body: some View {
        ZStack {
            StarfieldView()
            NavigationSplitView {
                sidebar
            } detail: {
                if let target = selection {
                    TargetDetailView(target: target, store: store,
                                     sessions: sessions,
                                     notifications: notifications,
                                     timer: sessionTimer,
                                     rig: rigStore.selected,
                                     slewService: slewService)
                } else {
                    emptyDetailView
                }
            }
            .navigationTitle("Tonight's Targets")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    moonChip
                }
                ToolbarItem(placement: .primaryAction) {
                    GradeChipView(store: store, weather: weather)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        copyToClipboard(Planning.schedulerYAML(
                            targets: filtered,
                            lat: store.settings.lat, lon: store.settings.lon,
                            minAlt: store.settings.minAlt,
                            date: store.now))
                    } label: {
                        Label("Copy scheduler YAML", systemImage: "doc.on.doc")
                    }
                    .help("Copy the listed targets as an AstroCapture plan YAML block")
                    .disabled(filtered.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.recompute()
                    } label: {
                        Label("Re-rank", systemImage: "arrow.clockwise")
                    }
                    .help("Re-rank for right now")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        nightVision.toggle()
                    } label: {
                        Label("Night vision",
                              systemImage: nightVision
                                ? "moon.circle.fill" : "moon.circle")
                    }
                    .help("Red overlay to preserve dark adaptation at the scope")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSkyChart = true
                    } label: {
                        Label("Sky chart", systemImage: "star.circle")
                    }
                    .help("Interactive planetarium chart for your site and time")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSatellites = true
                    } label: {
                        Label("Satellites", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .help("Upcoming satellite passes for your site")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showComets = true
                    } label: {
                        Label("Comets", systemImage: "sparkles")
                    }
                    .help("Bright comets with current ephemerides")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSchedule = true
                    } label: {
                        Label("Night schedule", systemImage: "calendar.badge.clock")
                    }
                    .help("Auto night schedule — top targets slotted into dark time")
                }
            }
            .searchable(text: $searchText, placement: .sidebar,
                        prompt: "Search name or catalogue ID")
            #if os(macOS)
            .frame(minWidth: 960, minHeight: 620)
            #endif
            .onChange(of: location.coordinate) { _, coord in
                guard let coord else { return }
                store.settings.lat = coord.latitude
                store.settings.lon = coord.longitude
            }
            // Night-vision mode: a non-interactive red multiply layer over
            // everything, so the app doesn't ruin dark adaptation at the
            // scope. v1 is overlay-only (no full theme swap).
            if nightVision {
                Color(red: 1, green: 0, blue: 0).opacity(0.35)
                    .blendMode(.multiply)
                    .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .task(id: "\(store.settings.lat),\(store.settings.lon)") {
            weather.refresh(lat: store.settings.lat, lon: store.settings.lon)
        }
        .onChange(of: horizonStore.profile) { _, _ in
            // Re-rank against the new horizon, debounced like the sliders.
            store.scheduleRecompute()
        }
        .onChange(of: store.targets) { _, _ in scheduleNotifications() }
        .onChange(of: notifications.notifyIDs) { _, _ in
            scheduleNotifications()
        }
        .onChange(of: notifications.masterEnabled) { _, _ in
            scheduleNotifications()
        }
        .onChange(of: notifications.duskEnabled) { _, _ in
            scheduleNotifications()
        }
        .onChange(of: notifications.satellitesEnabled) { _, _ in
            scheduleNotifications()
        }
        .onChange(of: notifications.isAuthorized) { _, _ in
            scheduleNotifications()
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(store: store, location: location,
                           rigStore: rigStore, didOnboard: $didOnboard)
        }
        .sheet(isPresented: $showSkyChart) {
            skyChartSheet
        }
        .sheet(isPresented: $showSatellites) {
            SatellitePassesView(tracker: satelliteTracker,
                                latitude: store.settings.lat,
                                longitude: store.settings.lon)
                .task {
                    await satelliteTracker.predictPasses(
                        latitude: store.settings.lat,
                        longitude: store.settings.lon)
                }
        }
        .sheet(isPresented: $showComets) {
            CometsView()
        }
        .sheet(isPresented: $showSchedule) {
            NightScheduleView(
                blocks: NightSchedule.buildSchedule(
                    ranked: store.targets,
                    lat: store.settings.lat,
                    lon: store.settings.lon,
                    minAlt: store.settings.minAlt,
                    horizon: horizonStore.profile,
                    darkStart: store.darkStart,
                    darkEnd: store.darkEnd,
                    now: store.now),
                slewService: slewService,
                darkStart: store.darkStart,
                darkEnd: store.darkEnd)
        }
        .onAppear {
            // First launch (and once for existing installs, since the
            // flag is new) — "Skip" keeps the current defaults.
            if !didOnboard { showOnboarding = true }
        }
    }

    /// (Re-)schedule window-open reminders for opted-in targets (plus
    /// the dusk reminder when enabled). Called whenever the ranking,
    /// the opt-ins, or the master switch changes — the service itself
    /// cancels stale requests first.
    private func scheduleNotifications() {
        Task {
            // Satellite passes need the (heavy) SGP4 scan first; skip it
            // entirely unless the user opted in. refresh stays sync.
            if notifications.satellitesEnabled {
                await satelliteTracker.predictPasses(
                    latitude: store.settings.lat,
                    longitude: store.settings.lon)
            }
            notifications.refresh(ranked: store.targets,
                                  lat: store.settings.lat,
                                  lon: store.settings.lon,
                                  minAlt: store.settings.minAlt,
                                  horizon: store.horizonProfile,
                                  darkStart: store.darkStart,
                                  satellitePasses: satelliteTracker.passes,
                                  now: store.now)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        Group {
            if store.isLoading {
                ProgressView("Loading catalogue…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = store.errorMessage {
                ContentUnavailableView(
                    "Catalogue failed to load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(err))
            } else if filtered.isEmpty {
                ContentUnavailableView(
                    "No targets match",
                    systemImage: "moon.stars",
                    description: Text("Try lowering the minimum altitude or clearing the search."))
            } else {
                List(selection: $selection) {
                    ForEach(filtered) { target in
                        NavigationLink(value: target) {
                            TargetRow(target: target,
                                      altNow: store.altNow(for: target),
                                      threshold: store.horizonProfile.minAlt(
                                        forAzimuth: store.azNow(for: target))
                                        ?? store.settings.minAlt,
                                      isSaved: store.savedIDs.contains(target.id),
                                      imagedDate: sessions.dateImaged(for: target.id),
                                      onToggleSave: { store.toggleSaved(id: target.id) })
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 8) {
                topPickCard

                DisclosureGroup("Tonight's schedule",
                                isExpanded: $showTimeline)
                {
                    NightTimelineView(
                        targets: timelineTargets,
                        usingList: !store.savedIDs.isEmpty,
                        lat: store.settings.lat,
                        lon: store.settings.lon,
                        minAlt: store.settings.minAlt,
                        horizon: store.horizonProfile,
                        darkStart: store.darkStart,
                        darkEnd: store.darkEnd,
                        bestDarkStart: bestDarkStretch?.start,
                        bestDarkEnd: bestDarkStretch?.end,
                        now: store.now,
                        windowStart: store.windowStart,
                        selection: $selection)
                }
                .font(.callout)

                Picker("Type", selection: $kind) {
                    ForEach(ObjectKind.allCases) { k in
                        Text(k.rawValue).tag(k)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Picker("Sort", selection: $sortMode) {
                    ForEach(SortMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack(spacing: 12) {
                    Toggle("Observing list", isOn: $listOnly)
                        .toggleStyle(.switch)
                    Toggle("Hide imaged", isOn: $hideImaged)
                        .toggleStyle(.switch)
                    Spacer()
                    Text("\(store.savedIDs.count) saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.callout)

                HStack(spacing: 14) {
                    if listOnly {
                        Button {
                            copyToClipboard(Planning.nightPlanYAML(
                                savedIDs: store.savedIDs,
                                ranked: store.targets,
                                lat: store.settings.lat, lon: store.settings.lon,
                                minAlt: store.settings.minAlt,
                                date: store.now))
                        } label: {
                            Label("Export night plan", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.link)
                        .help("Copy the observing list as an AstroCapture " +
                              "multi-target night plan")
                        .disabled(store.savedIDs.isEmpty)
                    }
                    Button {
                        copyToClipboard(observingPlanString)
                    } label: {
                        Label("Copy observing plan", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.link)
                    .help("Copy a Markdown observing plan for tonight")
                    .disabled(store.targets.isEmpty)
                    ShareLink(item: observingPlanString,
                              preview: SharePreview(
                                "Observing plan",
                                image: Image(systemName: "doc.text")))
                    {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.link)
                    .help("Share the observing plan")
                    .disabled(store.targets.isEmpty)
                    Button {
                        copyToClipboard(sessionLogString)
                    } label: {
                        Label("Copy session log", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.link)
                    .help("Copy the imaged session log as Markdown")
                    .disabled(sessions.entries.isEmpty)
                    ShareLink(item: sessionLogString,
                              preview: SharePreview(
                                "Session log",
                                image: Image(systemName: "doc.text")))
                    {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.link)
                    .help("Share the session log")
                    .disabled(sessions.entries.isEmpty)
                }
                .font(.callout)

                if let ds = store.darkStart, let de = store.darkEnd {
                    Text("Dark \(Fmt.time.string(from: ds)) → " +
                         "\(Fmt.time.string(from: de)) · " +
                         Fmt.hours(de.timeIntervalSince(ds) / 3600))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Text(moonRiseSetText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let bd = bestDarkStretch {
                    Text("Best dark \(Fmt.time.string(from: bd.start)) → " +
                         "\(Fmt.time.string(from: bd.end)) · " +
                         Fmt.dur(bd.durationHours))
                        .font(.caption)
                        .foregroundStyle(.green)
                        .monospacedDigit()
                }

                cloudStrip

                seeingRow

                dewRow

                windRow

                MoonMonthView(now: store.now)

                DisclosureGroup("Pre-session checklist",
                                isExpanded: $showChecklist)
                {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(checklist.items) { item in
                            HStack(spacing: 8) {
                                Button {
                                    checklist.toggle(item.id)
                                } label: {
                                    Image(systemName: item.done
                                        ? "checkmark.circle.fill"
                                        : "circle")
                                        .foregroundStyle(item.done
                                            ? .green : .secondary)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(
                                    item.done
                                    ? "Mark \(item.title) not done"
                                    : "Mark \(item.title) done")
                                Text(item.title)
                                    .foregroundStyle(item.done
                                        ? .secondary : .primary)
                                    .strikethrough(item.done)
                                Spacer()
                                Button {
                                    checklist.remove(item.id)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(
                                    "Remove \(item.title) from checklist")
                            }
                            .font(.callout)
                        }
                        HStack {
                            TextField("Add item", text: $checklistDraft)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { addChecklistItem() }
                            Button("Add") { addChecklistItem() }
                                .buttonStyle(.link)
                                .disabled(checklistDraft
                                    .trimmingCharacters(
                                        in: .whitespacesAndNewlines)
                                    .isEmpty)
                        }
                        .font(.callout)
                        if checklist.items.contains(where: { $0.done }) {
                            Button("Reset checks") { checklist.reset() }
                                .buttonStyle(.link)
                                .font(.callout)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.callout)

                DisclosureGroup("Site · \(SiteSettings.siteName)", isExpanded: $showSettings) {
                    siteControls
                }
                .font(.callout)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationDestination(for: RankedTarget.self) { target in
            TargetDetailView(target: target, store: store,
                             sessions: sessions,
                             notifications: notifications,
                             timer: sessionTimer,
                             rig: rigStore.selected,
                             slewService: slewService)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.commaSeparatedText])
        { result in
            handleImport(result)
        }
        .alert("CSV import", item: $importAlert) { _ in
            Button("OK", role: .cancel) { }
        } message: { a in
            Text(a.message)
        }
    }

    // MARK: - Top pick hero card

    /// Cached forecast samples, if the weather service has them.
    private var cloudSamples: [WeatherService.HourSample]? {
        if case .ready(let hours) = weather.state { return hours }
        return nil
    }

    /// Cached 7Timer seeing samples, if the weather service has them.
    private var seeingSamples: [WeatherService.SeeingSample]? {
        if case .ready(let samples) = weather.seeingState { return samples }
        return nil
    }

    /// The Markdown observing plan, computed once for both Copy and Share.
    private var observingPlanString: String {
        Planning.observingPlanText(
            savedIDs: store.savedIDs,
            ranked: store.targets,
            lat: store.settings.lat, lon: store.settings.lon,
            siteLabel: location.isFollowing
                ? "device location" : SiteSettings.siteName,
            minAlt: store.settings.minAlt,
            horizon: store.horizonProfile,
            darkStart: store.darkStart,
            darkEnd: store.darkEnd,
            cloud: cloudSamples,
            seeing: seeingSamples,
            dewSpread: currentDew?.spread,
            moonIllumination: store.moon?.illumination ?? 0,
            waxing: store.moon?.waxing ?? false,
            rig: rigStore.selected,
            imagedIDs: Set(sessions.entries.keys),
            now: store.now,
            fahrenheit: useFahrenheit)
    }

    /// The Markdown session log, computed once for both Copy and Share.
    private var sessionLogString: String {
        Planning.sessionLogMarkdown(
            sessions: sessions,
            nameFor: { id in
                store.targets.first(where: { $0.id == id })?.object.name ?? id
            },
            now: store.now)
    }

    /// "Image this now" hero card: the heuristic top pick when its window
    /// is open, otherwise the next upcoming window, otherwise nothing.
    private var topPickCard: some View {
        let pick = Planning.topPick(
            ranked: store.targets,
            lat: store.settings.lat, lon: store.settings.lon,
            horizon: store.horizonProfile,
            minAlt: store.settings.minAlt,
            now: store.now,
            cloud: cloudSamples,
            seeing: seeingSamples)
        return Group {
            if let pick, pick.openNow {
                Button {
                    selection = pick.target
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("IMAGE THIS NOW")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.green)
                        Text(pick.target.object.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(topPickDetails(pick))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .buttonStyle(.plain)
                .glassPanel(radius: 10)
            } else if let next = Planning.nextUpcomingWindow(
                ranked: store.targets,
                lat: store.settings.lat, lon: store.settings.lon,
                horizon: store.horizonProfile,
                minAlt: store.settings.minAlt,
                now: store.now)
            {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NOTHING IMAGEABLE RIGHT NOW")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.orange)
                    Button {
                        selection = next.target
                    } label: {
                        Text("\(next.target.object.name) window opens " +
                             "\(Fmt.time.string(from: next.window.start))")
                            .font(.callout)
                    }
                    .buttonStyle(.link)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .glassPanel(radius: 10)
            }
        }
    }

    private func topPickDetails(_ pick: Planning.TopPick) -> String {
        var bits = ["window closes in " +
            "\(Fmt.countdown(pick.window.end.timeIntervalSince(store.now)))"]
        if let c = pick.cloudCover {
            bits.append("cloud \(Int(c))%")
        }
        if let s = pick.seeing {
            bits.append("seeing \(s) · \(WeatherService.seeingLabel(s))")
        }
        bits.append(pick.target.moonOK ? "Moon OK" : "Moon glare risk")
        return bits.joined(separator: " · ")
    }

    /// Timeline rows: the observing list when it's non-empty, otherwise
    /// the top 8 ranked targets.
    private var timelineTargets: [RankedTarget] {
        if store.savedIDs.isEmpty {
            return Array(store.targets.prefix(8))
        }
        return store.targets.filter { store.savedIDs.contains($0.id) }
    }

    // MARK: - Device location

    private var locationRow: some View {
        Group {
            switch location.state {
            case .idle:
                Button {
                    location.request()
                } label: {
                    Label("Use my location", systemImage: "location.fill")
                }
                .buttonStyle(.link)
                .help(PlatformSystem.useLocationHelp)
            case .requesting:
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Locating…")
                        .foregroundStyle(.secondary)
                }
            case .following(let coord):
                HStack(spacing: 6) {
                    Label("Device location", systemImage: "location.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Text(String(format: "%.2f°, %.2f°",
                                coord.latitude, coord.longitude))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("Stop") { location.stop() }
                        .buttonStyle(.link)
                }
            case .denied:
                VStack(alignment: .leading, spacing: 4) {
                    Text(PlatformSystem.locationDeniedHint)
                        .foregroundStyle(.orange)
                    Button("Open Location Settings") {
                        location.openLocationSettings()
                    }
                    .buttonStyle(.link)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Text(message)
                        .foregroundStyle(.orange)
                    Button("Try again") { location.request() }
                        .buttonStyle(.link)
                }
            }
        }
        .font(.callout)
    }

    private var siteControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            locationRow
            Divider()
            HStack {
                Text("Lat")
                Spacer()
                Stepper(value: $store.settings.lat, in: -90...90, step: 0.1) {
                    Text(String(format: "%.2f°", store.settings.lat))
                        .monospacedDigit()
                }
                .disabled(location.isFollowing)
            }
            HStack {
                Text("Lon")
                Spacer()
                Stepper(value: $store.settings.lon, in: -180...180, step: 0.1) {
                    Text(String(format: "%.2f°", store.settings.lon))
                        .monospacedDigit()
                }
                .disabled(location.isFollowing)
            }
            HStack {
                Text("Min alt")
                Spacer()
                Slider(value: $store.settings.minAlt, in: 20...45, step: 1)
                    .frame(width: 110)
                Text(Fmt.deg(store.settings.minAlt))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            if !horizonStore.profile.isEmpty {
                Text("Horizon profile active — the slider is the fallback " +
                     "where the profile has no survey.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Show")
                Spacer()
                Picker("Show", selection: $store.settings.limit) {
                    Text("20").tag(20)
                    Text("40").tag(40)
                    Text("80").tag(80)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }
            Divider()
            rigControls
            Divider()
            HorizonEditor(horizon: horizonStore)
            Divider()
            Toggle("Window reminders", isOn: $notifications.masterEnabled)
            if notifications.masterEnabled {
                Text(notifications.isAuthorized
                    ? "Tap the bell in a target's detail view to opt in — " +
                      "you'll be notified 30 min before its window opens."
                    : "Tap a target's bell to request notification permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Remind me at astronomical dusk",
                       isOn: $notifications.duskEnabled)
                    .font(.callout)
                Toggle("Notify me of bright satellite passes",
                       isOn: $notifications.satellitesEnabled)
                    .font(.callout)
            }
            Button("Reset to \(SiteSettings.siteName)") {
                location.stop()
                store.settings = SiteSettings()
            }
            .buttonStyle(.link)
            Divider()
            Toggle("Use °F", isOn: $useFahrenheit)
            Button {
                showImporter = true
            } label: {
                Label("Import targets (CSV)", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.link)
            .help("Import your own targets from a CSV file " +
                  "(headers: name, ra, dec in decimal degrees)")
            if !store.customObjects.isEmpty {
                DisclosureGroup(
                    "Custom targets (\(store.customObjects.count))")
                {
                    ForEach(store.customObjects) { obj in
                        HStack {
                            Text(obj.name)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                store.removeCustomObject(id: obj.id)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete \(obj.name)")
                        }
                        .font(.callout)
                    }
                }
            }
            Link(destination: URL(string:
                "https://github.com/Skeleten80/astro-tonight/issues")!)
            {
                Label("Support & feedback", systemImage: "questionmark.circle")
            }
            .font(.callout)
            Text("24 h window centred on now · 10-min steps")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private var rigControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Rig")
                Spacer()
                Picker("Rig", selection: $rigStore.selectedID) {
                    ForEach(rigStore.presets) { p in
                        Text(p.name).tag(p.id)
                    }
                }
                .labelsHidden()
                .frame(width: 210)
            }
            Text(rigStore.selected.specLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            HStack {
                Text("Trail tolerance")
                    .foregroundStyle(.secondary)
                Spacer()
                Slider(value: $trailTolerancePx, in: 1...5, step: 0.5)
                    .frame(width: 120)
                Text("\(String(format: "%.1f", trailTolerancePx)) px")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            .font(.callout)
            .help("Corner-trailing tolerance for the max-sub recommendation " +
                  "in each target's detail view.")
            if rigStore.selectedIsCustom {
                Button("Delete this preset") {
                    rigStore.deleteSelectedCustom()
                }
                .buttonStyle(.link)
                .foregroundStyle(.red)
            }
            DisclosureGroup("Add custom rig") {
                RigCustomForm(rigStore: rigStore)
            }
        }
    }

    private var moonChip: some View {
        Group {
            if let moon = store.moon {
                Label(
                    String(format: "%.0f%% · %@", moon.illumination * 100,
                           AstroMath.moonPhaseName(
                            illumination: moon.illumination,
                            waxing: moon.waxing)),
                    systemImage: "moon.stars")
                    .help("Lunar illumination right now")
            }
        }
    }

    // MARK: - Moonrise/moonset + best dark stretch

    /// The moon's rise/set crossings nearest to now (low-precision
    /// model, ±1° — times good to ~±10 min).
    private var moonEvents: (rise: Date?, set: Date?) {
        AstroMath.moonRiseSet(lat: store.settings.lat,
                              lon: store.settings.lon,
                              now: store.now)
    }

    /// Longest stretch that is both astronomically dark and moonless.
    private var bestDarkStretch: Planning.ImagingWindow? {
        Planning.bestDarkStretch(lat: store.settings.lat,
                                 lon: store.settings.lon,
                                 now: store.now)
    }

    private var moonRiseSetText: String {
        let ev = moonEvents
        switch (ev.rise, ev.set) {
        case let (r?, s?):
            return "Moonrise \(Fmt.time.string(from: r)) · " +
                "Moonset \(Fmt.time.string(from: s))"
        case let (r?, nil):
            return "Moonrise \(Fmt.time.string(from: r))"
        case let (nil, s?):
            return "Moonset \(Fmt.time.string(from: s))"
        case (nil, nil):
            let jd = AstroMath.julianDate(store.now)
            let alt = AstroMath.moonAltitude(
                julianDate: jd, lat: store.settings.lat,
                lon: store.settings.lon)
            return alt > 0 ? "Moon up all night" : "Moon down all night"
        }
    }

    // MARK: - Filtering

    private var filtered: [RankedTarget] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let base = store.targets.filter { target in
            if listOnly && !store.savedIDs.contains(target.id) { return false }
            if hideImaged && sessions.dateImaged(for: target.id) != nil {
                return false
            }
            let kindOK: Bool
            if kind == .custom {
                kindOK = target.object.isCustom
            } else {
                kindOK = kind == .all
                    || ObjectKind.of(target.object.type) == kind
            }
            guard kindOK else { return false }
            guard !q.isEmpty else { return true }
            if target.object.name.lowercased().contains(q) { return true }
            return target.object.ids.contains {
                $0.lowercased().contains(q)
            }
        }
        // Rank mode keeps the ranker's order exactly; the others re-sort.
        switch sortMode {
        case .rank:
            return base
        case .peakTime:
            return base.sorted { $0.peakTime < $1.peakTime }
        case .name:
            return base.sorted {
                $0.object.name.localizedStandardCompare($1.object.name)
                    == .orderedAscending
            }
        case .windowOpens:
            var windows = [String: Planning.ImagingWindow]()
            for t in base {
                windows[t.id] = Planning.imagingWindow(
                    object: t.object,
                    lat: store.settings.lat, lon: store.settings.lon,
                    minAlt: store.settings.minAlt,
                    now: store.now,
                    horizon: store.horizonProfile)
            }
            return base.sorted { a, b in
                switch (windows[a.id], windows[b.id]) {
                case let (x?, y?): return x.start < y.start
                case (_?, nil): return true
                case (nil, _?): return false
                default: return false
                }
            }
        }
    }

    // MARK: - Cloud cover

    private var cloudStrip: some View {
        Group {
            switch weather.state {
            case .idle, .loading:
                Text("Cloud —")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed:
                Text("Cloud forecast unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .ready:
                let hours = upcomingCloud
                if hours.isEmpty {
                    Text("Cloud —")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "cloud")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ForEach(hours, id: \.date) { h in
                            VStack(spacing: 1) {
                                Text(Fmt.hour24.string(from: h.date))
                                Text("\(Int(h.cover))%")
                                    .foregroundStyle(cloudColor(h.cover))
                            }
                            .font(.caption2)
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    /// Current hour + the next 6, from the cached Open-Meteo forecast.
    private var upcomingCloud: [WeatherService.HourSample] {
        guard case .ready(let hours) = weather.state else { return [] }
        let from = store.now.addingTimeInterval(-1800)
        return Array(hours.filter { $0.date >= from }.prefix(7))
    }

    private func cloudColor(_ cover: Double) -> Color {
        if cover < 30 { return .green }
        if cover < 70 { return .orange }
        return .red
    }

    // MARK: - Seeing forecast (7Timer)

    /// The 7Timer sample nearest now, or nil when the forecast isn't in.
    private var currentSeeing: WeatherService.SeeingSample? {
        guard let samples = seeingSamples else { return nil }
        return Planning.seeing(at: store.now, in: samples)
    }

    private var seeingRow: some View {
        Group {
            switch weather.seeingState {
            case .idle, .loading:
                Text("Seeing —")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed:
                Text("Seeing forecast unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .ready:
                if let s = currentSeeing {
                    HStack(spacing: 6) {
                        Image(systemName: "eye")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Seeing \(s.seeing) · " +
                             "\(WeatherService.seeingLabel(s.seeing))")
                            .foregroundStyle(seeingColor(s.seeing))
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text("Transparency \(s.transparency)/8")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .monospacedDigit()
                } else {
                    Text("Seeing —")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .help("7Timer astro forecast: seeing 1–8 (lower is better), " +
              "transparency 1–8 (higher is better). Coarse model, not a " +
              "measurement.")
    }

    private func seeingColor(_ seeing: Int) -> Color {
        if seeing <= 2 { return .green }
        if seeing <= 5 { return .orange }
        return .red
    }

    // MARK: - Dew-point spread (Open-Meteo)

    /// Cached dew-spread samples, if the weather service has them.
    private var dewSamples: [WeatherService.DewSample]? {
        if case .ready(let samples) = weather.dewState { return samples }
        return nil
    }

    /// The dew-spread sample nearest now, or nil when the forecast isn't
    /// in (nil = no sample within 90 minutes).
    private var currentDew: WeatherService.DewSample? {
        guard let samples = dewSamples else { return nil }
        let nearest = samples.min(by: {
            abs($0.date.timeIntervalSince(store.now))
                < abs($1.date.timeIntervalSince(store.now))
        })
        guard let n = nearest,
              abs(n.date.timeIntervalSince(store.now)) <= 5400
        else { return nil }
        return n
    }

    private var dewRow: some View {
        Group {
            switch weather.dewState {
            case .idle, .loading:
                Text("Dew spread —")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed:
                Text("Dew forecast unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .ready:
                if let d = currentDew {
                    HStack(spacing: 6) {
                        Image(systemName: "drop")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Dew spread " +
                             Fmt.temperature(d.spread,
                                             fahrenheit: useFahrenheit))
                            .foregroundStyle(dewColor(d.spread))
                        if d.spread < 1.5 {
                            Text("· heater on")
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.caption)
                    .monospacedDigit()
                } else {
                    Text("Dew spread —")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .help("Temperature minus dew point (Open-Meteo forecast). Under " +
              "about \(Fmt.temperature(1.5, fahrenheit: useFahrenheit)) " +
              "the SCT corrector plate will dew up — run the heater.")
    }

    private func dewColor(_ spread: Double) -> Color {
        if spread < 1.5 { return .red }
        if spread < 3 { return .orange }
        return .green
    }

    // MARK: - Wind (7Timer, Open-Meteo fallback)

    /// Wind right now: 7Timer's wind10m first, else the nearest
    /// Open-Meteo hour sample. Thresholds are heuristic — an SCT on an
    /// alt-az mount starts to feel gusts well before 30 km/h.
    private var currentWind: (kmh: Double, direction: String?)? {
        if let s = currentSeeing, let w = s.windKmh {
            return (w, s.windDirection)
        }
        if case .ready(let hours) = weather.state {
            let nearest = hours.min(by: {
                abs($0.date.timeIntervalSince(store.now))
                    < abs($1.date.timeIntervalSince(store.now))
            })
            if let n = nearest,
               abs(n.date.timeIntervalSince(store.now)) <= 5400,
               let w = n.windKmh
            {
                return (w, nil)
            }
        }
        return nil
    }

    private var windRow: some View {
        Group {
            if let w = currentWind {
                HStack(spacing: 6) {
                    Image(systemName: "wind")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Wind \(Int(w.kmh)) km/h" +
                         (w.direction.map { " \($0)" } ?? ""))
                        .foregroundStyle(windColor(w.kmh))
                }
                .font(.caption)
                .monospacedDigit()
                .help("Wind at 10 m (7Timer forecast, Open-Meteo fallback). " +
                      "Gusts shake an SCT — orange means think twice.")
            } else {
                Text("Wind —")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func windColor(_ kmh: Double) -> Color {
        if kmh < 15 { return .green }
        if kmh < 30 { return .orange }
        return .red
    }

    private func copyToClipboard(_ s: String) {
        PlatformPasteboard.copy(s)
    }

    private func addChecklistItem() {
        checklist.add(title: checklistDraft)
        checklistDraft = ""
    }

    /// CSV import result → user-facing alert. `addCustomObjects`
    /// re-ranks, so imported targets appear immediately.
    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let access = url.startAccessingSecurityScopedResource()
            defer {
                if access { url.stopAccessingSecurityScopedResource() }
            }
            guard let text = try? String(contentsOf: url,
                                          encoding: .utf8)
            else {
                importAlert = ImportAlert(
                    message: "Couldn't read that file as text.")
                return
            }
            let r = CSVImport.parse(text)
            if !r.imported.isEmpty { store.addCustomObjects(r.imported) }
            if r.imported.isEmpty && r.skipped == 0 {
                importAlert = ImportAlert(message:
                    "No targets found — the CSV needs headers: name, ra, " +
                    "dec (decimal degrees).")
            } else {
                importAlert = ImportAlert(message:
                    "\(r.imported.count) imported" +
                    (r.skipped > 0
                        ? ", \(r.skipped) skipped (bad rows — check RA/Dec " +
                          "are decimal degrees)"
                        : "") + ".")
            }
        case .failure:
            break // user cancelled
        }
    }
}

// MARK: - Row

struct TargetRow: View {
    let target: RankedTarget
    let altNow: Double
    /// Per-target minimum: surveyed horizon at the current azimuth when
    /// one exists, else the flat slider value.
    let threshold: Double
    let isSaved: Bool
    let imagedDate: Date?
    let onToggleSave: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(target.object.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button(action: onToggleSave) {
                    Image(systemName: isSaved ? "star.fill" : "star")
                        .foregroundStyle(isSaved ? .yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .help(isSaved ? "Remove from observing list"
                              : "Add to observing list")
                .accessibilityLabel(isSaved
                    ? "Remove from observing list"
                    : "Add to observing list")
                nowBadge
                if let d = imagedDate {
                    Text("✓ \(Fmt.dayMonth.string(from: d))")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            Text(target.object.ids.first ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 8) {
                kindChip
                Text("mag \(Fmt.mag(target.object.mag))")
                Spacer()
                Text("peak \(Fmt.deg(target.peakAlt))")
                Text("·")
                Text(Fmt.hours(target.hoursAbove))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(.vertical, 3)
        #if os(macOS)
        .onHover { hovering = $0 }
        #endif
        .scaleEffect(hovering ? 1.015 : 1)
        .brightness(hovering ? 0.07 : 0)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var kindChip: some View {
        let k = ObjectKind.of(target.object.type)
        return Text(k == .all ? target.object.type : shortKind(k))
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(kindColor(k).opacity(0.18))
            .foregroundStyle(kindColor(k))
            .clipShape(Capsule())
    }

    private func shortKind(_ k: ObjectKind) -> String {
        switch k {
        case .all: return "all"
        case .galaxy: return "galaxy"
        case .nebula: return "nebula"
        case .cluster: return "cluster"
        case .other: return "other"
        case .custom: return "custom"
        }
    }

    private func kindColor(_ k: ObjectKind) -> Color {
        switch k {
        case .all: return .gray
        case .galaxy: return .blue
        case .nebula: return .purple
        case .cluster: return .orange
        case .other: return .gray
        case .custom: return .teal
        }
    }

    private var nowBadge: some View {
        let (text, color): (String, Color) =
            altNow >= threshold ? ("up now", .green)
            : altNow >= 0 ? ("low", .orange)
            : ("down", .secondary)
        return Text("\(text) · \(Fmt.deg(altNow))")
            .font(.caption2)
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - Horizon editor

/// Numeric survey of the real horizon: azimuth/altitude rows with
/// steppers, add/remove, and reset-to-flat. Points are linearly
/// interpolated around the compass by `HorizonProfile`.
struct HorizonEditor: View {
    @ObservedObject var horizon: HorizonStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Horizon profile")
                Spacer()
                if !horizon.profile.points.isEmpty {
                    Button("Reset to flat") { horizon.clear() }
                        .buttonStyle(.link)
                }
            }
            if horizon.profile.points.isEmpty {
                Text("Flat — the min-altitude slider above applies everywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach($horizon.profile.points) { $point in
                    HStack(spacing: 6) {
                        Text("Az")
                        Stepper(value: $point.azimuth, in: 0...360, step: 5) {
                            Text("\(Int(point.azimuth))°")
                                .monospacedDigit()
                                .frame(width: 46, alignment: .trailing)
                        }
                        Text("Alt")
                        Stepper(value: $point.altitude, in: 0...80, step: 1) {
                            Text("\(Int(point.altitude))°")
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                        Spacer()
                        Button {
                            horizon.remove($point.wrappedValue)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this point")
                        .accessibilityLabel("Remove this horizon point")
                    }
                    .font(.callout)
                }
            }
            Button {
                horizon.addPoint()
            } label: {
                Label("Add horizon point", systemImage: "plus")
            }
            .buttonStyle(.link)
            Text("Stand where the scope sits, note the compass azimuth and " +
                 "the altitude where the sky opens up (trees, roof…). " +
                 "Empty = flat minimum.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Custom rig form

/// Number fields for a user-defined rig preset.
struct RigCustomForm: View {
    @ObservedObject var rigStore: RigStore
    @State private var name = ""
    @State private var focalLength = 1500.0
    @State private var focalRatio = 10.0
    @State private var sensorW = 22.3
    @State private var sensorH = 14.9
    @State private var pixel = 3.72

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name (e.g. 6SE + ASI533MC)", text: $name)
                .textFieldStyle(.roundedBorder)
            numberRow("Focal length", $focalLength, "mm")
            numberRow("Focal ratio", $focalRatio, "f/")
            numberRow("Sensor width", $sensorW, "mm")
            numberRow("Sensor height", $sensorH, "mm")
            numberRow("Pixel size", $pixel, "µm")
            Button("Add preset") {
                let trimmed = name.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                rigStore.addCustom(RigPreset(
                    id: UUID().uuidString,
                    name: trimmed.isEmpty ? "Custom rig" : trimmed,
                    focalLengthMM: focalLength,
                    focalRatio: focalRatio,
                    sensorWidthMM: sensorW,
                    sensorHeightMM: sensorH,
                    pixelMicrons: pixel,
                    isBuiltin: false))
                name = ""
            }
            .buttonStyle(.link)
            .disabled(focalLength <= 0 || sensorW <= 0
                        || sensorH <= 0 || pixel <= 0)
        }
        .padding(.top, 4)
    }

    private func numberRow(_ label: String, _ value: Binding<Double>,
                           _ unit: String) -> some View
    {
        HStack {
            Text(label)
            Spacer()
            TextField(label, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
                .multilineTextAlignment(.trailing)
            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
        }
    }
}

// MARK: - Month moon planner

/// 30-day moon-illumination strip for planning around new moon. Pure
/// AstroMath (the same illumination function behind the toolbar chip) —
/// no networking, effectively instant.
struct MoonMonthView: View {
    let now: Date

    private struct DayMoon: Hashable {
        let date: Date
        let illumination: Double
    }

    private static let dayNumber: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f
    }()

    private var days: [DayMoon] {
        (0..<30).map { d in
            let date = Calendar.current.startOfDay(for: now)
                .addingTimeInterval(Double(d) * 86400 + 12 * 3600)
            let illum = AstroMath.moonIllumination(
                julianDate: AstroMath.julianDate(date)).fraction
            return DayMoon(date: date, illumination: illum)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Moon · next 30 days")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(days, id: \.date) { day in
                        VStack(spacing: 3) {
                            // Phase dot: dark at new moon, bright at full.
                            Circle()
                                .fill(Color.white.opacity(
                                    0.12 + 0.88 * day.illumination))
                                .frame(width: 14, height: 14)
                                .overlay(Circle().stroke(
                                    Color.secondary.opacity(0.4),
                                    lineWidth: 0.5))
                            Text("\(Int(day.illumination * 100))%")
                                .foregroundStyle(day.illumination < 0.25
                                    ? .green : .secondary)
                            Text(Self.dayNumber.string(from: day.date))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption2)
                        .monospacedDigit()
                        .accessibilityLabel(
                            "\(Fmt.weekday.string(from: day.date)): " +
                            "\(Int(day.illumination * 100))% illuminated")
                    }
                }
                .padding(.vertical, 2)
            }
            Text("Green % = dark nights (< 25% illuminated) — plan " +
                 "broadband targets there.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
