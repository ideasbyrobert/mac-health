import Foundation

public enum SentinelAction: Equatable {
    case reportSpike(latencyMs: Double, streak: Int)
    case reportRecovery(latencyMs: Double)
    case reportThermal(reason: String)
    case paceAll
}

/// Pure decision core of the sentinel loop: metrics in, actions out.
/// Keeping it side-effect free is what makes the failure workflows testable —
/// the daemon merely samples the system and executes whatever this returns.
public struct SentinelPolicy {
    public static let latencySpikeThresholdMs = 250.0

    public static func decide(
        latencyMs: Double,
        responsive: Bool,
        cpuSpeedLimit: Int,
        thermalPressure: Bool,
        previousStreak: Int
    ) -> (actions: [SentinelAction], streak: Int) {
        var actions: [SentinelAction] = []
        var streak = previousStreak
        var shouldPace = false

        if !responsive || latencyMs > latencySpikeThresholdMs {
            streak += 1
            actions.append(.reportSpike(latencyMs: latencyMs, streak: streak))
            shouldPace = true
        } else {
            if streak > 0 {
                actions.append(.reportRecovery(latencyMs: latencyMs))
            }
            streak = 0
        }

        if cpuSpeedLimit < 100 || thermalPressure {
            let reason = cpuSpeedLimit < 100
                ? "CPU Speed Limit \(cpuSpeedLimit)%"
                : "Thermal Pressure Serious/Critical"
            actions.append(.reportThermal(reason: reason))
            shouldPace = true
        }

        if shouldPace {
            actions.append(.paceAll)
        }
        return (actions, streak)
    }
}
