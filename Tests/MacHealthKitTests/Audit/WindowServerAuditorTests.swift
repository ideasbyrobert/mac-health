import Testing
@testable import MacHealthKit

struct WindowServerAuditorTests {

    func audit(probe: @escaping () -> Double?) -> WindowServerMetrics {
        WindowServerAuditor(shell: intelShell(), probe: probe).audit()
    }

    @Test func fastProbeIsResponsive() {
        let metrics = audit(probe: { 42.0 })
        #expect(metrics.isResponsive)
        #expect(metrics.latencyMs == 42.0)
        #expect(metrics.status == "RESPONSIVE")
        #expect(metrics.cpuPercent == 12.5)
        #expect(metrics.sleepAssertionHolder)
    }

    @Test func slowProbeIsElevatedLatency() {
        let metrics = audit(probe: { 320.0 })
        #expect(metrics.isResponsive)
        #expect(metrics.status == "ELEVATED_LATENCY")
    }

    @Test func timedOutProbeIsStall() {
        let metrics = audit(probe: { nil })
        #expect(!metrics.isResponsive)
        #expect(metrics.latencyMs == WindowServerAuditor.probeTimeoutMs)
        #expect(metrics.status == "UNRESPONSIVE_STALL_DETECTED")
    }

    @Test func highWindowServerCPUElevatesEvenWhenLatencyIsFine() {
        let hot = FakeShell()
        hot.stub("pgrep -x WindowServer", "210")
        hot.stub("-o %cpu", "91.0")
        hot.stub("pmset -g assertions", "")
        let metrics = WindowServerAuditor(shell: hot, probe: { 50.0 }).audit()
        #expect(metrics.status == "ELEVATED_LATENCY")
    }
}
