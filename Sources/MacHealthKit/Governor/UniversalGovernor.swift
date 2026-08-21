import Foundation

public struct UniversalGovernor {

    public struct GovernanceRule {
        public let category: String
        public let patterns: [String]
        public let niceLevel: Int
        public let backgroundQoS: Bool

        /// Whether processes matching this rule mostly supervise other work
        /// rather than perform it.
        ///
        /// This matters because both controls are inherited by children, but
        /// only one of them can be taken back. `taskpolicy -B` lifts the
        /// background policy without privilege; lowering a nice value needs
        /// root, so an unprivileged governor can raise a process's nice and
        /// then never undo it.
        ///
        /// An agent CLI is long lived and mostly idle: the CPU is burned by
        /// the compilers and test runners it launches. Nicing the supervisor
        /// therefore hands every future child a penalty it never earned, and
        /// any intermediate shell belongs to no rule at all, so it keeps the
        /// inherited value and passes it on. That is how a release compiler
        /// ends up two tiers below where this table says compilers belong.
        public let supervisesChildren: Bool

        public init(
            category: String,
            patterns: [String],
            niceLevel: Int,
            backgroundQoS: Bool,
            supervisesChildren: Bool = false
        ) {
            self.category = category
            self.patterns = patterns
            self.niceLevel = niceLevel
            self.backgroundQoS = backgroundQoS
            self.supervisesChildren = supervisesChildren
        }

        /// Supervisors get only the reversible control, so a build they spawn
        /// starts at the priority its own rule assigns.
        public var appliesNice: Bool { !supervisesChildren }
    }

    public static let rules: [GovernanceRule] = [
        GovernanceRule(
            category: "AI Agents & LLM Runtimes",
            patterns: ["claude", "agy", "antigravity", "codex", "ollama", "node", "python", "python3", "bun"],
            niceLevel: 15,
            backgroundQoS: true,
            supervisesChildren: true
        ),
        GovernanceRule(
            category: "Compilers & Heavy Toolchains",
            patterns: ["swiftc", "clang", "clang++", "rustc", "xcodebuild", "ld64", "swift-frontend", "swift-build", "swift-driver"],
            niceLevel: 10,
            backgroundQoS: true
        ),
        GovernanceRule(
            category: "System Indexers & File Scanners",
            patterns: ["mdworker", "mdworker_shared", "mds_stores", "corespotlightd", "rg", "find", "fd"],
            niceLevel: 15,
            backgroundQoS: true
        )
    ]

    public struct PacedProcessResult {
        public let pid: Int
        public let name: String
        public let category: String
        public let nice: Int
        public let qos: String
    }

    let shell: CommandRunning
    let currentPID: Int

    public init(shell: CommandRunning = SystemShell(), currentPID: Int = Int(ProcessInfo.processInfo.processIdentifier)) {
        self.shell = shell
        self.currentPID = currentPID
    }

    @discardableResult
    public func paceAll(verbose: Bool = true) -> [PacedProcessResult] {
        var results: [PacedProcessResult] = []

        if verbose {
            print("\n\(ConsoleFormat.bold)🛡️ Universal System-Wide Resource Governor\(ConsoleFormat.reset)")
            print(ConsoleFormat.rule())
            print("Pacing active background workloads (non-destructive, zero kills)...\n")
        }

        for rule in Self.rules {
            for pattern in rule.patterns {
                // -x: exact process-name match. A substring -f match hits unrelated
                // processes whose command line merely contains the pattern
                // (e.g. 'find' → findmylocateagent, 'node' → other apps' bundled node)
                // as well as the transient shell running pgrep itself.
                let pgrepCmd = "pgrep -x '\(pattern)' 2>/dev/null"
                let pidsStr = shell.run(pgrepCmd).output
                let pids = pidsStr.components(separatedBy: .whitespacesAndNewlines)
                    .compactMap { Int($0) }
                    .filter { $0 != currentPID && $0 != 1 && $0 != 0 }

                for pid in pids {
                    if results.contains(where: { $0.pid == pid }) { continue }

                    let commOut = shell.run("ps -p \(pid) -o comm= 2>/dev/null").output
                    let procName = URL(fileURLWithPath: commOut).lastPathComponent

                    if rule.backgroundQoS {
                        // DARWIN_BG (-b) already includes throttled disk I/O; taskpolicy
                        // does not support applying -d to an existing pid.
                        shell.run("taskpolicy -b -p \(pid) 2>/dev/null")
                    }
                    if rule.appliesNice {
                        shell.run("renice +\(rule.niceLevel) -p \(pid) 2>/dev/null")
                    }

                    // Report what was applied, not what the rule wished for: a
                    // supervisor keeps whatever nice it already had.
                    let appliedNice = rule.appliesNice ? rule.niceLevel : currentNice(of: pid)

                    let item = PacedProcessResult(
                        pid: pid,
                        name: procName.isEmpty ? pattern : procName,
                        category: rule.category,
                        nice: appliedNice,
                        qos: rule.backgroundQoS ? "Background" : "Utility"
                    )
                    results.append(item)

                    if verbose {
                        let priority = rule.appliesNice
                            ? "\(ConsoleFormat.yellow)nice +\(rule.niceLevel)\(ConsoleFormat.reset)"
                            : "\(ConsoleFormat.dim)nice unchanged (supervises children)\(ConsoleFormat.reset)"
                        print("  \(ConsoleFormat.green)\(ConsoleFormat.tick)\(ConsoleFormat.reset) Paced PID \(ConsoleFormat.bold)\(pid)\(ConsoleFormat.reset) (\(item.name)) → [\(rule.category)]")
                        print("    \(ConsoleFormat.arrow) Priority: \(priority) | QoS: \(ConsoleFormat.cyan)\(item.qos)\(ConsoleFormat.reset)\(rule.backgroundQoS ? " | Disk I/O: \(ConsoleFormat.blue)Throttled (BG policy)\(ConsoleFormat.reset)" : "")")
                    }
                }
            }
        }

        results.append(contentsOf: paceRunaways(alreadyPaced: results, verbose: verbose))

        if verbose {
            print("\n" + ConsoleFormat.rule())
            print("  Total Processes Paced: \(ConsoleFormat.green)\(ConsoleFormat.bold)\(results.count)\(ConsoleFormat.reset)")
            print("  Interactive Apps:      \(ConsoleFormat.green)100% Unrestricted Priority\(ConsoleFormat.reset)")
            print(ConsoleFormat.rule() + "\n")
        }

        return results
    }

    /// The behavioural pass: pace whatever is actually burning CPU, named or
    /// not. Runs after the pattern rules so a known tool keeps its tuned nice
    /// level rather than the generic runaway one.
    ///
    /// Two `ps` counters separated by `windowSeconds` decide it. That window
    /// is the cost of the check and the reason it is honest: a burst shorter
    /// than the window cannot trip it, so a compile starting up is not
    /// mistaken for a daemon stuck in a loop.
    @discardableResult
    public func paceRunaways(
        alreadyPaced: [PacedProcessResult] = [],
        windowSeconds: Double = 5,
        thresholdPercent: Double = RunawayDetector.defaultThresholdPercent,
        verbose: Bool = true
    ) -> [PacedProcessResult] {
        let firstOut = shell.run("ps -Ao pid=,time=,comm= 2>/dev/null").output
        let first = RunawayDetector.parseSamples(firstOut)
        guard !first.isEmpty else { return [] }

        Thread.sleep(forTimeInterval: windowSeconds)

        let secondOut = shell.run("ps -Ao pid=,time=,comm= 2>/dev/null").output
        let second = RunawayDetector.parseSamples(secondOut)

        var exemptPIDs = Set(alreadyPaced.map(\.pid))
        exemptPIDs.insert(currentPID)
        exemptPIDs.insert(1)
        exemptPIDs.formUnion(
            RunawayDetector.guiApplicationPIDs(shell.run("lsappinfo list 2>/dev/null").output)
        )

        let runaways = RunawayDetector.runaways(
            first: first,
            second: second,
            intervalSeconds: windowSeconds,
            thresholdPercent: thresholdPercent,
            exemptPIDs: exemptPIDs
        )

        var paced: [PacedProcessResult] = []
        for runaway in runaways {
            shell.run("taskpolicy -b -p \(runaway.pid) 2>/dev/null")
            shell.run("renice +\(Self.runawayNiceLevel) -p \(runaway.pid) 2>/dev/null")

            paced.append(
                PacedProcessResult(
                    pid: runaway.pid,
                    name: runaway.name,
                    category: Self.runawayCategory,
                    nice: Self.runawayNiceLevel,
                    qos: "Background"
                )
            )

            if verbose {
                let percent = String(format: "%.0f", runaway.cpuPercent)
                print("  \(ConsoleFormat.green)\(ConsoleFormat.tick)\(ConsoleFormat.reset) Paced PID \(ConsoleFormat.bold)\(runaway.pid)\(ConsoleFormat.reset) (\(runaway.name)) → [\(Self.runawayCategory)]")
                print("    \(ConsoleFormat.arrow) Sustained \(ConsoleFormat.red)\(percent)% CPU\(ConsoleFormat.reset) over \(Int(windowSeconds))s | Priority: \(ConsoleFormat.yellow)nice +\(Self.runawayNiceLevel)\(ConsoleFormat.reset) | QoS: \(ConsoleFormat.cyan)Background\(ConsoleFormat.reset)")
            }
        }

        return paced
    }

    /// The nice a process actually carries, so a report never claims a change
    /// that was not made. Unreadable means unchanged, which is 0.
    func currentNice(of pid: Int) -> Int {
        Int(shell.run("ps -o nice= -p \(pid) 2>/dev/null").output
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    public static let runawayCategory = "Sustained CPU Runaways"

    /// Below the indexer level: an unrecognised process holding multiple cores
    /// has less claim on them than a tool the person actually started.
    public static let runawayNiceLevel = 18
}
