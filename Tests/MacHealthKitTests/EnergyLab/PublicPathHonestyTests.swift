import Testing
import Foundation
@testable import EnergyLab

/// These pin the promises the lab makes to a user, at the boundary the user
/// actually touches. Each one exists because the same guarantee stated only in
/// a comment held by accident, and an accident is not a guarantee.
struct PublicPathHonestyTests {

    let classifier = PathologyClassifier()

    /// A signature with no heartbeat, which is every process the lab did not
    /// spawn itself.
    func unobservable(cycles: Double, ipc: Double = 0.8, cpu: Double = 5, wakeups: Double = 5) -> EnergySignature {
        EnergySignature(
            pid: 42, window: 2, cyclesPerSecond: cycles, instructionsPerCycle: ipc,
            cpuPercent: cpu, interruptWakeupsPerSecond: wakeups,
            packageIdleWakeupsPerSecond: wakeups, progressPerSecond: nil
        )
    }

    /// The single most important promise in the project: telling someone their
    /// application is deadlocked when it is merely waiting for them to type
    /// would be worse than saying nothing at all.
    @Test func noProgressSignalCanEverProduceADeadlockVerdict() {
        for cycles in [0.0, 1.0, 500_000.0, 999_999.0, 1_000_001.0, 5e9] {
            let d = classifier.classify(unobservable(cycles: cycles))
            #expect(d.pathology != .deadlock,
                    "counters alone named a deadlock at \(cycles) cycles/s")
        }
    }

    /// Silence is the case where deadlock and healthy idle are identical, so the
    /// lab must decline rather than choose.
    @Test func silenceWithoutAHeartbeatIsIndeterminate() {
        let d = classifier.classify(unobservable(cycles: 0, ipc: 0, cpu: 0, wakeups: 0))
        #expect(d.pathology == .indeterminate)
        #expect(d.confidence == .unknown)
        #expect(d.inquiry != nil)
        #expect(!d.confidence.mayDriveAction)
    }

    /// `mayDriveAction` is the gate between describing and doing. Nothing the
    /// lab infers from counters alone may open it.
    @Test func nothingInferredFromCountersAloneMayDriveAction() {
        let readings: [EnergySignature] = [
            unobservable(cycles: 0, ipc: 0, cpu: 0, wakeups: 0),
            unobservable(cycles: 2_380_367, ipc: 0.70, cpu: 0.10, wakeups: 0.5),
            unobservable(cycles: 3.8e9, ipc: 1.25, cpu: 99, wakeups: 0),
            unobservable(cycles: 2.3e7, ipc: 0.22, cpu: 1.2, wakeups: 815),
            unobservable(cycles: 2.3e9, ipc: 0.06, cpu: 99, wakeups: 0)
        ]
        for reading in readings {
            let d = classifier.classify(reading)
            #expect(!d.confidence.mayDriveAction,
                    "\(d.pathology.rawValue) claimed authority to act without a progress signal")
            #expect(d.inquiry != nil,
                    "\(d.pathology.rawValue) withheld the question that would settle it")
        }
    }

    /// The headline is the sentence that lands; the confidence word sits beside
    /// it and is easy to miss. So no unsettled verdict may speak in the
    /// vocabulary of a proven structure.
    @Test func unsettledVerdictsNeverAssertAStructure() {
        for pathology in Pathology.allCases {
            for confidence in Confidence.allCases where confidence < .known {
                let sentence = pathology.headline(at: confidence).lowercased()
                #expect(!sentence.contains("wait-for graph"),
                        "\(pathology.rawValue) asserts a graph property at \(confidence.rawValue)")
            }
        }
    }

    /// Knowledge by construction is strong evidence and is allowed to settle a
    /// verdict, but it must never be dressed up as an observation.
    @Test func constructionAndObservationAreReportedDifferently() {
        let silent = EnergySignature(
            pid: 1, window: 3, cyclesPerSecond: 0, instructionsPerCycle: 0,
            cpuPercent: 0, interruptWakeupsPerSecond: 0,
            packageIdleWakeupsPerSecond: 0, progressPerSecond: 0
        )
        let byConstruction = classifier.classify(silent, structure: .knownByConstruction(mode: "deadlock"))
        let t1 = Actor(pid: 1, threadID: 1, label: "T1")
        let t2 = Actor(pid: 1, threadID: 2, label: "T2")
        let observed = classifier.classify(silent, structure: .cycleFound(
            DeadlockCycle(edges: [
                WaitEdge(waiter: t1, holder: t2, gate: .mutex("B")),
                WaitEdge(waiter: t2, holder: t1, gate: .mutex("A"))
            ])
        ))

        #expect(byConstruction.confidence == .known)
        #expect(observed.confidence == .known)
        #expect(byConstruction.evidence != observed.evidence)
        #expect(!byConstruction.evidence.contains { $0.contains("cycle was found") })
        #expect(observed.evidence.contains { $0.contains("cycle was found") })
    }
}
