import SwiftUI

/// Upcoming satellite passes. The coordinator presents this in a sheet.
/// Standard SwiftUI views only, so the app's night-vision red overlay
/// covers it automatically.
struct SatellitePassesView: View {
    @ObservedObject var tracker: SatelliteTracker
    var latitude: Double
    var longitude: Double

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    var body: some View {
        Group {
            if !tracker.hasData {
                ContentUnavailableView {
                    Label("No satellite data",
                          systemImage: "antenna.radiowaves.left.and.right.slash")
                } description: {
                    Text("The bundled TLE snapshot is missing and the " +
                         "network refresh failed. Connect and try again.")
                } actions: {
                    Button("Try Again") {
                        Task { await refresh() }
                    }
                }
            } else if tracker.passes.isEmpty && tracker.isComputing {
                ProgressView("Predicting passes…")
            } else if tracker.passes.isEmpty {
                ContentUnavailableView {
                    Label("No bright passes", systemImage: "moon.stars")
                } description: {
                    Text("No passes above 10° in the next 48 hours.")
                }
            } else {
                List {
                    Text(tleAgeLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let err = tracker.lastRefreshError {
                        Text("Couldn't refresh: \(err) — using saved TLEs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(tracker.passes) { pass in
                        passRow(pass)
                    }
                }
            }
        }
        .navigationTitle("Satellite Passes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(tracker.isComputing)
            }
        }
        .task {
            await tracker.predictPasses(latitude: latitude,
                                        longitude: longitude)
        }
    }

    /// Honest TLE-age banner: "TLEs 3 days old — predictions degrade
    /// with age".
    private var tleAgeLine: String {
        let count = "\(tracker.satelliteCount) satellites"
        guard let age = tracker.tleAgeDays else {
            return "\(count) · TLE age unknown"
        }
        if age < 1 {
            return "\(count) · TLEs less than a day old"
        }
        let d = Int(age)
        let dayWord = d == 1 ? "day" : "days"
        return "\(count) · TLEs \(d) \(dayWord) old — predictions degrade with age"
    }

    private func passRow(_ pass: SatellitePass) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pass.name)
                    .font(.headline)
                Text(timeRange(pass))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Max elevation \(Int(pass.maxElevation.rounded()))°")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            visibilityBadge(pass)
        }
        .padding(.vertical, 2)
    }

    private func timeRange(_ pass: SatellitePass) -> String {
        let rise = Self.timeFormatter.string(from: pass.rise)
        let set = Self.timeFormatter.string(from: pass.set)
        if Calendar.current.isDate(pass.rise, inSameDayAs: Date()) {
            return "\(rise) – \(set)"
        }
        let day = Self.dayFormatter.string(from: pass.rise)
        return "\(day), \(rise) – \(set)"
    }

    @ViewBuilder
    private func visibilityBadge(_ pass: SatellitePass) -> some View {
        if pass.visible {
            Label("Visible", systemImage: "eye")
                .font(.caption)
                .foregroundStyle(.green)
        } else if pass.daylight {
            Label("Daylight", systemImage: "sun.max")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("Eclipsed", systemImage: "moon")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func refresh() async {
        await tracker.refreshFromNetwork()
        await tracker.predictPasses(latitude: latitude, longitude: longitude)
    }
}
