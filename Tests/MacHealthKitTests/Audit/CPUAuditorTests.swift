import Testing
@testable import MacHealthKit

struct CPUAuditorTests {

    @Test func parsesNominalIntelThermOutputWithMixedWhitespace() {
        let (speed, sched, warning) = CPUAuditor.speedLimit(from: Fix.thermNominal)
        #expect(speed == 100)
        #expect(sched == 100)
        #expect(!warning)
    }

    @Test func parsesThrottledSpeedLimit() {
        let (speed, sched, _) = CPUAuditor.speedLimit(from: Fix.thermThrottled)
        #expect(speed == 62)
        #expect(sched == 80)
    }

    @Test func missingKeysDefaultToUnthrottled() {
        let (speed, sched, warning) = CPUAuditor.speedLimit(from: Fix.thermNoKeys)
        #expect(speed == 100)
        #expect(sched == 100)
        #expect(!warning)
    }

    @Test func recordedThermalWarningIsDetected() {
        let out = "2026-08-20 01:00:00 -0700 Thermal Warning notify\n\tCPU_Speed_Limit \t= 100"
        let (_, _, warning) = CPUAuditor.speedLimit(from: out)
        #expect(warning)
    }

    @Test func auditReportsHealthyAtFullSpeed() {
        let metrics = CPUAuditor(shell: intelShell()).audit()
        #expect(metrics.status == "HEALTHY")
        #expect(metrics.model.contains("i7-9750H"))
        #expect(metrics.physicalCores == 6)
        #expect(metrics.logicalCores == 12)
    }

    @Test func auditReportsThrottledUnderSpeedLimit() {
        let metrics = CPUAuditor(shell: intelShell(therm: Fix.thermThrottled)).audit()
        #expect(metrics.status == "THROTTLED")
        #expect(metrics.speedLimitPercent == 62)
    }
}
