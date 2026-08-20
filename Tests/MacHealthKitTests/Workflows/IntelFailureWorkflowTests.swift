import Testing
@testable import MacHealthKit

/// End-to-end failure workflows on a dual-GPU Intel MacBook Pro: each test
/// feeds a whole-machine fixture through the composed HealthAuditor and
/// asserts the chain reaction — subsystem finding → overall verdict →
/// readiness withdrawal → actionable recommendation.
struct IntelFailureWorkflowTests {

    func audit(_ shell: FakeShell, probeMs: Double? = 42.0) -> DiagnosticReport {
        HealthAuditor(
            shell: shell,
            windowServerAuditor: WindowServerAuditor(shell: shell, probe: { probeMs }),
            now: { Fix.now }
        ).audit()
    }

    @Test func gpuRestartStormOnForcedDiscreteGPUIsCritical() {
        let incidents = Fix.incidents([
            (ageHours: 0.4, name: "Kernel_2026-08-19-231224.gpuRestart"),
            (ageHours: 0.6, name: "WindowServer.userspace_watchdog_timeout.spin"),
            (ageHours: 2.0, name: ".contents.panic")
        ])
        let report = audit(intelShell(gpuswitch: 1, incidents: incidents))

        #expect(report.overallHealth == "CRITICAL_ATTENTION_NEEDED")
        #expect(report.gpu.activeIncidentsLastHour == 2)
        #expect(!report.gpu.gpuSwitchSafe)
        #expect(!report.xcodeReadiness.isReady)
        #expect(!report.xcodeReadiness.gpuStable)
        #expect(report.xcodeReadiness.recommendations.contains { $0.contains("gpuswitch 0") })
        #expect(report.xcodeReadiness.recommendations.contains { $0.contains("within the last hour") })
    }

    @Test func windowServerStallAloneIsCritical() {
        let report = audit(intelShell(), probeMs: nil)

        #expect(report.overallHealth == "CRITICAL_ATTENTION_NEEDED")
        #expect(report.windowServer.status == "UNRESPONSIVE_STALL_DETECTED")
        #expect(!report.xcodeReadiness.windowServerHealthy)
        #expect(report.xcodeReadiness.recommendations.contains { $0.contains("WindowServer") })
    }

    @Test func recoveredMachineOnIntegratedGPUDegradesWithoutCriticality() {
        let incidents = Fix.incidents([(ageHours: 5.0, name: "Kernel.gpuRestart")])
        let report = audit(intelShell(gpuswitch: 0, incidents: incidents))

        #expect(report.overallHealth == "DEGRADED_OR_WARNING")
        #expect(report.gpu.gpuSwitchSafe)
        #expect(report.gpu.status == "HISTORICAL_PANICS_RECORDED")
        #expect(report.xcodeReadiness.gpuStable)
    }

    @Test func legacyKextLoadedDegradesAndNamesTheOffender() {
        let report = audit(intelShell(kmutil: Fix.kmutilDirty))

        #expect(report.overallHealth == "DEGRADED_OR_WARNING")
        #expect(report.kernelExtensions.nonAppleKextNames == ["com.rugarciap.DisableTurboBoost"])
        #expect(!report.xcodeReadiness.isReady)
        #expect(report.xcodeReadiness.recommendations.contains { $0.contains("DisableTurboBoost") })
    }

    @Test func thermalThrottlingWithdrawsCompilationReadiness() {
        let report = audit(intelShell(therm: Fix.thermThrottled))

        #expect(report.overallHealth == "DEGRADED_OR_WARNING")
        #expect(report.cpu.status == "THROTTLED")
        #expect(!report.xcodeReadiness.thermalsUnthrottled)
        #expect(report.xcodeReadiness.recommendations.contains { $0.contains("62%") })
    }

    @Test func invertedSleepTimersAreCaught() {
        let custom = Fix.custom(gpuswitch: 0, battDisplay: 20, battSleep: 15)
        let report = audit(intelShell(custom: custom))

        #expect(report.overallHealth == "DEGRADED_OR_WARNING")
        #expect(!report.power.sleepTimingsCoherent)
    }

    @Test func degradedBatteryFlagsHealthAndReadiness() {
        let report = audit(intelShell(condition: Fix.conditionService))

        #expect(report.overallHealth == "DEGRADED_OR_WARNING")
        #expect(report.power.isBatteryDegraded)
        #expect(!report.xcodeReadiness.batteryHealthy)
        #expect(report.xcodeReadiness.recommendations.contains { $0.contains("Service Recommended") })
    }

    @Test func healthyIntelMachineIsOptimalAndReady() {
        let report = audit(intelShell())

        #expect(report.overallHealth == "OPTIMAL")
        #expect(report.xcodeReadiness.isReady)
        #expect(report.xcodeReadiness.recommendations.isEmpty)
    }
}
