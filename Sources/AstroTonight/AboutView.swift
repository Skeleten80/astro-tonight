import SwiftUI

/// About sheet: app identity, data-source attributions (including the
/// legally-required OpenNGC CC-BY-SA-4.0 credit), and honest caveats.
/// Presented from a toolbar button in ContentView (see the integration
/// snippet — coordinator-owned, wired there, not here).
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let raw = info?["CFBundleShortVersionString"] as? String
        return raw ?? "—"
    }

    var body: some View {
        ZStack {
            StarfieldView()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    dataSources
                    caveats
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("AstroTonight")
                    .font(.title)
                    .fontWeight(.semibold)
                Text("Version \(appVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text("What's worth imaging tonight.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Data sources

    private var dataSources: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Data sources")
                .font(.headline)
            sourceRow(name: "OpenNGC",
                      detail: "NGC/IC catalog, CC-BY-SA-4.0 — " +
                              "attribution is legally required",
                      url: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/"),
                      linkLabel: "License")
            sourceRow(name: "Tycho-2",
                      detail: "Star catalog, public domain",
                      url: URL(string: "https://www.cosmos.esa.int/web/hipparcos/tycho-2"),
                      linkLabel: "Catalog")
            sourceRow(name: "CelesTrak",
                      detail: "Satellite TLEs",
                      url: URL(string: "https://celestrak.org"),
                      linkLabel: "Site")
            sourceRow(name: "Minor Planet Center",
                      detail: "Comet orbital elements",
                      url: URL(string: "https://www.minorplanetcenter.net"),
                      linkLabel: "Site")
            sourceRow(name: "Open-Meteo",
                      detail: "Cloud forecast",
                      url: URL(string: "https://open-meteo.com"),
                      linkLabel: "Site")
            sourceRow(name: "7Timer!",
                      detail: "Seeing forecast",
                      url: URL(string: "http://www.7timer.info"),
                      linkLabel: "Site")
            sourceRow(name: "NASA SkyView",
                      detail: "DSS2 Red thumbnails",
                      url: URL(string: "https://skyview.gsfc.nasa.gov"),
                      linkLabel: "Site")
        }
        .font(.callout)
        .padding(16)
        .glassPanel(radius: 12)
    }

    private func sourceRow(name: String, detail: String, url: URL?,
                           linkLabel: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let url {
                Link(linkLabel, destination: url)
                    .font(.caption)
            }
        }
    }

    // MARK: - Honest caveats

    private var caveats: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Honest caveats")
                .font(.headline)
            caveat("Coordinates are J2000, good to about ±0.5°.")
            caveat("The Moon model is low-precision: position ±1°, " +
                   "times ±10 min.")
            caveat("Cloud, seeing, dew, and wind are forecasts, " +
                   "not measurements.")
            caveat("DSS thumbnails and finder charts need an internet " +
                   "connection.")
            caveat("The max-sub recommendation covers field rotation only.")
            caveat("\"Slew succeeded\" means ScopePilot accepted the slew — " +
                   "fire-and-forget.")
            caveat("Notifications are scheduled while the app runs. " +
                   "There is no background refresh, so open the app in " +
                   "the evening.")
        }
        .font(.callout)
        .padding(16)
        .glassPanel(radius: 12)
    }

    private func caveat(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}
