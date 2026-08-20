import Testing
import Foundation
@testable import MacHealthKit

struct GPUAuditorTests {

    /// The default reader holds no report text, so every incident here is
    /// unattributed — the conservative path these tests pin. Attribution from
    /// real report bodies lives in GPUAttributionTests.
    func audit(_ shell: FakeShell, reader: FakeFileReader = FakeFileReader()) -> GPUMetrics {
        GPUAuditor(shell: shell, reader: reader, now: { Fix.now }).audit()
    }

    @Test func appleSiliconWithoutMuxIsAlwaysSafe() {
        let metrics = audit(siliconShell())
        #expect(metrics.gpuSwitchMode.contains("Apple Silicon"))
        #expect(metrics.gpuSwitchSafe)
        #expect(metrics.status == "STABLE")
    }

    @Test func healthyIntelDynamicSwitchingStaysGreen() {
        let metrics = audit(intelShell(gpuswitch: 2))
        #expect(metrics.gpuSwitchMode == "Dynamic Switching")
        #expect(metrics.gpuSwitchSafe)
        #expect(metrics.status == "STABLE")
    }

    @Test func discreteForcedWithIncidentHistoryIsFlagged() {
        let incidents = Fix.incidents([
            (ageHours: 2.0, name: "Kernel_2026-08-19-231224.gpuRestart"),
            (ageHours: 3.0, name: "Kernel_2026-08-19-221811.gpuRestart")
        ])
        let metrics = audit(intelShell(gpuswitch: 1, incidents: incidents))
        #expect(!metrics.gpuSwitchSafe)
        #expect(metrics.gpuSwitchMode.contains("Faulting"))
        #expect(metrics.historicalIncidents24h == 2)
        #expect(metrics.status == "HISTORICAL_PANICS_RECORDED")
    }

    @Test func integratedOnlyStaysSafeEvenWithHistory() {
        let incidents = Fix.incidents([(ageHours: 5.0, name: "WindowServer.spin")])
        let metrics = audit(intelShell(gpuswitch: 0, incidents: incidents))
        #expect(metrics.gpuSwitchSafe)
        #expect(metrics.status == "HISTORICAL_PANICS_RECORDED")
    }

    @Test func incidentWithinTheHourCountsAsActive() {
        let incidents = Fix.incidents([(ageHours: 0.5, name: "Kernel.gpuRestart")])
        let metrics = audit(intelShell(gpuswitch: 0, incidents: incidents))
        #expect(metrics.activeIncidentsLastHour == 1)
        #expect(metrics.status == "ACTIVE_HANGS_LAST_HOUR")
        #expect(metrics.hoursSinceLastCrash < 1.0)
    }

    @Test func filenamesWithSpacesSurviveParsing() {
        let incidents = Fix.incidents([(ageHours: 2.0, name: "disk writes_2026-08-17-190021.shutdownStall")])
        let metrics = audit(intelShell(gpuswitch: 0, incidents: incidents))
        #expect(metrics.historicalIncidents24h == 1)
        #expect(metrics.latestIncidentName == "disk writes_2026-08-17-190021.shutdownStall")
    }

    @Test func hiddenPanicFileIsAttributed() {
        let incidents = Fix.incidents([(ageHours: 3.2, name: ".contents.panic")])
        let metrics = audit(intelShell(gpuswitch: 0, incidents: incidents))
        #expect(metrics.latestIncidentName == ".contents.panic")
    }
}
