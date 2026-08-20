import Foundation

public struct DiskAuditor {
    let shell: CommandRunning

    public init(shell: CommandRunning = SystemShell()) {
        self.shell = shell
    }

    public func audit() -> DiskMetrics {
        let dfOut = shell.run("df -g /").output
        var totalGB = 0.0
        var freeGB = 0.0

        let lines = dfOut.components(separatedBy: "\n")
        if lines.count >= 2 {
            let cols = lines[1].components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if cols.count >= 4 {
                totalGB = Double(cols[1]) ?? 0.0
                freeGB = Double(cols[3]) ?? 0.0
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
}
