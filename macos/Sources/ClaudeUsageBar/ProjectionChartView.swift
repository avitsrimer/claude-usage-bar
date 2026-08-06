import SwiftUI
import Charts

/// A forward-looking "when will the 5-hour window run out?" panel: a one-line status plus a
/// projection chart spanning now → the next 5h reset, with a red rule at the projected run-out.
struct ProjectionChartView: View {
    @ObservedObject var service: UsageService
    @ObservedObject var historyService: UsageHistoryService
    // Threaded down from the parent's own minute-tick `@State`, matching
    // `AccountContentView`/`UsageBucketRow`'s existing convention rather than adding a second
    // "tick every 60s" mechanism (`TimelineView`) alongside that view's `Timer`-based one.
    let now: Date

    var body: some View {
        content(now: now)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let projection = UsageProjection.compute(
            points: historyService.history.dataPoints,
            currentPct: service.pct5h,
            reset: service.reset5h,
            pollingMinutes: service.pollingMinutes,
            now: now
        )

        VStack(alignment: .leading, spacing: 8) {
            statusText(for: projection.outcome)

            if let reset = projection.reset, projection.outcome != .insufficientData {
                chart(projection: projection, reset: reset)
            }
        }
    }

    // MARK: - Status line

    @ViewBuilder
    private func statusText(for outcome: UsageProjection.Outcome) -> some View {
        switch outcome {
        case .insufficientData:
            Text("Not enough data to project yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .lastsUntilReset:
            Label("Lasts until reset", systemImage: "checkmark.circle")
                .font(.subheadline)
                .foregroundStyle(.green)
        case .runsOut(let date):
            Label("Projected to run out at \(date, format: .dateTime.hour().minute())",
                  systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Chart

    struct ProjPoint: Identifiable {
        let id = UUID()
        let date: Date
        let pct: Double
    }

    /// Drawing parameters derived from a projection (kept out of the `@ViewBuilder` so the
    /// imperative branching below is treated as plain code, not view content).
    /// `internal`, not `private` — this is the pure clamping/branching logic that decides the
    /// chart's rendered endpoint, color, and run-out line, so it's unit-tested the same way
    /// `UsageProjection.compute` is, without constructing a `View`.
    struct ChartGeometry {
        let points: [ProjPoint]
        let color: Color
        let runsOutDate: Date?
        let now: Date
        let startPct: Double
    }

    /// Pure function of `projection`/`reset` — doesn't touch `self` — so it's `static` and
    /// `internal` for direct unit testing.
    static func geometry(projection: UsageProjection, reset: Date) -> ChartGeometry {
        let now = projection.now
        let startPct = projection.currentPct * 100

        // The projection line ends at the crossing (if it runs out before reset) or at the
        // reset edge (staying below 100% — visually confirming "lasts until reset").
        let endDate: Date
        let endPct: Double
        var runsOutDate: Date?
        if case .runsOut(let date) = projection.outcome {
            endDate = date
            endPct = 100
            runsOutDate = date
        } else {
            endDate = reset
            let projected = projection.currentPct + projection.ratePerSecond * reset.timeIntervalSince(now)
            endPct = min(max(projected * 100, 0), 100)
        }

        return ChartGeometry(
            points: [ProjPoint(date: now, pct: startPct), ProjPoint(date: endDate, pct: endPct)],
            color: runsOutDate != nil ? .red : .green,
            runsOutDate: runsOutDate,
            now: now,
            startPct: startPct
        )
    }

    @ViewBuilder
    private func chart(projection: UsageProjection, reset: Date) -> some View {
        let geo = Self.geometry(projection: projection, reset: reset)

        Chart {
            // 100% limit reference.
            RuleMark(y: .value("Limit", 100))
                .foregroundStyle(.secondary.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))

            // Projected trajectory (dashed).
            ForEach(geo.points) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Usage", point.pct)
                )
                .foregroundStyle(geo.color)
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }

            // Current usage marker at "now".
            PointMark(
                x: .value("Time", geo.now),
                y: .value("Usage", geo.startPct)
            )
            .foregroundStyle(geo.color)
            .symbolSize(28)

            // Red vertical line at the projected run-out time (clock time shown in the status).
            if let runsOutDate = geo.runsOutDate {
                RuleMark(x: .value("Runs out", runsOutDate))
                    .foregroundStyle(.red)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
        }
        .chartXScale(domain: geo.now...reset)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text("\(v)%").font(.caption2)
                    }
                }
                AxisGridLine()
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: Date.FormatStyle.dateTime.hour().minute())
                    .font(.caption2)
                AxisGridLine()
            }
        }
        .chartPlotStyle { plot in
            plot.clipped()
        }
        .frame(height: 100)
        .padding(.top, 4)
    }
}
