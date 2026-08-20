import Foundation
import MacHealthKit

/// The terminal face of the sleep guard. `never` and `dim` install the
/// persistent holder, `canonical` removes it, `status` shows what is held and
/// what the Mac's own timers say. `hold` is the plumbing launchd invokes.
enum SleepCommand {

    static func run(_ argv: [String]) -> Int32 {
        switch argv.first {
        case "never":
            SleepGuard.engage(.never)
            return 0
        case "dim":
            SleepGuard.engage(.dim)
            return 0
        case "canonical":
            SleepGuard.restoreCanonical()
            return 0
        case "status", .none:
            SleepGuard.status()
            return 0
        case "hold":
            guard let modeIndex = argv.firstIndex(of: "--mode"),
                  modeIndex + 1 < argv.count,
                  let mode = SleepMode(rawValue: argv[modeIndex + 1]),
                  mode != .canonical else {
                FileHandle.standardError.write(Data("mac-health: sleep hold needs --mode never|dim\n".utf8))
                return 64
            }
            SleepGuard.hold(mode)
        default:
            FileHandle.standardError.write(Data("mac-health: sleep needs a subcommand (never, dim, canonical, status)\n".utf8))
            return 64
        }
    }
}
