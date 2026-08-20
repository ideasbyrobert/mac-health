import Testing
@testable import MacHealthKit

struct DiskAuditorTests {

    @Test func parsesCapacityColumns() {
        let metrics = DiskAuditor(shell: intelShell()).audit()
        #expect(metrics.totalGB == 466.0)
        #expect(metrics.freeGB == 369.0)
        #expect(metrics.status == "AMPLE_SPACE")
        #expect(abs(metrics.percentFree - (369.0 / 466.0) * 100.0) < 0.01)
    }

    @Test func lowSpaceIsFlagged() {
        let metrics = DiskAuditor(shell: intelShell(df: Fix.dfLow)).audit()
        #expect(metrics.freeGB == 12.0)
        #expect(metrics.status == "LOW_SPACE")
    }
}
