import SwiftUI

// MARK: - Auto night schedule (Feature 2 of 4)
//
// Greedily slots the top-ranked targets into tonight's dark hours.
// The scheduling core (`NightSchedule.buildSchedule`) is a pure function:
// no singletons, no I/O — unit-testable by inspection.

/// One target's reserved imaging slot.
struct ScheduleBlock: Identifiable, Hashable {
    let id = UUID()
    let target: RankedTarget
    let start: Date
    let end: Date
}

/// Greedy scheduler: rank order IS the priority.
enum NightSchedule {

    /// Build up to `maxBlocks` imaging blocks from the ranked target list.
    ///
    /// Algorithm:
    /// 1. The schedulable window is `[darkStart, darkEnd]` when both are
    ///    known (astronomical darkness); otherwise it falls back to
    ///    `[now, now + 12 h]`.
    /// 2. Ranked targets are visited strictly in rank order — a higher-ranked
    ///    target always gets first pick of the night.
    /// 3. Each target's best dark-sky window comes from
    ///    `Planning.imagingWindow(...)`, clipped to the schedulable window.
    /// 4. A clipped window shorter than 45 minutes is discarded — not worth
    ///    the slew and setup time.
    /// 5. A clipped window overlapping an already-scheduled block is
    ///    discarded — no double-booking; the earlier (higher-ranked) block
    ///    wins.
    /// 6. The first `maxBlocks` accepted blocks are returned sorted by start
    ///    time.
    ///
    /// Pure: deterministic given its inputs; no singletons, no I/O.
    static func buildSchedule(ranked: [RankedTarget],
                              lat: Double,
                              lon: Double,
                              minAlt: Double,
                              horizon: HorizonProfile,
                              darkStart: Date?,
                              darkEnd: Date?,
                              now: Date,
                              maxBlocks: Int = 4) -> [ScheduleBlock]
    {
        let windowStart: Date
        let windowEnd: Date
        if let ds = darkStart, let de = darkEnd, de > ds {
            windowStart = ds
            windowEnd = de
        } else {
            windowStart = now
            windowEnd = now.addingTimeInterval(12 * 3600)
        }
        let minDuration: TimeInterval = 45 * 60

        var blocks: [ScheduleBlock] = []
        for target in ranked {
            guard blocks.count < maxBlocks else { break }
            guard let window = Planning.imagingWindow(
                object: target.object,
                lat: lat,
                lon: lon,
                minAlt: minAlt,
                now: now,
                horizon: horizon) else { continue }
            let start = max(window.start, windowStart)
            let end = min(window.end, windowEnd)
            guard end > start,
                  end.timeIntervalSince(start) >= minDuration else { continue }
            let overlaps = blocks.contains { block in
                start < block.end && end > block.start
            }
            if overlaps { continue }
            blocks.append(ScheduleBlock(target: target,
                                        start: start, end: end))
        }
        return blocks.sorted { $0.start < $1.start }
    }
}

// MARK: - Schedule sheet view

/// Presents the auto-built night schedule: one glass card per block with
/// the time range, target name + peak altitude, and a ScopePilot slew button.
struct NightScheduleView: View {
    let blocks: [ScheduleBlock]
    @ObservedObject var slewService: SlewService
    let darkStart: Date?
    let darkEnd: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if blocks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(blocks) { block in
                            blockRow(block)
                        }
                    }
                }
            }
        }
        .padding()
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 540)
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tonight's schedule")
                .font(.title2)
                .bold()
            if let ds = darkStart, let de = darkEnd {
                Text("Dark \(Fmt.time.string(from: ds)) – " +
                     "\(Fmt.time.string(from: de))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        Text("No schedulable blocks tonight — check the ranked list.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: .center)
    }

    private func blockRow(_ block: ScheduleBlock) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(block.target.object.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(Fmt.time.string(from: block.start)) – " +
                     "\(Fmt.time.string(from: block.end)) · " +
                     "peak \(Fmt.deg(block.target.peakAlt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SlewButton(ra: block.target.object.ra / 15.0,
                       dec: block.target.object.dec,
                       name: block.target.object.name,
                       slewService: slewService)
        }
        .padding(12)
        .glassPanel()
    }
}
