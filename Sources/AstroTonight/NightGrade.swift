import SwiftUI

/// The graded answer to "is tonight worth setting up?".
struct GradeResult {
    /// "A" through "F".
    let letter: String
    /// 0…100 after all deductions.
    let score: Double
    /// Every factor, in order: the points lost (`delta`, negative or 0)
    /// with a plain-language label. Missing inputs appear here too,
    /// marked "pending", so the sheet behind the chip is a complete
    /// audit of the number — never a black box.
    let breakdown: [(label: String, delta: Double)]
}

/// "Tonight's grade" (A–F).
///
/// A single transparent number grading tonight for deep-sky imaging.
/// Score (higher is better) — deliberately simple and documented:
///   start  = 100
///   − cloud cover % × 0.8            (Open-Meteo, via
///                                     Planning.cloudCover(at:in:);
///                                     no penalty when nil)
///   − 5 × (seeing − 3), floored at 0 (7Timer, via
///                                     Planning.seeing(at:in:);
///                                     no penalty when nil — mirrors
///                                     Planning.topPick so the two
///                                     can't disagree about seeing)
///   − 30 × moon illumination when the Moon is < 40° from the top
///     pick, − 15 × illumination when < 90°, else 0
///     (separation unknown: assume the close-Moon band, noted)
///   − 5 × (4 − darkHours), floored at 0 (from TargetStore
///     darkStart/darkEnd; no penalty when nil)
/// The result is clamped to 0…100 and mapped: ≥90 A, ≥80 B, ≥65 C,
/// ≥50 D, else F. This is a heuristic, not a measurement — the
/// detail views carry the real numbers behind it.
enum NightGrade {
    /// Pure grading function over explicit optionals, so the formula is
    /// unit-testable without a store. Returns nil — the caller shows
    /// "—" — when there is nothing to grade: moon data AND both
    /// weather inputs are nil. Otherwise it grades with whatever is
    /// available and marks missing factors "pending" in the breakdown.
    static func grade(cloudCover: Double?,
                      seeing: Int?,
                      moonIllumination: Double?,
                      moonSeparation: Double?,
                      darkHours: Double?) -> GradeResult?
    {
        guard moonIllumination != nil || cloudCover != nil || seeing != nil
        else { return nil }

        var score = 100.0
        var breakdown = [(label: String, delta: Double)]()

        // Cloud.
        if let c = cloudCover {
            let loss = c * 0.8
            score -= loss
            breakdown.append((label: "Cloud cover \(pct(c))", delta: -loss))
        } else {
            breakdown.append((label: "Cloud — forecast pending", delta: 0))
        }

        // Seeing.
        if let s = seeing {
            let loss = 5.0 * max(0, Double(s) - 3.0)
            score -= loss
            breakdown.append((label: "Seeing \(s)/5 " +
                "(\(WeatherService.seeingLabel(s)))", delta: -loss))
        } else {
            breakdown.append((label: "Seeing — forecast pending", delta: 0))
        }

        // Moon. Choice of separation: the top pick's moonSep (see
        // GradeChipView) — the grade is about the target the observer
        // would actually image, not the whole sky.
        if let illum = moonIllumination {
            let loss: Double
            let where_: String
            if let sep = moonSeparation {
                if sep < 40 { loss = 30 * illum }
                else if sep < 90 { loss = 15 * illum }
                else { loss = 0 }
                where_ = "\(Int(sep.rounded()))° from top pick"
            } else {
                loss = 30 * illum
                where_ = "separation unknown — assumed close"
            }
            score -= loss
            let note = loss > 0 ? "" : " — no penalty"
            breakdown.append((label: "Moon \(pct(illum)) · \(where_)\(note)",
                              delta: -loss))
        } else {
            breakdown.append((label: "Moon — data pending", delta: 0))
        }

        // Dark window.
        if let h = darkHours {
            let loss = 5.0 * max(0, 4.0 - h)
            score -= loss
            breakdown.append((label: "Dark window " +
                String(format: "%.1fh", h), delta: -loss))
        } else {
            breakdown.append((label: "Dark window — unknown", delta: 0))
        }

        score = max(0, score)
        return GradeResult(letter: letter(for: score), score: score,
                           breakdown: breakdown)
    }

    /// Letter for a clamped score.
    static func letter(for score: Double) -> String {
        if score >= 90 { return "A" }
        if score >= 80 { return "B" }
        if score >= 65 { return "C" }
        if score >= 50 { return "D" }
        return "F"
    }

    /// Letter colors: A/B green, C yellow, D orange, F red.
    static func color(forLetter letter: String) -> Color {
        switch letter {
        case "A", "B": return .green
        case "C": return .yellow
        case "D": return .orange
        default: return .red
        }
    }

    /// "72%" for a 0…1 fraction, "72%" for a 0…100 percent value.
    private static func pct(_ x: Double) -> String {
        let v = x <= 1 ? x * 100 : x
        return String(format: "%.0f%%", v)
    }
}

/// Toolbar chip showing tonight's grade. Tapping opens a sheet with the
/// full deduction breakdown, so every point lost is accounted for.
///
/// Data wiring (same samples the hero card already uses):
/// - cloud: `Planning.cloudCover(at:now:in:)` over
///   `weather.state`'s `.ready` samples (nil when pending)
/// - seeing: `Planning.seeing(at:now:in:)` over
///   `weather.seeingState`'s `.ready` samples (nil when pending)
/// - moon: `store.moon.illumination`; the separation is the top pick's
///   `moonSep` — the target the observer would actually image tonight
/// - dark hours: `store.darkStart`/`darkEnd`
struct GradeChipView: View {
    @ObservedObject var store: TargetStore
    @ObservedObject var weather: WeatherService
    @State private var showSheet = false

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

    private var darkHours: Double? {
        guard let start = store.darkStart, let end = store.darkEnd
        else { return nil }
        return max(0, end.timeIntervalSince(start) / 3600)
    }

    private var gradeResult: GradeResult? {
        let cloud = cloudSamples
            .flatMap { Planning.cloudCover(at: store.now, in: $0) }
        let seeingValue = seeingSamples
            .flatMap { Planning.seeing(at: store.now, in: $0)?.seeing }
        let pick = Planning.topPick(
            ranked: store.targets,
            lat: store.settings.lat, lon: store.settings.lon,
            horizon: store.horizonProfile,
            minAlt: store.settings.minAlt,
            now: store.now,
            cloud: cloudSamples,
            seeing: seeingSamples)
        return NightGrade.grade(
            cloudCover: cloud,
            seeing: seeingValue,
            moonIllumination: store.moon?.illumination,
            moonSeparation: pick?.target.moonSep,
            darkHours: darkHours)
    }

    var body: some View {
        Button {
            showSheet = true
        } label: {
            Group {
                if let g = gradeResult {
                    Label("\(g.letter) · \(Int(g.score.rounded()))",
                          systemImage: "star.fill")
                        .foregroundStyle(
                            NightGrade.color(forLetter: g.letter))
                } else {
                    Label("—", systemImage: "star")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .help("Tonight's grade — tap for the full breakdown")
        .disabled(gradeResult == nil)
        .sheet(isPresented: $showSheet) {
            if let g = gradeResult {
                GradeBreakdownSheet(result: g)
            }
        }
    }
}

/// The sheet behind the grade chip: the letter, the score, and every
/// factor with its deduction.
private struct GradeBreakdownSheet: View {
    let result: GradeResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(result.letter)
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(
                        NightGrade.color(forLetter: result.letter))
                VStack(alignment: .leading) {
                    Text("Tonight's grade")
                        .font(.headline)
                    Text("\(Int(result.score.rounded())) / 100 — starts " +
                         "at 100, every deduction below is subtracted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal)
            List {
                ForEach(result.breakdown.indices, id: \.self) { i in
                    let row = result.breakdown[i]
                    HStack {
                        Text(row.label)
                        Spacer()
                        Text(String(format: "%+.1f", row.delta))
                            .monospacedDigit()
                            .foregroundStyle(
                                row.delta < 0 ? .red : .secondary)
                    }
                }
            }
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.bottom)
        }
        .padding(.top)
        .frame(minWidth: 340, minHeight: 320)
    }
}
