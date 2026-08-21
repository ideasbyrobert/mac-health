import Testing
@testable import MacHealthKit

struct RunawayDetectorTests {

    // MARK: CPU time parsing

    @Test func parsesMinutesAndSeconds() {
        #expect(RunawayDetector.parseCPUTime("2:03.45") == 123.45)
    }

    @Test func parsesHoursMinutesSeconds() {
        #expect(RunawayDetector.parseCPUTime("1:00:00.00") == 3600)
    }

    @Test func rejectsNonNumericTime() {
        #expect(RunawayDetector.parseCPUTime("bogus") == nil)
    }

    @Test func parsesPSListingIntoSamples() {
        let output = """
            \u{20}   1   4:30.98 /sbin/launchd
             99   2:03.45 /usr/libexec/logd
            """
        let samples = RunawayDetector.parseSamples(output)

        #expect(samples.count == 2)
        #expect(samples[0] == RunawayDetector.Sample(pid: 1, cpuSeconds: 270.98, command: "launchd"))
        #expect(samples[1].command == "logd")
    }

    @Test func skipsMalformedRowsRatherThanFailing() {
        // A truncated listing must not cost the governor the rows it can read.
        let samples = RunawayDetector.parseSamples("nonsense\n42 1:00.00 /usr/bin/thing\n")
        #expect(samples.count == 1)
        #expect(samples[0].pid == 42)
    }

    // MARK: Behavioural detection

    /// The incident this whole pass exists for: a daemon nobody listed,
    /// holding eight cores inside a simulator.
    @Test func findsUnnamedRunawayHoldingEightCores() {
        let first = [RunawayDetector.Sample(pid: 89081, cpuSeconds: 100, command: "mediaanalysisd")]
        let second = [RunawayDetector.Sample(pid: 89081, cpuSeconds: 140, command: "mediaanalysisd")]

        let found = RunawayDetector.runaways(first: first, second: second, intervalSeconds: 5)

        #expect(found.count == 1)
        #expect(found[0].pid == 89081)
        #expect(found[0].name == "mediaanalysisd")
        #expect(found[0].cpuPercent == 800)
    }

    @Test func ignoresProcessBelowThreshold() {
        // One core exactly: real work, not a runaway.
        let first = [RunawayDetector.Sample(pid: 5, cpuSeconds: 0, command: "busy")]
        let second = [RunawayDetector.Sample(pid: 5, cpuSeconds: 5, command: "busy")]
        #expect(RunawayDetector.runaways(first: first, second: second, intervalSeconds: 5).isEmpty)
    }

    @Test func ignoresIdleProcess() {
        let first = [RunawayDetector.Sample(pid: 5, cpuSeconds: 900, command: "idle")]
        let second = [RunawayDetector.Sample(pid: 5, cpuSeconds: 900, command: "idle")]
        #expect(RunawayDetector.runaways(first: first, second: second, intervalSeconds: 5).isEmpty)
    }

    /// A long lived process that already burned hours must not be paced for
    /// history it is no longer repeating. This is the flaw in reading `%cpu`,
    /// which stays high for hours after a daemon goes quiet.
    @Test func judgesTheWindowRatherThanTheLifetime() {
        let first = [RunawayDetector.Sample(pid: 7, cpuSeconds: 9_000, command: "formerlyBusy")]
        let second = [RunawayDetector.Sample(pid: 7, cpuSeconds: 9_000.5, command: "formerlyBusy")]
        #expect(RunawayDetector.runaways(first: first, second: second, intervalSeconds: 5).isEmpty)
    }

    @Test func neverPacesTheThermalGovernorOrTheDisplayServer() {
        let names = ["kernel_task", "WindowServer", "loginwindow", "Finder"]
        let first = names.enumerated().map {
            RunawayDetector.Sample(pid: 100 + $0.offset, cpuSeconds: 0, command: $0.element)
        }
        let second = names.enumerated().map {
            RunawayDetector.Sample(pid: 100 + $0.offset, cpuSeconds: 100, command: $0.element)
        }
        #expect(RunawayDetector.runaways(first: first, second: second, intervalSeconds: 5).isEmpty)
    }

    @Test func exemptsGUIApplicationsSoInteractiveWorkIsNeverThrottled() {
        let first = [RunawayDetector.Sample(pid: 4242, cpuSeconds: 0, command: "Final Cut Pro")]
        let second = [RunawayDetector.Sample(pid: 4242, cpuSeconds: 60, command: "Final Cut Pro")]

        let found = RunawayDetector.runaways(
            first: first, second: second, intervalSeconds: 5, exemptPIDs: [4242]
        )
        #expect(found.isEmpty)
    }

    @Test func ignoresProcessThatExitedDuringTheWindow() {
        let first = [RunawayDetector.Sample(pid: 9, cpuSeconds: 0, command: "gone")]
        #expect(RunawayDetector.runaways(first: first, second: [], intervalSeconds: 5).isEmpty)
    }

    /// A recycled pid can show less CPU time than its predecessor. Trusting
    /// that would pace a brand new process for a counter that is not its own.
    @Test func discardsNegativeDeltaFromRecycledPID() {
        let first = [RunawayDetector.Sample(pid: 11, cpuSeconds: 500, command: "old")]
        let second = [RunawayDetector.Sample(pid: 11, cpuSeconds: 1, command: "new")]
        #expect(RunawayDetector.runaways(first: first, second: second, intervalSeconds: 5).isEmpty)
    }

    @Test func returnsWorstOffenderFirst() {
        let first = [
            RunawayDetector.Sample(pid: 1_001, cpuSeconds: 0, command: "medium"),
            RunawayDetector.Sample(pid: 1_002, cpuSeconds: 0, command: "worst"),
        ]
        let second = [
            RunawayDetector.Sample(pid: 1_001, cpuSeconds: 15, command: "medium"),
            RunawayDetector.Sample(pid: 1_002, cpuSeconds: 40, command: "worst"),
        ]

        let found = RunawayDetector.runaways(first: first, second: second, intervalSeconds: 5)
        #expect(found.map(\.name) == ["worst", "medium"])
    }

    @Test func zeroIntervalCannotDivideByZero() {
        let first = [RunawayDetector.Sample(pid: 3, cpuSeconds: 0, command: "x")]
        let second = [RunawayDetector.Sample(pid: 3, cpuSeconds: 10, command: "x")]
        #expect(RunawayDetector.runaways(first: first, second: second, intervalSeconds: 0).isEmpty)
    }

    // MARK: GUI application discovery

    @Test func readsPIDsFromLSAppInfoListing() {
        let output = """
            ASN:0x0-0x1e01e: "Safari" pid = 217 flavor=carbon
            ASN:0x0-0x2f02f: "Terminal" pid = 394 flavor=carbon
            """
        #expect(RunawayDetector.guiApplicationPIDs(output) == [217, 394])
    }

    @Test func toleratesEmptyLSAppInfoOutput() {
        #expect(RunawayDetector.guiApplicationPIDs("").isEmpty)
    }
}
