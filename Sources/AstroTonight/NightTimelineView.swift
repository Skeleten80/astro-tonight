import SwiftUI

/// Gantt-style strip of the night: the dark window as a background band,
/// one row per target with its imaging window as a bar, and a "now" line.
/// Bars are tappable — they select the target in the main list.
///
/// The rows show the observing list when it's non-empty, otherwise the
/// top 8 ranked targets (stated in the caption). Targets with no imaging
/// window tonight are hidden (also stated). All geometry comes from
/// `Planning.imagingWindow` — no new astro math here.
struct NightTimelineView: View {
    let targets: [RankedTarget]
    let usingList: Bool
    let lat: Double
    let lon: Double
    let minAlt: Double
    let horizon: HorizonProfile
    let darkStart: Date?
    let darkEnd: Date?
    let now: Date
    /// Ranking-window start — the axis fallback when dark hours are nil.
    let windowStart: Date
    @Binding var selection: RankedTarget?

    private struct Row {
        let target: RankedTarget
        let window: Planning.ImagingWindow
    }

    private let rowHeight: CGFloat = 26
    private let nameWidth: CGFloat = 84

    private var rows: [Row] {
        targets.compactMap { t in
            Planning.imagingWindow(object: t.object, lat: lat, lon: lon,
                                   minAlt: minAlt, now: now,
                                   horizon: horizon)
                .map { Row(target: t, window: $0) }
        }
    }

    /// Axis: the dark window ± 1 h when known, else the 24 h ranking
    /// window. Imaging windows only exist inside dark hours, so the
    /// dark-padded axis is the meaningful one.
    private var axisStart: Date {
        darkStart?.addingTimeInterval(-3600) ?? windowStart
    }

    private var axisEnd: Date {
        darkEnd?.addingTimeInterval(3600)
            ?? windowStart.addingTimeInterval(24 * 3600)
    }

    private func xPos(_ date: Date, total w: CGFloat) -> CGFloat {
        let span = axisEnd.timeIntervalSince(axisStart)
        guard span > 0, w > 0 else { return 0 }
        let f = date.timeIntervalSince(axisStart) / span
        return CGFloat(min(max(f, 0), 1)) * w
    }

    private func barWidth(_ a: Date, _ b: Date, total w: CGFloat) -> CGFloat {
        max(3, xPos(b, total: w) - xPos(a, total: w))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if rows.isEmpty {
                Text("No imaging windows tonight.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                GeometryReader { geo in
                    // Bar area = full width minus the fixed name column
                    // and the HStack spacing; every x-mapping below uses
                    // this same width so band, bars, and now-line align.
                    let barArea = max(0, geo.size.width - nameWidth - 6)
                    let fullH = CGFloat(rows.count) * rowHeight
                    ZStack(alignment: .topLeading) {
                        // Dark band behind the rows.
                        if let ds = darkStart, let de = darkEnd {
                            Rectangle()
                                .fill(Color.indigo.opacity(0.14))
                                .frame(
                                    width: barWidth(ds, de, total: barArea),
                                    height: fullH)
                                .offset(x: nameWidth + 6 +
                                            xPos(ds, total: barArea))
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(rows, id: \.target.id) { row in
                                Button {
                                    selection = row.target
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(row.target.object.name)
                                            .font(.caption2)
                                            .lineLimit(1)
                                            .frame(width: nameWidth,
                                                   alignment: .leading)
                                        ZStack(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(row.target.moonOK
                                                    ? Color.accentColor
                                                    : Color.orange
                                                        .opacity(0.75))
                                                .frame(
                                                    width: barWidth(
                                                        row.window.start,
                                                        row.window.end,
                                                        total: barArea),
                                                    height: 14)
                                                .offset(x: xPos(
                                                    row.window.start,
                                                    total: barArea))
                                        }
                                        .frame(maxWidth: .infinity,
                                               alignment: .leading)
                                    }
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity,
                                       alignment: .leading)
                                .frame(height: rowHeight)
                                .accessibilityLabel(
                                    "\(row.target.object.name), imaging " +
                                    "window \(Fmt.time.string(from: row.window.start)) " +
                                    "to \(Fmt.time.string(from: row.window.end))")
                            }
                        }
                        // Now line.
                        if now >= axisStart && now <= axisEnd {
                            Rectangle()
                                .fill(Color.white.opacity(0.7))
                                .frame(width: 1.5, height: fullH)
                                .offset(x: nameWidth + 6 +
                                            xPos(now, total: barArea))
                        }
                    }
                }
                .frame(height: CGFloat(rows.count) * rowHeight)
                HStack {
                    Text(Fmt.time.string(from: axisStart))
                    Spacer()
                    Text(Fmt.time.string(from: axisEnd))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Text(usingList
                 ? "Observing list · targets with no window tonight " +
                   "are hidden"
                 : "Top \(targets.count) ranked · targets with no " +
                   "window tonight are hidden")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
