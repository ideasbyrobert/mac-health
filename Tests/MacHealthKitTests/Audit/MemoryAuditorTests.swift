import Testing
@testable import MacHealthKit

struct MemoryAuditorTests {

    @Test func parsesFreePagesAndSwap() {
        let metrics = MemoryAuditor(shell: intelShell()).audit()
        #expect(metrics.totalPhysicalGB == 16.0)
        #expect(abs(metrics.freeGB - Double(112_233 * 4096) / (1024 * 1024 * 1024)) < 0.001)
        #expect(metrics.swapUsedMB == 512.25)
        #expect(metrics.swapFreeMB == 1535.75)
        #expect(metrics.pagesThrottled == 0)
        #expect(metrics.status == "OPTIMAL")
    }

    @Test func throttledPagesSignalPressure() {
        let metrics = MemoryAuditor(shell: intelShell(vmStat: Fix.vmStatThrashing)).audit()
        #expect(metrics.pagesThrottled == 4321)
        #expect(metrics.status == "PRESSURE")
    }
}
