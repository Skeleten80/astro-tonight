import SwiftUI

/// First-run setup: location → rig → minimum altitude → what's new.
/// Presented once via `.sheet` from ContentView, gated by
/// `AstroTonight.didOnboard`. Existing installs see it once too (the flag
/// is new); "Skip" keeps the current defaults, so nobody is stranded by it.
struct OnboardingView: View {
    @ObservedObject var store: TargetStore
    @ObservedObject var location: LocationProvider
    @ObservedObject var rigStore: RigStore
    @Binding var didOnboard: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0

    var body: some View {
        ZStack {
            StarfieldView()
            VStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text("Welcome to AstroTonight")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(step == 3 ? "And what's new."
                                       : "Three quick steps to tune it to your sky.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
                stepDots
                Group {
                    switch step {
                    case 0: locationStep
                    case 1: rigStep
                    case 2: minAltStep
                    default: featuresStep
                    }
                }
                .padding(16)
                .glassPanel(radius: 12)
                Spacer()
                navButtons
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
    }

    private var stepDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<4) { i in
                Circle()
                    .fill(i == step ? Color.accentColor
                                    : Color.secondary.opacity(0.35))
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityLabel("Step \(step + 1) of 4")
    }

    // MARK: - Steps

    private var locationStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where are you observing from?")
                .font(.headline)
            Group {
                switch location.state {
                case .idle:
                    Button {
                        location.request()
                    } label: {
                        Label("Use my location", systemImage: "location.fill")
                    }
                    .buttonStyle(.borderedProminent)
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
                    Text(PlatformSystem.locationDeniedHint)
                        .foregroundStyle(.orange)
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message)
                            .foregroundStyle(.orange)
                        Button("Try again") { location.request() }
                            .buttonStyle(.link)
                    }
                }
            }
            Divider()
            Text("Or set it manually:")
                .foregroundStyle(.secondary)
            HStack {
                Text("Latitude")
                Spacer()
                Stepper(value: $store.settings.lat, in: -90...90,
                        step: 0.1)
                {
                    Text(String(format: "%.2f°", store.settings.lat))
                        .monospacedDigit()
                }
                .disabled(location.isFollowing)
            }
            HStack {
                Text("Longitude")
                Spacer()
                Stepper(value: $store.settings.lon, in: -180...180,
                        step: 0.1)
                {
                    Text(String(format: "%.2f°", store.settings.lon))
                        .monospacedDigit()
                }
                .disabled(location.isFollowing)
            }
        }
        .font(.callout)
    }

    private var rigStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What's your rig?")
                .font(.headline)
            Text("The framing check compares each target against your " +
                 "telescope and camera.")
                .foregroundStyle(.secondary)
            Picker("Rig", selection: $rigStore.selectedID) {
                ForEach(rigStore.presets) { p in
                    Text(p.name).tag(p.id)
                }
            }
            .labelsHidden()
            Text(rigStore.selected.specLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text("You can add custom rigs later in Site settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private var minAltStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How low will you image?")
                .font(.headline)
            Text("Targets are ranked by their time above this altitude. " +
                 "30° is a good default — go lower if your horizon is clear.")
                .foregroundStyle(.secondary)
            HStack {
                Slider(value: $store.settings.minAlt, in: 20...45, step: 1)
                Text(Fmt.deg(store.settings.minAlt))
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            Text("You can survey your real horizon later in Site settings " +
                 "— then this slider is only the fallback.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    // MARK: - Navigation

    private var featuresStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What's new")
                .font(.headline)
            Text("Five recent additions, all a tap away in the toolbar.")
                .foregroundStyle(.secondary)
            featureRow(systemImage: "star.circle",
                       title: "Interactive sky chart",
                       detail: "1.46M-star planetarium chart, pan/zoom")
            featureRow(systemImage: "telescope",
                       title: "Tap-to-slew",
                       detail: "Slew the 6SE from any target via ScopePilot")
            featureRow(systemImage: "books.vertical",
                       title: "Full NGC/IC catalog",
                       detail: "12,823 objects, same ranking")
            featureRow(systemImage: "antenna.radiowaves.left.and.right",
                       title: "Satellite passes",
                       detail: "ISS and bright-satellite predictions")
            featureRow(systemImage: "sparkles",
                       title: "Comet ephemerides",
                       detail: "Bright comets with staleness badges")
        }
        .font(.callout)
    }

    private func featureRow(systemImage: String, title: String,
                            detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 24)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var navButtons: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
                    .buttonStyle(.link)
            }
            Spacer()
            Button("Skip") { finish() }
                .buttonStyle(.link)
                .foregroundStyle(.secondary)
            Button(step == 3 ? "Get started" : "Next") {
                if step == 3 { finish() } else { step += 1 }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func finish() {
        didOnboard = true
        dismiss()
    }
}
