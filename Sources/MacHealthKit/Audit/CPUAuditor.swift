import Foundation

public struct CPUAuditor {
    let shell: CommandRunning

    public init(shell: CommandRunning = SystemShell()) {
        self.shell = shell
    }

    /// Parses `pmset -g therm` output. pmset separates keys and values with
    /// mixed whitespace ("CPU_Speed_Limit \t= 100"), so values must be parsed
    /// by splitting on '=' — never by exact substring match. Machines that do
    /// not report a key (some Apple Silicon states) default to unthrottled.
    public static func speedLimit(from thermOutput: String) -> (speed: Int, scheduler: Int, warning: Bool) {
        var speedLimit = 100
        var schedLimit = 100
        var thermalWarning = false

        for line in thermOutput.components(separatedBy: "\n") {
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
        return (speedLimit, schedLimit, thermalWarning)
    }

    public func audit() -> CPUMetrics {
        let model = shell.run("sysctl -n machdep.cpu.brand_string").output
        let physCores = Int(shell.run("sysctl -n hw.physicalcpu").output) ?? 0
        let logCores = Int(shell.run("sysctl -n hw.logicalcpu").output) ?? 0

        let thermOut = shell.run("pmset -g therm").output
        let (speedLimit, schedLimit, thermalWarning) = Self.speedLimit(from: thermOut)

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
}
