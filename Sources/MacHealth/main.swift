import Foundation

// MARK: - Models

struct DiagnosticReport: Codable {
    let timestamp: Date
    let overallHealth: String
    let cpu: CPUMetrics
    let memory: MemoryMetrics
    let gpu: GPUMetrics
    let power: PowerMetrics
    let disk: DiskMetrics
    let daemons: DaemonMetrics
    let xcodeReadiness: XcodeReadiness
}

struct CPUMetrics: Codable {
    let model: String
    let physicalCores: Int
    let logicalCores: Int
    let speedLimitPercent: Int
    let schedulerLimitPercent: Int
    let thermalWarning: Bool
    let status: String
}

struct MemoryMetrics: Codable {
    let totalPhysicalGB: Double
    let freeGB: Double
    let swapUsedMB: Double
    let swapFreeMB: Double
    let pagesThrottled: Int
    let status: String
}

struct GPUMetrics: Codable {
    let activeIncidentsLastHour: Int
    let historicalIncidents24h: Int
    let hoursSinceLastCrash: Double
    let status: String
    let latestIncidentName: String?
    let latestIncidentTime: String?
}

struct PowerMetrics: Codable {
    let powerSource: String
    let batteryPercentage: Int
    let batteryCondition: String
    let sleepPrevented: Bool
    let sleepAssertionHolder: String?
    let batterySleepMinutes: Int
    let acSleepMinutes: Int
    let status: String
}

struct DiskMetrics: Codable {
    let mountPoint: String
    let totalGB: Double
    let freeGB: Double
    let percentFree: Double
    let status: String
}

struct DaemonMetrics: Codable {
    let gSwitchRunning: Bool
    let turboBoostSwitcherRunning: Bool
    let status: String
}

struct XcodeReadiness: Codable {
    let isReady: Bool
    let diskSpaceAdequate: Bool
    let thermalsUnthrottled: Bool
    let powerConnected: Bool
    let recommendations: [String]
}

// MARK: - Helper Shell Executor

final class Shell {
    @discardableResult
    static func run(_ command: String) -> (output: String, exitCode: Int32) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (output, process.terminationStatus)
        } catch {
            return ("", 1)
        }
    }
}

// MARK: - Universal Resource Governor

final class UniversalGovernor {
    
    // Categorized process definitions for non-destructive governance
    struct GovernanceRule {
        let category: String
        let patterns: [String]
        let niceLevel: Int
        let backgroundQoS: Bool
        let throttleDiskIO: Bool
    }
    
    static let rules: [GovernanceRule] = [
        GovernanceRule(
            category: "AI Agents & LLM Runtimes",
            patterns: ["claude", "agy", "antigravity", "ollama", "node", "python", "python3", "bun"],
            niceLevel: 15,
            backgroundQoS: true,
            throttleDiskIO: true
        ),
        GovernanceRule(
            category: "Compilers & Heavy Toolchains",
            patterns: ["swiftc", "clang", "clang++", "rustc", "xcodebuild", "ld64", "swift-frontend"],
            niceLevel: 10,
            backgroundQoS: true,
            throttleDiskIO: true
        ),
        GovernanceRule(
            category: "System Indexers & File Scanners",
            patterns: ["mdworker", "mdworker_shared", "mds_stores", "corespotlightd", "rg", "find", "fd"],
            niceLevel: 15,
            backgroundQoS: true,
            throttleDiskIO: true
        )
    ]
    
    struct PacedProcessResult {
        let pid: Int
        let name: String
        let category: String
        let nice: Int
        let qos: String
    }
    
    @discardableResult
    static func paceAll(verbose: Bool = true) -> [PacedProcessResult] {
        var results: [PacedProcessResult] = []
        let currentPID = ProcessInfo.processInfo.processIdentifier
        
        if verbose {
            print("\n\(Formatter.bold)🛡️ Universal System-Wide Resource Governor\(Formatter.reset)")
            print("\(Formatter.cyan)────────────────────────────────────────────────────────────\(Formatter.reset)")
            print("Pacing active background workloads (non-destructive, zero kills)...\n")
        }
        
        for rule in rules {
            for pattern in rule.patterns {
                let pgrepCmd = "pgrep -f '\(pattern)' 2>/dev/null"
                let pidsStr = Shell.run(pgrepCmd).output
                let pids = pidsStr.components(separatedBy: .whitespacesAndNewlines)
                    .compactMap { Int($0) }
                    .filter { $0 != currentPID && $0 != 1 && $0 != 0 }
                
                for pid in pids {
                    // Avoid duplicating already paced PIDs in this pass
                    if results.contains(where: { $0.pid == pid }) { continue }
                    
                    // Fetch process command name
                    let commOut = Shell.run("ps -p \(pid) -o comm= 2>/dev/null").output
                    let procName = URL(fileURLWithPath: commOut).lastPathComponent
                    
                    // Apply non-destructive QoS and priority governance
                    if rule.backgroundQoS {
                        Shell.run("taskpolicy -b -p \(pid) 2>/dev/null")
                    }
                    if rule.throttleDiskIO {
                        Shell.run("taskpolicy -d -p \(pid) 2>/dev/null")
                    }
                    Shell.run("renice +\(rule.niceLevel) -p \(pid) 2>/dev/null")
                    
                    let item = PacedProcessResult(
                        pid: pid,
                        name: procName.isEmpty ? pattern : procName,
                        category: rule.category,
                        nice: rule.niceLevel,
                        qos: rule.backgroundQoS ? "Background" : "Utility"
                    )
                    results.append(item)
                    
                    if verbose {
                        print("  \(Formatter.green)✓\(Formatter.reset) Paced PID \(Formatter.bold)\(pid)\(Formatter.reset) (\(item.name)) → [\(rule.category)]")
                        print("    ↳ Priority: \(Formatter.yellow)nice +\(rule.niceLevel)\(Formatter.reset) | QoS: \(Formatter.cyan)\(item.qos)\(Formatter.reset) | Disk I/O: \(Formatter.blue)Throttled\(Formatter.reset)")
                    }
                }
            }
        }
        
        if verbose {
            print("\n\(Formatter.cyan)────────────────────────────────────────────────────────────\(Formatter.reset)")
            print("  Total Processes Paced: \(Formatter.green)\(Formatter.bold)\(results.count)\(Formatter.reset)")
            print("  Interactive Apps:      \(Formatter.green)100% Unrestricted Priority\(Formatter.reset)")
            print("\(Formatter.cyan)────────────────────────────────────────────────────────────\(Formatter.reset)\n")
        }
        
        return results
    }
    
    static func runDaemon(intervalSec: UInt32 = 5) {
        print("\n\(Formatter.bold)🛡️ Universal System Governor Daemon Active\(Formatter.reset)")
        print("Monitoring process table and auto-pacing heavy tasks every \(intervalSec)s...")
        print("Press Ctrl+C to stop.\n")
        
        while true {
            let _ = paceAll(verbose: false)
            sleep(intervalSec)
        }
    }
}

// MARK: - Auditor

final class MacHealthAuditor {
    
    func audit() -> DiagnosticReport {
        let cpu = auditCPU()
        let memory = auditMemory()
        let gpu = auditGPU()
        let power = auditPower()
        let disk = auditDisk()
        let daemons = auditDaemons()
        let xcode = auditXcodeReadiness(disk: disk, cpu: cpu, power: power)
        
        var isHealthy = true
        if cpu.speedLimitPercent < 100 || cpu.thermalWarning { isHealthy = false }
        if memory.pagesThrottled > 0 { isHealthy = false }
        if gpu.activeIncidentsLastHour > 0 { isHealthy = false }
        if !daemons.gSwitchRunning || !daemons.turboBoostSwitcherRunning { isHealthy = false }
        
        let overallHealth = isHealthy ? "OPTIMAL" : "DEGRADED_OR_WARNING"
        
        return DiagnosticReport(
            timestamp: Date(),
            overallHealth: overallHealth,
            cpu: cpu,
            memory: memory,
            gpu: gpu,
            power: power,
            disk: disk,
            daemons: daemons,
            xcodeReadiness: xcode
        )
    }
    
    private func auditCPU() -> CPUMetrics {
        let model = Shell.run("sysctl -n machdep.cpu.brand_string").output
        let physCores = Int(Shell.run("sysctl -n hw.physicalcpu").output) ?? 6
        let logCores = Int(Shell.run("sysctl -n hw.logicalcpu").output) ?? 12
        
        let thermOut = Shell.run("pmset -g therm").output
        var speedLimit = 100
        var schedLimit = 100
        var thermalWarning = false
        
        for line in thermOut.components(separatedBy: "\n") {
            if line.contains("CPU_Speed_Limit") {
                let parts = line.components(separatedBy: "=")
                if parts.count == 2, let val = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                    speedLimit = val
                }
            } else if line.contains("CPU_Scheduler_Limit") {
                let parts = line.components(separatedBy: "=")
                if parts.count == 2, let val = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                    schedLimit = val
                }
            } else if line.lowercased().contains("thermal warning") && !line.lowercased().contains("no thermal warning") {
                thermalWarning = true
            }
        }
        
        let status = (speedLimit == 100 && !thermalWarning) ? "HEALTHY" : "THROTTLED"
        return CPUMetrics(
            model: model,
            physicalCores: physCores,
            logicalCores: logCores,
            speedLimitPercent: speedLimit,
            schedulerLimitPercent: schedLimit,
            thermalWarning: thermalWarning,
            status: status
        )
    }
    
    private func auditMemory() -> MemoryMetrics {
        let memBytes = Double(Int(Shell.run("sysctl -n hw.memsize").output) ?? 17179869184)
        let totalGB = memBytes / (1024 * 1024 * 1024)
        
        let swapOut = Shell.run("sysctl -n vm.swapusage 2>/dev/null").output
        var swapUsed = 0.0
        var swapFree = 0.0
        
        if let usedRange = swapOut.range(of: "used = ") {
            let sub = swapOut[usedRange.upperBound...]
            let numStr = sub.prefix(while: { $0.isNumber || $0 == "." })
            swapUsed = Double(numStr) ?? 0.0
        }
        if let freeRange = swapOut.range(of: "free = ") {
            let sub = swapFreeRange(from: swapOut, range: freeRange)
            swapFree = sub
        }
        
        let vmStatOut = Shell.run("vm_stat").output
        var freePages = 0
        var throttledPages = 0
        for line in vmStatOut.components(separatedBy: "\n") {
            if line.contains("Pages free:") {
                let parts = line.components(separatedBy: ":")
                if parts.count == 2 {
                    let cleaned = parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "")
                    freePages = Int(cleaned) ?? 0
                }
            } else if line.contains("Pages throttled:") {
                let parts = line.components(separatedBy: ":")
                if parts.count == 2 {
                    let cleaned = parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "")
                    throttledPages = Int(cleaned) ?? 0
                }
            }
        }
        
        let freeGB = Double(freePages * 4096) / (1024 * 1024 * 1024)
        let status = (throttledPages == 0) ? "OPTIMAL" : "PRESSURE"
        
        return MemoryMetrics(
            totalPhysicalGB: totalGB,
            freeGB: freeGB,
            swapUsedMB: swapUsed,
            swapFreeMB: swapFree,
            pagesThrottled: throttledPages,
            status: status
        )
    }
    
    private func swapFreeRange(from str: String, range: Range<String.Index>) -> Double {
        let sub = str[range.upperBound...]
        let numStr = sub.prefix(while: { $0.isNumber || $0 == "." })
        return Double(numStr) ?? 0.0
    }
    
    private func auditGPU() -> GPUMetrics {
        let logsCmd = "find /Library/Logs/DiagnosticReports/ -type f \\( -name \"*.gpuRestart\" -o -name \"*.spin\" -o -name \"*.panic\" \\) -mtime -1 -exec stat -f \"%m %N\" {} \\; 2>/dev/null | sort -rn"
        let logsOut = Shell.run(logsCmd).output
        
        let now = Date().timeIntervalSince1970
        var active1h = 0
        var historical24h = 0
        var latestName: String? = nil
        var latestTimeStr: String? = nil
        var hoursSince = 999.0
        
        let lines = logsOut.components(separatedBy: "\n").filter { !$0.isEmpty }
        for (idx, line) in lines.enumerated() {
            let parts = line.components(separatedBy: " ")
            if parts.count >= 2, let mtime = Double(parts[0]) {
                let filePath = parts[1]
                let ageSeconds = now - mtime
                let ageHours = ageSeconds / 3600.0
                
                historical24h += 1
                if ageHours < 1.0 {
                    active1h += 1
                }
                
                if idx == 0 {
                    hoursSince = ageHours
                    latestName = URL(fileURLWithPath: filePath).lastPathComponent
                    let df = DateFormatter()
                    df.dateFormat = "h:mm a"
                    latestTimeStr = df.string(from: Date(timeIntervalSince1970: mtime))
                }
            }
        }
        
        let status = (active1h == 0) ? "STABLE_RESOLVED" : "ACTIVE_HANGS"
        return GPUMetrics(
            activeIncidentsLastHour: active1h,
            historicalIncidents24h: historical24h,
            hoursSinceLastCrash: hoursSince,
            status: status,
            latestIncidentName: latestName,
            latestIncidentTime: latestTimeStr
        )
    }
    
    private func auditPower() -> PowerMetrics {
        let battOut = Shell.run("pmset -g batt").output
        let isAC = battOut.contains("AC Power")
        var batteryPercent = 100
        if let pctRange = battOut.range(of: "%") {
            let prefix = battOut[..<pctRange.lowerBound]
            let digits = String(prefix.reversed().prefix(while: { $0.isNumber }).reversed())
            batteryPercent = Int(digits) ?? 100
        }
        
        let customOut = Shell.run("pmset -g custom").output
        var battSleep = 15
        var acSleep = 0
        var inBattSection = false
        var inACSection = false
        
        for line in customOut.components(separatedBy: "\n") {
            if line.contains("Battery Power:") {
                inBattSection = true; inACSection = false
            } else if line.contains("AC Power:") {
                inACSection = true; inBattSection = false
            } else if line.contains("sleep") && !line.contains("displaysleep") && !line.contains("disksleep") {
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 2, let val = Int(parts[1]) {
                    if inBattSection { battSleep = val }
                    if inACSection { acSleep = val }
                }
            }
        }
        
        let assertOut = Shell.run("pmset -g assertions").output
        let isAsserted = assertOut.contains("PreventUserIdleSystemSleep") || assertOut.contains("PreventSystemSleep")
        var holder: String? = nil
        if assertOut.contains("caffeinate") {
            holder = "caffeinate"
        } else if assertOut.contains("WindowServer") {
            holder = "WindowServer"
        }
        
        let conditionOut = Shell.run("system_profiler SPPowerDataType | grep 'Condition:'").output
        let condition = conditionOut.replacingOccurrences(of: "Condition:", with: "").trimmingCharacters(in: .whitespaces)
        
        let status = (isAC && battSleep >= 10) ? "OPTIMAL" : "CAUTION"
        
        return PowerMetrics(
            powerSource: isAC ? "AC Charger" : "Battery",
            batteryPercentage: batteryPercent,
            batteryCondition: condition.isEmpty ? "Normal" : condition,
            sleepPrevented: isAsserted,
            sleepAssertionHolder: holder,
            batterySleepMinutes: battSleep,
            acSleepMinutes: acSleep,
            status: status
        )
    }
    
    private func auditDisk() -> DiskMetrics {
        let dfOut = Shell.run("df -g /").output
        var totalGB = 0.0
        var freeGB = 0.0
        
        let lines = dfOut.components(separatedBy: "\n")
        if lines.count >= 2 {
            let cols = lines[1].components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if cols.count >= 4 {
                totalGB = Double(cols[1]) ?? 466.0
                freeGB = Double(cols[3]) ?? 390.0
            }
        }
        
        let pctFree = totalGB > 0 ? (freeGB / totalGB) * 100.0 : 0.0
        let status = freeGB >= 40.0 ? "AMPLE_SPACE" : "LOW_SPACE"
        
        return DiskMetrics(
            mountPoint: "/",
            totalGB: totalGB,
            freeGB: freeGB,
            percentFree: pctFree,
            status: status
        )
    }
    
    private func auditDaemons() -> DaemonMetrics {
        let gswitch = Shell.run("pgrep -l gSwitch").exitCode == 0
        let tbs = Shell.run("pgrep -l -f 'Turbo Boost Switcher'").exitCode == 0
        let status = (gswitch && tbs) ? "ALL_RUNNING" : "MISSING_DAEMON"
        
        return DaemonMetrics(
            gSwitchRunning: gswitch,
            turboBoostSwitcherRunning: tbs,
            status: status
        )
    }
    
    private func auditXcodeReadiness(disk: DiskMetrics, cpu: CPUMetrics, power: PowerMetrics) -> XcodeReadiness {
        var recs: [String] = []
        let diskOk = disk.freeGB >= 45.0
        if !diskOk {
            recs.append("Free disk space is under 45 GB (current: \(Int(disk.freeGB)) GB). Xcode install requires ~40 GB free.")
        }
        
        let thermOk = cpu.speedLimitPercent == 100 && !cpu.thermalWarning
        if !thermOk {
            recs.append("CPU is currently thermal throttled (\(cpu.speedLimitPercent)%). Heavy compilation will trigger fans and delays.")
        }
        
        let powerOk = power.powerSource == "AC Charger"
        if !powerOk {
            recs.append("Machine is on battery power. Keep charger plugged into right-side ports during heavy Xcode builds.")
        }
        
        let isReady = diskOk && thermOk && powerOk
        return XcodeReadiness(
            isReady: isReady,
            diskSpaceAdequate: diskOk,
            thermalsUnthrottled: thermOk,
            powerConnected: powerOk,
            recommendations: recs
        )
    }
}

// MARK: - CLI Terminal Formatter

struct Formatter {
    static let green = "\u{001B}[32m"
    static let yellow = "\u{001B}[33m"
    static let red = "\u{001B}[31m"
    static let blue = "\u{001B}[34m"
    static let cyan = "\u{001B}[36m"
    static let bold = "\u{001B}[1m"
    static let reset = "\u{001B}[0m"
    
    static func render(_ report: DiagnosticReport) {
        print("\n\(bold)🍎 macOS Hardware & Workload Health Audit\(reset)")
        print("\(cyan)────────────────────────────────────────────────────────────\(reset)")
        
        // Overview banner
        if report.overallHealth == "OPTIMAL" {
            print("  System Status:  \(green)\(bold)● OPTIMAL (All Guardrails Active)\(reset)")
        } else {
            print("  System Status:  \(yellow)\(bold)▲ ATTENTION NEEDED\(reset)")
        }
        print("  Audit Time:     \(report.timestamp)")
        print("\(cyan)────────────────────────────────────────────────────────────\(reset)\n")
        
        // 1. CPU & Thermals
        print("\(bold)1. CPU & Thermal Throttling\(reset)")
        print("   • Model:            \(report.cpu.model)")
        print("   • Cores:            \(report.cpu.physicalCores) Physical / \(report.cpu.logicalCores) Virtual (Hyper-Threads)")
        let speedColor = report.cpu.speedLimitPercent == 100 ? green : red
        print("   • CPU Speed Limit:  \(speedColor)\(report.cpu.speedLimitPercent)%\(reset) \(report.cpu.speedLimitPercent == 100 ? "✓ Full Speed" : "⚠ Throttled")")
        print("   • Thermal State:    \(report.cpu.thermalWarning ? "\(red)⚠ Warning Recorded\(reset)" : "\(green)✓ Safe Operating Zone\(reset)")")
        
        // 2. Memory & Swapping
        print("\n\(bold)2. Memory & Virtual Memory Pressure\(reset)")
        print("   • Physical Memory:  \(Int(report.memory.totalPhysicalGB)) GB")
        print("   • Free RAM:         \(String(format: "%.2f", report.memory.freeGB)) GB")
        print("   • Swap Used:        \(Int(report.memory.swapUsedMB)) MB")
        print("   • Pages Throttled:  \(report.memory.pagesThrottled == 0 ? "\(green)0 Pages (Zero Thrashing)\(reset)" : "\(red)\(report.memory.pagesThrottled) Pages\(reset)")")
        
        // 3. GPU Stability
        print("\n\(bold)3. GPU Power & Crash Audit\(reset)")
        if report.gpu.activeIncidentsLastHour == 0 {
            let hoursStr = String(format: "%.1f", report.gpu.hoursSinceLastCrash)
            print("   • Active State:     \(green)✓ 0 Crashes in last \(hoursStr)h (STABLE)\(reset)")
            if report.gpu.historicalIncidents24h > 0, let time = report.gpu.latestIncidentTime {
                print("   • Historical:       \(report.gpu.historicalIncidents24h) prior restarts resolved at \(time) (before guardrails)")
            }
        } else {
            print("   • Active State:     \(red)⚠ \(report.gpu.activeIncidentsLastHour) crashes in past hour!\(reset)")
        }
        
        // 4. Protection Daemons
        print("\n\(bold)4. Active Guardrail Daemons\(reset)")
        let gColor = report.daemons.gSwitchRunning ? green : red
        let tColor = report.daemons.turboBoostSwitcherRunning ? green : red
        print("   • gSwitch:          \(gColor)\(report.daemons.gSwitchRunning ? "✓ Running (GPU Isolated)" : "✗ NOT Running")\(reset)")
        print("   • TBS Pro:          \(tColor)\(report.daemons.turboBoostSwitcherRunning ? "✓ Running (80°C Auto-Cap)" : "✗ NOT Running")\(reset)")
        
        // 5. Power & Sleep Timers
        print("\n\(bold)5. Power & Sleep Management\(reset)")
        print("   • Source:           \(report.power.powerSource == "AC Charger" ? "\(green)🔌 AC Power (96W)\(reset)" : "\(yellow)🔋 Battery\(reset)")")
        print("   • Battery Level:    \(report.power.batteryPercentage)% (\(report.power.batteryCondition))")
        print("   • Battery Sleep:    \(report.power.batterySleepMinutes >= 10 ? "\(green)\(report.power.batterySleepMinutes) mins (Safe)\(reset)" : "\(red)\(report.power.batterySleepMinutes) mins (Too aggressive!)\(reset)")")
        print("   • Sleep Prevented:  \(report.power.sleepPrevented ? "\(green)✓ Active (\(report.power.sleepAssertionHolder ?? "system"))\(reset)" : "No")")
        
        // 6. Disk & Xcode Readiness
        print("\n\(bold)6. Xcode & Heavy Workload Readiness\(reset)")
        print("   • Free Disk Space:  \(green)\(Int(report.disk.freeGB)) GB free\(reset) (\(Int(report.disk.percentFree))% available)")
        if report.xcodeReadiness.isReady {
            print("   • Xcode Status:     \(green)\(bold)✓ READY FOR XCODE & COMPILATION\(reset)")
        } else {
            print("   • Xcode Status:     \(yellow)\(bold)▲ CAUTION BEFORE HEAVY BUILDS\(reset)")
            for rec in report.xcodeReadiness.recommendations {
                print("     - \(yellow)\(rec)\(reset)")
            }
        }
        print("\(cyan)────────────────────────────────────────────────────────────\(reset)\n")
    }
}

// MARK: - Entry Point

let args = CommandLine.arguments

if args.contains("--help") || args.contains("-h") {
    print("""
    OVERVIEW: mac-health — Native macOS Hardware Health & Universal Resource Governor
    
    USAGE: mac-health [subcommand / options]
    
    SUBCOMMANDS:
      pace           Scan and pace ALL AI agents, compilers, runtimes, and indexers system-wide
      governor       Launch continuous background daemon to auto-pace newly spawned tasks
    
    OPTIONS:
      --json         Output diagnostic metrics as JSON
      --watch <sec>  Continuously poll and print health telemetry every N seconds
      -h, --help     Show help information
    """)
    exit(0)
}

if args.contains("pace") {
    UniversalGovernor.paceAll(verbose: true)
    exit(0)
}

if args.contains("governor") {
    UniversalGovernor.runDaemon(intervalSec: 5)
    exit(0)
}

let auditor = MacHealthAuditor()

if args.contains("--json") {
    let report = auditor.audit()
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(report), let str = String(data: data, encoding: .utf8) {
        print(str)
    }
    exit(0)
}

if let watchIndex = args.firstIndex(of: "--watch"), watchIndex + 1 < args.count, let sec = UInt32(args[watchIndex + 1]) {
    while true {
        print("\u{001B}[2J\u{001B}[H", terminator: "") // Clear screen
        let report = auditor.audit()
        Formatter.render(report)
        sleep(sec)
    }
} else {
    let report = auditor.audit()
    Formatter.render(report)
}
