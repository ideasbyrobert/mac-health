import Testing
@testable import MacHealthKit

/// End-to-end workflows on Apple Silicon: no GPU mux exists, `pmset -g custom`
/// carries no gpuswitch key, and some power states omit CPU limit keys —
/// none of which may produce false alarms.
struct SiliconWorkflowTests {

    func audit(_ shell: FakeShell, probeMs: Double? = 18.0) -> DiagnosticReport {
        HealthAuditor(
            shell: shell,
            windowServerAuditor: WindowServerAuditor(shell: shell, probe: { probeMs }),
            now: { Fix.now }
        ).audit()
    }

    @Test func healthySiliconMachineIsOptimalAndReady() {
        let report = audit(siliconShell())

        #expect(report.overallHealth == "OPTIMAL")
        #expect(report.gpu.gpuSwitchMode.contains("Apple Silicon"))
        #expect(report.gpu.gpuSwitchSafe)
        #expect(report.cpu.speedLimitPercent == 100)
        #expect(report.xcodeReadiness.isReady)
    }

    @Test func batteryPowerCostsReadinessButNotHealth() {
        let report = audit(siliconShell(batt: Fix.battOnBattery87))

        #expect(report.overallHealth == "OPTIMAL")
        #expect(!report.xcodeReadiness.isReady)
        #expect(!report.xcodeReadiness.powerConnected)
        #expect(report.xcodeReadiness.recommendations.contains { $0.contains("battery power") })
    }

    @Test func swapThrashingDegradesSilicon() {
        let report = audit(siliconShell(vmStat: Fix.vmStatThrashing))

        #expect(report.overallHealth == "DEGRADED_OR_WARNING")
        #expect(report.memory.status == "PRESSURE")
        #expect(report.memory.pagesThrottled == 4321)
    }

    @Test func incidentHistoryWithoutMuxDegradesButStaysMuxSafe() {
        let incidents = Fix.incidents([(ageHours: 6.0, name: "Kernel.panic")])
        let report = audit(siliconShell(incidents: incidents))

        #expect(report.overallHealth == "DEGRADED_OR_WARNING")
        #expect(report.gpu.gpuSwitchSafe)
        #expect(report.gpu.status == "HISTORICAL_PANICS_RECORDED")
        #expect(report.xcodeReadiness.gpuStable)
        #expect(!report.xcodeReadiness.recommendations.contains { $0.contains("gpuswitch") })
    }

    @Test func windowServerStallIsCriticalOnSiliconToo() {
        let report = audit(siliconShell(), probeMs: nil)

        #expect(report.overallHealth == "CRITICAL_ATTENTION_NEEDED")
        #expect(report.windowServer.status == "UNRESPONSIVE_STALL_DETECTED")
    }
}
