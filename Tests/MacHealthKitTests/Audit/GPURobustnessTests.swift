import Testing
import Foundation
@testable import MacHealthKit

/// Regression cover for the failure modes where a wrong answer is worse than no
/// answer: a silent all-clear, a mux mode read from the wrong power block, and
/// an incident age taken from a timestamp macOS rewrites.
struct GPURobustnessTests {

    func audit(_ shell: FakeShell, reader: FakeFileReader = FakeFileReader()) -> GPUMetrics {
        GPUAuditor(shell: shell, reader: reader, now: { Fix.now }).audit()
    }

    // MARK: An unreadable reports directory is not a clean bill of health

    /// /Library/Logs/DiagnosticReports is mode 0770 root:_analyticsusers. An
    /// admin account is in that group; a standard account is not.
    func unreadableShell(gpuswitch: Int = 2) -> FakeShell {
        intelShell(gpuswitch: gpuswitch, incidents: GPUAuditor.unreadableMarker)
    }

    @Test func anUnreadableReportsDirectoryIsReportedAsUnknown() {
        let metrics = audit(unreadableShell())

        #expect(!metrics.incidentScanAvailable)
        #expect(metrics.status == "INCIDENT_SCAN_UNAVAILABLE")
        #expect(metrics.historicalIncidents24h == 0)
        #expect(metrics.faultingGPU == nil)
    }

    @Test func anUnreadableScanNeverReportsOptimalHealth() {
        let report = HealthAuditor(
            shell: unreadableShell(),
            reader: FakeFileReader(),
            windowServerAuditor: nil,
            now: { Fix.now }
        ).audit()

        #expect(report.overallHealth != "OPTIMAL")
        #expect(report.severity.exitCode != 0)
        #expect(report.xcodeReadiness.recommendations.contains { $0.contains("Cannot read") })
        #expect(!report.xcodeReadiness.gpuStable)
    }

    /// Absence of evidence is not evidence of a fault either: an unreadable scan
    /// must not start accusing the discrete GPU.
    @Test func anUnreadableScanDoesNotAccuseAnyGPU() {
        for mode in [0, 1, 2] {
            #expect(audit(unreadableShell(gpuswitch: mode)).gpuSwitchSafe)
        }
    }

    // MARK: gpuswitch is per power source

    /// `pmset -g custom` prints a Battery block and an AC block, each with its
    /// own gpuswitch. `pmset -b`/`-c` can leave them disagreeing.
    static let divergentCustom = """
    Battery Power:
     lidwake              1
     gpuswitch            0
     displaysleep         10
     sleep                15
    AC Power:
     lidwake              1
     gpuswitch            2
     displaysleep         20
     sleep                0
    """

    @Test func theMuxValueFollowsTheActivePowerSource() {
        #expect(GPUAuditor.gpuSwitchValue(from: Self.divergentCustom, onACPower: true) == 2)
        #expect(GPUAuditor.gpuSwitchValue(from: Self.divergentCustom, onACPower: false) == 0)
    }

    @Test func aMissingBlockFallsBackToTheOneThatExists() {
        let acOnly = "AC Power:\n gpuswitch            1\n sleep                0"
        #expect(GPUAuditor.gpuSwitchValue(from: acOnly, onACPower: false) == 1)
        #expect(GPUAuditor.gpuSwitchValue(from: acOnly, onACPower: true) == 1)
    }

    @Test func anAuditOnACPowerReadsTheACMuxValue() {
        let shell = intelShell(custom: Self.divergentCustom, batt: Fix.battAC100)
        // Dynamic switching on AC, with nothing faulting, stays green.
        #expect(audit(shell).gpuSwitchMode == "Dynamic Switching")
    }

    @Test func anAuditOnBatteryReadsTheBatteryMuxValue() {
        let shell = intelShell(custom: Self.divergentCustom, batt: Fix.battOnBattery87)
        #expect(audit(shell).gpuSwitchMode.hasPrefix("Integrated Only"))
    }

    // MARK: Incident age comes from the filename, not the rewritten mtime

    /// macOS refiles reports in bulk: on the development machine twenty reports
    /// timestamped 05:54-06:08 all carry an mtime of 18:36.
    @Test func aPlausibleFilenameTimestampBeatsTheMtime() {
        let calendar = Calendar.current
        let realIncident = calendar.date(byAdding: .hour, value: -9, to: Fix.now)!
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "Kernel_\(df.string(from: realIncident))_mac.gpuRestart"

        // mtime claims one hour ago; the filename says nine.
        let age = GPUAuditor.ageHours(
            fileName: name,
            mtime: Fix.now.timeIntervalSince1970 - 3600.0,
            now: Fix.now,
            nowSeconds: Fix.now.timeIntervalSince1970
        )
        #expect(abs(age - 9.0) < 0.05)
    }

    @Test func anImplausibleFilenameTimestampFallsBackToMtime() {
        // A filename dated in the future must not produce a negative age.
        let age = GPUAuditor.ageHours(
            fileName: "Kernel_2999-01-01-120000_mac.gpuRestart",
            mtime: Fix.now.timeIntervalSince1970 - 7200.0,
            now: Fix.now,
            nowSeconds: Fix.now.timeIntervalSince1970
        )
        #expect(abs(age - 2.0) < 0.05)
    }

    @Test func anUnparseableFilenameFallsBackToMtime() {
        let age = GPUAuditor.ageHours(
            fileName: ".contents.panic",
            mtime: Fix.now.timeIntervalSince1970 - 5400.0,
            now: Fix.now,
            nowSeconds: Fix.now.timeIntervalSince1970
        )
        #expect(abs(age - 1.5) < 0.05)
    }

    @Test func filenameTimestampsAreParsedOutOfRealReportNames() {
        let parsed = GPUIncidentParser.timestamp(fromFileName: "Kernel_2026-08-19-223130_users-MacBook-Pro.gpuRestart")
        #expect(parsed != nil)
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: parsed!)
        #expect(comps.year == 2026 && comps.month == 8 && comps.day == 19)
        #expect(comps.hour == 22 && comps.minute == 31 && comps.second == 30)
        #expect(GPUIncidentParser.timestamp(fromFileName: "no-timestamp-here.spin") == nil)
    }
}
