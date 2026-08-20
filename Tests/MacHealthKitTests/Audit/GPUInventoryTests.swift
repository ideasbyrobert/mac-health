import Testing
import Foundation
@testable import MacHealthKit

/// The inventory is what every downstream attribution decision is expressed in
/// terms of, so a misread bus line would silently invert the mux advice.
struct GPUInventoryTests {

    @Test func dualGPUMachineListsBothPartsInProbeOrder() {
        let devices = GPUInventory.parse(Fix.displaysIntelAMD)

        #expect(devices == [
            GPUDevice(name: Fix.intelIGPU, isDiscrete: false),
            GPUDevice(name: Fix.amdDGPU, isDiscrete: true)
        ])
    }

    @Test func builtInBusIsIntegratedAndPCIeIsDiscrete() {
        let devices = GPUInventory.parse(Fix.displaysIntelAMD)

        #expect(devices.first { $0.name == Fix.intelIGPU }?.isDiscrete == false)
        #expect(devices.first { $0.name == Fix.amdDGPU }?.isDiscrete == true)
    }

    @Test func aThunderboltEGPUCountsAsDiscrete() {
        let output = Fix.displays([
            (name: Fix.intelIGPU, bus: "Built-In", vendor: "Intel"),
            (name: "AMD Radeon RX 6800", bus: "Thunderbolt/USB4", vendor: "AMD (0x1002)")
        ])
        let devices = GPUInventory.parse(output)

        #expect(devices.count == 2)
        #expect(devices.last?.isDiscrete == true)
    }

    @Test func appleSiliconReportsOneIntegratedGPU() {
        let devices = GPUInventory.parse(Fix.displaysAppleSilicon)

        #expect(devices == [GPUDevice(name: Fix.appleGPU, isDiscrete: false)])
    }

    @Test func singleIntegratedIntelMachineHasNoDiscretePart() {
        let devices = GPUInventory.parse(Fix.displaysIntegratedOnly)

        #expect(devices.count == 1)
        #expect(devices.contains { $0.isDiscrete } == false)
    }

    @Test func emptyOutputYieldsNoDevices() {
        #expect(GPUInventory.parse("").isEmpty)
    }

    @Test func garbageOutputYieldsNoDevices() {
        #expect(GPUInventory.parse("sh: system_profiler: command not found").isEmpty)
        #expect(GPUInventory.parse("Graphics/Displays:\n\n    No information found\n").isEmpty)
    }

    @Test func repeatedChipsetModelLinesAreNotDoubleCounted() {
        // system_profiler repeats the chipset for each attached display panel.
        let output = """
        Graphics/Displays:

            AMD Radeon Pro 5300M:

              Chipset Model: AMD Radeon Pro 5300M
              Type: GPU
              Bus: PCIe
              Displays:
                Color LCD:
                  Chipset Model: AMD Radeon Pro 5300M
                  Resolution: 3072 x 1920
        """
        let devices = GPUInventory.parse(output)

        #expect(devices == [GPUDevice(name: Fix.amdDGPU, isDiscrete: true)])
    }

    @Test func aBlockWithoutABusLineIsTreatedAsIntegrated() {
        let output = """
        Graphics/Displays:

            Apple M3 Pro:

              Chipset Model: Apple M3 Pro
              Type: GPU
              Total Number of Cores: 18
        """
        let devices = GPUInventory.parse(output)

        #expect(devices == [GPUDevice(name: Fix.appleGPU, isDiscrete: false)])
    }

    @Test func inventoryAsksSystemProfilerForTheDisplaysDataType() {
        let shell = intelShell()
        let devices = GPUInventory(shell: shell).devices()

        #expect(shell.issued("system_profiler SPDisplaysDataType"))
        #expect(devices.count == 2)
    }
}
