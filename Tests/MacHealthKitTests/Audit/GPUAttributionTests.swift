import Testing
import Foundation
@testable import MacHealthKit

/// Whole-auditor attribution: a listing of diagnostic reports plus the text of
/// those reports has to produce a verdict that names the faulting part and
/// picks the mux mode that parks it — including when the faulting part is the
/// integrated GPU, which the AMD-specific first cut of this tool got wrong.
struct GPUAttributionTests {

    let stormNames = [
        "Kernel_2026-08-19-231224.gpuRestart",
        "Kernel_2026-08-19-224410.gpuRestart",
        "Kernel_2026-08-19-221811.gpuRestart"
    ]

    var stormListing: String {
        Fix.incidents([
            (ageHours: 2.0, name: stormNames[0]),
            (ageHours: 3.0, name: stormNames[1]),
            (ageHours: 4.0, name: stormNames[2])
        ])
    }

    func audit(_ shell: FakeShell, reader: FakeFileReader) -> GPUMetrics {
        GPUAuditor(shell: shell, reader: reader, now: { Fix.now }).audit()
    }

    /// Three gpuRestart reports that all name the same GPU.
    func storm(blaming gpu: String, driverState: String?) -> FakeFileReader {
        let reader = FakeFileReader()
        for name in stormNames {
            reader.stub(fileName: name, Fix.gpuRestartReport(graphicsHardware: gpu, driverState: driverState))
        }
        return reader
    }

    func amdStorm() -> FakeFileReader {
        storm(blaming: Fix.amdDGPU, driverState: "AMDRadeonX6000_AMDNavi14GraphicsAccelerator")
    }

    func intelStorm() -> FakeFileReader {
        storm(blaming: Fix.intelIGPU, driverState: "AppleIntelUHD630Graphics")
    }

    // MARK: A faulting discrete GPU

    @Test func amdStormOnIntegratedOnlyNamesThePartAndStaysSafe() {
        let metrics = audit(intelShell(gpuswitch: 0, incidents: stormListing), reader: amdStorm())

        #expect(metrics.gpuSwitchSafe)
        #expect(metrics.gpuSwitchMode == "Integrated Only (discrete GPU kept idle)")
        #expect(metrics.faultingGPU == Fix.amdDGPU)
        #expect(metrics.faultingGPUIsDiscrete)
        #expect(metrics.incidentsByGPU == [Fix.amdDGPU: 3])
        #expect(metrics.unattributedIncidents == 0)
        #expect(metrics.restartChannels == ["VMPT"])
        #expect(metrics.historicalIncidents24h == 3)
    }

    @Test func amdStormListsTheMachinesWholeGPUComplement() {
        let metrics = audit(intelShell(gpuswitch: 0, incidents: stormListing), reader: amdStorm())

        #expect(metrics.installedGPUs == [
            GPUDevice(name: Fix.intelIGPU, isDiscrete: false),
            GPUDevice(name: Fix.amdDGPU, isDiscrete: true)
        ])
    }

    @Test func amdStormUnderDynamicSwitchingIsUnsafe() {
        let metrics = audit(intelShell(gpuswitch: 2, incidents: stormListing), reader: amdStorm())

        #expect(!metrics.gpuSwitchSafe)
        #expect(metrics.gpuSwitchMode.contains("Faulting"))
        #expect(metrics.faultingGPU == Fix.amdDGPU)
    }

    @Test func amdStormUnderForcedDiscreteIsUnsafe() {
        let metrics = audit(intelShell(gpuswitch: 1, incidents: stormListing), reader: amdStorm())

        #expect(!metrics.gpuSwitchSafe)
        #expect(metrics.gpuSwitchMode == "Discrete Only (Faulting dGPU Engaged!)")
    }

    @Test func amdStormReadsEveryListedReport() {
        let reader = amdStorm()
        _ = audit(intelShell(gpuswitch: 0, incidents: stormListing), reader: reader)

        #expect(reader.requestedPaths.count == 3)
        #expect(reader.wasAsked(for: "/Library/Logs/DiagnosticReports/\(stormNames[0])"))
    }

    // MARK: A faulting integrated GPU

    @Test func integratedOnlyIsUnsafeWhenTheIntegratedGPUIsTheFaultingPart() {
        let metrics = audit(intelShell(gpuswitch: 0, incidents: stormListing), reader: intelStorm())

        #expect(!metrics.gpuSwitchSafe)
        #expect(metrics.gpuSwitchMode == "Integrated Only (Faulting iGPU Engaged!)")
        #expect(metrics.faultingGPU == Fix.intelIGPU)
        #expect(!metrics.faultingGPUIsDiscrete)
    }

    @Test func forcedDiscreteIsSafeWhenTheIntegratedGPUIsTheFaultingPart() {
        let metrics = audit(intelShell(gpuswitch: 1, incidents: stormListing), reader: intelStorm())

        #expect(metrics.gpuSwitchSafe)
        #expect(metrics.gpuSwitchMode == "Discrete Only (dGPU forced)")
        #expect(metrics.incidentsByGPU == [Fix.intelIGPU: 3])
    }

    @Test func dynamicSwitchingIsUnsafeWhenTheIntegratedGPUIsTheFaultingPart() {
        let metrics = audit(intelShell(gpuswitch: 2, incidents: stormListing), reader: intelStorm())

        #expect(!metrics.gpuSwitchSafe)
        #expect(metrics.gpuSwitchMode.contains("Faulting"))
    }

    // MARK: Reports that name no hardware

    func anonymousIncidents() -> (listing: String, reader: FakeFileReader) {
        let names = [
            "WindowServer_2026-08-19-231811.userspace_watchdog_timeout.spin",
            "WindowServer_2026-08-19-224410.userspace_watchdog_timeout.spin"
        ]
        let listing = Fix.incidents([
            (ageHours: 2.0, name: names[0]),
            (ageHours: 6.0, name: names[1])
        ])
        let reader = FakeFileReader()
        for name in names { reader.stub(fileName: name, Fix.spinWithoutHardware) }
        return (listing, reader)
    }

    @Test func incidentsNamingNoHardwareBlameNoGPU() {
        let scenario = anonymousIncidents()
        let metrics = audit(intelShell(gpuswitch: 0, incidents: scenario.listing), reader: scenario.reader)

        #expect(metrics.unattributedIncidents == 2)
        #expect(metrics.incidentsByGPU.isEmpty)
        #expect(metrics.faultingGPU == nil)
        #expect(!metrics.faultingGPUIsDiscrete)
        #expect(metrics.restartChannels.isEmpty)
    }

    /// A WindowServer stall is a symptom with many causes, so on its own it must
    /// not convict a GPU. Recommending a mux change off the back of one unrelated
    /// shutdown hang is exactly the false positive this rule exists to prevent.
    @Test func stallReportsAloneDoNotSuspectAnyGPU() {
        let scenario = anonymousIncidents()

        for mode in [0, 1, 2] {
            let metrics = audit(intelShell(gpuswitch: mode, incidents: scenario.listing), reader: scenario.reader)
            #expect(metrics.gpuSwitchSafe)
            #expect(metrics.unattributedIncidents == 2)
        }
    }

    /// A `.gpuRestart` file is by definition a GPU reset, so one that cannot be
    /// read still counts as GPU evidence and keeps the conservative fallback.
    @Test func unreadableGPURestartsStillSuspectTheDiscreteGPU() {
        let names = [
            "Kernel_2026-08-19-231224_mac.gpuRestart",
            "Kernel_2026-08-19-221811_mac.gpuRestart"
        ]
        let listing = Fix.incidents([
            (ageHours: 2.0, name: names[0]),
            (ageHours: 6.0, name: names[1])
        ])
        // No stubs registered: the reader cannot read either report.
        let reader = FakeFileReader()

        #expect(audit(intelShell(gpuswitch: 0, incidents: listing), reader: reader).gpuSwitchSafe)
        #expect(!audit(intelShell(gpuswitch: 1, incidents: listing), reader: reader).gpuSwitchSafe)
        #expect(!audit(intelShell(gpuswitch: 2, incidents: listing), reader: reader).gpuSwitchSafe)
    }

    /// A machine with no discrete GPU has nothing to park, so the fallback must
    /// not invent one and recommend a mux change that cannot help.
    @Test func theDiscreteFallbackNeedsAnActualDiscreteGPU() {
        #expect(safe(1, discrete: false, integrated: false, unattributed: 3, hasDiscrete: false))
        #expect(safe(2, discrete: false, integrated: false, unattributed: 3, hasDiscrete: false))
        #expect(!safe(1, discrete: false, integrated: false, unattributed: 3, hasDiscrete: true))
    }

    // MARK: A machine with nothing to blame

    @Test func aMachineWithoutIncidentsIsSafeInEveryMuxMode() {
        for value in [0, 1, 2] {
            let metrics = audit(intelShell(gpuswitch: value), reader: FakeFileReader())
            #expect(metrics.gpuSwitchSafe)
            #expect(metrics.status == "STABLE")
            #expect(metrics.faultingGPU == nil)
            #expect(!metrics.gpuSwitchMode.contains("Faulting"))
        }
    }

    @Test func appleSiliconHasNoMuxToJudge() {
        let metrics = audit(siliconShell(), reader: FakeFileReader())

        #expect(metrics.gpuSwitchSafe)
        #expect(metrics.status == "STABLE")
        #expect(metrics.installedGPUs == [GPUDevice(name: Fix.appleGPU, isDiscrete: false)])
    }

    // MARK: muxVerdict, exhaustively

    func safe(_ value: Int, discrete: Bool, integrated: Bool, unattributed: Int = 0, hasDiscrete: Bool = true) -> Bool {
        GPUAuditor.muxVerdict(
            gpuSwitchValue: value,
            faultingDiscrete: discrete,
            faultingIntegrated: integrated,
            unattributedGPUEvidence: unattributed,
            hasDiscreteGPU: hasDiscrete
        ).safe
    }

    @Test func machinesWithoutAMuxAreSafeWhateverTheEvidenceSays() {
        for discrete in [false, true] {
            for integrated in [false, true] {
                for unattributed in [0, 3] {
                    #expect(safe(-1, discrete: discrete, integrated: integrated, unattributed: unattributed))
                }
            }
        }
    }

    @Test func integratedOnlyIsUnsafeExactlyWhenTheIntegratedGPUFaults() {
        #expect(safe(0, discrete: false, integrated: false))
        #expect(safe(0, discrete: true, integrated: false))
        #expect(safe(0, discrete: false, integrated: false, unattributed: 3))
        #expect(safe(0, discrete: true, integrated: false, unattributed: 3))
        #expect(!safe(0, discrete: false, integrated: true))
        #expect(!safe(0, discrete: true, integrated: true))
        #expect(!safe(0, discrete: false, integrated: true, unattributed: 3))
        #expect(!safe(0, discrete: true, integrated: true, unattributed: 3))
    }

    @Test func discreteOnlyIsUnsafeWhenTheDiscreteGPUOrAnUnknownPartFaults() {
        #expect(safe(1, discrete: false, integrated: false))
        #expect(safe(1, discrete: false, integrated: true))
        #expect(!safe(1, discrete: true, integrated: false))
        #expect(!safe(1, discrete: true, integrated: true))
        #expect(!safe(1, discrete: false, integrated: false, unattributed: 3))
        #expect(!safe(1, discrete: false, integrated: true, unattributed: 3))
        #expect(!safe(1, discrete: true, integrated: false, unattributed: 3))
        #expect(!safe(1, discrete: true, integrated: true, unattributed: 3))
    }

    @Test func dynamicSwitchingIsSafeOnlyWhenNothingIsFaulting() {
        #expect(safe(2, discrete: false, integrated: false))
        #expect(!safe(2, discrete: true, integrated: false))
        #expect(!safe(2, discrete: false, integrated: true))
        #expect(!safe(2, discrete: true, integrated: true))
        #expect(!safe(2, discrete: false, integrated: false, unattributed: 3))
        #expect(!safe(2, discrete: true, integrated: false, unattributed: 3))
        #expect(!safe(2, discrete: false, integrated: true, unattributed: 3))
        #expect(!safe(2, discrete: true, integrated: true, unattributed: 3))
    }

    @Test func anUnrecognisedGPUSwitchValueIsTreatedAsDynamic() {
        let verdict = GPUAuditor.muxVerdict(
            gpuSwitchValue: 7,
            faultingDiscrete: false,
            faultingIntegrated: false,
            unattributedGPUEvidence: 0,
            hasDiscreteGPU: true
        )
        #expect(verdict.mode == "Dynamic Switching")
        #expect(verdict.safe)
        #expect(!safe(7, discrete: true, integrated: false))
    }

    @Test func muxModeNamesTheEngagedPartWhenUnsafe() {
        #expect(GPUAuditor.muxVerdict(
            gpuSwitchValue: 0, faultingDiscrete: false, faultingIntegrated: true, unattributedGPUEvidence: 0, hasDiscreteGPU: true
        ).mode == "Integrated Only (Faulting iGPU Engaged!)")
        #expect(GPUAuditor.muxVerdict(
            gpuSwitchValue: 1, faultingDiscrete: true, faultingIntegrated: false, unattributedGPUEvidence: 0, hasDiscreteGPU: true
        ).mode == "Discrete Only (Faulting dGPU Engaged!)")
        #expect(GPUAuditor.muxVerdict(
            gpuSwitchValue: 2, faultingDiscrete: true, faultingIntegrated: false, unattributedGPUEvidence: 0, hasDiscreteGPU: true
        ).mode == "Dynamic Switching (Faulting GPU Engaged!)")
    }

    // MARK: gpuswitch parsing

    @Test func anAbsentGPUSwitchKeyReadsAsNoMux() {
        #expect(GPUAuditor.gpuSwitchValue(from: Fix.custom(gpuswitch: nil), onACPower: true) == -1)
        #expect(GPUAuditor.gpuSwitchValue(from: "", onACPower: true) == -1)
    }

    @Test func gpuSwitchValueIsReadFromPmsetCustom() {
        #expect(GPUAuditor.gpuSwitchValue(from: Fix.custom(gpuswitch: 0), onACPower: true) == 0)
        #expect(GPUAuditor.gpuSwitchValue(from: Fix.custom(gpuswitch: 2), onACPower: true) == 2)
    }
}
