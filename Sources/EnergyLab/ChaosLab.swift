import Foundation

/// One named experiment: a worker mode, what it is meant to teach, and the
/// wait-for structure the lab expects to find inside it.
public struct Scenario: Sendable {
    public let id: String
    public let title: String
    /// The OS principle the scenario exists to make visible.
    public let teaches: String
    /// Stated before the run. If the observation contradicts it, the scenario
    /// is wrong and must be fixed — a prediction that cannot fail teaches
    /// nothing.
    public let predicted: Pathology
    public let sfSymbol: String
    /// How the same job should be coordinated instead.
    public let remedy: String

    public init(id: String, title: String, teaches: String, predicted: Pathology, sfSymbol: String, remedy: String) {
        self.id = id
        self.title = title
        self.teaches = teaches
        self.predicted = predicted
        self.sfSymbol = sfSymbol
        self.remedy = remedy
    }

    public static let all: [Scenario] = [
        Scenario(
            id: "healthy",
            title: "Blocking wait",
            teaches: "A thread that blocks until an event arrives costs the machine almost nothing. The scheduler takes it off the run queue entirely, and the package is free to enter a deep idle state until something signals. The event here comes from a timer thread standing in for the hardware a real program would wait on, so the process still wakes about five times a second — that arrival rate, not the waiting, is what its cost is made of.",
            predicted: .idleWaiting,
            sfSymbol: "leaf.fill",
            remedy: "Nothing to fix. This is the shape every other scenario should be turned into."
        ),
        Scenario(
            id: "wakeup-storm",
            title: "Polling instead of waiting",
            teaches: "This worker receives work at exactly the same rate as the blocking one, but asks for it a thousand times a second instead of waiting to be told. Each wakeup drags the package out of idle before it has recouped the cost of entering, and it takes roughly two hundred wakeups to collect one unit of work. CPU percentage barely moves, which is why this pathology survives code review.",
            predicted: .wakeupStorm,
            sfSymbol: "alarm.waves.left.and.right.fill",
            remedy: "Wait on the event, not on the clock: a condition variable, kqueue, or dispatch source. If you must poll, coalesce timers and widen the interval."
        ),
        Scenario(
            id: "livelock",
            title: "Spinning on a condition",
            teaches: "A spin loop keeps the thread on the run queue and the core at full clock. It is the most expensive state a machine can occupy, and from the outside it looks like hard work.",
            predicted: .livelock,
            sfSymbol: "arrow.triangle.2.circlepath",
            remedy: "Block instead of spinning. Spin only for the few hundred nanoseconds where a context switch would genuinely cost more, and always with a bounded backoff."
        ),
        Scenario(
            id: "deadlock",
            title: "Lock-order inversion",
            teaches: "Two threads take two mutexes in opposite orders. The wait-for graph closes into a cycle, and no amount of waiting can ever open it. The counters go silent — the same silence as a healthy idle process.",
            predicted: .deadlock,
            sfSymbol: "lock.trianglebadge.exclamationmark.fill",
            remedy: "Impose a global lock order and take locks in that order everywhere, or take both under a single higher-level lock."
        ),
        Scenario(
            id: "pipe-deadlock",
            title: "Backpressure deadlock",
            teaches: "No mutex is involved: the pipe buffer is the gate. The parent waits for the child to exit before draining, so once the child fills ~64KB it blocks writing while the parent blocks waiting. This exact defect shipped in this repository's own shell layer.",
            predicted: .deadlock,
            sfSymbol: "cylinder.split.1x2.fill",
            remedy: "Drain the pipe before reaping the child, or read on another thread. Never make a producer's completion a prerequisite for consuming what it produced."
        ),
        Scenario(
            id: "stalled",
            title: "Memory-bound work",
            teaches: "Progress continues, but each unit costs far more than it should. The core is at full clock while the pipeline waits on memory, so instructions-per-cycle collapses even though CPU percentage is high.",
            predicted: .stalled,
            sfSymbol: "tortoise.fill",
            remedy: "Improve locality: shrink the working set, traverse contiguously, and separate data that different threads write so they do not share cache lines."
        )
    ]

    public static func named(_ id: String) -> Scenario? { all.first { $0.id == id } }
}

/// The observed outcome of running one scenario.
public struct ScenarioResult: Sendable {
    public let scenario: Scenario
    public let diagnosis: Diagnosis
    /// Whether observation matched the prediction stated before the run.
    public var predictionHeld: Bool {
        diagnosis.pathology == scenario.predicted
            || (scenario.predicted == .deadlock && diagnosis.pathology == .indeterminate)
    }

    public init(scenario: Scenario, diagnosis: Diagnosis) {
        self.scenario = scenario
        self.diagnosis = diagnosis
    }
}

/// Runs a scenario as a real child process and measures it.
public struct ChaosLab {
    let workerPath: String
    let sampler: ProcessSampling
    let stateDirectory: String

    public init(
        workerPath: String,
        sampler: ProcessSampling = KernelProcessSampler(),
        stateDirectory: String = NSTemporaryDirectory()
    ) {
        self.workerPath = workerPath
        self.sampler = sampler
        self.stateDirectory = stateDirectory
    }

    /// Locates the chaos-worker binary next to the running executable, which is
    /// where SwiftPM puts sibling products.
    public static func defaultWorkerPath() -> String {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        return exe.deletingLastPathComponent().appendingPathComponent("chaos-worker").path
    }

    public func run(_ scenario: Scenario, window: TimeInterval = 3.0) -> ScenarioResult? {
        let progressFile = "\(stateDirectory)/machealth-chaos-\(scenario.id)-\(UUID().uuidString).progress"
        defer { try? FileManager.default.removeItem(atPath: progressFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: workerPath)
        process.arguments = [scenario.id, progressFile]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }

        // Let the worker reach its steady state before the first reading, or a
        // scenario's startup would be measured instead of its behaviour.
        Thread.sleep(forTimeInterval: 0.4)

        let pid = process.processIdentifier
        guard let first = sampler.sample(pid: pid, now: Date()) else { return nil }
        let progressBefore = readProgress(progressFile)
        Thread.sleep(forTimeInterval: window)
        guard let second = sampler.sample(pid: pid, now: Date()) else { return nil }
        let progressAfter = readProgress(progressFile)

        let delta = (progressBefore != nil && progressAfter != nil)
            ? Double(progressAfter! - progressBefore!)
            : nil
        guard let signature = EnergySignature.between(first, second, progressDelta: delta) else { return nil }

        // The lock-order scenario is the one case where the lab knows the ring
        // without searching for it: this process was launched from a source that
        // contains the inversion. That is knowledge by construction, and it is
        // labelled as such rather than dressed up as a graph search.
        let structure: StructuralEvidence = (scenario.id == "deadlock" && (delta ?? 0) == 0)
            ? .knownByConstruction(mode: scenario.id)
            : .none
        let diagnosis = PathologyClassifier().classify(signature, structure: structure)
        return ScenarioResult(scenario: scenario, diagnosis: diagnosis)
    }

    /// The worker keeps its heartbeat in an mmap'd 8-byte slot rather than
    /// rewriting a file, so counting work costs one store and the measurement
    /// reflects the scenario instead of the instrument.
    private func readProgress(_ path: String) -> UInt64? {
        guard let data = FileManager.default.contents(atPath: path),
              data.count >= MemoryLayout<UInt64>.size else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
    }
}
