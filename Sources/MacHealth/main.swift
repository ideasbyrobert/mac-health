import Foundation
import CoreGraphics

// MARK: - Models

struct DiagnosticReport: Codable {
    let timestamp: Date
    let overallHealth: String
    let cpu: CPUMetrics
    let memory: MemoryMetrics
    let gpu: GPUMetrics
    let windowServer: WindowServerMetrics
    let power: PowerMetrics
    let disk: DiskMetrics
    let kernelExtensions: KernelExtensionsMetrics
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
    let gpuSwitchMode: String
    let gpuSwitchSafe: Bool
    let status: String
    let latestIncidentName: String?
    let latestIncidentTime: String?
}

struct WindowServerMetrics: Codable {
    let latencyMs: Double
    let isResponsive: Bool
    let cpuPercent: Double
    let sleepAssertionHolder: Bool
    let status: String
}

struct PowerMetrics: Codable {
    let powerSource: String
    let batteryPercentage: Int
    let batteryCondition: String
    let isBatteryDegraded: Bool
    let sleepPrevented: Bool
    let sleepAssertionHolder: String?
    let batteryDisplaySleepMinutes: Int
    let batterySleepMinutes: Int
    let acDisplaySleepMinutes: Int
    let acSleepMinutes: Int
    let sleepTimingsCoherent: Bool
    let status: String
}

struct DiskMetrics: Codable {
    let mountPoint: String
    let totalGB: Double
    let freeGB: Double
    let percentFree: Double
    let status: String
}

struct KernelExtensionsMetrics: Codable {
    let nonAppleKextsCount: Int
    let nonAppleKextNames: [String]
    let isCleanNative: Bool
    let status: String
}

struct XcodeReadiness: Codable {
    let isReady: Bool
    let diskSpaceAdequate: Bool
    let thermalsUnthrottled: Bool
    let powerConnected: Bool
    let batteryHealthy: Bool
    let gpuStable: Bool
    let windowServerHealthy: Bool
    let recommendations: [String]
}

// MARK: - Shell Executor

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
            patterns: ["claude", "agy", "antigravity", "codex", "ollama", "node", "python", "python3", "bun"],
            niceLevel: 15,
            backgroundQoS: true,
            throttleDiskIO: true
        ),
        GovernanceRule(
            category: "Compilers & Heavy Toolchains",
            patterns: ["swiftc", "clang", "clang++", "rustc", "xcodebuild", "ld64", "swift-frontend", "swift-build", "swift-driver"],
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
                // -x: exact process-name match. A substring -f match hits unrelated
                // processes whose command line merely contains the pattern
                // (e.g. 'find' → findmylocateagent, 'node' → other apps' bundled node)
                // as well as the transient shell running pgrep itself.
                let pgrepCmd = "pgrep -x '\(pattern)' 2>/dev/null"
                let pidsStr = Shell.run(pgrepCmd).output
                let pids = pidsStr.components(separatedBy: .whitespacesAndNewlines)
                    .compactMap { Int($0) }
                    .filter { $0 != currentPID && $0 != 1 && $0 != 0 }
                
                for pid in pids {
                    if results.contains(where: { $0.pid == pid }) { continue }
                    
                    let commOut = Shell.run("ps -p \(pid) -o comm= 2>/dev/null").output
                    let procName = URL(fileURLWithPath: commOut).lastPathComponent
                    
                    if rule.backgroundQoS {
                        // DARWIN_BG (-b) already includes throttled disk I/O; taskpolicy
                        // does not support applying -d to an existing pid.
                        Shell.run("taskpolicy -b -p \(pid) 2>/dev/null")
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
                        print("    ↳ Priority: \(Formatter.yellow)nice +\(rule.niceLevel)\(Formatter.reset) | QoS: \(Formatter.cyan)\(item.qos)\(Formatter.reset)\(rule.backgroundQoS ? " | Disk I/O: \(Formatter.blue)Throttled (BG policy)\(Formatter.reset)" : "")")
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
}

// MARK: - Auditor

final class MacHealthAuditor {
    
    func audit() -> DiagnosticReport {
        let cpu = auditCPU()
        let memory = auditMemory()
        let gpu = auditGPU()
        let windowServer = auditWindowServer()
        let power = auditPower()
        let disk = auditDisk()
        let kexts = auditKernelExtensions()
        let xcode = auditXcodeReadiness(disk: disk, cpu: cpu, power: power, gpu: gpu, ws: windowServer, kexts: kexts)
        
        var isHealthy = true
        var isCritical = false
        
        if cpu.speedLimitPercent < 100 || cpu.thermalWarning { isHealthy = false }
        if memory.pagesThrottled > 0 { isHealthy = false }
        if gpu.activeIncidentsLastHour > 0 { isHealthy = false; isCritical = true }
        if gpu.historicalIncidents24h > 0 && gpu.hoursSinceLastCrash < 24.0 { isHealthy = false }
        if !gpu.gpuSwitchSafe { isHealthy = false }
        if !windowServer.isResponsive || windowServer.latencyMs > 500.0 { isHealthy = false; isCritical = true }
        if power.isBatteryDegraded { isHealthy = false }
        if !power.sleepTimingsCoherent { isHealthy = false }
        if !kexts.isCleanNative { isHealthy = false }
        
        let overallHealth: String
        if isCritical {
            overallHealth = "CRITICAL_ATTENTION_NEEDED"
        } else if !isHealthy {
            overallHealth = "DEGRADED_OR_WARNING"
        } else {
            overallHealth = "OPTIMAL"
        }
        
        return DiagnosticReport(
            timestamp: Date(),
            overallHealth: overallHealth,
            cpu: cpu,
            memory: memory,
            gpu: gpu,
            windowServer: windowServer,
            power: power,
            disk: disk,
            kernelExtensions: kexts,
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
            let sub = swapOut[freeRange.upperBound...]
            let numStr = sub.prefix(while: { $0.isNumber || $0 == "." })
            swapFree = Double(numStr) ?? 0.0
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
    
    private func auditGPU() -> GPUMetrics {
        let logsCmd = "find /Library/Logs/DiagnosticReports/ -type f \\( -name \"*.gpuRestart\" -o -name \"*.spin\" -o -name \"*.panic\" -o -name \"*.shutdownStall\" \\) -mtime -1 -exec stat -f \"%m %N\" {} \\; 2>/dev/null | sort -rn"
        let logsOut = Shell.run(logsCmd).output
        
        let now = Date().timeIntervalSince1970
        var active1h = 0
        var historical24h = 0
        var latestName: String? = nil
        var latestTimeStr: String? = nil
        var hoursSince = 999.0
        
        let lines = logsOut.components(separatedBy: "\n").filter { !$0.isEmpty }
        for (idx, line) in lines.enumerated() {
            // Split on the first space only — report filenames can contain spaces.
            if let sep = line.firstIndex(of: " "), let mtime = Double(line[..<sep]) {
                let filePath = String(line[line.index(after: sep)...])
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
        
        // Audit GPU switching mode
        let customOut = Shell.run("pmset -g custom").output
        var gpuSwitchVal = 2
        for line in customOut.components(separatedBy: "\n") {
            if line.contains("gpuswitch") {
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 2, let val = Int(parts[1]) {
                    gpuSwitchVal = val
                    break
                }
            }
        }
        
        // Diagnostic history on this machine (gpuRestart storms + WindowServer
        // watchdog spins, Aug 2026): the AMD Radeon Pro 5300M (Navi14) is the
        // component that faults (VMPT restarts), so any mode that engages the
        // dGPU for the desktop is the risk — integrated-only is the safe state.
        let gpuSwitchMode: String
        let gpuSwitchSafe: Bool
        switch gpuSwitchVal {
        case 0:
            gpuSwitchMode = "Integrated Only (iGPU - faulting AMD dGPU kept idle)"
            gpuSwitchSafe = true
        case 1:
            gpuSwitchMode = "Discrete Only (AMD Forced - Faulting GPU Engaged!)"
            gpuSwitchSafe = false
        default:
            gpuSwitchMode = "Dynamic Switching (AMD dGPU Engaged)"
            gpuSwitchSafe = false
        }
        
        let status: String
        if active1h > 0 {
            status = "ACTIVE_HANGS_LAST_HOUR"
        } else if historical24h > 0 && hoursSince < 24.0 {
            status = "HISTORICAL_PANICS_RECORDED"
        } else if !gpuSwitchSafe {
            status = "DYNAMIC_SWITCHING_UNSAFE"
        } else {
            status = "STABLE"
        }
        
        return GPUMetrics(
            activeIncidentsLastHour: active1h,
            historicalIncidents24h: historical24h,
            hoursSinceLastCrash: hoursSince,
            gpuSwitchMode: gpuSwitchMode,
            gpuSwitchSafe: gpuSwitchSafe,
            status: status,
            latestIncidentName: latestName,
            latestIncidentTime: latestTimeStr
        )
    }
    
    func auditWindowServer() -> WindowServerMetrics {
        // Probe WindowServer Mach IPC round-trip latency
        var latency = 0.0
        var responsive = true
        
        let group = DispatchGroup()
        group.enter()
        
        let startTime = CFAbsoluteTimeGetCurrent()
        DispatchQueue.global(qos: .userInteractive).async {
            let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)
            let _ = (list as? [Any])?.count ?? 0
            latency = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            group.leave()
        }
        
        let result = group.wait(timeout: .now() + .milliseconds(1500))
        if result == .timedOut {
            latency = 1500.0
            responsive = false
        }
        
        // WindowServer CPU usage
        let wsPidOut = Shell.run("pgrep -x WindowServer 2>/dev/null").output
        var wsCpu = 0.0
        if let wsPid = Int(wsPidOut.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let cpuOut = Shell.run("ps -p \(wsPid) -o %cpu= 2>/dev/null").output
            wsCpu = Double(cpuOut.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0.0
        }
        
        // Sleep assertion check
        let assertOut = Shell.run("pmset -g assertions 2>/dev/null").output
        let wsAssert = assertOut.contains("WindowServer")
        
        let status: String
        if !responsive || latency >= 1000.0 {
            status = "UNRESPONSIVE_STALL_DETECTED"
        } else if latency > 200.0 || wsCpu > 80.0 {
            status = "ELEVATED_LATENCY"
        } else {
            status = "RESPONSIVE"
        }
        
        return WindowServerMetrics(
            latencyMs: latency,
            isResponsive: responsive,
            cpuPercent: wsCpu,
            sleepAssertionHolder: wsAssert,
            status: status
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
        var battDisplaySleep = 10
        var acSleep = 0
        var acDisplaySleep = 20
        var inBattSection = false
        var inACSection = false
        
        for line in customOut.components(separatedBy: "\n") {
            if line.contains("Battery Power:") {
                inBattSection = true; inACSection = false
            } else if line.contains("AC Power:") {
                inACSection = true; inBattSection = false
            } else if line.contains("displaysleep") {
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 2, let val = Int(parts[1]) {
                    if inBattSection { battDisplaySleep = val }
                    if inACSection { acDisplaySleep = val }
                }
            } else if line.contains("sleep") && !line.contains("displaysleep") && !line.contains("disksleep") {
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 2, let val = Int(parts[1]) {
                    if inBattSection { battSleep = val }
                    if inACSection { acSleep = val }
                }
            }
        }
        
        // Coherency check: displaysleep must be <= sleep when sleep is enabled (> 0)
        var coherent = true
        if battSleep > 0 && battDisplaySleep > battSleep { coherent = false }
        if acSleep > 0 && acDisplaySleep > acSleep { coherent = false }
        
        let assertOut = Shell.run("pmset -g assertions").output
        let isAsserted = assertOut.contains("PreventUserIdleSystemSleep") || assertOut.contains("PreventSystemSleep")
        var holder: String? = nil
        if assertOut.contains("caffeinate") {
            holder = "caffeinate"
        } else if assertOut.contains("WindowServer") {
            holder = "WindowServer"
        }
        
        let conditionOut = Shell.run("system_profiler SPPowerDataType 2>/dev/null | grep 'Condition:'").output
        let condition = conditionOut.replacingOccurrences(of: "Condition:", with: "").trimmingCharacters(in: .whitespaces)
        let isDegraded = !condition.isEmpty && condition.lowercased() != "normal"
        
        let status: String
        if isDegraded {
            status = "SERVICE_RECOMMENDED"
        } else if !coherent {
            status = "INCOHERENT_SLEEP_TIMINGS"
        } else if isAC {
            status = "OPTIMAL_AC"
        } else {
            status = "BATTERY_ACTIVE"
        }
        
        return PowerMetrics(
            powerSource: isAC ? "AC Charger" : "Battery",
            batteryPercentage: batteryPercent,
            batteryCondition: condition.isEmpty ? "Normal" : condition,
            isBatteryDegraded: isDegraded,
            sleepPrevented: isAsserted,
            sleepAssertionHolder: holder,
            batteryDisplaySleepMinutes: battDisplaySleep,
            batterySleepMinutes: battSleep,
            acDisplaySleepMinutes: acDisplaySleep,
            acSleepMinutes: acSleep,
            sleepTimingsCoherent: coherent,
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
    
    private func auditKernelExtensions() -> KernelExtensionsMetrics {
        let kextOut = Shell.run("kmutil showloaded 2>/dev/null | grep -v 'com.apple.' | grep -v 'Index Refs' | grep -v 'Executing:' | grep -v 'No variant'").output
        let lines = kextOut.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        
        var nonAppleNames: [String] = []
        for line in lines {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if parts.count >= 6 {
                nonAppleNames.append(parts[5])
            } else if !parts.isEmpty {
                nonAppleNames.append(parts.joined(separator: " "))
            }
        }
        
        let isClean = nonAppleNames.isEmpty
        let status = isClean ? "CLEAN_NATIVE" : "UNSAFE_LEGACY_KEXTS_LOADED"
        
        return KernelExtensionsMetrics(
            nonAppleKextsCount: nonAppleNames.count,
            nonAppleKextNames: nonAppleNames,
            isCleanNative: isClean,
            status: status
        )
    }
    
    private func auditXcodeReadiness(
        disk: DiskMetrics,
        cpu: CPUMetrics,
        power: PowerMetrics,
        gpu: GPUMetrics,
        ws: WindowServerMetrics,
        kexts: KernelExtensionsMetrics
    ) -> XcodeReadiness {
        var recs: [String] = []
        
        let diskOk = disk.freeGB >= 45.0
        if !diskOk {
            recs.append("Free disk space is under 45 GB (current: \(Int(disk.freeGB)) GB). Xcode builds require >= 40 GB free.")
        }
        
        let thermOk = cpu.speedLimitPercent == 100 && !cpu.thermalWarning
        if !thermOk {
            recs.append("CPU is currently thermal throttled (\(cpu.speedLimitPercent)%). Heavy compilation will trigger thermal delays.")
        }
        
        let powerOk = power.powerSource == "AC Charger"
        if !powerOk {
            recs.append("Machine is on battery power. Plug into 96W AC adapter during heavy builds.")
        }
        
        let batteryOk = !power.isBatteryDegraded
        if !batteryOk {
            recs.append("Battery health is '\(power.batteryCondition)'. High power draw may cause sudden voltage drops if unplugged.")
        }
        
        let gpuOk = gpu.gpuSwitchSafe && gpu.activeIncidentsLastHour == 0
        if !gpuOk {
            if !gpu.gpuSwitchSafe {
                recs.append("The AMD Radeon 5300M is engaged for the desktop; it is the GPU that repeatedly faults (VMPT gpuRestarts -> WindowServer watchdog panics). Run 'sudo pmset -a gpuswitch 0' to keep the internal display on the Intel iGPU. Note: external displays are hardwired to the dGPU on this model.")
            }
            if gpu.activeIncidentsLastHour > 0 {
                recs.append("GPU crashes/restarts occurred within the last hour.")
            }
        }
        
        let wsOk = ws.isResponsive && ws.latencyMs < 500.0
        if !wsOk {
            recs.append("WindowServer is experiencing elevated latency (\(String(format: "%.1f", ws.latencyMs))ms). UI compositor may be stalling.")
        }
        
        if !kexts.isCleanNative {
            recs.append("Non-native third-party kernel extensions loaded: \(kexts.nonAppleKextNames.joined(separator: ", ")). Unload them to avoid kernel panics.")
        }
        
        let isReady = diskOk && thermOk && powerOk && gpuOk && wsOk && kexts.isCleanNative
        return XcodeReadiness(
            isReady: isReady,
            diskSpaceAdequate: diskOk,
            thermalsUnthrottled: thermOk,
            powerConnected: powerOk,
            batteryHealthy: batteryOk,
            gpuStable: gpuOk,
            windowServerHealthy: wsOk,
            recommendations: recs
        )
    }
}

// MARK: - Proactive Sentinel & Auto-Healing Daemon

final class ProactiveSentinel {
    
    static var userHome: String {
        if FileManager.default.fileExists(atPath: "/Users/robert") {
            return "/Users/robert"
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }
    
    static var agentPlistPath: String {
        return "\(userHome)/Library/LaunchAgents/com.robert.mac-health.sentinel.plist"
    }
    
    static var userUID: String {
        let uidOut = Shell.run("id -u robert 2>/dev/null || id -u").output.trimmingCharacters(in: .whitespacesAndNewlines)
        return uidOut.isEmpty ? "502" : uidOut
    }
    
    static func runDaemon(intervalSec: UInt32 = 5, verbose: Bool = true) {
        // Under launchd, stdout is redirected to a file and becomes fully buffered,
        // so events would sit invisible in a 64KB buffer for hours. Line-buffer it.
        setvbuf(stdout, nil, _IOLBF, 0)
        if verbose {
            print("\n\(Formatter.bold)🛡️ mac-health Proactive Sentinel Daemon Active\(Formatter.reset)")
            print("\(Formatter.cyan)────────────────────────────────────────────────────────────\(Formatter.reset)")
            print("  • Heartbeat Interval:  \(intervalSec) seconds")
            print("  • Proactive Monitors:  WindowServer IPC, GPU Watchdog, Thermal Headroom, Swap Thrashing")
            print("  • Auto-Healing:        Dynamic QoS Pacing, Priority Shedding, Sleep Timings")
            print("\(Formatter.cyan)────────────────────────────────────────────────────────────\(Formatter.reset)\n")
            print("Sentinel is actively guarding the system. Press Ctrl+C to stop.\n")
        }
        
        let auditor = MacHealthAuditor()
        var consecutiveSlowWS = 0
        
        while true {
            let wsMetrics = auditor.auditWindowServer()
            // Parse the value: pmset separates the key and value with mixed
            // whitespace ("CPU_Speed_Limit \t= 100"), so an exact substring
            // check for "CPU_Speed_Limit = 100" never matches and would report
            // permanent throttling.
            let thermOut = Shell.run("pmset -g therm 2>/dev/null").output
            var cpuSpeedLimit = 100
            for line in thermOut.components(separatedBy: "\n") where line.contains("CPU_Speed_Limit") {
                let parts = line.components(separatedBy: "=")
                if parts.count == 2, let val = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                    cpuSpeedLimit = val
                }
            }
            let isThrottled = cpuSpeedLimit < 100
            // pmset only reports hard throttling; ProcessInfo surfaces the OS
            // thermal pressure level well before the speed limit drops (fans
            // maxed, die near Tjmax), which is when shedding load actually
            // prevents the stall instead of reacting to it.
            let thermalState = ProcessInfo.processInfo.thermalState
            let thermalPressure = thermalState == .serious || thermalState == .critical
            
            // Check for WindowServer latency elevation or stall
            if !wsMetrics.isResponsive || wsMetrics.latencyMs > 250.0 {
                consecutiveSlowWS += 1
                let timestamp = Formatter.timeString(Date())
                print("[\(timestamp)] \(Formatter.red)⚠ WindowServer Latency Spike: \(String(format: "%.1f", wsMetrics.latencyMs))ms (Streak: \(consecutiveSlowWS))\(Formatter.reset)")
                print("  ↳ Proactively shedding CPU contention and pacing heavy background processes...")
                
                // Immediately pace all background runtimes and heavy tasks
                UniversalGovernor.paceAll(verbose: false)
            } else {
                if consecutiveSlowWS > 0 {
                    let timestamp = Formatter.timeString(Date())
                    print("[\(timestamp)] \(Formatter.green)✓ WindowServer Recovered: \(String(format: "%.1f", wsMetrics.latencyMs))ms latency (Normal)\(Formatter.reset)")
                }
                consecutiveSlowWS = 0
            }
            
            // If thermal throttling or serious thermal pressure kicks in,
            // auto-pace heavy toolchains
            if isThrottled || thermalPressure {
                let timestamp = Formatter.timeString(Date())
                let reason = isThrottled ? "CPU Speed Limit \(cpuSpeedLimit)%" : "Thermal Pressure \(thermalState == .critical ? "CRITICAL" : "Serious")"
                print("[\(timestamp)] \(Formatter.yellow)▲ Thermal Event (\(reason)) → Auto-pacing heavy compilers & agents...\(Formatter.reset)")
                UniversalGovernor.paceAll(verbose: false)
            }
            
            sleep(intervalSec)
        }
    }
    
    static func installLaunchAgent() {
        let resolvedBinary = "/Users/robert/.local/bin/mac-health"
        
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.robert.mac-health.sentinel</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(resolvedBinary)</string>
                <string>sentinel</string>
                <string>--daemon</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>/tmp/mac-health-sentinel.log</string>
            <key>StandardErrorPath</key>
            <string>/tmp/mac-health-sentinel.err</string>
        </dict>
        </plist>
        """
        
        let dir = URL(fileURLWithPath: agentPlistPath).deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        
        do {
            try plistContent.write(toFile: agentPlistPath, atomically: true, encoding: .utf8)
            let uid = userUID
            // `launchctl asuser` requires root; when running as the target user,
            // talk to launchd directly.
            let prefix = getuid() == 0 ? "launchctl asuser \(uid) " : ""
            Shell.run("\(prefix)launchctl bootout gui/\(uid) '\(agentPlistPath)' 2>/dev/null")
            let bootstrap = Shell.run("\(prefix)launchctl bootstrap gui/\(uid) '\(agentPlistPath)'")

            print("\n\(Formatter.green)✓ Proactive Sentinel LaunchAgent Installed Successfully!\(Formatter.reset)")
            print("  • Plist Location:  \(agentPlistPath)")
            print("  • Binary Path:     \(resolvedBinary)")
            print("  • Service Target:  gui/\(uid) (robert)")
            if bootstrap.exitCode == 0 {
                print("  • Status:          Running in Background")
            } else {
                print("  • Status:          \(Formatter.yellow)Bootstrap failed — \(bootstrap.output)\(Formatter.reset)")
                print("    ↳ If running over SSH, run: launchctl bootstrap gui/\(uid) '\(agentPlistPath)' from a GUI terminal session.")
            }
            print("  • Logs:            /tmp/mac-health-sentinel.log\n")
        } catch {
            print("\(Formatter.red)✗ Failed to write LaunchAgent plist: \(error.localizedDescription)\(Formatter.reset)")
        }
    }
    
    static func uninstallLaunchAgent() {
        let uid = userUID
        let prefix = getuid() == 0 ? "launchctl asuser \(uid) " : ""
        Shell.run("\(prefix)launchctl bootout gui/\(uid) '\(agentPlistPath)' 2>/dev/null")
        Shell.run("pkill -f '[m]ac-health sentinel --daemon' 2>/dev/null")
        try? FileManager.default.removeItem(atPath: agentPlistPath)
        print("\n\(Formatter.green)✓ Proactive Sentinel LaunchAgent Removed Successfully.\(Formatter.reset)\n")
    }
    
    static func statusLaunchAgent() {
        // The [m] regex trick stops pgrep -f from matching the shell that is
        // running this very pgrep (its command line contains the pattern text),
        // which previously made status report "Active" even with no daemon.
        let psOut = Shell.run("pgrep -f '[m]ac-health sentinel --daemon'").output.trimmingCharacters(in: .whitespacesAndNewlines)
        let exists = FileManager.default.fileExists(atPath: agentPlistPath)

        print("\n\(Formatter.bold)🛡️ mac-health Sentinel LaunchAgent Status\(Formatter.reset)")
        print("\(Formatter.cyan)────────────────────────────────────────────────────────────\(Formatter.reset)")
        print("  • Installed on Disk: \(exists ? "\(Formatter.green)Yes (\(agentPlistPath))\(Formatter.reset)" : "\(Formatter.yellow)No\(Formatter.reset)")")
        let pids = psOut.components(separatedBy: .newlines).filter { !$0.isEmpty }
        if pids.isEmpty {
            print("  • Service Status:    \(Formatter.yellow)Inactive / Stopped\(Formatter.reset)")
        } else {
            print("  • Service Status:    \(Formatter.green)Active (PID: \(pids.joined(separator: ", ")))\(Formatter.reset)")
        }
        print("\(Formatter.cyan)────────────────────────────────────────────────────────────\(Formatter.reset)\n")
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
    
    static func timeString(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df.string(from: date)
    }
    
    static func render(_ report: DiagnosticReport) {
        print("\n\(bold)🍎 macOS Hardware Health & Watchdog Guard Audit\(reset)")
        print("\(cyan)────────────────────────────────────────────────────────────\(reset)")
        
        switch report.overallHealth {
        case "OPTIMAL":
            print("  System Status:  \(green)\(bold)● OPTIMAL (All Guardrails Active & Stable)\(reset)")
        case "DEGRADED_OR_WARNING":
            print("  System Status:  \(yellow)\(bold)▲ ATTENTION / DEGRADED (Check Warnings Below)\(reset)")
        default:
            print("  System Status:  \(red)\(bold)■ CRITICAL ATTENTION REQUIRED\(reset)")
        }
        print("  Audit Time:     \(report.timestamp)")
        print("\(cyan)────────────────────────────────────────────────────────────\(reset)\n")
        
        // 1. WindowServer & Watchdog Health
        print("\(bold)1. WindowServer Compositor & Watchdog Probe\(reset)")
        let wsColor = report.windowServer.isResponsive ? (report.windowServer.latencyMs < 200 ? green : yellow) : red
        print("   • IPC Latency:      \(wsColor)\(String(format: "%.1f", report.windowServer.latencyMs)) ms\(reset) \(report.windowServer.isResponsive ? "✓ Responsive" : "⚠ Stall Detected")")
        print("   • CPU Utilization:  \(String(format: "%.1f", report.windowServer.cpuPercent))%")
        print("   • Sleep Assertion:  \(report.windowServer.sleepAssertionHolder ? "Active" : "None")")
        
        // 2. GPU Power & Mux Stability
        print("\n\(bold)2. GPU Stability & Hardware Mux State\(reset)")
        let gpuMuxColor = report.gpu.gpuSwitchSafe ? green : red
        print("   • GPU Mode:         \(gpuMuxColor)\(report.gpu.gpuSwitchMode)\(reset)")
        if report.gpu.activeIncidentsLastHour == 0 {
            let hoursStr = String(format: "%.1f", report.gpu.hoursSinceLastCrash)
            print("   • Active State:     \(green)✓ 0 Crashes in last \(hoursStr)h\(reset)")
            if report.gpu.historicalIncidents24h > 0, let time = report.gpu.latestIncidentTime, let name = report.gpu.latestIncidentName {
                print("   • 24h History:      \(yellow)\(report.gpu.historicalIncidents24h) prior incidents recorded (last: \(name) at \(time))\(reset)")
            }
        } else {
            print("   • Active State:     \(red)⚠ \(report.gpu.activeIncidentsLastHour) crashes in past hour!\(reset)")
        }
        
        // 3. Power & Battery Health
        print("\n\(bold)3. Power, Battery & Sleep Timings\(reset)")
        print("   • Source:           \(report.power.powerSource == "AC Charger" ? "\(green)🔌 AC Power (96W)\(reset)" : "\(yellow)🔋 Battery\(reset)")")
        let battCondColor = report.power.isBatteryDegraded ? red : green
        print("   • Battery Level:    \(report.power.batteryPercentage)% (\(battCondColor)\(report.power.batteryCondition)\(reset))")
        let sleepTimingColor = report.power.sleepTimingsCoherent ? green : red
        let isAC = report.power.powerSource == "AC Charger"
        let dispSleep = isAC ? report.power.acDisplaySleepMinutes : report.power.batteryDisplaySleepMinutes
        let sysSleep = isAC ? report.power.acSleepMinutes : report.power.batterySleepMinutes
        print("   • Sleep Timers:     \(sleepTimingColor)Display: \(dispSleep)m / Sleep: \(sysSleep)m \(report.power.sleepTimingsCoherent ? "✓ Coherent" : "⚠ Inverted Order")\(reset)")
        
        // 4. Kernel Extensions & Cleanliness
        print("\n\(bold)4. Kernel Integrity & Third-Party Extensions\(reset)")
        if report.kernelExtensions.isCleanNative {
            print("   • Native State:     \(green)✓ 100% Clean (0 Unsafe Third-Party Kexts)\(reset)")
        } else {
            print("   • Non-Apple Kexts:  \(red)⚠ \(report.kernelExtensions.nonAppleKextsCount) detected: \(report.kernelExtensions.nonAppleKextNames.joined(separator: ", "))\(reset)")
        }
        
        // 5. CPU & Thermal State
        print("\n\(bold)5. CPU & Thermal Headroom\(reset)")
        print("   • Model:            \(report.cpu.model)")
        print("   • Cores:            \(report.cpu.physicalCores) Physical / \(report.cpu.logicalCores) Virtual (Hyper-Threads)")
        let speedColor = report.cpu.speedLimitPercent == 100 ? green : red
        print("   • CPU Speed Limit:  \(speedColor)\(report.cpu.speedLimitPercent)%\(reset) \(report.cpu.speedLimitPercent == 100 ? "✓ Full Speed" : "⚠ Throttled")")
        print("   • Thermal State:    \(report.cpu.thermalWarning ? "\(red)⚠ Warning Recorded\(reset)" : "\(green)✓ Safe Operating Zone\(reset)")")
        
        // 6. Memory & Virtual Memory Pressure
        print("\n\(bold)6. Memory & Virtual Memory Pressure\(reset)")
        print("   • Physical Memory:  \(Int(report.memory.totalPhysicalGB)) GB")
        print("   • Free RAM:         \(String(format: "%.2f", report.memory.freeGB)) GB")
        print("   • Swap Used:        \(Int(report.memory.swapUsedMB)) MB")
        print("   • Pages Throttled:  \(report.memory.pagesThrottled == 0 ? "\(green)0 Pages (Zero Thrashing)\(reset)" : "\(red)\(report.memory.pagesThrottled) Pages\(reset)")")
        
        // 7. Disk & Xcode Readiness
        print("\n\(bold)7. Xcode & Compilation Readiness\(reset)")
        print("   • Free Disk Space:  \(green)\(Int(report.disk.freeGB)) GB free\(reset) (\(Int(report.disk.percentFree))% available)")
        if report.xcodeReadiness.isReady {
            print("   • Readiness Status: \(green)\(bold)✓ READY FOR HEAVY WORKLOADS & COMPILATION\(reset)")
        } else {
            print("   • Readiness Status: \(yellow)\(bold)▲ CAUTION BEFORE HEAVY BUILDS\(reset)")
            for rec in report.xcodeReadiness.recommendations {
                print("     ↳ \(yellow)\(rec)\(reset)")
            }
        }
        print("\(cyan)────────────────────────────────────────────────────────────\(reset)\n")
    }
}

// MARK: - Entry Point

let args = CommandLine.arguments

if args.contains("--help") || args.contains("-h") {
    print("""
    OVERVIEW: mac-health — Native macOS Hardware Health, Watchdog Sentinel & Resource Governor
    
    USAGE: mac-health [subcommand / options]
    
    SUBCOMMANDS:
      pace                  Scan and pace ALL AI agents, compilers, runtimes, and indexers
      sentinel              Run proactive real-time watchdog sentinel & auto-healing monitor
      sentinel install      Install persistent background LaunchAgent service across reboots
      sentinel uninstall    Remove persistent background LaunchAgent service
      sentinel status       Check status of the background sentinel service
    
    OPTIONS:
      --json                Output diagnostic metrics as structured JSON
      --watch <sec>         Continuously poll and render health telemetry every N seconds
      -h, --help            Show help information
    """)
    exit(0)
}

if args.contains("pace") {
    UniversalGovernor.paceAll(verbose: true)
    exit(0)
}

if args.contains("sentinel") {
    if args.contains("install") {
        ProactiveSentinel.installLaunchAgent()
        exit(0)
    }
    if args.contains("uninstall") {
        ProactiveSentinel.uninstallLaunchAgent()
        exit(0)
    }
    if args.contains("status") {
        ProactiveSentinel.statusLaunchAgent()
        exit(0)
    }
    
    let isDaemon = args.contains("--daemon")
    ProactiveSentinel.runDaemon(intervalSec: 5, verbose: !isDaemon)
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
        print("\u{001B}[2J\u{001B}[H", terminator: "")
        let report = auditor.audit()
        Formatter.render(report)
        sleep(sec)
    }
} else {
    let report = auditor.audit()
    Formatter.render(report)
}
