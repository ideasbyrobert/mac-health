import Foundation
@testable import MacHealthKit

enum Fix {
    /// Frozen clock for deterministic incident-age math.
    static let now = Date(timeIntervalSince1970: 1_000_000_000)

    // MARK: pmset -g therm (note the real-world mixed "space-tab-equals" separators)

    static let thermNominal = """
    Note: No thermal warning level has been recorded
    Note: No performance warning level has been recorded
    2026-08-20 05:08:37 -0700 CPU Power notify
    \tCPU_Scheduler_Limit \t= 100
    \tCPU_Available_CPUs \t= 12
    \tCPU_Speed_Limit \t= 100
    """

    static let thermThrottled = """
    2026-08-20 05:08:37 -0700 CPU Power notify
    \tCPU_Scheduler_Limit \t= 80
    \tCPU_Available_CPUs \t= 12
    \tCPU_Speed_Limit \t= 62
    """

    /// Some Apple Silicon states report no limit keys at all.
    static let thermNoKeys = "Note: No thermal warning level has been recorded"

    // MARK: pmset -g custom

    static func custom(
        gpuswitch: Int?,
        battDisplay: Int = 10, battSleep: Int = 15,
        acDisplay: Int = 20, acSleep: Int = 0
    ) -> String {
        let gpuLine = gpuswitch.map { " gpuswitch            \($0)\n" } ?? ""
        return """
        Battery Power:
         lidwake              1
        \(gpuLine) displaysleep         \(battDisplay)
         disksleep            10
         sleep                \(battSleep)
         hibernatefile        /var/vm/sleepimage
        AC Power:
         lidwake              1
        \(gpuLine) displaysleep         \(acDisplay)
         disksleep            10
         sleep                \(acSleep)
         hibernatefile        /var/vm/sleepimage
        """
    }

    // MARK: vm_stat / swap

    static let vmStat = """
    Mach Virtual Memory Statistics: (page size of 4096 bytes)
    Pages free:                              112233.
    Pages active:                           1000000.
    Pages throttled:                              0.
    """

    static let vmStatThrashing = """
    Mach Virtual Memory Statistics: (page size of 4096 bytes)
    Pages free:                                1201.
    Pages active:                           1900000.
    Pages throttled:                           4321.
    """

    static let swapUsage = "vm.swapusage: total = 2048.00M  used = 512.25M  free = 1535.75M  (encrypted)"

    // MARK: df

    static let dfAmple = """
    Filesystem 1G-blocks Used Available Capacity iused ifree %iused Mounted on
    /dev/disk1s1 466 90 369 20% 500000 4000000 11% /
    """

    static let dfLow = """
    Filesystem 1G-blocks Used Available Capacity iused ifree %iused Mounted on
    /dev/disk1s1 466 450 12 98% 500000 4000000 11% /
    """

    // MARK: kmutil (already grep-filtered by the auditor's pipeline)

    static let kmutilClean = ""
    static let kmutilDirty = "  142    0  0xffffff7fa8826000  0x1000     0x1000     com.rugarciap.DisableTurboBoost (0.0.1) 8E3AC-UUID <5 3 1>"

    // MARK: pmset -g batt / battery condition

    static let battAC100 = """
    Now drawing from 'AC Power'
     -InternalBattery-0 (id=12345)\t100%; charged; 0:00 remaining present: true
    """

    static let battOnBattery87 = """
    Now drawing from 'Battery Power'
     -InternalBattery-0 (id=12345)\t87%; discharging; 4:20 remaining present: true
    """

    static let conditionNormal = "Condition: Normal"
    static let conditionService = "Condition: Service Recommended"

    // MARK: DiagnosticReports incident listings ("mtime path", newest first)

    static func incidents(_ entries: [(ageHours: Double, name: String)]) -> String {
        entries
            .map { entry -> String in
                let mtime = now.timeIntervalSince1970 - entry.ageHours * 3600.0
                return "\(String(format: "%.0f", mtime)) /Library/Logs/DiagnosticReports/\(entry.name)"
            }
            .joined(separator: "\n")
    }

    // MARK: GPU complement (system_profiler SPDisplaysDataType)

    /// The exact chipset spellings the development machine reports, reused by
    /// every attribution fixture so canonicalisation is tested against one
    /// consistent inventory.
    static let intelIGPU = "Intel UHD Graphics 630"
    static let amdDGPU = "AMD Radeon Pro 5300M"
    static let appleGPU = "Apple M3 Pro"

    /// One indented block per GPU, matching the layout system_profiler emits.
    static func displays(_ gpus: [(name: String, bus: String, vendor: String)]) -> String {
        var lines = ["Graphics/Displays:", ""]
        for gpu in gpus {
            lines.append("    \(gpu.name):")
            lines.append("")
            lines.append("      Chipset Model: \(gpu.name)")
            lines.append("      Type: GPU")
            lines.append("      Bus: \(gpu.bus)")
            lines.append("      VRAM (Total): 4 GB")
            lines.append("      Vendor: \(gpu.vendor)")
            lines.append("      Metal Support: Metal 3")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static let displaysIntelAMD = displays([
        (name: intelIGPU, bus: "Built-In", vendor: "Intel"),
        (name: amdDGPU, bus: "PCIe", vendor: "AMD (0x1002)")
    ])

    static let displaysIntegratedOnly = displays([
        (name: intelIGPU, bus: "Built-In", vendor: "Intel")
    ])

    static let displaysAppleSilicon = displays([
        (name: appleGPU, bus: "Built-In", vendor: "Apple (0x106b)")
    ])

    // MARK: Diagnostic report bodies

    /// A .gpuRestart report header as the 2019 16" MacBook Pro writes it.
    /// Passing nil for a field omits its line entirely, which is how a report
    /// that names no hardware is built.
    static func gpuRestartReport(
        graphicsHardware: String? = Fix.amdDGPU,
        restartChannel: String? = "18 VMPT",
        driverState: String? = "AMDRadeonX6000_AMDNavi14GraphicsAccelerator"
    ) -> String {
        var lines = [
            "Wed Aug 19 22:31:30 2026",
            "",
            "Event:               GPU Reset",
            "Date/Time:           Wed Aug 19 22:31:30 2026",
            "Application:",
            "Path:",
            "Tailspin:            /Library/Logs/DiagnosticReports/gpuRestart2026-08-19-223130.tailspin",
            "GPUSubmission Trace ID: 0",
            "OS Version:          Mac OS X Version 26.6.2 (Build 25G83)"
        ]
        if let graphicsHardware {
            lines.append("Graphics Hardware:   \(graphicsHardware)")
        }
        lines.append(contentsOf: [
            "Signature:           2",
            "",
            "Report Data:",
            "",
            "GPU Log Version: 2",
            ""
        ])
        if let restartChannel {
            lines.append("Restart Channel: \(restartChannel)")
            lines.append("")
        }
        lines.append("---THE STATE OF THE DRIVER---")
        lines.append("")
        if let driverState {
            lines.append("\(driverState) state: ENABLED")
            lines.append(" PCIe Device: [3:0:0], DID=0x7340, RID=0x43, SSID=0x210")
        }
        return lines.joined(separator: "\n")
    }

    /// A .panic report: one line of JSON whose panic_string carries the
    /// userspace watchdog timeout and a driver frame in the backtrace.
    static func panicReport(driverFrame: String = "AMDRadeonX6000_AMDNavi14GraphicsAccelerator") -> String {
        let panicString = "panic(cpu 4 caller 0xffffff801a2b3c4d): userspace watchdog timeout: "
            + "no successful checkins from WindowServer (2 induced crashes) in 120 seconds\\n"
            + "Backtrace:\\n0xffffff7fa9c11000 : \(driverFrame)::submitCommandBuffer(IOAccelCommandQueue*) + 268\\n"
            + "0xffffff7fa9c12440 : IOAccelContext2::clientMemoryForType(unsigned int) + 92\\n"
        return "{\"bug_type\":\"210\",\"timestamp\":\"2026-08-19 23:12:24.00 -0700\","
            + "\"os_version\":\"macOS 26.6.2 (25G83)\","
            + "\"files_to_attach\":[\"/private/var/db/spindump/WindowServer.spindump\"],"
            + "\"panic_string\":\"\(panicString)\"}"
    }

    static let windowServerWatchdogPanic = panicReport()

    /// A .spin report that names no graphics hardware and carries no driver
    /// bundle — the case where the tool must refuse to blame a GPU.
    static let spinWithoutHardware = """
    Date/Time:       2026-08-19 23:18:11.000 -0700
    End time:        2026-08-19 23:18:16.000 -0700
    OS Version:      macOS 26.6.2 (Build 25G83)
    Architecture:    x86_64
    Report Version:  35

    Command:         WindowServer
    Path:            /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
    Version:         ???
    PID:             210

    Duration:        5.00s

    Heaviest stack for the main thread of the target process:
      16  start_wqthread + 15 (libsystem_pthread.dylib)
      16  _pthread_wqthread + 327 (libsystem_pthread.dylib)
      16  mach_msg2_trap + 10 (libsystem_kernel.dylib)
    """
}

// MARK: Whole-machine shell builders

/// A healthy dual-GPU Intel MacBook Pro on AC power.
func intelShell(
    gpuswitch: Int? = 0,
    incidents: String = "",
    therm: String = Fix.thermNominal,
    custom: String? = nil,
    batt: String = Fix.battAC100,
    condition: String = Fix.conditionNormal,
    df: String = Fix.dfAmple,
    kmutil: String = Fix.kmutilClean,
    vmStat: String = Fix.vmStat,
    displays: String = Fix.displaysIntelAMD
) -> FakeShell {
    let shell = FakeShell()
    shell.stub("SPDisplaysDataType", displays)
    shell.stub("machdep.cpu.brand_string", "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz")
    shell.stub("hw.physicalcpu", "6")
    shell.stub("hw.logicalcpu", "12")
    shell.stub("hw.memsize", "17179869184")
    shell.stub("vm.swapusage", Fix.swapUsage)
    shell.stub("vm_stat", vmStat)
    shell.stub("pmset -g therm", therm)
    shell.stub("pmset -g custom", custom ?? Fix.custom(gpuswitch: gpuswitch))
    shell.stub("pmset -g batt", batt)
    shell.stub("pmset -g assertions", "pid 210(WindowServer): PreventUserIdleDisplaySleep named: com.apple.WindowServer.display")
    shell.stub("SPPowerDataType", condition)
    shell.stub("df -g /", df)
    shell.stub("kmutil showloaded", kmutil)
    shell.stub("find /Library/Logs/DiagnosticReports", incidents)
    shell.stub("pgrep -x WindowServer", "210")
    shell.stub("-o %cpu", "12.5")
    return shell
}

/// A healthy Apple Silicon Mac (no GPU mux, no gpuswitch key at all).
func siliconShell(
    incidents: String = "",
    therm: String = Fix.thermNoKeys,
    batt: String = Fix.battAC100,
    vmStat: String = Fix.vmStat,
    displays: String = Fix.displaysAppleSilicon
) -> FakeShell {
    let shell = intelShell(
        gpuswitch: nil,
        incidents: incidents,
        therm: therm,
        batt: batt,
        vmStat: vmStat,
        displays: displays
    )
    return shell
}
