import Foundation
import CoreGraphics

public struct WindowServerAuditor {
    let shell: CommandRunning
    /// Round-trip probe latency in milliseconds; nil means the probe timed out.
    let probe: () -> Double?

    public static let probeTimeoutMs = 1500.0

    public init(shell: CommandRunning = SystemShell(), probe: @escaping () -> Double? = WindowServerAuditor.liveProbe) {
        self.shell = shell
        self.probe = probe
    }

    /// Probes WindowServer Mach IPC round-trip latency via CoreGraphics with a
    /// strict timeout so a stalled compositor cannot hang the auditor.
    public static func liveProbe() -> Double? {
        var latency: Double? = nil
        let group = DispatchGroup()
        group.enter()

        let startTime = CFAbsoluteTimeGetCurrent()
        DispatchQueue.global(qos: .userInteractive).async {
            let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)
            _ = (list as? [Any])?.count ?? 0
            latency = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            group.leave()
        }

        let result = group.wait(timeout: .now() + .milliseconds(Int(probeTimeoutMs)))
        if result == .timedOut {
            return nil
        }
        return latency
    }

    public func audit() -> WindowServerMetrics {
        let probed = probe()
        let responsive = probed != nil
        let latency = probed ?? Self.probeTimeoutMs

        // WindowServer CPU usage
        let wsPidOut = shell.run("pgrep -x WindowServer 2>/dev/null").output
        var wsCpu = 0.0
        if let wsPid = Int(wsPidOut.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? "") {
            let cpuOut = shell.run("ps -p \(wsPid) -o %cpu= 2>/dev/null").output
            wsCpu = Double(cpuOut.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0.0
        }

        // Sleep assertion check
        let assertOut = shell.run("pmset -g assertions 2>/dev/null").output
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
}
