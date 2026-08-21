import Testing
@testable import MacHealthKit

struct UniversalGovernorTests {

    /// Uses an indexer rather than an agent: agents supervise children and are
    /// deliberately left un-niced, so they are no longer an example of a
    /// process receiving both controls.
    @Test func pacesMatchedProcessWithBackgroundPolicyAndNice() {
        let shell = FakeShell()
        shell.stub("pgrep -x 'mdworker'", "4242")
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
        // These patterns belong to the supervising rule, so the control that
        // actually gets applied is the background policy.
        #expect(shell.commands.filter { $0.contains("taskpolicy") && $0.contains("5555") }.count == 1)
    }

    // MARK: Supervisors

    /// The regression this rule exists for. An agent CLI was niced to 15, and
    /// because nice is inherited, the release compiler it launched minutes
    /// later started life two tiers below where the compiler rule puts it.
    /// Nothing could correct that: lowering a nice value needs root.
    @Test func agentKeepsItsPriorityBecauseChildrenInheritIt() {
        let shell = FakeShell()
        shell.stub("pgrep -x 'codex'", "1758")
        let results = UniversalGovernor(shell: shell, currentPID: 1).paceAll(verbose: false)

        #expect(results.count == 1)
        #expect(!shell.issued("renice +15 -p 1758"))
    }

    /// The reversible half is still applied, which is what the shipped shell
    /// aliases already do to these tools by hand.
    @Test func agentStillGetsTheBackgroundPolicy() {
        let shell = FakeShell()
        shell.stub("pgrep -x 'codex'", "1758")
        UniversalGovernor(shell: shell, currentPID: 1).paceAll(verbose: false)
        #expect(shell.issued("taskpolicy -b -p 1758"))
    }

    /// Leaf workers are not supervisors: they do the work themselves, so their
    /// nice lands on the process that is actually burning the CPU.
    @Test func compilersAndIndexersAreStillNiced() {
        let shell = FakeShell()
        shell.stub("pgrep -x 'xcodebuild'", "4242")
        shell.stub("pgrep -x 'mds_stores'", "318")
        UniversalGovernor(shell: shell, currentPID: 1).paceAll(verbose: false)

        #expect(shell.issued("renice +10 -p 4242"))
        #expect(shell.issued("renice +15 -p 318"))
    }

    /// A report that claimed nice 15 on a process it deliberately left alone
    /// would be worse than no report.
    @Test func supervisorResultReportsItsActualPriority() {
        let shell = FakeShell()
        shell.stub("pgrep -x 'codex'", "1758")
        shell.stub("ps -o nice= -p 1758", "0")
        let results = UniversalGovernor(shell: shell, currentPID: 1).paceAll(verbose: false)

        #expect(results[0].nice == 0)
    }

    @Test func exactlyOneRuleSupervises() {
        let supervising = UniversalGovernor.rules.filter(\.supervisesChildren)
        #expect(supervising.count == 1)
        #expect(supervising[0].category == "AI Agents & LLM Runtimes")
        #expect(UniversalGovernor.rules.allSatisfy { $0.backgroundQoS })
    }
}
