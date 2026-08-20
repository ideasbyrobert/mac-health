import Foundation
@testable import MacHealthKit

/// Records every command and replays fixture output for the first stub whose
/// key is contained in the command. Unstubbed commands return empty output.
final class FakeShell: CommandRunning {
    private(set) var commands: [String] = []
    private var stubs: [(contains: String, output: String, exit: Int32)] = []

    func stub(_ contains: String, _ output: String, exit: Int32 = 0) {
        stubs.append((contains, output, exit))
    }

    @discardableResult
    func run(_ command: String) -> (output: String, exitCode: Int32) {
        commands.append(command)
        for s in stubs where command.contains(s.contains) {
            return (s.output, s.exit)
        }
        return ("", 1)
    }

    func issued(_ fragment: String) -> Bool {
        commands.contains { $0.contains(fragment) }
    }
}
