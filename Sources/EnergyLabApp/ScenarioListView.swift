import SwiftUI
import EnergyLab

/// The sidebar: six ways to coordinate one identical job, plus the two views
/// that read across all of them.
struct ScenarioListView: View {
    @EnvironmentObject private var model: LabModel
    @Binding var selection: LabSelection?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section(header: SidebarHeader(text: "Scenarios")) {
                    ForEach(Scenario.all, id: \.id) { scenario in
                        ScenarioRow(scenario: scenario,
                                    result: model.result(for: scenario),
                                    running: model.isRunning(scenario))
                            .tag(LabSelection.scenario(scenario.id))
                    }
                }
                Section(header: SidebarHeader(text: "Reading across")) {
                    SidebarRow(symbol: "chart.bar.doc.horizontal",
                               title: "Cost of coordination",
                               subtitle: "the same job, six ways",
                               tint: Theme.dusk)
                        .tag(LabSelection.comparison)
                    SidebarRow(symbol: "books.vertical.fill",
                               title: "Principles",
                               subtitle: "what the scheduler is doing",
                               tint: Theme.sage)
                        .tag(LabSelection.principles)
                }
            }
            .listStyle(.sidebar)

            Divider()
            SidebarFooter()
        }
    }
}

private struct SidebarHeader: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.label)
            .foregroundStyle(.secondary)
    }
}

/// One scenario. The symbol is the one the `Scenario` itself declares, and the
/// colour is the one its pathology carries everywhere else in the window —
/// observed once it has been measured, predicted until then.
struct ScenarioRow: View {
    let scenario: Scenario
    let result: ScenarioResult?
    let running: Bool

    private var pathology: Pathology { result?.diagnosis.pathology ?? scenario.predicted }
    private var tint: Color { Theme.tint(for: pathology) }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: scenario.sfSymbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                // An unmeasured scenario shows its prediction at a lower
                // presence, so a colour on screen never overstates its footing.
                .opacity(result == nil ? 0.55 : 1)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(scenario.title)
                    .font(.system(size: 13, weight: .medium))
                Text(result.map { $0.diagnosis.pathology.headline(at: $0.diagnosis.confidence) }
                     ?? "predicts \(scenario.predicted.rawValue)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if running {
                ProgressView()
                    .controlSize(.small)
            } else if let confidence = result?.diagnosis.confidence {
                Image(systemName: confidence.sfSymbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tint(for: confidence))
                    .help(Theme.phrase(for: confidence))
            }
        }
        .padding(.vertical, 3)
    }
}

private struct SidebarRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let tint: Color

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

/// Says plainly whether the window is showing a recorded run or is able to take
/// its own measurements, and offers the run only when it can actually happen.
struct SidebarFooter: View {
    @EnvironmentObject private var model: LabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.canMeasure {
                HStack(spacing: 8) {
                    Button {
                        model.measureAll()
                    } label: {
                        Label("Run the lab", systemImage: "play.fill")
                    }
                    .disabled(model.isBusy)

                    Button {
                        model.restoreRecorded()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .help("Show the recorded run again")
                    .disabled(model.isBusy)
                }
                Text("Each scenario runs a real worker process for about three and a half seconds.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "tray.full")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Theme.slate)
                        .font(.system(size: 11))
                    Text("Recorded run")
                        .font(Theme.label)
                        .foregroundStyle(.secondary)
                }
                Text("The chaos-worker binary is not beside this app, so the figures shown are the ones measured earlier rather than live.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failure = model.lastFailure {
                Text(failure)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ochre)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
