import Foundation

/// One GPU as macOS reports it. `isDiscrete` is what decides which mux modes
/// engage the part: the integrated GPU is always on the built-in bus, a
/// discrete one hangs off PCIe.
public struct GPUDevice: Codable, Equatable {
    public let name: String
    public let isDiscrete: Bool

    public init(name: String, isDiscrete: Bool) {
        self.name = name
        self.isDiscrete = isDiscrete
    }
}

/// Reads the machine's actual GPU complement instead of assuming a vendor.
/// Every attribution decision downstream is expressed in terms of these
/// devices, which is what keeps the tool honest on a machine whose faulting
/// part is not the AMD dGPU this project started with.
public struct GPUInventory {
    let shell: CommandRunning

    public init(shell: CommandRunning = SystemShell()) {
        self.shell = shell
    }

    public func devices() -> [GPUDevice] {
        Self.parse(shell.run("system_profiler SPDisplaysDataType 2>/dev/null").output)
    }

    /// `system_profiler SPDisplaysDataType` emits one indented block per GPU,
    /// each with a `Chipset Model:` line and a `Bus:` line. Anything that is
    /// not on the built-in bus is discrete.
    public static func parse(_ output: String) -> [GPUDevice] {
        var devices: [GPUDevice] = []
        var pendingName: String?
        var pendingIsDiscrete = false

        func flush() {
            guard let name = pendingName, !name.isEmpty else { return }
            if !devices.contains(where: { $0.name == name }) {
                devices.append(GPUDevice(name: name, isDiscrete: pendingIsDiscrete))
            }
            pendingName = nil
            pendingIsDiscrete = false
        }

        for rawLine in output.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let value = Self.value(of: "Chipset Model", in: line) {
                flush()
                pendingName = value
            } else if let bus = Self.value(of: "Bus", in: line), pendingName != nil {
                // "Built-In" is the integrated part; "PCIe" (and anything else,
                // e.g. an eGPU on Thunderbolt) is discrete.
                pendingIsDiscrete = bus.range(of: "built-in", options: .caseInsensitive) == nil
            }
        }
        flush()
        return devices
    }

    private static func value(of key: String, in line: String) -> String? {
        guard line.hasPrefix("\(key):") else { return nil }
        return String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
    }
}
