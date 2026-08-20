import Foundation
import Darwin

/// One reading of a process's cumulative kernel counters.
///
/// `proc_pid_rusage` is the honest source here: it reports cycles and retired
/// instructions, not a vendor "energy score", so every derived number below can
/// be traced to something the hardware counted.
public struct EnergySample: Sendable, Equatable {
    public let pid: Int32
    public let at: Date
    public let cycles: UInt64
    public let instructions: UInt64
    public let userTimeNs: UInt64
    public let systemTimeNs: UInt64
    /// Wakeups caused by an interrupt arriving.
    public let interruptWakeups: UInt64
    /// Wakeups that pulled the CPU package out of an idle state. These are the
    /// expensive ones: they deny the hardware the deep C-states where it spends
    /// almost nothing.
    public let packageIdleWakeups: UInt64

    public init(
        pid: Int32, at: Date, cycles: UInt64, instructions: UInt64,
        userTimeNs: UInt64, systemTimeNs: UInt64,
        interruptWakeups: UInt64, packageIdleWakeups: UInt64
    ) {
        self.pid = pid
        self.at = at
        self.cycles = cycles
        self.instructions = instructions
        self.userTimeNs = userTimeNs
        self.systemTimeNs = systemTimeNs
        self.interruptWakeups = interruptWakeups
        self.packageIdleWakeups = packageIdleWakeups
    }
}

public protocol ProcessSampling: Sendable {
    func sample(pid: Int32, now: Date) -> EnergySample?
}

/// Reads the live kernel counters. Returns nil when the process is gone or the
/// caller is not permitted to look — never a zeroed sample, because "no data"
/// and "no work" must stay distinguishable.
public struct KernelProcessSampler: ProcessSampling {
    public init() {}

    public func sample(pid: Int32, now: Date = Date()) -> EnergySample? {
        var info = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V6, rebound)
            }
        }
        guard rc == 0 else { return nil }
        return EnergySample(
            pid: pid,
            at: now,
            cycles: info.ri_cycles,
            instructions: info.ri_instructions,
            userTimeNs: info.ri_user_time,
            systemTimeNs: info.ri_system_time,
            interruptWakeups: info.ri_interrupt_wkups,
            packageIdleWakeups: info.ri_pkg_idle_wkups
        )
    }
}

/// The difference between two samples, expressed per second. Rates rather than
/// totals, because a process that has run for a week is not thereby a problem.
public struct EnergySignature: Sendable, Equatable {
    public let pid: Int32
    public let window: TimeInterval
    public let cyclesPerSecond: Double
    public let instructionsPerCycle: Double
    public let cpuPercent: Double
    public let interruptWakeupsPerSecond: Double
    public let packageIdleWakeupsPerSecond: Double
    /// Units of application-visible work completed per second, when the worker
    /// reports a heartbeat. nil when the lab cannot see progress — which is
    /// precisely when a deadlock becomes indistinguishable from healthy idle.
    public let progressPerSecond: Double?

    public init(
        pid: Int32, window: TimeInterval, cyclesPerSecond: Double,
        instructionsPerCycle: Double, cpuPercent: Double,
        interruptWakeupsPerSecond: Double, packageIdleWakeupsPerSecond: Double,
        progressPerSecond: Double?
    ) {
        self.pid = pid
        self.window = window
        self.cyclesPerSecond = cyclesPerSecond
        self.instructionsPerCycle = instructionsPerCycle
        self.cpuPercent = cpuPercent
        self.interruptWakeupsPerSecond = interruptWakeupsPerSecond
        self.packageIdleWakeupsPerSecond = packageIdleWakeupsPerSecond
        self.progressPerSecond = progressPerSecond
    }

    /// Counters are cumulative and monotonic; a negative delta means the pid was
    /// reused or the sample order was wrong, so the caller gets nil rather than
    /// a wrapped-around number presented as a measurement.
    public static func between(
        _ first: EnergySample, _ second: EnergySample,
        progressDelta: Double? = nil
    ) -> EnergySignature? {
        guard first.pid == second.pid else { return nil }
        let window = second.at.timeIntervalSince(first.at)
        guard window > 0 else { return nil }
        guard second.cycles >= first.cycles,
              second.instructions >= first.instructions,
              second.userTimeNs >= first.userTimeNs,
              second.systemTimeNs >= first.systemTimeNs,
              second.interruptWakeups >= first.interruptWakeups,
              second.packageIdleWakeups >= first.packageIdleWakeups
        else { return nil }

        let dCycles = Double(second.cycles - first.cycles)
        let dInstructions = Double(second.instructions - first.instructions)
        let dCPUNs = Double((second.userTimeNs + second.systemTimeNs)
            - (first.userTimeNs + first.systemTimeNs))

        return EnergySignature(
            pid: first.pid,
            window: window,
            cyclesPerSecond: dCycles / window,
            instructionsPerCycle: dCycles > 0 ? dInstructions / dCycles : 0,
            cpuPercent: (dCPUNs / 1e9) / window * 100.0,
            interruptWakeupsPerSecond: Double(second.interruptWakeups - first.interruptWakeups) / window,
            packageIdleWakeupsPerSecond: Double(second.packageIdleWakeups - first.packageIdleWakeups) / window,
            progressPerSecond: progressDelta.map { $0 / window }
        )
    }
}
