import Testing
@testable import MacHealthKit

struct UniversalGovernorTests {

    @Test func pacesMatchedProcessWithBackgroundPolicyAndNice() {
        let shell = FakeShell()
        shell.stub("pgrep -x 'codex'", "4242")
        let results = UniversalGovernor(shell: shell, currentPID: 1).paceAll(verbose: false)

        #expect(results.count == 1)
        #expect(results[0].pid == 4242)
        #expect(results[0].nice == 15)
        #expect(shell.issued("taskpolicy -b -p 4242"))
        #expect(shell.issued("renice +15 -p 4242"))
    }

    @Test func compilersGetNiceTen() {
        let shell = FakeShell()
        shell.stub("pgrep -x 'swift-build'", "777")
        let results = UniversalGovernor(shell: shell, currentPID: 1).paceAll(verbose: false)
        #expect(results.count == 1)
        #expect(results[0].nice == 10)
        #expect(shell.issued("renice +10 -p 777"))
    }

    @Test func neverUsesInvalidDiskPolicyFlagOnExistingPids() {
        let shell = FakeShell()
        shell.stub("pgrep -x 'node'", "999")
        UniversalGovernor(shell: shell, currentPID: 1).paceAll(verbose: false)
        #expect(!shell.issued("taskpolicy -d"))
    }

    @Test func onlyExactNameMatchingIsUsed() {
        let shell = FakeShell()
        UniversalGovernor(shell: shell, currentPID: 1).paceAll(verbose: false)
        let pgreps = shell.commands.filter { $0.contains("pgrep") }
        #expect(!pgreps.isEmpty)
        #expect(pgreps.allSatisfy { $0.contains("pgrep -x") })
    }

    @Test func skipsItsOwnProcess() {
        let shell = FakeShell()
        shell.stub("pgrep -x 'claude'", "4242")
        let results = UniversalGovernor(shell: shell, currentPID: 4242).paceAll(verbose: false)
        #expect(results.isEmpty)
        #expect(!shell.issued("renice"))
    }

    @Test func dedupesPidsAcrossOverlappingPatterns() {
        let shell = FakeShell()
        shell.stub("pgrep -x 'python'", "5555")
        shell.stub("pgrep -x 'python3'", "5555")
        let results = UniversalGovernor(shell: shell, currentPID: 1).paceAll(verbose: false)
        #expect(results.count == 1)
        #expect(shell.commands.filter { $0.contains("renice") && $0.contains("5555") }.count == 1)
    }
}
