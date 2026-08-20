import Foundation

public struct MemoryAuditor {
    let shell: CommandRunning

    public init(shell: CommandRunning = SystemShell()) {
        self.shell = shell
    }

    public func audit() -> MemoryMetrics {
        let memBytes = Double(Int(shell.run("sysctl -n hw.memsize").output) ?? 0)
        let totalGB = memBytes / (1024 * 1024 * 1024)

        let swapOut = shell.run("sysctl -n vm.swapusage 2>/dev/null").output
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

        let vmStatOut = shell.run("vm_stat").output
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
}
