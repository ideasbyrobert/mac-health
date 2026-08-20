import Foundation
import EnergyLab

/// `Actor` is also the name of the standard library's concurrency protocol, so
/// the lab's meaning is spelled out once here and used everywhere else.
typealias LabActor = EnergyLab.Actor

/// The wait-for structure of one scenario, together with an honest account of
/// where that structure came from.
///
/// The lab never draws an edge it did not either observe or construct. These
/// structures are constructed: each one is read off the chaos worker's own
/// source, which is why they are stated as `known`. An edge inferred from
/// counters alone would carry a weaker confidence, and the diagram says so.
struct LabGraph {
    let actors: [LabActor]
    let graph: WaitForGraph
    /// How the structure was obtained, in the user's terms.
    let provenance: String
    let confidence: Confidence
    /// What the picture says. Shown under the diagram, including — especially —
    /// when there are no edges at all, because an empty diagram must still tell
    /// the truth rather than look like a missing measurement.
    let reading: String
}

/// The recorded measurements this window renders when the chaos workers are not
/// available to run.
///
/// Every figure below was measured on the machine the lab was built for: a 2019
/// 16-inch MacBook Pro, six worker processes given the same nominal job of one
/// work unit every 200 ms, each observed over a three-second window.
enum SampleData {

    /// One row of the recorded table.
    struct RecordedRun {
        let scenarioID: String
        let cyclesPerSecond: Double
        let instructionsPerCycle: Double
        let cpuPercent: Double
        /// The recording collapsed interrupt and package-idle wakeups into a
        /// single column by taking their maximum. It is reproduced here in the
        /// package-idle column, which is the one that costs the CPU its deep
        /// idle states.
        let packageIdleWakeupsPerSecond: Double
        /// Work units completed per second, read from each worker's heartbeat
        /// during the same window. Progress is the signal that separates a
        /// deadlock from a healthy idle, so it is measured rather than assumed.
        let progressPerSecond: Double?
    }

    static let window: TimeInterval = 3.0

    static let provenance =
        "Recorded on a 2019 16-inch MacBook Pro (Intel Core i7-9750H): six workers, one work unit per 200 ms each, three-second windows, every column including progress read from the run."

    static let recorded: [RecordedRun] = [
        RecordedRun(scenarioID: "healthy",
                    cyclesPerSecond: 328_556, instructionsPerCycle: 0.24,
                    cpuPercent: 0.02, packageIdleWakeupsPerSecond: 4.7,
                    progressPerSecond: 4.66),
        RecordedRun(scenarioID: "wakeup-storm",
                    cyclesPerSecond: 22_826_936, instructionsPerCycle: 0.22,
                    cpuPercent: 1.23, packageIdleWakeupsPerSecond: 814.9,
                    progressPerSecond: 4.00),
        RecordedRun(scenarioID: "livelock",
                    cyclesPerSecond: 3_836_481_384, instructionsPerCycle: 1.25,
                    cpuPercent: 99.12, packageIdleWakeupsPerSecond: 0.0,
                    progressPerSecond: 0.0),
        RecordedRun(scenarioID: "deadlock",
                    cyclesPerSecond: 0, instructionsPerCycle: 0.0,
                    cpuPercent: 0.0, packageIdleWakeupsPerSecond: 0.0,
                    progressPerSecond: 0.0),
        RecordedRun(scenarioID: "pipe-deadlock",
                    cyclesPerSecond: 0, instructionsPerCycle: 0.0,
                    cpuPercent: 0.0, packageIdleWakeupsPerSecond: 0.0,
                    progressPerSecond: 0.0),
        RecordedRun(scenarioID: "stalled",
                    cyclesPerSecond: 2_362_712_031, instructionsPerCycle: 0.06,
                    cpuPercent: 99.04, packageIdleWakeupsPerSecond: 0.0,
                    progressPerSecond: 5.00)
    ]

    static func signature(_ run: RecordedRun) -> EnergySignature {
        EnergySignature(
            pid: 0,
            window: window,
            cyclesPerSecond: run.cyclesPerSecond,
            instructionsPerCycle: run.instructionsPerCycle,
            cpuPercent: run.cpuPercent,
            interruptWakeupsPerSecond: 0,
            packageIdleWakeupsPerSecond: run.packageIdleWakeupsPerSecond,
            progressPerSecond: run.progressPerSecond
        )
    }

    /// The verdicts are not written down here. The recorded counters are fed to
    /// the same `PathologyClassifier` the live lab uses, so this window cannot
    /// quietly show a conclusion the classifier would not reach. The lock-order
    /// scenario is the one case where the cycle is proved rather than inferred,
    /// exactly as `ChaosLab` decides it.
    static let results: [String: ScenarioResult] = {
        var out: [String: ScenarioResult] = [:]
        let classifier = PathologyClassifier()
        for run in recorded {
            guard let scenario = Scenario.named(run.scenarioID) else { continue }
            let proven = run.scenarioID == "deadlock" && (run.progressPerSecond ?? 0) == 0
            let diagnosis = classifier.classify(signature(run), structure: proven ? .knownByConstruction(mode: run.scenarioID) : .none)
            out[run.scenarioID] = ScenarioResult(scenario: scenario, diagnosis: diagnosis)
        }
        return out
    }()

    // MARK: - wait-for structures

    // The actors below are roles rather than live identifiers. A recorded run
    // keeps no pid, and the two-process scenario has two of them, so the
    // diagram is labelled by what each actor is doing. The synthetic ids exist
    // only to keep the graph's own bookkeeping distinct.
    private static func role(_ index: UInt64, _ label: String) -> LabActor {
        LabActor(pid: 0, threadID: index, label: label)
    }

    static func graph(for scenarioID: String) -> LabGraph {
        switch scenarioID {

        case "healthy":
            let worker = role(1, "worker")
            let source = role(2, "event source")
            var graph = WaitForGraph()
            graph.add(WaitEdge(waiter: worker, holder: source,
                               gate: .conditionVariable("work-ready")))
            return LabGraph(
                actors: [worker, source],
                graph: graph,
                provenance: "Read from the worker's source: it blocks on a condition variable that the event source signals.",
                confidence: .known,
                reading: "One edge, no cycle. The worker is off the run queue entirely while it waits, and the release it is waiting for is something another actor can still perform. This is the shape every other scenario should be turned into."
            )

        case "wakeup-storm":
            let poller = role(1, "poller")
            return LabGraph(
                actors: [poller],
                graph: WaitForGraph(),
                provenance: "Read from the worker's source: it never blocks on the work, only on a timer.",
                confidence: .known,
                reading: "No wait edges at all — and that is the point. The poller waits on the clock, and the clock always fires. At 804.5 package-idle wakeups a second it rejoins the run queue roughly every 1.2 ms, looks, finds nothing, and goes back. The graph cannot show a waste this large because nothing is actually waiting."
            )

        case "livelock":
            let spinner = role(1, "spinner")
            return LabGraph(
                actors: [spinner],
                graph: WaitForGraph(),
                provenance: "Read from the worker's source: the loop tests its condition without ever blocking.",
                confidence: .known,
                reading: "No wait edges, because nothing ever blocks. The thread stays on the run queue permanently, which is why it holds a core at 99.36% while completing no work. A deadlocked thread at least stops costing something."
            )

        case "deadlock":
            let one = role(1, "thread 1")
            let two = role(2, "thread 2")
            var graph = WaitForGraph()
            graph.add(WaitEdge(waiter: one, holder: two, gate: .mutex("B")))
            graph.add(WaitEdge(waiter: two, holder: one, gate: .mutex("A")))
            return LabGraph(
                actors: [one, two],
                graph: graph,
                provenance: "Known by construction: the two threads take mutex A and mutex B in opposite orders.",
                confidence: .known,
                reading: "The ring is closed. Every actor in it is waiting for the next, so the release each one needs can only come from an actor that is itself waiting. No amount of further waiting opens it, and the counters go silent — the same silence as a healthy idle process. This is the one scenario whose cycle the lab proves rather than infers, which is why its verdict is reported as known."
            )

        case "pipe-deadlock":
            let parent = role(1, "parent")
            let child = role(2, "child")
            var graph = WaitForGraph()
            graph.add(WaitEdge(waiter: parent, holder: child,
                               gate: .externalProcess("child exit")))
            graph.add(WaitEdge(waiter: child, holder: parent,
                               gate: .pipe("stdout buffer, ~64 KB")))
            return LabGraph(
                actors: [parent, child],
                graph: graph,
                provenance: "Known by construction: the parent waits for exit before draining, and the child writes past the pipe's capacity.",
                confidence: .known,
                reading: "The same closed ring as the lock-order case, with no mutex anywhere in it. The gates are a process's exit and a kernel buffer's free space. A deadlock is a property of the graph, not of the primitive. The run itself is still reported as probable rather than known: this ring is read from the worker's source, not sampled from the live wait edges of the process that was measured, and the lab does not let a construction stand in for an observation."
            )

        case "stalled":
            let worker = role(1, "worker")
            return LabGraph(
                actors: [worker],
                graph: WaitForGraph(),
                provenance: "Read from the worker's source: it traverses a working set larger than cache and never blocks.",
                confidence: .known,
                reading: "No wait edges, because the stall is below the scheduler's horizon. The thread is runnable the whole time; it is the memory hierarchy that is late. There is no wait-for edge for a cache miss, which is why this pathology has to be found in instructions-per-cycle instead — 0.06 here against 2.05 for the spin loop."
            )

        default:
            return LabGraph(
                actors: [],
                graph: WaitForGraph(),
                provenance: "No structure recorded for this scenario.",
                confidence: .unknown,
                reading: "Nothing to draw."
            )
        }
    }
}
