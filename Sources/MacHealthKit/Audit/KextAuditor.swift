import Foundation

public struct KextAuditor {
    let shell: CommandRunning

    public init(shell: CommandRunning = SystemShell()) {
        self.shell = shell
    }

    public func audit() -> KernelExtensionsMetrics {
        let kextOut = shell.run("kmutil showloaded 2>/dev/null | grep -v 'com.apple.' | grep -v 'Index Refs' | grep -v 'Executing:' | grep -v 'No variant'").output
        let lines = kextOut.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        var nonAppleNames: [String] = []
        for line in lines {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if parts.count >= 6 {
                nonAppleNames.append(parts[5])
            } else if !parts.isEmpty {
                nonAppleNames.append(parts.joined(separator: " "))
            }
        }

        let isClean = nonAppleNames.isEmpty
        let status = isClean ? "CLEAN_NATIVE" : "UNSAFE_LEGACY_KEXTS_LOADED"

        return KernelExtensionsMetrics(
            nonAppleKextsCount: nonAppleNames.count,
            nonAppleKextNames: nonAppleNames,
            isCleanNative: isClean,
            status: status
        )
    }
}
