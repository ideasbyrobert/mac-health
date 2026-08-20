import Foundation

/// One process, measured over one window, with the lab's verdict attached.
public struct ProcessDiagnosis: Sendable {
    public let process: RunningProcess
    public let diagnosis: Diagnosis

    public init(process: RunningProcess, diagnosis: Diagnosis) {
        self.process = process
        self.diagnosis = diagnosis
    }

    public var cyclesPerSecond: Double { diagnosis.signature.cyclesPerSecond }
}

/// What the machine was spending energy on over one window.
///
/// The shape a daemon logs on a timer and a UI renders: a total, an ordering,
/// and a census. It also carries how many processes could not be read, because
/// a total that silently omits half the machine is a worse lie than a smaller
/// total that says so.
public struct EnergyReport: Sendable {
    public let at: Date
    public let window: TimeInterval
    /// Every process the observer could measure across both ends of the window,
    /// ordered by cycles per second, most expensive first.
    public let observed: [ProcessDiagnosis]
    /// Processes present in the roster that the observer could not measure —
    /// they exited, or the sampler was not permitted to read them. Counted, not
    /// guessed at.
    public let unreadable: Int

    public init(at: Date, window: TimeInterval, observed: [ProcessDiagnosis], unreadable: Int) {
        self.at = at
        self.window = window
        self.observed = observed
        self.unreadable = unreadable
    }

    /// The machine's measured cycle rate. Cycles rather than an energy estimate,
    /// because cycles are what the hardware actually counted.
    public var totalCyclesPerSecond: Double {
        observed.reduce(0) { $0 + $1.cyclesPerSecond }
    }

    public func topConsumers(_ limit: Int = 10) -> [ProcessDiagnosis] {
        Array(observed.prefix(max(0, limit)))
    }

    /// The share of measured cycles one process accounts for, in 0...1. Zero
    /// when nothing was measured, rather than a division by zero dressed up as
    /// a percentage.
    public func share(_ entry: ProcessDiagnosis) -> Double {
        let total = totalCyclesPerSecond
        guard total > 0 else { return 0 }
        return entry.cyclesPerSecond / total
    }

    public var pathologyCounts: [Pathology: Int] {
        var counts: [Pathology: Int] = [:]
        for entry in observed {
            counts[entry.diagnosis.pathology, default: 0] += 1
        }
        return counts
    }

    /// The census in a stable order, so a log line does not reshuffle itself
    /// between cycles. Pathologies with no members are omitted.
    public func tally() -> [(pathology: Pathology, count: Int)] {
        let counts = pathologyCounts
        return Pathology.allCases.compactMap { pathology in
            guard let count = counts[pathology], count > 0 else { return nil }
            return (pathology, count)
        }
    }

    /// Diagnoses evidenced strongly enough to justify acting on them. The
    /// methodology's rule, applied literally: weaker claims may be shown and
    /// explained, never used to drive execution.
    public var actionable: [ProcessDiagnosis] {
        observed.filter { $0.diagnosis.confidence.mayDriveAction }
    }

    /// A single line for a daemon's log. States what was measured and what was
    /// missed; names no pathology the evidence does not carry.
    public func summaryLine() -> String {
        let total = Self.formatRate(totalCyclesPerSecond)
        let census = tally()
            .map { "\($0.count) \($0.pathology.rawValue)" }
            .joined(separator: ", ")
        let leader = observed.first.map {
            String(format: "%@ leads at %@ (%.0f%%)",
                   $0.process.name,
                   Self.formatRate($0.cyclesPerSecond),
                   share($0) * 100)
        } ?? "nothing measurable"
        return String(
            format: "%.1fs window: %d processes at %@ cycles/s total, %d unreadable. %@. %@",
            window, observed.count, total, unreadable, leader, census
        )
    }

    /// Cycles per second is a number with six orders of magnitude of useful
    /// range on this machine — 1.5e5 for a blocking wait, 3.9e9 for a spin
    /// loop — so it is always shown scaled rather than as raw digits.
    public static func formatRate(_ cyclesPerSecond: Double) -> String {
        switch cyclesPerSecond {
        case 1e9...: return String(format: "%.2f G", cyclesPerSecond / 1e9)
        case 1e6...: return String(format: "%.1f M", cyclesPerSecond / 1e6)
        case 1e3...: return String(format: "%.1f K", cyclesPerSecond / 1e3)
        default: return String(format: "%.0f", cyclesPerSecond)
        }
    }
}

/// Watches the machine's real processes and reports where its energy is going.
///
/// This is the always-on half of the lab, and it operates under a strictly
/// weaker evidence standard than the chaos scenarios do. The lab spawns its own
/// workers and can therefore read their heartbeat; it did not spawn Safari, and
/// has no way to ask whether Safari made forward progress. Since a deadlocked
/// process and a healthy blocked one are separated by the progress signal and
/// by nothing else — on this machine they differ by 0.01 percentage points of
/// CPU — the observer never claims a deadlock it cannot prove. It reports what
/// it measured and turns the gap into a question.
public struct EnergyObserver {
    let sampler: ProcessSampling
    let roster: ProcessEnumerating
    private let classifier = PathologyClassifier()

    public init(
        sampler: ProcessSampling = KernelProcessSampler(),
        roster: ProcessEnumerating = LibprocRoster()
    ) {
        self.sampler = sampler
        self.roster = roster
    }

    /// Samples every process the roster offers, waits out the window, samples
    /// again, and keeps only the processes that were readable and monotonic at
    /// both ends. Sorted by cycles per second, most expensive first.
    ///
    /// Blocks for `window`. A caller that must stay responsive runs this off the
    /// main thread; the sleep is the measurement, not overhead.
    public func observe(window: TimeInterval) -> [ProcessDiagnosis] {
        report(window: window).observed
    }

    /// The same measurement, with the totals and the census a daemon needs.
    public func report(window: TimeInterval) -> EnergyReport {
        guard window > 0 else {
            return EnergyReport(at: Date(), window: window, observed: [], unreadable: 0)
        }

        let processes = roster.running()
        var known: [Int32: RunningProcess] = [:]
        var first: [Int32: EnergySample] = [:]
        first.reserveCapacity(processes.count)

        for process in processes {
            // Each sample carries its own timestamp rather than one shared
            // start time: walking a thousand pids takes long enough that a
            // shared stamp would overstate the rate of every process read late
            // in the pass.
            guard let sample = sampler.sample(pid: process.pid, now: Date()) else { continue }
            first[process.pid] = sample
            known[process.pid] = process
        }

        Thread.sleep(forTimeInterval: window)

        var results: [ProcessDiagnosis] = []
        results.reserveCapacity(first.count)
        for (pid, before) in first {
            // A process that exited or became unreadable during the window is
            // omitted. Reporting it with zeroed counters would turn "no data"
            // into "no work", which is exactly the confusion this lab exists to
            // undo.
            guard let process = known[pid],
                  let after = sampler.sample(pid: pid, now: Date()),
                  let signature = EnergySignature.between(before, after, progressDelta: nil)
            else { continue }
            results.append(ProcessDiagnosis(process: process, diagnosis: diagnose(signature)))
        }

        results.sort {
            $0.cyclesPerSecond == $1.cyclesPerSecond
                ? $0.process.pid < $1.process.pid
                : $0.cyclesPerSecond > $1.cyclesPerSecond
        }

        return EnergyReport(
            at: Date(),
            window: window,
            observed: results,
            unreadable: processes.count - results.count
        )
    }

    /// The classifier is passed `progressDelta: nil` and no structural evidence
    /// because both are true: the observer has no heartbeat from a process it
    /// did not spawn, and it has not walked anyone's wait edges. Fabricating a
    /// progress value to get a crisper verdict would be manufacturing domain
    /// truth.
    ///
    /// The guard below is a belt-and-braces check on that contract. The
    /// classifier already answers `indeterminate` when progress is unknown; if a
    /// future change to it ever did otherwise, an accusation of deadlock would
    /// still not escape this file. Telling someone their editor is deadlocked
    /// when it is merely waiting for them to type is worse than saying nothing.
    private func diagnose(_ signature: EnergySignature) -> Diagnosis {
        let verdict = classifier.classify(signature, structure: .none)
        guard verdict.pathology == .deadlock else { return verdict }
        return Diagnosis(
            signature: signature,
            pathology: .indeterminate,
            confidence: .unknown,
            evidence: verdict.evidence + [
                "this process was not started by the lab, so no forward-progress signal exists for it",
                "a deadlocked process and a healthy blocked process are indistinguishable in these counters"
            ],
            inquiry: "To separate the two, watch this process under `energy watch`, or capture its wait edges: only a proven cycle in the wait-for graph justifies the word deadlock."
        )
    }
}
