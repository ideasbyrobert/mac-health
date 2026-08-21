import Foundation

public struct UniversalGovernor {

    public struct GovernanceRule {
        public let category: String
        public let patterns: [String]
        public let niceLevel: Int
        public let backgroundQoS: Bool
    }

    public static let rules: [GovernanceRule] = [
        GovernanceRule(
            category: "AI Agents & LLM Runtimes",
            patterns: ["claude", "agy", "antigravity", "codex", "ollama", "node", "python", "python3", "bun"],
            niceLevel: 15,
            backgroundQoS: true
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
                    shell.run("renice +\(rule.niceLevel) -p \(pid) 2>/dev/null")

                    let item = PacedProcessResult(
                        pid: pid,
                        name: procName.isEmpty ? pattern : procName,
                        category: rule.category,
                        nice: rule.niceLevel,
                        qos: rule.backgroundQoS ? "Background" : "Utility"
                    )
                    results.append(item)

                    if verbose {
                        print("  \(ConsoleFormat.green)\(ConsoleFormat.tick)\(ConsoleFormat.reset) Paced PID \(ConsoleFormat.bold)\(pid)\(ConsoleFormat.reset) (\(item.name)) → [\(rule.category)]")
                        print("    \(ConsoleFormat.arrow) Priority: \(ConsoleFormat.yellow)nice +\(rule.niceLevel)\(ConsoleFormat.reset) | QoS: \(ConsoleFormat.cyan)\(item.qos)\(ConsoleFormat.reset)\(rule.backgroundQoS ? " | Disk I/O: \(ConsoleFormat.blue)Throttled (BG policy)\(ConsoleFormat.reset)" : "")")
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

    public static let runawayCategory = "Sustained CPU Runaways"

    /// Below the indexer level: an unrecognised process holding multiple cores
    /// has less claim on them than a tool the person actually started.
    public static let runawayNiceLevel = 18
}
