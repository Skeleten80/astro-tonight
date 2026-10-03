import AppKit
import SwiftUI

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

// MARK: - Main view

struct ContentView: View {
    @StateObject private var store = TargetStore()
    @StateObject private var location = LocationProvider()
    @StateObject private var sessions = SessionStore()
    @StateObject private var weather = WeatherService()
    @AppStorage("AstroTonight.nightVision") private var nightVision = false
    @State private var selection: RankedTarget?
    @State private var searchText = ""
    @State private var kind: ObjectKind = .all
    @State private var listOnly = false
    @State private var hideImaged = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            StarfieldView()
            NavigationSplitView {
                sidebar
            } detail: {
                if let target = selection {
                    TargetDetailView(target: target, store: store,
                                     sessions: sessions)
                } else {
                    ContentUnavailableView(
                        "Select a target",
                        systemImage: "telescope",
                        description: Text("Ranked for your site — same ordering as `astrocapture tonight`."))
                }
            }
            .navigationTitle("Tonight's Targets")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    moonChip
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
            }
            .searchable(text: $searchText, placement: .sidebar,
                        prompt: "Search name or catalogue ID")
            .frame(minWidth: 960, minHeight: 620)
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
                                      minAlt: store.settings.minAlt,
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
                Picker("Type", selection: $kind) {
                    ForEach(ObjectKind.allCases) { k in
                        Text(k.rawValue).tag(k)
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
                    .font(.callout)
                    .help("Copy the observing list as an AstroCapture " +
                          "multi-target night plan")
                    .disabled(store.savedIDs.isEmpty)
                }

                if let ds = store.darkStart, let de = store.darkEnd {
                    Text("Dark \(Fmt.time.string(from: ds)) → " +
                         "\(Fmt.time.string(from: de)) · " +
                         Fmt.hours(de.timeIntervalSince(ds) / 3600))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                cloudStrip

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
                             sessions: sessions)
        }
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
                .help("Set the site from this Mac's location services")
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
                    Text("Location access denied — set the site manually, " +
                         "or allow it in System Settings.")
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
            Button("Reset to \(SiteSettings.siteName)") {
                location.stop()
                store.settings = SiteSettings()
            }
            .buttonStyle(.link)
            Text("24 h window centred on now · 10-min steps")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private var moonChip: some View {
        Group {
            if let moon = store.moon {
                Label(
                    String(format: "%.0f%% %@", moon.illumination * 100,
                           moon.waxing ? "waxing" : "waning"),
                    systemImage: "moon.stars")
                    .help("Lunar illumination right now")
            }
        }
    }

    // MARK: - Filtering

    private var filtered: [RankedTarget] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return store.targets.filter { target in
            if listOnly && !store.savedIDs.contains(target.id) { return false }
            if hideImaged && sessions.dateImaged(for: target.id) != nil {
                return false
            }
            let kindOK = kind == .all
                || ObjectKind.of(target.object.type) == kind
            guard kindOK else { return false }
            guard !q.isEmpty else { return true }
            if target.object.name.lowercased().contains(q) { return true }
            return target.object.ids.contains {
                $0.lowercased().contains(q)
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

    private func copyToClipboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
}

// MARK: - Row

struct TargetRow: View {
    let target: RankedTarget
    let altNow: Double
    let minAlt: Double
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
        .onHover { hovering = $0 }
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
        }
    }

    private func kindColor(_ k: ObjectKind) -> Color {
        switch k {
        case .all: return .gray
        case .galaxy: return .blue
        case .nebula: return .purple
        case .cluster: return .orange
        case .other: return .gray
        }
    }

    private var nowBadge: some View {
        let (text, color): (String, Color) =
            altNow >= minAlt ? ("up now", .green)
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
