import SwiftUI
import EnergyLab

/// One scenario, read end to end: what it teaches, what was predicted before it
/// ran, what the counters said, the shape of the waiting, where the energy
/// went, and how to write the same job differently.
struct ScenarioDetailView: View {
    @EnvironmentObject private var model: LabModel
    let scenario: Scenario

    private var result: ScenarioResult? { model.result(for: scenario) }
    private var pathology: Pathology { result?.diagnosis.pathology ?? scenario.predicted }
    private var tint: Color { Theme.tint(for: pathology) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                Prose(scenario.teaches, font: Theme.proseLead)

                predictionCard

                if let result {
                    Card("Measured", symbol: "ruler", tint: tint) {
                        SignatureFigures(signature: result.diagnosis.signature, tint: tint)
                    }
                }

                Card("Wait-for graph", symbol: "arrow.triangle.branch", tint: tint) {
                    WaitForGraphView(lab: SampleData.graph(for: scenario.id), tint: tint)
                }

                if let result {
                    Card("Where the energy went", symbol: "bolt.fill", tint: tint) {
                        EnergyFlowView(result: result,
                                       yardstick: EnergyYardstick.derive(from: model.results))
                    }

                    Card("Evidence", symbol: result.diagnosis.confidence.sfSymbol,
                         tint: Theme.tint(for: result.diagnosis.confidence)) {
                        EvidenceList(evidence: result.diagnosis.evidence)
                    }

                    if let inquiry = result.diagnosis.inquiry {
                        InquiryCard(text: inquiry)
                    }
                }

                Card("How to shape the same job instead", symbol: "wrench.and.screwdriver.fill", tint: Theme.sage) {
                    Prose(scenario.remedy)
                }

                provenance
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.canMeasure {
                    Button {
                        model.measure(scenario)
                    } label: {
                        Label("Measure", systemImage: "play.fill")
                    }
                    .disabled(model.isRunning(scenario))
                }
            }
        }
    }

    // MARK: sections

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: scenario.sfSymbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text(scenario.title)
                    .font(.system(size: 26, weight: .semibold, design: .serif))
                HStack(spacing: 8) {
                    Text(scenario.id)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    if let result {
                        Pill(symbol: result.diagnosis.confidence.sfSymbol,
                             text: Theme.phrase(for: result.diagnosis.confidence),
                             tint: Theme.tint(for: result.diagnosis.confidence))
                    }
                }
            }
            Spacer(minLength: 0)
            if model.isRunning(scenario) {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var predictionCard: some View {
        Card("Before and after", symbol: "arrow.left.arrow.right", tint: Theme.dusk) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 30) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Predicted, before the run")
                            .font(Theme.label).foregroundStyle(.secondary)
                        Pill(symbol: scenario.predicted.sfSymbol,
                             text: scenario.predicted.rawValue,
                             tint: Theme.tint(for: scenario.predicted).opacity(0.9))
                        Text(scenario.predicted.headline(at: .known))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Divider().frame(height: 66)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Observed")
                            .font(Theme.label).foregroundStyle(.secondary)
                        if let result {
                            Pill(symbol: result.diagnosis.pathology.sfSymbol,
                                 text: result.diagnosis.pathology.rawValue,
                                 tint: Theme.tint(for: result.diagnosis.pathology))
                            Text(result.diagnosis.pathology.headline(at: result.diagnosis.confidence))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("not measured yet")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }

                if let result {
                    HStack(spacing: 7) {
                        Image(systemName: result.predictionHeld ? "checkmark.seal.fill" : "arrow.triangle.branch")
                            .symbolRenderingMode(.hierarchical)
                            .font(.system(size: 12))
                            .foregroundStyle(result.predictionHeld ? Theme.sage : Theme.ochre)
                        Text(result.predictionHeld
                             ? "The prediction held."
                             : "The observation contradicted the prediction — so the scenario is what needs fixing, not the machine.")
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Prose("A prediction is stated before the run and is allowed to fail. One that cannot fail would teach nothing.",
                      font: Theme.proseSmall)
            }
        }
    }

    private var provenance: some View {
        HStack(spacing: 6) {
            Image(systemName: (model.origin(for: scenario)?.isLive ?? false) ? "dot.radiowaves.left.and.right" : "tray.full")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 10))
                .foregroundStyle(Theme.slate)
            Text(provenanceText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private var provenanceText: String {
        switch model.origin(for: scenario) {
        case .measured(let when):
            let formatter = DateFormatter()
            formatter.timeStyle = .medium
            formatter.dateStyle = .none
            let window = result.map { Figures.fixed($0.diagnosis.signature.window, 1) } ?? "?"
            return "Measured on this machine at \(formatter.string(from: when)), over a \(window)-second window."
        case .recorded:
            return SampleData.provenance
        case .none:
            return "Not yet measured on this machine."
        }
    }
}

// MARK: - pieces

private struct SignatureFigures: View {
    let signature: EnergySignature
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 26) {
                FigureCell(value: Figures.compact(signature.cyclesPerSecond), unit: "cycles/s",
                           name: "cycles", tint: tint,
                           exact: "\(Figures.grouped(signature.cyclesPerSecond)) cycles per second")
                FigureCell(value: Figures.fixed(signature.instructionsPerCycle, 2), unit: "IPC",
                           name: "instructions per cycle",
                           tint: Theme.ink,
                           exact: "Retired instructions per cycle. Well under one on a superscalar core means the pipeline is waiting rather than executing.")
                FigureCell(value: Figures.fixed(signature.cpuPercent, 2), unit: "%",
                           name: "CPU", tint: Theme.ink)
                FigureCell(value: Figures.fixed(max(signature.packageIdleWakeupsPerSecond,
                                                   signature.interruptWakeupsPerSecond), 1),
                           unit: "/s", name: "wakeups",
                           tint: signature.packageIdleWakeupsPerSecond >= PathologyClassifier.wakeupStormPerSecond
                                 ? Theme.amber : Theme.ink,
                           exact: "Wakeups that pulled the CPU package out of an idle state.")
                FigureCell(value: signature.progressPerSecond.map { Figures.fixed($0, 1) } ?? "none",
                           unit: signature.progressPerSecond == nil ? "" : "units/s",
                           name: "progress",
                           tint: (signature.progressPerSecond ?? 0) > 0 ? Theme.sage : Theme.slate,
                           exact: signature.progressPerSecond == nil
                                  ? "No heartbeat was available, which is exactly when a deadlock stops being distinguishable from healthy idle."
                                  : nil)
            }
            Text("Rates over \(Figures.fixed(signature.window, 1)) seconds, from the kernel's own cycle and instruction counters — not a vendor energy score.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

private struct EvidenceList: View {
    let evidence: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(evidence.enumerated()), id: \.offset) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(Theme.slate.opacity(0.55))
                        .frame(width: 4, height: 4)
                    Text(item.element)
                        .font(.system(size: 12, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// An open question, and it must never be mistaken for a conclusion.
///
/// Evidence is drawn as a settled list; this is drawn as an unfinished note —
/// dashed, unfilled, set in italic, and labelled as something the lab cannot
/// answer yet. The methodology's rule is that an unknown becomes an inquiry
/// rather than a blank, and an inquiry that looks like a finding would be
/// worse than a blank.
private struct InquiryCard: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: Confidence.unknown.sfSymbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.dusk)
                Text("Open question — the lab cannot answer this yet")
                    .font(Theme.label)
                    .foregroundStyle(Theme.dusk)
            }
            Text(text)
                .font(Theme.prose.italic())
                .lineSpacing(Theme.proseLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Theme.proseWidth, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.dusk.opacity(0.5),
                              style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }
}
