import Foundation

/// Composes every subsystem auditor into one report, then derives the overall
/// health verdict and compilation readiness. This is where the chain reactions
/// live: a GPU incident history flips mux safety, which degrades overall
/// health and withdraws compilation readiness with a concrete recommendation.
public struct HealthAuditor {
    let cpuAuditor: CPUAuditor
    let memoryAuditor: MemoryAuditor
    let gpuAuditor: GPUAuditor
    let windowServerAuditor: WindowServerAuditor
    let powerAuditor: PowerAuditor
    let diskAuditor: DiskAuditor
    let kextAuditor: KextAuditor
    let now: () -> Date

    public init(
        shell: CommandRunning = SystemShell(),
        reader: FileReading = SystemFileReader(),
        windowServerAuditor: WindowServerAuditor? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.cpuAuditor = CPUAuditor(shell: shell)
        self.memoryAuditor = MemoryAuditor(shell: shell)
        self.gpuAuditor = GPUAuditor(shell: shell, reader: reader, now: now)
        self.windowServerAuditor = windowServerAuditor ?? WindowServerAuditor(shell: shell)
        self.powerAuditor = PowerAuditor(shell: shell)
        self.diskAuditor = DiskAuditor(shell: shell)
        self.kextAuditor = KextAuditor(shell: shell)
        self.now = now
    }

    public func audit() -> DiagnosticReport {
        let cpu = cpuAuditor.audit()
        let memory = memoryAuditor.audit()
        let gpu = gpuAuditor.audit()
        let windowServer = windowServerAuditor.audit()
        let power = powerAuditor.audit()
        let disk = diskAuditor.audit()
        let kexts = kextAuditor.audit()
        let xcode = readiness(disk: disk, cpu: cpu, power: power, gpu: gpu, ws: windowServer, kexts: kexts)

        var isHealthy = true
        var isCritical = false

        if cpu.speedLimitPercent < 100 || cpu.thermalWarning { isHealthy = false }
        if memory.pagesThrottled > 0 { isHealthy = false }
        // An unreadable reports directory means the GPU history is unknown, not
        // clean. Reporting OPTIMAL there would be the one failure that matters:
        // a silent all-clear on a machine that is actively crashing.
        if !gpu.incidentScanAvailable { isHealthy = false }
        if gpu.activeIncidentsLastHour > 0 { isHealthy = false; isCritical = true }
        if gpu.historicalIncidents24h > 0 && gpu.hoursSinceLastCrash < 24.0 { isHealthy = false }
        if !gpu.gpuSwitchSafe { isHealthy = false }
        if !windowServer.isResponsive || windowServer.latencyMs > 500.0 { isHealthy = false; isCritical = true }
        if power.isBatteryDegraded { isHealthy = false }
        if !power.sleepTimingsCoherent { isHealthy = false }
        if !kexts.isCleanNative { isHealthy = false }

        let severity: HealthSeverity
        if isCritical {
            severity = .critical
        } else if !isHealthy {
            severity = .degraded
        } else {
            severity = .optimal
        }

        return DiagnosticReport(
            schemaVersion: macHealthSchemaVersion,
            toolVersion: macHealthVersion,
            timestamp: now(),
            overallHealth: severity.rawValue,
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

    /// Names the part the machine's own reports blamed and points at the mux
    /// mode that parks it. Which mode that is depends on which GPU is faulting,
    /// so this is derived rather than hardcoded to "switch to integrated".
    static func muxRecommendation(for gpu: GPUMetrics) -> String {
        let evidence: String
        if let faulting = gpu.faultingGPU, let count = gpu.incidentsByGPU[faulting] {
            let channel = gpu.restartChannels.isEmpty
                ? ""
                : " on the \(gpu.restartChannels.joined(separator: "/")) channel"
            evidence = "\(count) diagnostic report(s) in the last 24h name \(faulting)\(channel) as the faulting GPU"
        } else {
            evidence = "\(gpu.historicalIncidents24h) GPU incident report(s) in the last 24h name no specific hardware, so the discrete GPU is assumed"
        }

        // gpuswitch 0 parks the discrete GPU; 1 forces the discrete GPU and so
        // parks the integrated one. Recommend whichever keeps the faulting part idle.
        let mitigation = gpu.faultingGPUIsDiscrete || gpu.faultingGPU == nil
            ? "Run 'sudo pmset -a gpuswitch 0' to keep the internal display on the integrated GPU. Note: external displays are hardwired to the dGPU on many dual-GPU MacBook Pros, so an attached monitor will re-engage it."
            : "Run 'sudo pmset -a gpuswitch 1' to drive the display from the discrete GPU and leave the faulting integrated GPU idle. This costs battery life."

        return "\(evidence); gpuRestart storms stall WindowServer until the userspace watchdog panics the machine at 120s. \(mitigation)"
    }

    func readiness(
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
            recs.append("Machine is on battery power. Plug into AC power during heavy builds.")
        }

        let batteryOk = !power.isBatteryDegraded
        if !batteryOk {
            recs.append("Battery health is '\(power.batteryCondition)'. High power draw may cause sudden voltage drops if unplugged.")
        }

        if !gpu.incidentScanAvailable {
            recs.append("Cannot read /Library/Logs/DiagnosticReports, so the GPU incident history is unknown — the zeroes above mean 'not scanned', not 'no crashes'. That directory is owned by root:_analyticsusers with mode 0770; an administrator account is a member, a standard account is not. Re-run from an admin account, or with sudo, for a verdict backed by evidence.")
        }

        let gpuOk = gpu.gpuSwitchSafe && gpu.activeIncidentsLastHour == 0 && gpu.incidentScanAvailable
        if !gpuOk {
            if !gpu.gpuSwitchSafe {
                recs.append(Self.muxRecommendation(for: gpu))
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
