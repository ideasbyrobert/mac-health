import Foundation

public struct ConsoleFormat {

    /// Overridable so tests can render against a chosen terminal instead of
    /// whatever the machine running them happens to have.
    public nonisolated(unsafe) static var capabilities: TerminalCapabilities = .current

    // Every style resolves through `capabilities`, so a redirected stream gets
    // the same text without a single escape byte in it.
    private static func code(_ sequence: String) -> String {
        capabilities.usesColor ? sequence : ""
    }

    public static var green: String { code("\u{001B}[32m") }
    public static var yellow: String { code("\u{001B}[33m") }
    public static var red: String { code("\u{001B}[31m") }
    public static var blue: String { code("\u{001B}[34m") }
    public static var cyan: String { code("\u{001B}[36m") }
    public static var dim: String { code("\u{001B}[2m") }
    public static var bold: String { code("\u{001B}[1m") }
    public static var reset: String { code("\u{001B}[0m") }

    /// A horizontal rule the width of the terminal rather than a fixed sixty
    /// columns, which wrapped on a narrow pane and stranded a short line on a
    /// wide one.
    public static func rule() -> String {
        let glyph = capabilities.usesUnicode ? "\u{2500}" : "-"
        return cyan + String(repeating: glyph, count: capabilities.width) + reset
    }

    /// Status glyphs degrade to ASCII where UTF-8 is not promised.
    public static var tick: String { capabilities.usesUnicode ? "\u{2713}" : "OK" }
    public static var warn: String { capabilities.usesUnicode ? "\u{25B2}" : "!" }
    public static var fail: String { capabilities.usesUnicode ? "\u{25A0}" : "X" }
    public static var bullet: String { capabilities.usesUnicode ? "\u{2022}" : "-" }
    public static var arrow: String { capabilities.usesUnicode ? "\u{21B3}" : ">" }

    public static func timeString(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df.string(from: date)
    }

    /// Width of the label column every bullet aligns its value against.
    private static let labelWidth = 18

    private static func row(_ label: String, _ value: String) -> String {
        let padding = max(labelWidth - label.count, 1)
        return "   \(bullet) \(label)\(String(repeating: " ", count: padding))\(value)"
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

        // Printing "\(tick) 0 Crashes" when nothing was scanned would be the most
        // dangerous line this tool could emit, so the unknown state replaces it
        // rather than sitting beside it.
        if !gpu.incidentScanAvailable {
            lines.append(row("Incident Scan:", "\(yellow)\(warn) Unavailable — cannot read \(GPUAuditor.reportsDirectory)\(reset)"))
            lines.append(row("Active State:", "\(yellow)Unknown (not scanned — this is not an all-clear)\(reset)"))
            return lines
        }

        if gpu.activeIncidentsLastHour == 0 {
            let hoursStr = String(format: "%.1f", gpu.hoursSinceLastCrash)
            lines.append(row("Active State:", "\(green)\(tick) 0 Crashes in last \(hoursStr)h\(reset)"))
            if gpu.historicalIncidents24h > 0, let time = gpu.latestIncidentTime, let name = gpu.latestIncidentName {
                lines.append(row("24h History:", "\(yellow)\(gpu.historicalIncidents24h) prior incidents recorded (last: \(name) at \(time))\(reset)"))
            }
        } else {
            lines.append(row("Active State:", "\(red)\(warn) \(gpu.activeIncidentsLastHour) crashes in past hour!\(reset)"))
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
        print(rule())

        switch report.overallHealth {
        case "OPTIMAL":
            print("  System Status:  \(green)\(bold)● OPTIMAL (All Guardrails Active & Stable)\(reset)")
        case "DEGRADED_OR_WARNING":
            print("  System Status:  \(yellow)\(bold)\(warn) ATTENTION / DEGRADED (Check Warnings Below)\(reset)")
        default:
            print("  System Status:  \(red)\(bold)\(fail) CRITICAL ATTENTION REQUIRED\(reset)")
        }
        print("  Audit Time:     \(report.timestamp)")
        print(rule() + "\n")

        // 1. WindowServer & Watchdog Health
        print("\(bold)1. WindowServer Compositor & Watchdog Probe\(reset)")
        let wsColor = report.windowServer.isResponsive ? (report.windowServer.latencyMs < 200 ? green : yellow) : red
        print("   \(bullet) IPC Latency:      \(wsColor)\(String(format: "%.1f", report.windowServer.latencyMs)) ms\(reset) \(report.windowServer.isResponsive ? "\(tick) Responsive" : "\(warn) Stall Detected")")
        print("   \(bullet) CPU Utilization:  \(String(format: "%.1f", report.windowServer.cpuPercent))%")
        print("   \(bullet) Sleep Assertion:  \(report.windowServer.sleepAssertionHolder ? "Active" : "None")")

        // 2. GPU Power & Mux Stability
        print("\n\(bold)2. GPU Stability & Hardware Mux State\(reset)")
        for line in gpuSection(for: report.gpu) {
            print(line)
        }

        // 3. Power & Battery Health
        print("\n\(bold)3. Power, Battery & Sleep Timings\(reset)")
        print("   \(bullet) Source:           \(report.power.powerSource == "AC Charger" ? "\(green)🔌 AC Power\(reset)" : "\(yellow)🔋 Battery\(reset)")")
        let battCondColor = report.power.isBatteryDegraded ? red : green
        print("   \(bullet) Battery Level:    \(report.power.batteryPercentage)% (\(battCondColor)\(report.power.batteryCondition)\(reset))")
        let sleepTimingColor = report.power.sleepTimingsCoherent ? green : red
        let isAC = report.power.powerSource == "AC Charger"
        let dispSleep = isAC ? report.power.acDisplaySleepMinutes : report.power.batteryDisplaySleepMinutes
        let sysSleep = isAC ? report.power.acSleepMinutes : report.power.batterySleepMinutes
        print("   \(bullet) Sleep Timers:     \(sleepTimingColor)Display: \(dispSleep)m / Sleep: \(sysSleep)m \(report.power.sleepTimingsCoherent ? "\(tick) Coherent" : "\(warn) Inverted Order")\(reset)")

        // 4. Kernel Extensions & Cleanliness
        print("\n\(bold)4. Kernel Integrity & Third-Party Extensions\(reset)")
        if report.kernelExtensions.isCleanNative {
            print("   \(bullet) Native State:     \(green)\(tick) 100% Clean (0 Unsafe Third-Party Kexts)\(reset)")
        } else {
            print("   \(bullet) Non-Apple Kexts:  \(red)\(warn) \(report.kernelExtensions.nonAppleKextsCount) detected: \(report.kernelExtensions.nonAppleKextNames.joined(separator: ", "))\(reset)")
        }

        // 5. CPU & Thermal State
        print("\n\(bold)5. CPU & Thermal Headroom\(reset)")
        print("   \(bullet) Model:            \(report.cpu.model)")
        print("   \(bullet) Cores:            \(report.cpu.physicalCores) Physical / \(report.cpu.logicalCores) Virtual")
        let speedColor = report.cpu.speedLimitPercent == 100 ? green : red
        print("   \(bullet) CPU Speed Limit:  \(speedColor)\(report.cpu.speedLimitPercent)%\(reset) \(report.cpu.speedLimitPercent == 100 ? "\(tick) Full Speed" : "\(warn) Throttled")")
        print("   \(bullet) Thermal State:    \(report.cpu.thermalWarning ? "\(red)\(warn) Warning Recorded\(reset)" : "\(green)\(tick) Safe Operating Zone\(reset)")")

        // 6. Memory & Virtual Memory Pressure
        print("\n\(bold)6. Memory & Virtual Memory Pressure\(reset)")
        print("   \(bullet) Physical Memory:  \(Int(report.memory.totalPhysicalGB)) GB")
        print("   \(bullet) Free RAM:         \(String(format: "%.2f", report.memory.freeGB)) GB")
        print("   \(bullet) Swap Used:        \(Int(report.memory.swapUsedMB)) MB")
        print("   \(bullet) Pages Throttled:  \(report.memory.pagesThrottled == 0 ? "\(green)0 Pages (Zero Thrashing)\(reset)" : "\(red)\(report.memory.pagesThrottled) Pages\(reset)")")

        // 7. Disk & Xcode Readiness
        print("\n\(bold)7. Xcode & Compilation Readiness\(reset)")
        print("   \(bullet) Free Disk Space:  \(green)\(Int(report.disk.freeGB)) GB free\(reset) (\(Int(report.disk.percentFree))% available)")
        if report.xcodeReadiness.isReady {
            print("   \(bullet) Readiness Status: \(green)\(bold)\(tick) READY FOR HEAVY WORKLOADS & COMPILATION\(reset)")
        } else {
            print("   \(bullet) Readiness Status: \(yellow)\(bold)\(warn) CAUTION BEFORE HEAVY BUILDS\(reset)")
            for rec in report.xcodeReadiness.recommendations {
                print("     \(arrow) \(yellow)\(rec)\(reset)")
            }
        }
        print(rule() + "\n")
    }
}
