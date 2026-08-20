import Testing
@testable import MacHealthKit

struct SentinelPolicyTests {

    @Test func quietSystemTakesNoAction() {
        let (actions, streak) = SentinelPolicy.decide(
            latencyMs: 40, responsive: true, cpuSpeedLimit: 100, thermalPressure: false, previousStreak: 0)
        #expect(actions.isEmpty)
        #expect(streak == 0)
    }

    @Test func latencySpikeTriggersPacingAndStreak() {
        let (actions, streak) = SentinelPolicy.decide(
            latencyMs: 400, responsive: true, cpuSpeedLimit: 100, thermalPressure: false, previousStreak: 0)
        #expect(streak == 1)
        #expect(actions.contains(.reportSpike(latencyMs: 400, streak: 1)))
        #expect(actions.contains(.paceAll))
    }

    @Test func unresponsiveProbeCountsAsSpikeRegardlessOfLatency() {
        let (actions, streak) = SentinelPolicy.decide(
            latencyMs: 10, responsive: false, cpuSpeedLimit: 100, thermalPressure: false, previousStreak: 2)
        #expect(streak == 3)
        #expect(actions.contains(.paceAll))
    }

    @Test func recoveryAfterStreakIsAnnouncedOnce() {
        let (actions, streak) = SentinelPolicy.decide(
            latencyMs: 35, responsive: true, cpuSpeedLimit: 100, thermalPressure: false, previousStreak: 4)
        #expect(streak == 0)
        #expect(actions == [.reportRecovery(latencyMs: 35)])
    }

    @Test func hardThrottleTriggersThermalPacing() {
        let (actions, _) = SentinelPolicy.decide(
            latencyMs: 40, responsive: true, cpuSpeedLimit: 60, thermalPressure: false, previousStreak: 0)
        #expect(actions.contains(.reportThermal(reason: "CPU Speed Limit 60%")))
        #expect(actions.contains(.paceAll))
    }

    @Test func thermalPressureAloneTriggersPacingBeforeHardThrottle() {
        let (actions, _) = SentinelPolicy.decide(
            latencyMs: 40, responsive: true, cpuSpeedLimit: 100, thermalPressure: true, previousStreak: 0)
        #expect(actions.contains(.reportThermal(reason: "Thermal Pressure Serious/Critical")))
        #expect(actions.contains(.paceAll))
    }

    @Test func combinedSpikeAndThermalPaceOnlyOnce() {
        let (actions, _) = SentinelPolicy.decide(
            latencyMs: 900, responsive: true, cpuSpeedLimit: 55, thermalPressure: true, previousStreak: 0)
        #expect(actions.filter { $0 == .paceAll }.count == 1)
    }
}
