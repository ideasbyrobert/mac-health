import Foundation

/// The overall verdict, and the process exit code that carries it to scripts
/// and MDM: 0 healthy, 1 degraded, 2 critical.
public enum HealthSeverity: String, Codable {
    case optimal = "OPTIMAL"
    case degraded = "DEGRADED_OR_WARNING"
    case critical = "CRITICAL_ATTENTION_NEEDED"

    public var exitCode: Int32 {
        switch self {
        case .optimal: return 0
        case .degraded: return 1
        case .critical: return 2
        }
    }
}

public struct DiagnosticReport: Codable {
    /// Version of this JSON contract. Bumped only on a breaking change, so a
    /// consumer can refuse a payload it does not understand. Additive fields
    /// do not bump it.
    public let schemaVersion: Int
    public let toolVersion: String
    public let timestamp: Date
    public let overallHealth: String
    public let cpu: CPUMetrics
    public let memory: MemoryMetrics
    public let gpu: GPUMetrics
    public let windowServer: WindowServerMetrics
    public let power: PowerMetrics
    public let disk: DiskMetrics
    public let kernelExtensions: KernelExtensionsMetrics
    public let xcodeReadiness: XcodeReadiness

    public var severity: HealthSeverity {
        HealthSeverity(rawValue: overallHealth) ?? .degraded
    }
}

public struct CPUMetrics: Codable {
    public let model: String
    public let physicalCores: Int
    public let logicalCores: Int
    public let speedLimitPercent: Int
    public let schedulerLimitPercent: Int
    public let thermalWarning: Bool
    public let status: String
}

public struct MemoryMetrics: Codable {
    public let totalPhysicalGB: Double
    public let freeGB: Double
    public let swapUsedMB: Double
    public let swapFreeMB: Double
    public let pagesThrottled: Int
    public let status: String
}

public struct GPUMetrics: Codable {
    public let activeIncidentsLastHour: Int
    public let historicalIncidents24h: Int
    public let hoursSinceLastCrash: Double
    public let gpuSwitchMode: String
    public let gpuSwitchSafe: Bool
    public let status: String
    public let latestIncidentName: String?
    public let latestIncidentTime: String?
    /// Every GPU macOS reports on this machine, integrated first or not
    /// depending on probe order — the population attribution draws from.
    public let installedGPUs: [GPUDevice]
    /// Incident counts keyed by the GPU the report named. Reports that name no
    /// hardware are counted under `unattributedIncidents` instead.
    public let incidentsByGPU: [String: Int]
    public let unattributedIncidents: Int
    /// The GPU carrying the most attributed incidents, when there is one.
    public let faultingGPU: String?
    public let faultingGPUIsDiscrete: Bool
    /// Distinct hardware channels seen in gpuRestart reports (e.g. "VMPT").
    public let restartChannels: [String]
    /// False when /Library/Logs/DiagnosticReports could not be read at all, in
    /// which case every incident count above is zero because nothing was
    /// scanned — NOT because the machine is healthy.
    public let incidentScanAvailable: Bool
}

public struct WindowServerMetrics: Codable {
    public let latencyMs: Double
    public let isResponsive: Bool
    public let cpuPercent: Double
    public let sleepAssertionHolder: Bool
    public let status: String
}

public struct PowerMetrics: Codable {
    public let powerSource: String
    public let batteryPercentage: Int
    public let batteryCondition: String
    public let isBatteryDegraded: Bool
    public let sleepPrevented: Bool
    public let sleepAssertionHolder: String?
    public let batteryDisplaySleepMinutes: Int
    public let batterySleepMinutes: Int
    public let acDisplaySleepMinutes: Int
    public let acSleepMinutes: Int
    public let sleepTimingsCoherent: Bool
    public let status: String
}

public struct DiskMetrics: Codable {
    public let mountPoint: String
    public let totalGB: Double
    public let freeGB: Double
    public let percentFree: Double
    public let status: String
}

public struct KernelExtensionsMetrics: Codable {
    public let nonAppleKextsCount: Int
    public let nonAppleKextNames: [String]
    public let isCleanNative: Bool
    public let status: String
}

public struct XcodeReadiness: Codable {
    public let isReady: Bool
    public let diskSpaceAdequate: Bool
    public let thermalsUnthrottled: Bool
    public let powerConnected: Bool
    public let batteryHealthy: Bool
    public let gpuStable: Bool
    public let windowServerHealthy: Bool
    public let recommendations: [String]
}
