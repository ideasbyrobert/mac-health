import Testing
import Foundation
@testable import EnergyLab

/// The classifier is where the lab is either honest or not. Most of these tests
/// pin a branch; the first one pins the refusal that the whole design exists to
/// make, and the last one pins it as a property rather than a single case.
struct PathologyClassifierTests {

    let classifier = PathologyClassifier()

    // MARK: the refusal

    /// Zero cycles is exactly what a deadlocked process looks like and exactly
    /// what a healthy blocked process looks like. With no progress signal the
    /// counters cannot choose between them, so the lab must not choose either.
    /// This is the central claim of the design: everything else in the file is
    /// less important than this test.
    @Test func quiescentWithoutAProgressSignalRefusesToSayDeadlock() {
        let diagnosis = classifier.classify(
            signature(cyclesPerSecond: 0, instructionsPerCycle: 0, cpuPercent: 0, progressPerSecond: nil)
        )

        #expect(diagnosis.pathology == .indeterminate)
        #expect(diagnosis.pathology != .deadlock)
        #expect(diagnosis.confidence == .unknown)
        #expect(diagnosis.inquiry != nil)
        #expect(!diagnosis.confidence.mayDriveAction)
    }

    /// The unknown is turned into a question, not a blank: the inquiry names
    /// the measurement that would resolve it.
    @Test func theRefusalExplainsWhatWouldResolveIt() throws {
        let diagnosis = classifier.classify(signature(cyclesPerSecond: 0, progressPerSecond: nil))
        let inquiry = try #require(diagnosis.inquiry)

        #expect(inquiry.lowercased().contains("progress"))
        #expect(diagnosis.evidence.contains { $0.contains("no forward-progress signal") })
    }

    /// The two readings that a human eye cannot separate, side by side. Only
    /// the progress signal differs, and only the verdict follows it.
    @Test func silenceWithAndWithoutProgressDivergeOnlyBecauseOfProgress() {
        let silent = signature(cyclesPerSecond: 0, progressPerSecond: nil)
        let silentButWorking = signature(cyclesPerSecond: 0, progressPerSecond: 5.0)

        #expect(silent.cpuPercent == silentButWorking.cpuPercent)
        #expect(classifier.classify(silent).pathology == .indeterminate)
        #expect(classifier.classify(silentButWorking).pathology == .idleWaiting)
    }

    // MARK: quiescent branches

    @Test func quiescentWithProgressIsHealthyWaiting() {
        let diagnosis = classifier.classify(Measured.healthy)

        #expect(diagnosis.pathology == .idleWaiting)
        #expect(diagnosis.confidence == .known)
        #expect(diagnosis.inquiry == nil)
    }

    @Test func quiescentWithNoWorkCompletedIsAProbableDeadlock() {
        let diagnosis = classifier.classify(Measured.deadlock)

        #expect(diagnosis.pathology == .deadlock)
        #expect(diagnosis.confidence == .probable)
        #expect(diagnosis.inquiry != nil)
        #expect(!diagnosis.confidence.mayDriveAction)
    }

    /// The classifier reads the counters, not the scenario name: the pipe
    /// deadlock has no mutex in it and produces the same verdict.
    @Test func aBackpressureDeadlockLooksIdenticalToALockInversion() {
        let pipe = classifier.classify(Measured.pipeDeadlock)
        let locks = classifier.classify(Measured.deadlock)

        #expect(pipe.pathology == locks.pathology)
        #expect(pipe.confidence == locks.confidence)
    }

    @Test func cyclesExactlyAtTheQuiescentThresholdAreNotQuiescent() {
        let diagnosis = classifier.classify(signature(
            cyclesPerSecond: PathologyClassifier.quiescentCyclesPerSecond,
            instructionsPerCycle: 1.0,
            cpuPercent: 1.0,
            progressPerSecond: nil
        ))

        #expect(diagnosis.pathology != .indeterminate)
        #expect(diagnosis.pathology == .healthy)
    }

    // MARK: proof outranks inference

    /// A cycle found in the wait-for graph is structural: it says forward
    /// progress is impossible regardless of what the counters happen to read.
    @Test func aFoundCycleOutranksEveryCounter() {
        let t1 = Actor(pid: 9, threadID: 1, label: "T1")
        let t2 = Actor(pid: 9, threadID: 2, label: "T2")
        let ring = DeadlockCycle(edges: [
            WaitEdge(waiter: t1, holder: t2, gate: .mutex("B")),
            WaitEdge(waiter: t2, holder: t1, gate: .mutex("A"))
        ])
        let diagnosis = classifier.classify(Measured.livelock, structure: .cycleFound(ring))

        #expect(diagnosis.pathology == .deadlock)
        #expect(diagnosis.confidence == .known)
        #expect(diagnosis.confidence.mayDriveAction)
        #expect(diagnosis.evidence.contains { $0.contains("cycle was found in the wait-for graph") })
        #expect(diagnosis.evidence.contains { $0.contains("T1") && $0.contains("T2") })
    }

    /// Knowledge by construction is strong, but it is not an observation, and
    /// the evidence must not claim a graph search that never ran.
    @Test func constructionEvidenceNeverClaimsAGraphSearch() {
        let diagnosis = classifier.classify(Measured.deadlock, structure: .knownByConstruction(mode: "deadlock"))

        #expect(diagnosis.pathology == .deadlock)
        #expect(diagnosis.confidence == .known)
        #expect(!diagnosis.evidence.contains { $0.contains("cycle was found") })
        #expect(diagnosis.evidence.contains { $0.contains("known from that source") })
    }

    @Test func aProvenCycleNeedsNoFurtherInquiry() {
        let diagnosis = classifier.classify(Measured.deadlock, structure: .knownByConstruction(mode: "deadlock"))
        #expect(diagnosis.confidence == .known)
        #expect(diagnosis.inquiry == nil)
    }

    // MARK: burning cycles

    @Test func saturatedSpinningWithoutProgressIsAKnownLivelock() {
        let diagnosis = classifier.classify(Measured.livelock)

        #expect(diagnosis.pathology == .livelock)
        #expect(diagnosis.confidence == .known)
        #expect(diagnosis.inquiry == nil)
    }

    /// Below saturation the same shape has an innocent explanation — a slow
    /// producer sampled over too short a window — so the verdict is softened
    /// and the inquiry names the fix.
    @Test func unsaturatedSpinningWithoutProgressStaysProbable() throws {
        let diagnosis = classifier.classify(signature(
            cyclesPerSecond: 1_800_000_000,
            instructionsPerCycle: 1.9,
            cpuPercent: 40.0,
            progressPerSecond: 0
        ))

        #expect(diagnosis.pathology == .livelock)
        #expect(diagnosis.confidence == .probable)
        let inquiry = try #require(diagnosis.inquiry)
        #expect(inquiry.lowercased().contains("window"))
    }

    @Test func cpuExactlyAtSaturationIsAKnownLivelock() {
        let diagnosis = classifier.classify(signature(
            cyclesPerSecond: 3_000_000_000,
            instructionsPerCycle: 2.0,
            cpuPercent: PathologyClassifier.saturatedCPUPercent,
            progressPerSecond: 0
        ))

        #expect(diagnosis.pathology == .livelock)
        #expect(diagnosis.confidence == .known)
    }

    /// The lab cannot call anything a livelock without a progress signal: with
    /// no way to see work completing, a busy process is just a busy process.
    @Test func busyWithoutAProgressSignalIsNotCalledALivelock() {
        let diagnosis = classifier.classify(signature(
            cyclesPerSecond: 3_900_000_000,
            instructionsPerCycle: 2.05,
            cpuPercent: 99.36,
            progressPerSecond: nil
        ))

        #expect(diagnosis.pathology != .livelock)
        #expect(diagnosis.pathology == .healthy)
    }

    // MARK: wakeups

    @Test func pollingIsAWakeupStorm() {
        let diagnosis = classifier.classify(Measured.wakeupStorm)

        #expect(diagnosis.pathology == .wakeupStorm)
        #expect(diagnosis.confidence == .known)
        #expect(diagnosis.inquiry == nil)
    }

    /// The storm is diagnosed from wakeups, not from CPU: this reading is
    /// barely over 1% CPU and is still the second most expensive scenario in
    /// the catalogue.
    @Test func aWakeupStormHidesBehindNegligibleCPU() {
        #expect(Measured.wakeupStorm.cpuPercent < 2.0)
        #expect(classifier.classify(Measured.wakeupStorm).pathology == .wakeupStorm)
    }

    @Test func interruptWakeupsAloneRaiseTheStorm() {
        let diagnosis = classifier.classify(signature(
            cyclesPerSecond: 20_000_000,
            instructionsPerCycle: 0.9,
            cpuPercent: 1.5,
            interruptWakeupsPerSecond: 400.0,
            packageIdleWakeupsPerSecond: 0,
            progressPerSecond: 5.0
        ))

        #expect(diagnosis.pathology == .wakeupStorm)
    }

    @Test func wakeupsExactlyAtTheThresholdCountAsAStorm() {
        let diagnosis = classifier.classify(signature(
            cyclesPerSecond: 20_000_000,
            instructionsPerCycle: 0.9,
            cpuPercent: 1.5,
            packageIdleWakeupsPerSecond: PathologyClassifier.wakeupStormPerSecond,
            progressPerSecond: 5.0
        ))

        #expect(diagnosis.pathology == .wakeupStorm)
    }

    // MARK: stalls

    @Test func memoryBoundWorkIsAProbableStall() {
        let diagnosis = classifier.classify(Measured.stalled)

        #expect(diagnosis.pathology == .stalled)
        #expect(diagnosis.confidence == .probable)
        #expect(diagnosis.inquiry != nil)
    }

    /// Low IPC has several causes — cache misses, false sharing, lock
    /// contention — so the counters alone can never make this one known.
    @Test func aStallIsNeverStatedAsKnown() throws {
        let diagnosis = classifier.classify(Measured.stalled)
        let inquiry = try #require(diagnosis.inquiry)

        #expect(diagnosis.confidence < .known)
        #expect(inquiry.lowercased().contains("memory"))
    }

    @Test func ipcExactlyAtTheStallThresholdIsNotAStall() {
        let diagnosis = classifier.classify(signature(
            cyclesPerSecond: 2_000_000_000,
            instructionsPerCycle: PathologyClassifier.stalledIPC,
            cpuPercent: 50.0,
            progressPerSecond: 5.0
        ))

        #expect(diagnosis.pathology == .healthy)
    }

    /// Low IPC at a trivial duty cycle is not worth a name: the process is
    /// barely running, so nothing is being wasted at scale.
    @Test func lowIPCAtNegligibleCPUIsNotCalledAStall() {
        let diagnosis = classifier.classify(signature(
            cyclesPerSecond: 2_000_000,
            instructionsPerCycle: 0.1,
            cpuPercent: 10.0,
            progressPerSecond: 5.0
        ))

        #expect(diagnosis.pathology == .healthy)
    }

    // MARK: health

    @Test func ordinaryWorkIsHealthy() {
        let diagnosis = classifier.classify(signature(
            cyclesPerSecond: 2_000_000_000,
            instructionsPerCycle: 1.8,
            cpuPercent: 45.0,
            packageIdleWakeupsPerSecond: 12.0,
            progressPerSecond: 40.0
        ))

        #expect(diagnosis.pathology == .healthy)
        #expect(diagnosis.confidence == .known)
        #expect(diagnosis.inquiry == nil)
        #expect(diagnosis.confidence.mayDriveAction)
    }

    /// The same counters that condemn the livelock acquit it once work is
    /// visibly completing. Cost alone is not a defect; cost without progress is.
    @Test func theLivelockCountersBecomeHealthyOnceWorkCompletes() {
        let spinning = classifier.classify(Measured.livelock)
        let working = classifier.classify(signature(
            cyclesPerSecond: Measured.livelock.cyclesPerSecond,
            instructionsPerCycle: Measured.livelock.instructionsPerCycle,
            cpuPercent: Measured.livelock.cpuPercent,
            progressPerSecond: 5.0
        ))

        #expect(spinning.pathology == .livelock)
        #expect(working.pathology == .healthy)
    }

    // MARK: evidence

    @Test func everyDiagnosisQuotesTheCountersItUsed() {
        let diagnosis = classifier.classify(Measured.wakeupStorm)

        #expect(diagnosis.evidence.contains { $0.contains("cycles/s") })
        #expect(diagnosis.evidence.contains { $0.contains("instructions/cycle") })
        #expect(diagnosis.evidence.contains { $0.contains("% CPU") })
        #expect(diagnosis.evidence.contains { $0.contains("wakeups/s") })
    }

    @Test func progressIsQuotedOnlyWhenItWasMeasured() {
        let measured = classifier.classify(signature(cyclesPerSecond: 0, progressPerSecond: 5.0))
        let absent = classifier.classify(signature(cyclesPerSecond: 0, progressPerSecond: nil))

        #expect(measured.evidence.contains { $0.contains("work units/s") })
        #expect(!absent.evidence.contains { $0.contains("work units/s") })
    }

    @Test func theSignatureIsCarriedIntoTheDiagnosis() {
        let input = Measured.stalled
        #expect(classifier.classify(input).signature == input)
    }

    // MARK: properties across every branch

    /// The methodology's rule stated as a property rather than a case: a claim
    /// the lab cannot fully evidence must arrive with the question that would
    /// settle it, and a fully evidenced one must not pad itself with one.
    @Test func confidenceBelowKnownAlwaysCarriesAnInquiry() {
        for (name, input, proven) in Self.everyBranch {
            let diagnosis = classifier.classify(input, structure: proven ? .knownByConstruction(mode: "deadlock") : .none)
            if diagnosis.confidence < .known {
                #expect(diagnosis.inquiry != nil, "\(name) is \(diagnosis.confidence.rawValue) but asks nothing")
            } else {
                #expect(diagnosis.inquiry == nil, "\(name) is known yet still asks a question")
            }
        }
    }

    @Test func onlyFullyEvidencedVerdictsMayDriveAction() {
        for (name, input, proven) in Self.everyBranch {
            let diagnosis = classifier.classify(input, structure: proven ? .knownByConstruction(mode: "deadlock") : .none)
            #expect(
                diagnosis.confidence.mayDriveAction == (diagnosis.confidence == .known),
                "\(name) disagrees with its own confidence about acting"
            )
        }
    }

    @Test func everyDiagnosisCarriesAtLeastTheFourBaseCounters() {
        for (name, input, proven) in Self.everyBranch {
            let diagnosis = classifier.classify(input, structure: proven ? .knownByConstruction(mode: "deadlock") : .none)
            #expect(diagnosis.evidence.count >= 4, "\(name) reported \(diagnosis.evidence.count) lines of evidence")
        }
    }

    /// Every named pathology has to be reachable, or the taxonomy contains a
    /// case the classifier can never emit.
    @Test func theBranchTableReachesEveryPathology() {
        let reached = Set(Self.everyBranch.map { classifier.classify($0.input, structure: $0.proven ? .knownByConstruction(mode: "deadlock") : .none).pathology })
        #expect(reached == Set(Pathology.allCases))
    }

    /// One row per branch of `classify`, named so a failure says which one.
    static let everyBranch: [(name: String, input: EnergySignature, proven: Bool)] = [
        ("proven cycle", Measured.livelock, true),
        ("quiescent, progress unknown", signature(cyclesPerSecond: 0, progressPerSecond: nil), false),
        ("quiescent, progressing", Measured.healthy, false),
        ("quiescent, no progress", Measured.deadlock, false),
        ("saturated livelock", Measured.livelock, false),
        ("unsaturated livelock", signature(
            cyclesPerSecond: 1_800_000_000, instructionsPerCycle: 1.9,
            cpuPercent: 40.0, progressPerSecond: 0), false),
        ("wakeup storm", Measured.wakeupStorm, false),
        ("stalled", Measured.stalled, false),
        ("healthy", signature(
            cyclesPerSecond: 2_000_000_000, instructionsPerCycle: 1.8,
            cpuPercent: 45.0, packageIdleWakeupsPerSecond: 12.0, progressPerSecond: 40.0), false)
    ]
}

// MARK: helpers

private let labPID: Int32 = 501

private func signature(
    cyclesPerSecond: Double,
    instructionsPerCycle: Double = 1.0,
    cpuPercent: Double = 0.0,
    interruptWakeupsPerSecond: Double = 0.0,
    packageIdleWakeupsPerSecond: Double = 0.0,
    progressPerSecond: Double? = nil,
    window: TimeInterval = 3.0
) -> EnergySignature {
    EnergySignature(
        pid: labPID,
        window: window,
        cyclesPerSecond: cyclesPerSecond,
        instructionsPerCycle: instructionsPerCycle,
        cpuPercent: cpuPercent,
        interruptWakeupsPerSecond: interruptWakeupsPerSecond,
        packageIdleWakeupsPerSecond: packageIdleWakeupsPerSecond,
        progressPerSecond: progressPerSecond
    )
}

/// Readings taken from the six chaos workers on the development machine over a
/// three-second window, each worker asked to complete one work unit every
/// 200 ms. These are observations, not invented thresholds; the ratios between
/// them are order-of-magnitude only, since a near-idle baseline moves around on
/// a loaded machine.
private enum Measured {
    static let healthy = signature(
        cyclesPerSecond: 152_996, instructionsPerCycle: 0.19, cpuPercent: 0.01,
        packageIdleWakeupsPerSecond: 1.0, progressPerSecond: 5.0)

    static let wakeupStorm = signature(
        cyclesPerSecond: 21_746_369, instructionsPerCycle: 0.22, cpuPercent: 1.29,
        packageIdleWakeupsPerSecond: 804.5, progressPerSecond: 5.0)

    static let livelock = signature(
        cyclesPerSecond: 3_917_410_412, instructionsPerCycle: 2.05, cpuPercent: 99.36,
        packageIdleWakeupsPerSecond: 0.0, progressPerSecond: 0)

    static let deadlock = signature(
        cyclesPerSecond: 0, instructionsPerCycle: 0, cpuPercent: 0,
        packageIdleWakeupsPerSecond: 0, progressPerSecond: 0)

    /// No mutex is involved: the gate is a full pipe buffer. The counters are
    /// indistinguishable from the lock-inversion case all the same.
    static let pipeDeadlock = signature(
        cyclesPerSecond: 0, instructionsPerCycle: 0, cpuPercent: 0,
        packageIdleWakeupsPerSecond: 0, progressPerSecond: 0)

    static let stalled = signature(
        cyclesPerSecond: 2_282_394_334, instructionsPerCycle: 0.06, cpuPercent: 99.47,
        packageIdleWakeupsPerSecond: 0.0, progressPerSecond: 5.0)
}
