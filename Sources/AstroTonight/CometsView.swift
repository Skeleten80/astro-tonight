import SwiftUI
import Combine

/// Live comet list: current RA/Dec from the Kepler solver, an
/// approximate magnitude estimate, and — shown PROMINENTLY — the age
/// of each object's element epoch.
///
/// The STALE banner appears when the oldest elements in the list exceed
/// `MinorBodyService.staleThresholdDays` (30 d). Rationale, documented
/// in `MinorBodies.swift`: the MPC refreshes comet elements roughly
/// monthly, and the build-VM validation showed even 1-day-old elements
/// can already be 34" off JPL's fit near perihelion (161P), while
/// 341-day-old 3I/ATLAS elements were 151" off. Beyond one MPC element
/// cycle the positions are not trustworthy for finding.
struct CometsView: View {
    @StateObject private var service = MinorBodyService()
    @State private var now = Date()

    private let tick = Timer.publish(every: 60, on: .main,
                                     in: .common).autoconnect()

    var body: some View {
        List {
            if service.isStale {
                Section {
                    Label {
                        Text(staleBannerText)
                            .font(.headline)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.red)
                    Text("Comet orbits decay quickly — planetary "
                         + "perturbations and outgassing, worst near "
                         + "perihelion. Refresh when online for fresh "
                         + "MPC elements.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(service.comets) { comet in
                    cometRow(comet)
                }
            } header: {
                Text("Comets · \(service.comets.count) objects")
            } footer: {
                provenanceText
            }

            if let err = service.lastError {
                Section {
                    Label(err, systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Comets")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await service.refreshFromNetwork() }
                } label: {
                    if service.isRefreshing {
                        ProgressView()
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(service.isRefreshing)
            }
        }
        .onReceive(tick) { value in
            now = value
        }
    }

    // MARK: Rows

    private func cometRow(_ comet: CometElements) -> some View {
        let pos = MinorBodies.position(of: comet, at: now)
        let age = service.ageDays(of: comet)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(comet.name)
                    .font(.headline)
                Spacer()
                ageChip(days: age)
            }
            HStack(spacing: 12) {
                Text("RA \(AstroMath.raToHMS(pos.ra))")
                Text("Dec \(AstroMath.decToDMS(pos.dec))")
            }
            .font(.subheadline)
            .monospacedDigit()
            HStack {
                if let m = pos.mag {
                    Text("mag ~\(String(format: "%.1f", m))")
                } else {
                    Text("mag —")
                }
                Text("·")
                Text("elements \(ageText(days: age)) old")
                    .fontWeight(.semibold)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// Per-object epoch age, impossible to miss: colored chip plus the
    /// plain-language age in the row below it.
    private func ageChip(days: Double) -> some View {
        let color: Color = days > MinorBodyService.staleThresholdDays
            ? .red : (days > 7 ? .orange : .green)
        return Text(ageText(days: days))
            .font(.caption)
            .fontWeight(.bold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func ageText(days: Double) -> String {
        if days < 1 {
            return "today"
        } else if days < 2 {
            return "1 day"
        } else {
            return "\(Int(days)) days"
        }
    }

    private var staleBannerText: String {
        if let age = service.epochAgeDays {
            return "STALE — elements \(Int(age)) days old, "
                + "positions unreliable"
        } else {
            return "STALE — element ages unknown, positions unreliable"
        }
    }

    private var provenanceText: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let stamp = service.fetchedUTC {
                Text("Elements fetched \(stamp).")
            }
            Text("Source: Minor Planet Center Soft03Cmt.txt. "
                 + "Magnitudes are H/G estimates — comets outburst.")
        }
        .font(.caption)
    }
}
