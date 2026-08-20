import Foundation

/// A named way for work to stop converting energy into progress.
///
/// Each case is a distinct *shape* in the counters, not a severity level. The
/// point of the taxonomy is that CPU percentage alone cannot separate them:
/// a deadlocked process and a perfectly healthy idle one both read 0%.
public enum Pathology: String, Codable, CaseIterable, Sendable {
    /// Energy in, progress out. The machine is doing its job.
    case healthy
    /// Blocked on something that will arrive. Costs almost nothing while it waits.
    case idleWaiting
    /// A cycle in the wait-for graph. No cycles burned, no progress ever again.
    case deadlock
    /// Burning cycles at full rate, achieving nothing. The most expensive state
    /// a machine can be in.
    case livelock
    /// Correct results, absurd cost: waking hundreds of times a second to poll
    /// for work that an event would have delivered for free.
    case wakeupStorm
    /// Progress continues but each unit costs far more than it should, because
    /// the work is stalled on memory rather than executing.
    case stalled
    /// The counters cannot separate two very different explanations.
    case indeterminate

    public var sfSymbol: String {
        switch self {
        case .healthy: return "leaf.fill"
        case .idleWaiting: return "moon.zzz.fill"
        case .deadlock: return "lock.trianglebadge.exclamationmark.fill"
        case .livelock: return "arrow.triangle.2.circlepath"
        case .wakeupStorm: return "alarm.waves.left.and.right.fill"
        case .stalled: return "tortoise.fill"
        case .indeterminate: return "questionmark.circle"
        }
    }

    /// Not a judgement of the process — a description of what the *energy* is
    /// doing, which is the only thing the lab actually measured.
    ///
    /// The wording depends on confidence because some of these sentences name a
    /// *structure* ("a cycle in the wait-for graph") that only a settled verdict
    /// has any right to assert. Below `.known` the headline must describe the
    /// reading instead of the conclusion, or the confidence label ends up
    /// arguing with the sentence next to it — and the sentence is what lands.
    public func headline(at confidence: Confidence = .known) -> String {
        let settled = confidence >= .known
        switch self {
        case .healthy:
            return settled ? "Energy is becoming progress" : "Unremarkable cost, no pathology visible"
        case .idleWaiting:
            return "Waiting cheaply, as it should"
        case .deadlock:
            // "cycles" is deliberately absent from the unsettled wording: the
            // word means CPU cycles here and graph cycles above, and a reader
            // cannot be expected to carry both senses at once.
            return settled ? "Frozen: a cycle in the wait-for graph"
                           : "Silent: consuming no CPU and completing no work"
        case .livelock:
            return settled ? "Burning at full rate, achieving nothing"
                           : "Consuming cycles with no work completing"
        case .wakeupStorm:
            // Says only what was counted. Whether the output is correct is not
            // something a wakeup rate can tell anyone.
            return "Waking hundreds of times a second"
        case .stalled:
            return "Running, but retiring very few instructions per cycle"
        case .indeterminate:
            return "Not enough evidence to say"
        }
    }
}

/// What the lab knows about a process's *structure*, as opposed to its counters.
///
/// The distinction matters because the lab's strongest verdict used to be minted
/// from a string comparison against a scenario name while claiming a graph
/// search had happened. A construction is not an observation; neither is a
/// guess. Each is stated as itself.
public enum StructuralEvidence: Sendable {
    /// Nothing but counters.
    case none
    /// The lab launched this worker itself, in a mode whose wait-for ring is
    /// visible in its source. Strong evidence, but read from code, not harvested.
    case knownByConstruction(mode: String)
    /// A cycle was actually found by searching a wait-for graph.
    case cycleFound(DeadlockCycle)
}

/// The lab's verdict about one process over one observation window.
public struct Diagnosis: Sendable {
    public let signature: EnergySignature
    public let pathology: Pathology
    public let confidence: Confidence
    public let evidence: [String]
    /// What would raise the confidence, when it is not already `known`. The
    /// methodology's rule: an unknown becomes an inquiry, never a blank.
    public let inquiry: String?

    public init(
        signature: EnergySignature, pathology: Pathology,
        confidence: Confidence, evidence: [String], inquiry: String? = nil
    ) {
        self.signature = signature
        self.pathology = pathology
        self.confidence = confidence
        self.evidence = evidence
        self.inquiry = inquiry
    }
}

/// Turns counters into a named pathology, and refuses to name one when the
/// counters genuinely do not distinguish the possibilities.
public struct PathologyClassifier: Sendable {

    // These four are round numbers chosen by hand, informed by the measurements
    // in docs/energy-lab.md and not derived from first principles. Each one
    // decides what the lab is willing to name, so changing one changes the
    // verdicts — they are policy, not physics.

    /// Below this, treat the process as doing essentially nothing.
    public static let quiescentCyclesPerSecond = 1_000_000.0
    /// Above this, sustained wakeups are assumed to be denying the package its
    /// deep idle states often enough to matter.
    public static let wakeupStormPerSecond = 100.0
    /// Retired instructions per cycle. A low value on a superscalar core is
    /// *consistent with* the pipeline waiting on memory, but cache misses,
    /// false sharing and lock contention all produce it, which is why this
    /// branch never returns better than `.probable`.
    public static let stalledIPC = 0.35
    /// Roughly one core saturated.
    public static let saturatedCPUPercent = 90.0

    public init() {}

    public func classify(_ s: EnergySignature, structure: StructuralEvidence = .none) -> Diagnosis {
        var evidence: [String] = [
            String(format: "%.0f cycles/s", s.cyclesPerSecond),
            String(format: "%.2f instructions/cycle", s.instructionsPerCycle),
            String(format: "%.2f%% CPU", s.cpuPercent),
            String(format: "%.1f package-idle wakeups/s", s.packageIdleWakeupsPerSecond)
        ]
        if let progress = s.progressPerSecond {
            evidence.append(String(format: "%.2f work units/s", progress))
        }

        // Structural knowledge outranks every inference from counters: it says
        // forward progress is impossible rather than merely absent. Each kind of
        // structural evidence states its own provenance, so a verdict can never
        // describe a graph search that did not happen.
        switch structure {
        case .cycleFound(let cycle):
            return Diagnosis(
                signature: s, pathology: .deadlock, confidence: .known,
                evidence: evidence + ["a cycle was found in the wait-for graph: \(cycle.describe())"]
            )
        case .knownByConstruction(let mode):
            return Diagnosis(
                signature: s, pathology: .deadlock, confidence: .known,
                evidence: evidence + [
                    "the worker was launched in '\(mode)' mode, whose wait-for ring is visible in its source",
                    "the ring is known from that source, not harvested from live wait edges"
                ]
            )
        case .none:
            break
        }

        let quiescent = s.cyclesPerSecond < Self.quiescentCyclesPerSecond
        let makingProgress = (s.progressPerSecond ?? 0) > 0

        if quiescent {
            guard let progress = s.progressPerSecond else {
                // This is the honest centre of the whole design. Zero cycles is
                // exactly what a healthy blocked process looks like AND exactly
                // what a deadlocked one looks like. Without a progress signal
                // the counters cannot choose, so the lab does not choose either.
                return Diagnosis(
                    signature: s, pathology: .indeterminate, confidence: .unknown,
                    evidence: evidence + [
                        "no forward-progress signal available",
                        "a deadlocked process and a healthy blocked process both read ~0% CPU"
                    ],
                    inquiry: "Does this process make forward progress? Attach a heartbeat, or sample its wait edges, to separate deadlock from healthy waiting."
                )
            }
            if progress > 0 {
                return Diagnosis(
                    signature: s, pathology: .idleWaiting, confidence: .known,
                    evidence: evidence + ["blocked between units of work, and work is still completing"]
                )
            }
            return Diagnosis(
                signature: s, pathology: .deadlock, confidence: .probable,
                evidence: evidence + ["no cycles consumed and no work completed during the window"],
                inquiry: "Confirm by sampling the wait edges: a proven cycle in the wait-for graph raises this from probable to known."
            )
        }

        // Burning cycles. The question is whether any of it becomes progress.
        if s.progressPerSecond != nil && !makingProgress {
            let saturated = s.cpuPercent >= Self.saturatedCPUPercent
            return Diagnosis(
                signature: s, pathology: .livelock,
                confidence: saturated ? .known : .probable,
                evidence: evidence + ["cycles are being consumed but no work is completing"],
                inquiry: saturated ? nil : "Widen the observation window: a slow producer can look like a livelock over a short sample."
            )
        }

        if s.packageIdleWakeupsPerSecond >= Self.wakeupStormPerSecond
            || s.interruptWakeupsPerSecond >= Self.wakeupStormPerSecond {
            let rate = max(s.packageIdleWakeupsPerSecond, s.interruptWakeupsPerSecond)
            let counted = String(format: "%.0f wakeups/s, which denies the package its deep idle states", rate)
            // A wakeup rate cannot distinguish wasteful polling from genuinely
            // event-driven work at a high event rate. Only a progress signal can
            // say whether those wakeups bought anything, and `known` is the one
            // confidence that opens `mayDriveAction` — so it is not granted on a
            // hand-picked threshold alone.
            guard makingProgress else {
                return Diagnosis(
                    signature: s, pathology: .wakeupStorm, confidence: .probable,
                    evidence: evidence + [counted],
                    inquiry: "Is this rate intentional? A wakeup count alone cannot separate wasteful polling from event-driven work at a genuinely high event rate. Compare wakeups against units of work completed."
                )
            }
            return Diagnosis(
                signature: s, pathology: .wakeupStorm, confidence: .known,
                evidence: evidence + [
                    counted,
                    String(format: "%.1f wakeups for every unit of work completed",
                           rate / max(s.progressPerSecond ?? 1, 0.0001))
                ]
            )
        }

        if s.instructionsPerCycle < Self.stalledIPC && s.cpuPercent > 10.0 {
            return Diagnosis(
                signature: s, pathology: .stalled, confidence: .probable,
                evidence: evidence + ["fewer than one instruction retired every three cycles"],
                inquiry: "Confirm with a memory-hierarchy profile: low IPC is consistent with cache misses, false sharing, and lock contention alike."
            )
        }

        // "Energy is becoming progress" is a claim about progress, so it cannot
        // be `known` without a progress signal. A process the lab did not spawn
        // has none: a busy loop that achieves nothing looks identical to useful
        // work from the counters alone. Saying `healthy` with certainty here
        // would be the same error as calling an unreadable GPU report a clean
        // bill of health.
        guard makingProgress else {
            return Diagnosis(
                signature: s, pathology: .healthy, confidence: .probable,
                evidence: evidence + ["consuming cycles at an unremarkable rate, with no sign of the pathologies above"],
                inquiry: "No forward-progress signal is available for this process, so 'healthy' is an inference from cost alone. Attach a heartbeat, or watch a metric the process itself advances, to raise this to known."
            )
        }

        return Diagnosis(
            signature: s, pathology: .healthy, confidence: .known,
            evidence: evidence
        )
    }
}
