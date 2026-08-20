import SwiftUI
import EnergyLab

/// The cost of one unit of work when the same job is coordinated well.
///
/// This is a measurement, not a target someone chose: it is the blocking-wait
/// worker's own cycles divided by its own completed units. Every other scenario
/// is then asked how much of what it spent went into work priced at that rate.
struct EnergyYardstick {
    let cyclesPerUnit: Double
    let sourceTitle: String

    static func derive(from results: [String: ScenarioResult]) -> EnergyYardstick? {
        guard let reference = results["healthy"] else { return nil }
        let signature = reference.diagnosis.signature
        guard let progress = signature.progressPerSecond, progress > 0,
              signature.cyclesPerSecond > 0 else { return nil }
        return EnergyYardstick(cyclesPerUnit: signature.cyclesPerSecond / progress,
                               sourceTitle: reference.scenario.title)
    }
}

/// How much of the energy a scenario consumed became work.
///
/// Where the proportion can be computed it is drawn as one honest split of one
/// bar. Where it cannot — nothing was consumed, or nothing reported progress —
/// the two quantities are put side by side instead, because a ratio nobody
/// measured is worse than no ratio at all.
struct EnergyFlowView: View {
    let result: ScenarioResult
    let yardstick: EnergyYardstick?

    private var signature: EnergySignature { result.diagnosis.signature }
    private var tint: Color { Theme.tint(for: result.diagnosis.pathology) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if signature.cyclesPerSecond <= 0 {
                sideBySide(
                    note: "Nothing was spent and nothing was produced. That is not thrift — it is a stop. A process this quiet is either resting or finished forever, and the counters cannot tell you which."
                )
            } else if let progress = signature.progressPerSecond, let yardstick {
                converted(progress: progress, yardstick: yardstick)
            } else {
                sideBySide(
                    note: "No progress signal was available for this run, so the share of the energy that became work cannot be computed. The two quantities are shown as they were measured."
                )
            }
        }
    }

    // MARK: the computable case

    private func converted(progress: Double, yardstick: EnergyYardstick) -> some View {
        let total = signature.cyclesPerSecond
        let becameWork = min(progress * yardstick.cyclesPerUnit, total)
        let fraction = becameWork / total

        return VStack(alignment: .leading, spacing: 12) {
            Canvas { context, size in
                let bar = CGRect(x: 0, y: 6, width: size.width, height: size.height - 12)
                let rounded = Path(roundedRect: bar, cornerRadius: 7, style: .continuous)

                // Everything above the yardstick's price for the work actually
                // completed. Hatched, because it is spend rather than output.
                context.fill(rounded, with: .color(tint.opacity(0.22)))
                var hatch = context
                hatch.clip(to: rounded)
                var lines = Path()
                var x = -bar.height
                while x < bar.maxX {
                    lines.move(to: CGPoint(x: x, y: bar.maxY))
                    lines.addLine(to: CGPoint(x: x + bar.height, y: bar.minY))
                    x += 9
                }
                hatch.stroke(lines, with: .color(tint.opacity(0.35)), lineWidth: 1)

                // A sliver this thin is often the whole point, so it is never
                // allowed to round down to nothing.
                let workWidth = max(bar.width * CGFloat(fraction), fraction > 0 ? 3 : 0)
                if workWidth > 0 {
                    let workRect = CGRect(x: 0, y: bar.minY, width: workWidth, height: bar.height)
                    context.fill(Path(roundedRect: workRect, cornerRadius: 7, style: .continuous),
                                 with: .color(Theme.sage))
                }
                context.stroke(rounded, with: .color(Color.primary.opacity(0.12)), lineWidth: 1)
            }
            .frame(height: 42)

            HStack(alignment: .top, spacing: 26) {
                flowLabel(swatch: Theme.sage,
                          headline: Figures.percent(fraction),
                          detail: "became work, priced at what a \(yardstick.sourceTitle.lowercased()) pays for the same unit — \(Figures.grouped(yardstick.cyclesPerUnit)) cycles each.")
                flowLabel(swatch: tint.opacity(0.45),
                          headline: Figures.percent(1 - fraction),
                          detail: fraction >= 0.999
                            ? "left over. There is essentially nothing here that is not work."
                            : "went somewhere else: into polling, spinning, or waiting on memory.")
            }

            HStack(spacing: 18) {
                FigureCell(value: Figures.compact(total), unit: "cycles/s",
                           name: "consumed", tint: tint,
                           exact: "\(Figures.grouped(total)) cycles per second")
                FigureCell(value: Figures.fixed(progress, 1), unit: "units/s",
                           name: "completed",
                           tint: progress > 0 ? Theme.sage : Theme.slate)
                FigureCell(value: progress > 0 ? Figures.compact(total / progress) : "—",
                           unit: progress > 0 ? "cycles/unit" : "",
                           name: "cost of one unit",
                           tint: Theme.ink,
                           exact: progress > 0 ? "\(Figures.grouped(total / progress)) cycles per completed work unit" : nil)
            }

            caveat
        }
    }

    private func flowLabel(swatch: Color, headline: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(swatch)
                .frame(width: 12, height: 12)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(Theme.figureSmall)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 330, alignment: .leading)
    }

    @ViewBuilder
    private var caveat: some View {
        let stalled = result.diagnosis.pathology == .stalled
        Text(stalled
             ? "Read this split as an upper bound on waste, not a measurement of it: the yardstick assumes a unit of work costs the same everywhere, and a memory-bound unit genuinely costs more than a cheap one."
             : "The yardstick is one worker's measured cost for one unit of the same job. It carries that worker's variance with it, so treat the split as order-of-magnitude.")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Theme.proseWidth, alignment: .leading)
    }

    // MARK: the honest refusal

    private func sideBySide(note: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 26) {
                FigureCell(value: Figures.compact(signature.cyclesPerSecond), unit: "cycles/s",
                           name: "energy in", tint: tint,
                           exact: "\(Figures.grouped(signature.cyclesPerSecond)) cycles per second")
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                FigureCell(value: signature.progressPerSecond.map { Figures.fixed($0, 1) } ?? "no signal",
                           unit: signature.progressPerSecond == nil ? "" : "units/s",
                           name: "work out",
                           tint: (signature.progressPerSecond ?? 0) > 0 ? Theme.sage : Theme.slate)
            }
            Prose(note, font: Theme.proseSmall)
        }
    }
}
