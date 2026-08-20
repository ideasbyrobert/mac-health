import Testing
import Foundation
@testable import MacHealthKit

/// The `--json` payload and the process exit code are the tool's machine-facing
/// contract: scripts and MDM branch on them, so both are pinned here.
struct ReportContractTests {

    func audit(
        _ shell: FakeShell,
        reader: FakeFileReader = FakeFileReader(),
        probeMs: Double? = 42.0
    ) -> DiagnosticReport {
        HealthAuditor(
            shell: shell,
            reader: reader,
            windowServerAuditor: WindowServerAuditor(shell: shell, probe: { probeMs }),
            now: { Fix.now }
        ).audit()
    }

    func encode(_ report: DiagnosticReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    func decode(_ data: Data) throws -> DiagnosticReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DiagnosticReport.self, from: data)
    }

    func json(_ report: DiagnosticReport) throws -> [String: Any] {
        let data = try encode(report)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    // MARK: Envelope

    @Test func payloadCarriesTheSchemaVersionConsumersBranchOn() throws {
        let object = try json(audit(intelShell()))

        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["schemaVersion"] as? Int == macHealthSchemaVersion)
    }

    @Test func payloadCarriesTheToolVersionThatProducedIt() throws {
        let object = try json(audit(intelShell()))

        #expect(object["toolVersion"] as? String == macHealthVersion)
    }

    @Test func payloadCarriesEverySubsystemSection() throws {
        let object = try json(audit(intelShell()))

        for key in ["cpu", "memory", "gpu", "windowServer", "power", "disk", "kernelExtensions", "xcodeReadiness"] {
            #expect(object[key] != nil)
        }
    }

    // MARK: Severity and exit codes

    @Test func severityExitCodesAreZeroOneTwo() {
        #expect(HealthSeverity.optimal.exitCode == 0)
        #expect(HealthSeverity.degraded.exitCode == 1)
        #expect(HealthSeverity.critical.exitCode == 2)
    }

    @Test func anOptimalMachineExitsZero() {
        let report = audit(intelShell())

        #expect(report.overallHealth == "OPTIMAL")
        #expect(report.severity == .optimal)
        #expect(report.severity.exitCode == 0)
    }

    @Test func aDegradedMachineExitsOne() {
        let report = audit(intelShell(therm: Fix.thermThrottled))

        #expect(report.overallHealth == "DEGRADED_OR_WARNING")
        #expect(report.severity == .degraded)
        #expect(report.severity.exitCode == 1)
    }

    @Test func aCriticalMachineExitsTwo() {
        let report = audit(intelShell(), probeMs: nil)

        #expect(report.overallHealth == "CRITICAL_ATTENTION_NEEDED")
        #expect(report.severity == .critical)
        #expect(report.severity.exitCode == 2)
    }

    @Test func unknownOverallHealthFallsBackToDegraded() throws {
        var object = try json(audit(intelShell()))
        object["overallHealth"] = "SOMETHING_A_LATER_VERSION_ADDED"
        let mutated = try JSONSerialization.data(withJSONObject: object)
        let decoded = try decode(mutated)

        #expect(decoded.severity == .degraded)
        #expect(decoded.severity.exitCode == 1)
    }

    // MARK: Round trip

    @Test func attributionSurvivesAnEncodeDecodeRoundTrip() throws {
        let names = ["Kernel_2026-08-19-231224.gpuRestart", "Kernel_2026-08-19-221811.gpuRestart"]
        let reader = FakeFileReader()
        for name in names { reader.stub(fileName: name, Fix.gpuRestartReport()) }
        let listing = Fix.incidents([
            (ageHours: 2.0, name: names[0]),
            (ageHours: 5.0, name: names[1])
        ])
        let original = audit(intelShell(gpuswitch: 1, incidents: listing), reader: reader)
        let decoded = try decode(try encode(original))

        #expect(decoded.gpu.installedGPUs == original.gpu.installedGPUs)
        #expect(decoded.gpu.incidentsByGPU == [Fix.amdDGPU: 2])
        #expect(decoded.gpu.unattributedIncidents == 0)
        #expect(decoded.gpu.faultingGPU == Fix.amdDGPU)
        #expect(decoded.gpu.faultingGPUIsDiscrete)
        #expect(decoded.gpu.restartChannels == ["VMPT"])
        #expect(!decoded.gpu.gpuSwitchSafe)
    }

    @Test func theEnvelopeAndTimestampSurviveARoundTrip() throws {
        let original = audit(intelShell())
        let decoded = try decode(try encode(original))

        #expect(decoded.schemaVersion == original.schemaVersion)
        #expect(decoded.toolVersion == original.toolVersion)
        #expect(decoded.overallHealth == original.overallHealth)
        // iso8601 drops sub-second precision, which the contract never promised.
        #expect(abs(decoded.timestamp.timeIntervalSince(original.timestamp)) < 1.0)
    }

    @Test func aGPUWithNoAttributedIncidentsEncodesEmptyCollectionsRatherThanOmittingThem() throws {
        let object = try json(audit(intelShell()))
        let gpu = try #require(object["gpu"] as? [String: Any])

        #expect((gpu["incidentsByGPU"] as? [String: Any])?.isEmpty == true)
        #expect((gpu["restartChannels"] as? [Any])?.isEmpty == true)
        #expect(gpu["unattributedIncidents"] as? Int == 0)
        #expect((gpu["installedGPUs"] as? [Any])?.count == 2)
    }

    @Test func theRecommendationNamesTheFaultingPartAndItsMitigation() throws {
        let reader = FakeFileReader()
        reader.stub(fileName: "Kernel.gpuRestart", Fix.gpuRestartReport())
        let listing = Fix.incidents([(ageHours: 3.0, name: "Kernel.gpuRestart")])
        let report = audit(intelShell(gpuswitch: 2, incidents: listing), reader: reader)

        let recommendation = try #require(report.xcodeReadiness.recommendations.first { $0.contains("gpuswitch") })
        #expect(recommendation.contains(Fix.amdDGPU))
        #expect(recommendation.contains("VMPT"))
        #expect(recommendation.contains("gpuswitch 0"))
    }
}
