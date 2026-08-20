import Foundation

/// Abstraction over shelling out, so every auditor can be exercised in tests
/// with recorded fixture output instead of the live system.
public protocol CommandRunning {
    @discardableResult
    func run(_ command: String) -> (output: String, exitCode: Int32)
}

public struct SystemShell: CommandRunning {
    public init() {}

    @discardableResult
    public func run(_ command: String) -> (output: String, exitCode: Int32) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            // Drain the pipe BEFORE reaping. Waiting first deadlocks forever on
            // any command whose combined stdout+stderr exceeds the ~64KB pipe
            // buffer: the child blocks writing, the parent blocks waiting, and
            // neither ever moves. The sentinel runs this loop indefinitely, so
            // that hang would silently take the guard offline.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (output, process.terminationStatus)
        } catch {
            return ("", 1)
        }
    }
}
