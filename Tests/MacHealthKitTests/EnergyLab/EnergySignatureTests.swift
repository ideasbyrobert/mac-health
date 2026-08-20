import Testing
import Foundation
@testable import EnergyLab

/// `EnergySignature.between` is the only arithmetic in the lab that turns raw
/// kernel counters into the numbers every verdict rests on, so each rate is
/// checked against a hand-computed value rather than against itself.
struct EnergySignatureTests {

    // MARK: the ordinary case

    @Test func computesEveryRateFromHandCheckedCounters() throws {
        let first = sample(atSeconds: 0)
        let second = sample(
            atSeconds: 2,
            cycles: 2_000_000_000,
            instructions: 4_000_000_000,
            userTimeNs: 1_000_000_000,
            systemTimeNs: 200_000_000,
            interruptWakeups: 100,
            packageIdleWakeups: 300
        )

        let signature = try #require(EnergySignature.between(first, second))
        #expect(signature.pid == labPID)
        #expect(isClose(signature.window, 2.0))
        #expect(isClose(signature.cyclesPerSecond, 1_000_000_000))
        #expect(isClose(signature.instructionsPerCycle, 2.0))
        // 1.2 s of CPU across a 2 s wall window is 60% of one core.
        #expect(isClose(signature.cpuPercent, 60.0, 1e-6))
        #expect(isClose(signature.interruptWakeupsPerSecond, 50.0))
        #expect(isClose(signature.packageIdleWakeupsPerSecond, 150.0))
    }

    @Test func cpuPercentSumsUserAndSystemTime() throws {
        let first = sample(atSeconds: 0)
        let second = sample(atSeconds: 2, userTimeNs: 500_000_000, systemTimeNs: 500_000_000)

        let signature = try #require(EnergySignature.between(first, second))
        #expect(isClose(signature.cpuPercent, 50.0, 1e-6))
    }

    /// More than one core's worth of CPU time in the window is a real reading,
    /// not an error: a multithreaded process exceeds 100%.
    @Test func cpuPercentExceedsOneHundredForMultipleCores() throws {
        let first = sample(atSeconds: 0)
        let second = sample(atSeconds: 1, userTimeNs: 4_000_000_000)

        let signature = try #require(EnergySignature.between(first, second))
        #expect(isClose(signature.cpuPercent, 400.0, 1e-6))
    }

    @Test func ratesScaleWithTheWindowNotWithTheTotals() throws {
        let short = try #require(EnergySignature.between(
            sample(atSeconds: 0),
            sample(atSeconds: 1, cycles: 1_000_000_000)
        ))
        let long = try #require(EnergySignature.between(
            sample(atSeconds: 0),
            sample(atSeconds: 10, cycles: 10_000_000_000)
        ))

        #expect(isClose(short.cyclesPerSecond, long.cyclesPerSecond))
    }

    // MARK: refusals

    @Test func mismatchedPidsReturnNil() {
        let first = sample(pid: 501, atSeconds: 0)
        let second = sample(pid: 502, atSeconds: 1, cycles: 1_000)
        #expect(EnergySignature.between(first, second) == nil)
    }

    @Test func zeroWindowReturnsNil() {
        let first = sample(atSeconds: 1)
        let second = sample(atSeconds: 1, cycles: 1_000)
        #expect(EnergySignature.between(first, second) == nil)
    }

    @Test func reversedSampleOrderReturnsNil() {
        let earlier = sample(atSeconds: 0, cycles: 1_000)
        let later = sample(atSeconds: 5, cycles: 9_000)
        #expect(EnergySignature.between(later, earlier) == nil)
    }

    /// A pid can be reused while the lab is watching. The counters then restart
    /// from a lower value, and an unsigned subtraction would wrap into an
    /// enormous rate that reads as a catastrophe. nil is the honest answer.
    @Test func cyclesGoingBackwardsReturnNilRatherThanWrapping() {
        let first = sample(atSeconds: 0, cycles: 5_000_000_000)
        let second = sample(atSeconds: 1, cycles: 1_000)
        #expect(EnergySignature.between(first, second) == nil)
    }

    @Test func instructionsGoingBackwardsReturnNil() {
        let first = sample(atSeconds: 0, cycles: 10, instructions: 5_000_000_000)
        let second = sample(atSeconds: 1, cycles: 20, instructions: 1_000)
        #expect(EnergySignature.between(first, second) == nil)
    }

    @Test func userTimeGoingBackwardsReturnsNil() {
        let first = sample(atSeconds: 0, userTimeNs: 5_000_000_000)
        let second = sample(atSeconds: 1, userTimeNs: 1_000)
        #expect(EnergySignature.between(first, second) == nil)
    }

    @Test func systemTimeGoingBackwardsReturnsNil() {
        let first = sample(atSeconds: 0, systemTimeNs: 5_000_000_000)
        let second = sample(atSeconds: 1, systemTimeNs: 1_000)
        #expect(EnergySignature.between(first, second) == nil)
    }

    @Test func interruptWakeupsGoingBackwardsReturnNil() {
        let first = sample(atSeconds: 0, interruptWakeups: 4_000)
        let second = sample(atSeconds: 1, interruptWakeups: 3)
        #expect(EnergySignature.between(first, second) == nil)
    }

    @Test func packageIdleWakeupsGoingBackwardsReturnNil() {
        let first = sample(atSeconds: 0, packageIdleWakeups: 4_000)
        let second = sample(atSeconds: 1, packageIdleWakeups: 3)
        #expect(EnergySignature.between(first, second) == nil)
    }

    // MARK: degenerate but legitimate readings

    /// A process that consumed no cycles has no instructions-per-cycle to
    /// report. Zero is the guarded answer; a NaN would poison every comparison
    /// the classifier makes downstream, because NaN fails them all silently.
    @Test func zeroCycleDeltaYieldsZeroIPCNotNaN() throws {
        let first = sample(atSeconds: 0, cycles: 1_000, instructions: 2_000)
        let second = sample(atSeconds: 3, cycles: 1_000, instructions: 2_000)

        let signature = try #require(EnergySignature.between(first, second))
        #expect(signature.instructionsPerCycle == 0)
        #expect(!signature.instructionsPerCycle.isNaN)
        #expect(signature.cyclesPerSecond == 0)
    }

    /// The reading at the centre of the lab's thesis: a completely silent
    /// process. Nothing here distinguishes a deadlock from a healthy sleeper.
    @Test func aSilentProcessProducesAnAllZeroSignature() throws {
        let quiet = sample(atSeconds: 0)
        let stillQuiet = sample(atSeconds: 3)

        let signature = try #require(EnergySignature.between(quiet, stillQuiet))
        #expect(signature.cyclesPerSecond == 0)
        #expect(signature.cpuPercent == 0)
        #expect(signature.packageIdleWakeupsPerSecond == 0)
        #expect(signature.interruptWakeupsPerSecond == 0)
    }

    // MARK: the progress signal

    @Test func absentProgressDeltaLeavesProgressPerSecondNil() throws {
        let signature = try #require(EnergySignature.between(
            sample(atSeconds: 0),
            sample(atSeconds: 3, cycles: 1_000_000)
        ))
        #expect(signature.progressPerSecond == nil)
    }

    @Test func progressDeltaIsDividedByTheWindow() throws {
        let signature = try #require(EnergySignature.between(
            sample(atSeconds: 0),
            sample(atSeconds: 4, cycles: 1_000_000),
            progressDelta: 20
        ))
        let progress = try #require(signature.progressPerSecond)
        #expect(isClose(progress, 5.0))
    }

    /// Zero work completed is a measurement, not a missing one. The classifier
    /// depends on being able to tell those two apart.
    @Test func zeroProgressDeltaIsAMeasurementNotAnAbsence() throws {
        let signature = try #require(EnergySignature.between(
            sample(atSeconds: 0),
            sample(atSeconds: 3),
            progressDelta: 0
        ))
        #expect(signature.progressPerSecond == 0)
        #expect(signature.progressPerSecond != nil)
    }

    // MARK: the sample itself

    @Test func samplesCompareByValue() {
        #expect(sample(atSeconds: 0, cycles: 7) == sample(atSeconds: 0, cycles: 7))
        #expect(sample(atSeconds: 0, cycles: 7) != sample(atSeconds: 0, cycles: 8))
    }
}

// MARK: helpers

private let labPID: Int32 = 501

/// Frozen origin so every window in this file is exact wall-clock arithmetic.
private let labEpoch = Date(timeIntervalSince1970: 1_000_000_000)

private func sample(
    pid: Int32 = labPID,
    atSeconds: TimeInterval,
    cycles: UInt64 = 0,
    instructions: UInt64 = 0,
    userTimeNs: UInt64 = 0,
    systemTimeNs: UInt64 = 0,
    interruptWakeups: UInt64 = 0,
    packageIdleWakeups: UInt64 = 0
) -> EnergySample {
    EnergySample(
        pid: pid,
        at: labEpoch.addingTimeInterval(atSeconds),
        cycles: cycles,
        instructions: instructions,
        userTimeNs: userTimeNs,
        systemTimeNs: systemTimeNs,
        interruptWakeups: interruptWakeups,
        packageIdleWakeups: packageIdleWakeups
    )
}

private func isClose(_ actual: Double, _ expected: Double, _ tolerance: Double = 1e-9) -> Bool {
    abs(actual - expected) <= tolerance
}
