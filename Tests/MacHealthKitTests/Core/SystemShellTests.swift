import Testing
import Foundation
@testable import MacHealthKit

/// These exercise the real shell rather than a fake, because the defect they
/// cover lives in the process plumbing itself.
struct SystemShellTests {

    @Test func capturesStdoutAndExitCode() {
        let result = SystemShell().run("echo hello")
        #expect(result.output == "hello")
        #expect(result.exitCode == 0)
    }

    @Test func capturesStderrAndReportsFailure() {
        let result = SystemShell().run("echo oops >&2; exit 3")
        #expect(result.output == "oops")
        #expect(result.exitCode == 3)
    }

    /// Runs the shell on a worker thread so a deadlock fails the test instead of
    /// hanging the whole suite. `.timeLimit` would be the idiomatic trait but it
    /// needs macOS 13 and this package supports 12.
    private func runWithDeadline(_ command: String, seconds: Int = 30) -> (output: String, exitCode: Int32)? {
        let done = DispatchSemaphore(value: 0)
        var captured: (output: String, exitCode: Int32)?
        DispatchQueue.global().async {
            captured = SystemShell().run(command)
            done.signal()
        }
        return done.wait(timeout: .now() + .seconds(seconds)) == .success ? captured : nil
    }

    /// Reaping the child before draining the pipe deadlocks forever once output
    /// exceeds the ~64KB pipe buffer: the child blocks writing, the parent
    /// blocks waiting. The sentinel runs this loop indefinitely, so that hang
    /// would silently take the guard offline. 1 MB is comfortably past the
    /// buffer; before the fix this call never returned.
    @Test func largeOutputDoesNotDeadlock() {
        let result = runWithDeadline("yes ABCDEFGHIJKLMNOPQRSTUVWXYZ | head -c 1048576")
        #expect(result != nil, "SystemShell.run deadlocked on output larger than the pipe buffer")
        #expect(result?.exitCode == 0)
        #expect(result?.output.count == 1_048_576)
    }

    @Test func largeStderrDoesNotDeadlock() {
        let result = runWithDeadline("yes ERRORLINE | head -c 1048576 >&2")
        #expect(result != nil, "SystemShell.run deadlocked on stderr larger than the pipe buffer")
        #expect(result?.output.count == 1_048_576)
    }
}
