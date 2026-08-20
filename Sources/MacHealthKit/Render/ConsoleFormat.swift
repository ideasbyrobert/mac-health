import Foundation

public struct ConsoleFormat {
    public static let green = "\u{001B}[32m"
    public static let yellow = "\u{001B}[33m"
    public static let red = "\u{001B}[31m"
    public static let blue = "\u{001B}[34m"
    public static let cyan = "\u{001B}[36m"
    public static let bold = "\u{001B}[1m"
    public static let reset = "\u{001B}[0m"

    public static func timeString(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df.string(from: date)
    }

    /// Width of the label column every bullet aligns its value against.
    private static let labelWidth = 18

    private static func row(_ label: String, _ value: String) -> String {
        let padding = max(labelWidth - label.count, 1)
        return "   • \(label)\(String(repeating: " ", count: padding))\(value)"
    }

    private static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// Section 2 as lines, without its header. Split out because the mux
    /// verdict is only trustworthy if the evidence behind it is printed
    /// alongside it, and that is several branches worth of text.
    public static func gpuSection(for gpu: GPUMetrics) -> [String] {
        var lines: [String] = []

        let gpuMuxColor = gpu.gpuSwitchSafe ? green : red
        lines.append(row("GPU Mode:", "\(gpuMuxColor)\(gpu.gpuSwitchMode)\(reset)"))

        // A machine that reports no GPUs tells us nothing; an empty bullet
        // would imply we looked and found none installed.
        if !gpu.installedGPUs.isEmpty {
            let devices = gpu.installedGPUs
                .map { "\($0.name) (\($0.isDiscrete ? "discrete" : "integrated"))" }
                .joined(separator: ", ")
            lines.append(row("Installed GPUs:", devices))
        }

        // Printing "✓ 0 Crashes" when nothing was scanned would be the most
        // dangerous line this tool could emit, so the unknown state replaces it
        // rather than sitting beside it.
        if !gpu.incidentScanAvailable {
            lines.append(row("Incident Scan:", "\(yellow)⚠ Unavailable — cannot read \(GPUAuditor.reportsDirectory)\(reset)"))
            lines.append(row("Active State:", "\(yellow)Unknown (not scanned — this is not an all-clear)\(reset)"))
            return lines
        }

        if gpu.activeIncidentsLastHour == 0 {
            let hoursStr = String(format: "%.1f", gpu.hoursSinceLastCrash)
            lines.append(row("Active State:", "\(green)✓ 0 Crashes in last \(hoursStr)h\(reset)"))
            if gpu.historicalIncidents24h > 0, let time = gpu.latestIncidentTime, let name = gpu.latestIncidentName {
                lines.append(row("24h History:", "\(yellow)\(gpu.historicalIncidents24h) prior incidents recorded (last: \(name) at \(time))\(reset)"))
            }
        } else {
            lines.append(row("Active State:", "\(red)⚠ \(gpu.activeIncidentsLastHour) crashes in past hour!\(reset)"))
        }

        if let faulting = gpu.faultingGPU {
            let count = gpu.incidentsByGPU[faulting] ?? 0
            let kind = gpu.faultingGPUIsDiscrete ? "discrete" : "integrated"
            lines.append(row("Faulting Part:", "\(red)\(faulting) (\(kind)) — named by \(plural(count, "report"))\(reset)"))

            let others = gpu.incidentsByGPU
                .filter { $0.key != faulting }
                .sorted { ($0.value, $0.key) > ($1.value, $1.key) }
                .map { "\($0.key) (\($0.value))" }
            if !others.isEmpty {
                lines.append(row("Also Named:", "\(yellow)\(others.joined(separator: ", "))\(reset)"))
            }

            if !gpu.restartChannels.isEmpty {
                let label = gpu.restartChannels.count == 1 ? "Restart Channel:" : "Restart Channels:"
                lines.append(row(label, "\(red)\(gpu.restartChannels.joined(separator: ", "))\(reset)"))
            }
        }

        // An assumption is not a finding, so it is labelled as one. The
        // discrete-GPU assumption only applies on a machine that has one.
        if gpu.unattributedIncidents > 0 {
            let subject = plural(gpu.unattributedIncidents, "report")
            let verb = gpu.unattributedIncidents == 1 ? "names" : "name"
            let assumption = gpu.installedGPUs.contains(where: \.isDiscrete)
                ? " — discrete GPU assumed for GPU-shaped reports"
                : ""
            lines.append(row("Unattributed:", "\(yellow)\(subject) \(verb) no hardware\(assumption)\(reset)"))
        }

        return lines
    }

    public static func render(_ report: DiagnosticReport) {
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
        for line in gpuSection(for: report.gpu) {
            print(line)
        }

        // 3. Power & Battery Health
        print("\n\(bold)3. Power, Battery & Sleep Timings\(reset)")
        print("   • Source:           \(report.power.powerSource == "AC Charger" ? "\(green)🔌 AC Power\(reset)" : "\(yellow)🔋 Battery\(reset)")")
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
        print("   • Cores:            \(report.cpu.physicalCores) Physical / \(report.cpu.logicalCores) Virtual")
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
