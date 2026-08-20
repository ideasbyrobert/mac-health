import Testing
import Foundation
@testable import MacHealthKit

/// Attribution is the evidence layer: no mitigation may be recommended without
/// a report that names the part. These tests pin each tier of evidence and the
/// order they override one another in.
struct GPUIncidentParserTests {

    let machine = [
        GPUDevice(name: Fix.intelIGPU, isDiscrete: false),
        GPUDevice(name: Fix.amdDGPU, isDiscrete: true)
    ]

    func attribute(_ header: String) -> String? {
        GPUIncidentParser.attribute(header: header, knownGPUs: machine)
    }

    // MARK: Tier 1 — an explicit Graphics Hardware: line

    @Test func graphicsHardwareLineNamesTheFaultingGPU() {
        #expect(attribute(Fix.gpuRestartReport()) == Fix.amdDGPU)
    }

    @Test func graphicsHardwareLineOutranksTheDriverBundleInTheSameReport() {
        // The driver-state dump blames AMD, but the header says Intel; the
        // stronger evidence has to win or the mux advice inverts.
        let header = Fix.gpuRestartReport(
            graphicsHardware: Fix.intelIGPU,
            driverState: "AMDRadeonX6000_AMDNavi14GraphicsAccelerator"
        )
        #expect(attribute(header) == Fix.intelIGPU)
    }

    @Test func graphicsHardwareValueIsExtractedWithoutPadding() {
        #expect(GPUIncidentParser.graphicsHardware(in: Fix.gpuRestartReport()) == Fix.amdDGPU)
    }

    @Test func anEmptyGraphicsHardwareValueIsNotEvidence() {
        let header = "Event:               GPU Reset\nGraphics Hardware:   \nSignature:           2"
        #expect(GPUIncidentParser.graphicsHardware(in: header) == nil)
        #expect(attribute(header) == nil)
    }

    // MARK: Canonicalisation onto the machine's own spelling

    @Test func aDifferentlyCasedNameCollapsesOntoTheInventorySpelling() {
        let header = Fix.gpuRestartReport(graphicsHardware: "amd radeon pro 5300m")
        #expect(attribute(header) == Fix.amdDGPU)
    }

    @Test func anAbbreviatedNameCollapsesOntoTheInventorySpelling() {
        let header = Fix.gpuRestartReport(graphicsHardware: "Radeon Pro 5300M", driverState: nil)
        #expect(attribute(header) == Fix.amdDGPU)
    }

    @Test func aBareVendorNameResolvesToThatVendorsDevice() {
        #expect(GPUIncidentParser.canonicalize("AMD", knownGPUs: machine) == Fix.amdDGPU)
        #expect(GPUIncidentParser.canonicalize("Intel", knownGPUs: machine) == Fix.intelIGPU)
        #expect(GPUIncidentParser.canonicalize("NVIDIA", knownGPUs: machine) == nil)
    }

    @Test func hardwareThisMachineDoesNotHaveIsReportedVerbatim() {
        let header = Fix.gpuRestartReport(graphicsHardware: "NVIDIA GeForce GT 750M", driverState: nil)
        #expect(attribute(header) == "NVIDIA GeForce GT 750M")
    }

    // MARK: Tier 2 — a device name appearing verbatim in the body

    @Test func aDeviceNameInTheBodyAttributesTheReport() {
        let header = Fix.gpuRestartReport(graphicsHardware: nil, driverState: nil)
            + "\n  Accelerator: AMD Radeon Pro 5300M (IOService:/AppleACPIPlatformExpert)"
        #expect(attribute(header) == Fix.amdDGPU)
    }

    @Test func aDeviceNameInTheBodyOutranksADriverBundle() {
        let header = Fix.gpuRestartReport(
            graphicsHardware: nil,
            driverState: "AMDRadeonX6000_AMDNavi14GraphicsAccelerator"
        ) + "\n  Display attached to: Intel UHD Graphics 630"
        #expect(attribute(header) == Fix.intelIGPU)
    }

    // MARK: Tier 3 — the driver bundle in a panic backtrace

    @Test func anAMDDriverFrameInAPanicBlamesTheAMDDevice() {
        #expect(attribute(Fix.windowServerWatchdogPanic) == Fix.amdDGPU)
    }

    @Test func anIntelDriverFrameInAPanicBlamesTheIntelDevice() {
        let panic = Fix.panicReport(driverFrame: "AppleIntelUHD630Graphics")
        #expect(attribute(panic) == Fix.intelIGPU)
    }

    @Test func aDriverFrameForAnAbsentVendorIsNotEvidence() {
        let panic = Fix.panicReport(driverFrame: "NVDAResman")
        #expect(attribute(panic) == nil)
    }

    @Test func anAGXFrameBlamesTheAppleGPUOnSilicon() {
        let silicon = [GPUDevice(name: Fix.appleGPU, isDiscrete: false)]
        let panic = Fix.panicReport(driverFrame: "AGXAcceleratorG14X")
        #expect(GPUIncidentParser.attribute(header: panic, knownGPUs: silicon) == Fix.appleGPU)
    }

    // MARK: No evidence at all

    @Test func aReportNamingNoHardwareIsNotAttributed() {
        #expect(attribute(Fix.spinWithoutHardware) == nil)
    }

    @Test func aGPURestartWithoutAHardwareLineOrDriverStateIsNotAttributed() {
        #expect(attribute(Fix.gpuRestartReport(graphicsHardware: nil, driverState: nil)) == nil)
    }

    // MARK: Restart channel

    @Test func restartChannelIsTheTrailingTokenOfTheChannelLine() {
        #expect(GPUIncidentParser.restartChannel(in: Fix.gpuRestartReport()) == "VMPT")
    }

    @Test func restartChannelIsNilWhenTheReportHasNoChannelLine() {
        #expect(GPUIncidentParser.restartChannel(in: Fix.gpuRestartReport(restartChannel: nil)) == nil)
        #expect(GPUIncidentParser.restartChannel(in: Fix.spinWithoutHardware) == nil)
    }

    @Test func aDifferentChannelIsCarriedThroughUnchanged() {
        let header = Fix.gpuRestartReport(restartChannel: "3 GFXCOMPUTE")
        #expect(GPUIncidentParser.restartChannel(in: header) == "GFXCOMPUTE")
    }

    // MARK: Report kind from the file name

    @Test func compoundSpinSuffixIsRecognised() {
        let name = "WindowServer_2026-08-19-231811.userspace_watchdog_timeout.spin"
        #expect(GPUIncidentKind(fileName: name) == .spin)
    }

    @Test func hiddenPanicFileIsRecognised() {
        #expect(GPUIncidentKind(fileName: ".contents.panic") == .panic)
    }

    @Test func gpuRestartAndShutdownStallAreRecognised() {
        #expect(GPUIncidentKind(fileName: "Kernel_2026-08-19-231224.gpuRestart") == .gpuRestart)
        #expect(GPUIncidentKind(fileName: "disk writes_2026-08-17-190021.shutdownStall") == .shutdownStall)
    }

    @Test func anythingElseIsOther() {
        #expect(GPUIncidentKind(fileName: "Kernel.gpuRestart.tailspin") == .other)
        #expect(GPUIncidentKind(fileName: "spin") == .other)
        #expect(GPUIncidentKind(fileName: "") == .other)
    }
}
