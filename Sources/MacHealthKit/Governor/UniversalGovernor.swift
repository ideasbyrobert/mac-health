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
            print("\(ConsoleFormat.cyan)────────────────────────────────────────────────────────────\(ConsoleFormat.reset)")
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
                        print("  \(ConsoleFormat.green)✓\(ConsoleFormat.reset) Paced PID \(ConsoleFormat.bold)\(pid)\(ConsoleFormat.reset) (\(item.name)) → [\(rule.category)]")
                        print("    ↳ Priority: \(ConsoleFormat.yellow)nice +\(rule.niceLevel)\(ConsoleFormat.reset) | QoS: \(ConsoleFormat.cyan)\(item.qos)\(ConsoleFormat.reset)\(rule.backgroundQoS ? " | Disk I/O: \(ConsoleFormat.blue)Throttled (BG policy)\(ConsoleFormat.reset)" : "")")
                    }
                }
            }
        }

        if verbose {
            print("\n\(ConsoleFormat.cyan)────────────────────────────────────────────────────────────\(ConsoleFormat.reset)")
            print("  Total Processes Paced: \(ConsoleFormat.green)\(ConsoleFormat.bold)\(results.count)\(ConsoleFormat.reset)")
            print("  Interactive Apps:      \(ConsoleFormat.green)100% Unrestricted Priority\(ConsoleFormat.reset)")
            print("\(ConsoleFormat.cyan)────────────────────────────────────────────────────────────\(ConsoleFormat.reset)\n")
        }

        return results
    }
}
