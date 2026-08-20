import SwiftUI
import EnergyLab

/// The whole thesis on one screen: identical work, six ways of coordinating it,
/// and the counters that tell them apart.
struct EnergyComparisonView: View {
    @EnvironmentObject private var model: LabModel

    private var rows: [ScenarioResult] {
        Scenario.all.compactMap { model.result(for: $0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Cost of coordination")
                        .font(.system(size: 26, weight: .semibold, design: .serif))
                    Prose("Every worker below completes the same nominal job: one unit of work every two hundred milliseconds. Nothing about the work differs. Every difference in these counters was produced purely by how that work was coordinated.",
                          font: Theme.proseLead)
                }

                thesis

                Card("Cycles per second, logarithmic", symbol: "chart.bar.doc.horizontal", tint: Theme.dusk) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(rows, id: \.scenario.id) { row in
                            LogBarRow(result: row)
                        }
                        LogAxis()
                        Text("Each gridline is ten times the one before it — a linear axis would render the blocking wait as a line one pixel wide. Ratios between these are order-of-magnitude only: a near-idle baseline varies substantially between runs on a loaded machine.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: Theme.proseWidth, alignment: .leading)
                    }
                }

                Card("What one unit of work cost", symbol: "scalemass", tint: Theme.sage) {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(rows, id: \.scenario.id) { row in
                            CostRow(result: row)
                        }
                        Text("A scenario that completed no units has no cost per unit — dividing by zero would invent a number, so none is shown.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                Card("Wakeups per second", symbol: Pathology.wakeupStorm.sfSymbol, tint: Theme.amber) {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(rows, id: \.scenario.id) { row in
                            WakeupRow(result: row)
                        }
                        Prose("A wakeup is not CPU time. It is the moment the package is pulled back out of a deep idle state, having paid to enter it and not yet earned that back. This is why the polling worker costs so much while its CPU percentage stays near one.",
                              font: Theme.proseSmall)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The measurement the entire lab exists to make visible.
    @ViewBuilder
    private var thesis: some View {
        let healthy = model.results["healthy"]?.diagnosis
        let deadlocked = model.results["deadlock"]?.diagnosis
        if let healthy, let deadlocked {
            Card("Why CPU percentage is not enough", symbol: "eye.trianglebadge.exclamationmark", tint: Theme.dusk) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 30) {
                        verdictColumn(healthy, title: "Blocking wait")
                        Divider().frame(height: 62)
                        verdictColumn(deadlocked, title: "Lock-order inversion")
                    }
                    Prose("One of these processes is resting between units of work and will wake the instant the next one arrives. The other will never do anything again. They are separated by one hundredth of a percentage point of CPU — which is to say, they are not separated by CPU at all. What separates them is whether work is still coming out.",
                          font: Theme.prose)
                }
            }
        }
    }

    private func verdictColumn(_ diagnosis: Diagnosis, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
            HStack(spacing: 20) {
                FigureCell(value: Figures.fixed(diagnosis.signature.cpuPercent, 2), unit: "%",
                           name: "CPU", tint: Theme.slate)
                FigureCell(value: diagnosis.signature.progressPerSecond.map { Figures.fixed($0, 1) } ?? "—",
                           unit: "units/s", name: "progress",
                           tint: (diagnosis.signature.progressPerSecond ?? 0) > 0 ? Theme.sage : Theme.alarm)
            }
            Pill(symbol: diagnosis.pathology.sfSymbol,
                 text: diagnosis.pathology.headline(at: diagnosis.confidence),
                 tint: Theme.tint(for: diagnosis.pathology))
        }
    }
}

// MARK: - rows

private struct LogBarRow: View {
    let result: ScenarioResult

    var body: some View {
        let tint = Theme.tint(for: result.diagnosis.pathology)
        let value = result.diagnosis.signature.cyclesPerSecond
        return HStack(spacing: 12) {
            RowTitle(result: result)
            Canvas { context, size in
                LogScale.drawGrid(in: context, size: size)
                guard let position = LogScale.position(value) else {
                    // Zero has no place on a logarithmic axis, and drawing a
                    // stub would imply a small amount rather than none.
                    let dot = CGRect(x: 1, y: size.height / 2 - 4, width: 8, height: 8)
                    context.stroke(Path(ellipseIn: dot), with: .color(tint), lineWidth: 1.5)
                    var zero = context.resolve(Text("nothing consumed")
                        .font(.system(size: 10, weight: .medium)))
                    zero.shading = .color(tint)
                    context.draw(zero, at: CGPoint(x: 15, y: size.height / 2), anchor: .leading)
                    return
                }
                let width = max(CGFloat(position) * size.width, 4)
                let bar = CGRect(x: 0, y: 4, width: width, height: size.height - 8)
                context.fill(Path(roundedRect: bar, cornerRadius: 4, style: .continuous),
                             with: .color(tint.opacity(0.85)))
            }
            .frame(height: 24)
            Text(Figures.compact(value))
                .font(Theme.figureSmall)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
                .help("\(Figures.grouped(value)) cycles per second")
        }
    }
}

private struct LogAxis: View {
    var body: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: RowTitle.width, height: 1)
            Canvas { context, size in
                for tick in LogScale.ticks {
                    let x = CGFloat((tick.exponent - LogScale.minExponent)
                                    / (LogScale.maxExponent - LogScale.minExponent)) * size.width
                    var label = context.resolve(Text(tick.label)
                        .font(.system(size: 9, weight: .medium)))
                    label.shading = .color(Theme.slate)
                    context.draw(label, at: CGPoint(x: min(max(x, 12), size.width - 12), y: 8),
                                 anchor: .center)
                }
            }
            .frame(height: 16)
            Color.clear.frame(width: 84, height: 1)
        }
    }
}

private struct CostRow: View {
    let result: ScenarioResult

    var body: some View {
        let signature = result.diagnosis.signature
        let progress = signature.progressPerSecond ?? 0
        let cost = progress > 0 ? signature.cyclesPerSecond / progress : nil
        return HStack(spacing: 12) {
            RowTitle(result: result)
            if let cost {
                Text("\(Figures.grouped(cost)) cycles per unit")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                Text("no units completed")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Theme.tint(for: result.diagnosis.pathology))
            }
            Spacer(minLength: 0)
        }
    }
}

private struct WakeupRow: View {
    let result: ScenarioResult

    var body: some View {
        let signature = result.diagnosis.signature
        let wakeups = max(signature.packageIdleWakeupsPerSecond, signature.interruptWakeupsPerSecond)
        return HStack(spacing: 12) {
            RowTitle(result: result)
            Canvas { context, size in
                // Linear here, because the interesting comparison is one
                // scenario against the rest rather than across decades.
                let ceiling = 900.0
                let width = max(CGFloat(min(wakeups / ceiling, 1)) * size.width, wakeups > 0 ? 3 : 0)
                if width > 0 {
                    let bar = CGRect(x: 0, y: 5, width: width, height: size.height - 10)
                    context.fill(Path(roundedRect: bar, cornerRadius: 4, style: .continuous),
                                 with: .color(Theme.amber))
                }
            }
            .frame(height: 20)
            Text(Figures.fixed(wakeups, 1))
                .font(Theme.figureSmall)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
        }
    }
}

private struct RowTitle: View {
    static let width: CGFloat = 196
    let result: ScenarioResult

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: result.scenario.sfSymbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.tint(for: result.diagnosis.pathology))
                .frame(width: 16)
            Text(result.scenario.title)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(width: Self.width, alignment: .leading)
    }
}

// MARK: - scale

/// A decade scale. The recorded figures span from a hundred and fifty thousand
/// cycles a second to nearly four billion, so nothing linear can show them
/// together without erasing the small one.
private enum LogScale {
    static let minExponent: Double = 4
    static let maxExponent: Double = 10

    struct Tick {
        let exponent: Double
        let label: String
    }

    static let ticks: [Tick] = [
        Tick(exponent: 4, label: "10 K"),
        Tick(exponent: 5, label: "100 K"),
        Tick(exponent: 6, label: "1 M"),
        Tick(exponent: 7, label: "10 M"),
        Tick(exponent: 8, label: "100 M"),
        Tick(exponent: 9, label: "1 B"),
        Tick(exponent: 10, label: "10 B")
    ]

    static func position(_ value: Double) -> Double? {
        guard value > 0 else { return nil }
        let exponent = log10(value)
        return min(max((exponent - minExponent) / (maxExponent - minExponent), 0), 1)
    }

    static func drawGrid(in context: GraphicsContext, size: CGSize) {
        var grid = Path()
        for tick in ticks {
            let x = CGFloat((tick.exponent - minExponent) / (maxExponent - minExponent)) * size.width
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(grid, with: .color(Color.primary.opacity(0.07)), lineWidth: 1)
    }
}
