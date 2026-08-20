import Foundation

public struct PowerAuditor {
    let shell: CommandRunning

    public init(shell: CommandRunning = SystemShell()) {
        self.shell = shell
    }

    public func audit() -> PowerMetrics {
        let battOut = shell.run("pmset -g batt").output
        let isAC = battOut.contains("AC Power")
        var batteryPercent = 100
        if let pctRange = battOut.range(of: "%") {
            let prefix = battOut[..<pctRange.lowerBound]
            let digits = String(prefix.reversed().prefix(while: { $0.isNumber }).reversed())
            batteryPercent = Int(digits) ?? 100
        }

        let customOut = shell.run("pmset -g custom").output
        var battSleep = 0
        var battDisplaySleep = 0
        var acSleep = 0
        var acDisplaySleep = 0
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

        let assertOut = shell.run("pmset -g assertions").output
        let isAsserted = assertOut.contains("PreventUserIdleSystemSleep") || assertOut.contains("PreventSystemSleep")
        var holder: String? = nil
        if assertOut.contains("caffeinate") {
            holder = "caffeinate"
        } else if assertOut.contains("WindowServer") {
            holder = "WindowServer"
        }

        let conditionOut = shell.run("system_profiler SPPowerDataType 2>/dev/null | grep 'Condition:'").output
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
}
