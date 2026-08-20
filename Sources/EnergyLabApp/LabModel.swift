import Foundation
import Combine
import EnergyLab

/// Where a shown result came from. The window never blurs the two: a recorded
/// measurement is labelled as recorded, and a live one carries the moment it
/// was taken.
enum ResultOrigin {
    case recorded
    case measured(Date)

    var isLive: Bool {
        if case .measured = self { return true }
        return false
    }
}

/// Finds the chaos-worker binary, which the app needs before it can measure
/// anything itself.
///
/// SwiftPM puts sibling products next to the executable; `make app` wraps the
/// executable in a bundle, which moves it two directories away from where the
/// worker was built. Both arrangements are checked rather than assumed.
enum WorkerLocator {

    static func find() -> String? {
        let fileManager = FileManager.default
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let executableDirectory = executable.deletingLastPathComponent()

        var candidates = [ChaosLab.defaultWorkerPath()]
        if let resources = Bundle.main.resourceURL?.appendingPathComponent("chaos-worker").path {
            candidates.append(resources)
        }
        // Contents/MacOS/EnergyLabApp -> Contents/Resources/chaos-worker
        candidates.append(executableDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/chaos-worker").path)
        // …/EnergyLab.app/Contents/MacOS/EnergyLabApp -> …/chaos-worker
        candidates.append(executableDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("chaos-worker").path)

        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }
}

/// Everything the window renders, and the one place that decides whether a
/// figure on screen was recorded earlier or measured just now.
///
/// The views read model values only. They render identically whether the chaos
/// workers exist on this machine or not, which is what lets the whole interface
/// be inspected without running anything.
@MainActor
final class LabModel: ObservableObject {

    @Published private(set) var results: [String: ScenarioResult]
    @Published private(set) var origins: [String: ResultOrigin]
    @Published private(set) var running: Set<String> = []
    /// Set when a live run could not be completed. Stated as a fact about the
    /// measurement, never as a fault of the machine.
    @Published private(set) var lastFailure: String?

    /// nil when the worker binary is not on this machine, in which case the
    /// window shows the recorded run and says so.
    let workerPath: String?

    var canMeasure: Bool { workerPath != nil }
    var isBusy: Bool { !running.isEmpty }

    init(results: [String: ScenarioResult] = SampleData.results,
         workerPath: String? = WorkerLocator.find()) {
        self.results = results
        self.origins = results.mapValues { _ in ResultOrigin.recorded }
        self.workerPath = workerPath
    }

    func result(for scenario: Scenario) -> ScenarioResult? { results[scenario.id] }
    func origin(for scenario: Scenario) -> ResultOrigin? { origins[scenario.id] }
    func isRunning(_ scenario: Scenario) -> Bool { running.contains(scenario.id) }

    /// Runs one scenario as a real child process and replaces its figures with
    /// what was measured.
    func measure(_ scenario: Scenario) {
        guard let workerPath, !running.contains(scenario.id) else { return }
        running.insert(scenario.id)
        lastFailure = nil

        // ChaosLab blocks for the length of its observation window on purpose:
        // the measurement is the wait. It is moved off the main actor so the
        // window keeps drawing, and nothing else about it changes.
        Task.detached(priority: .userInitiated) {
            let lab = ChaosLab(workerPath: workerPath)
            let outcome = lab.run(scenario)
            await MainActor.run { [weak self] in
                self?.apply(outcome, for: scenario)
            }
        }
    }

    func measureAll() {
        for scenario in Scenario.all { measure(scenario) }
    }

    /// Puts the recorded run back, so the window can always be returned to the
    /// state it can explain without a machine.
    func restoreRecorded() {
        results = SampleData.results
        origins = results.mapValues { _ in ResultOrigin.recorded }
        lastFailure = nil
    }

    private func apply(_ outcome: ScenarioResult?, for scenario: Scenario) {
        running.remove(scenario.id)
        guard let outcome else {
            lastFailure = "\(scenario.title) could not be measured: the worker did not start, or its counters were unreadable."
            return
        }
        results[scenario.id] = outcome
        origins[scenario.id] = .measured(Date())
    }
}
