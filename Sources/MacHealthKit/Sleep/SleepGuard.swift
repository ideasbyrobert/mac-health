import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac awake by holding IOKit power assertions from a LaunchAgent,
/// the same way caffeinate would, but persistent across logout and reboot.
/// It never touches pmset: the machine's own sleep timers remain the
/// untouched "canonical" configuration, and removing the agent restores them
/// by construction rather than by replaying saved values.
public struct SleepGuard {

    public static let label = "com.fundamentalapplications.mac-health.sleepguard"
    public static let logPath = "/tmp/mac-health-sleepguard.log"

    static var shell: CommandRunning { SystemShell() }

    public static var agentPlistPath: String {
        return "\(ProactiveSentinel.userHome)/Library/LaunchAgents/\(label).plist"
    }

    /// The mode the installed agent was asked to hold, or canonical when no
    /// agent is installed.
    public static var engagedMode: SleepMode {
        guard let content = try? String(contentsOfFile: agentPlistPath, encoding: .utf8) else {
            return .canonical
        }
        return SleepPolicy.mode(fromInstalledPlist: content) ?? .canonical
    }

    // MARK: engage / restore

    public static func engage(_ mode: SleepMode) {
        guard mode != .canonical else {
            restoreCanonical()
            return
        }

        let resolvedBinary = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            .resolvingSymlinksInPath().path
        guard let plistContent = SleepPolicy.agentPlist(
            label: label, binary: resolvedBinary, mode: mode, logPath: logPath) else {
            return
        }

        let dir = URL(fileURLWithPath: agentPlistPath).deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)

        do {
            try plistContent.write(toFile: agentPlistPath, atomically: true, encoding: .utf8)
            let uid = ProactiveSentinel.userUID
            let prefix = getuid() == 0 ? "launchctl asuser \(uid) " : ""
            shell.run("\(prefix)launchctl bootout gui/\(uid) '\(agentPlistPath)' 2>/dev/null")
            let bootstrap = shell.run("\(prefix)launchctl bootstrap gui/\(uid) '\(agentPlistPath)'")

            let headline = mode == .never
                ? "Sleep Guard Engaged: the Mac will not sleep, and the display stays on."
                : "Sleep Guard Engaged: the system stays awake; the display may still sleep."
            print("\n\(ConsoleFormat.green)\(ConsoleFormat.tick) \(headline)\(ConsoleFormat.reset)")
            print("  \(ConsoleFormat.bullet) Mode:            \(mode.rawValue)")
            print("  \(ConsoleFormat.bullet) Assertions:      \(SleepPolicy.assertionTypes(for: mode).joined(separator: ", "))")
            print("  \(ConsoleFormat.bullet) Plist Location:  \(agentPlistPath)")
            print("  \(ConsoleFormat.bullet) Binary Path:     \(resolvedBinary)")
            if bootstrap.exitCode == 0 {
                print("  \(ConsoleFormat.bullet) Status:          Holding (survives logout and reboot)")
            } else {
                print("  \(ConsoleFormat.bullet) Status:          \(ConsoleFormat.yellow)Bootstrap failed — \(bootstrap.output)\(ConsoleFormat.reset)")
                print("    \(ConsoleFormat.arrow) If running over SSH, run: launchctl bootstrap gui/\(uid) '\(agentPlistPath)' from a GUI terminal session.")
            }
            print("  \(ConsoleFormat.bullet) Restore:         mac-health sleep canonical")
            print("  \(ConsoleFormat.cyan)Note: closing the lid still sleeps the Mac; only 'sudo pmset -a disablesleep 1'")
            print("  changes that, and mac-health does not run sudo.\(ConsoleFormat.reset)\n")
        } catch {
            print("\(ConsoleFormat.red)✗ Failed to write LaunchAgent plist: \(error.localizedDescription)\(ConsoleFormat.reset)")
        }
    }

    public static func restoreCanonical() {
        let uid = ProactiveSentinel.userUID
        let prefix = getuid() == 0 ? "launchctl asuser \(uid) " : ""
        shell.run("\(prefix)launchctl bootout gui/\(uid) '\(agentPlistPath)' 2>/dev/null")
        shell.run("pkill -f '[m]ac-health sleep hold' 2>/dev/null")
        try? FileManager.default.removeItem(atPath: agentPlistPath)

        print("\n\(ConsoleFormat.green)\(ConsoleFormat.tick) Canonical sleep behavior restored.\(ConsoleFormat.reset)")
        print("  The guard held assertions instead of editing pmset, so the timers below")
        print("  were never changed and are simply back in force:\n")
        printConfiguredTimers(indent: "  ")
        print("")
    }

    // MARK: status

    public static func status() {
        let mode = engagedMode
        let holderPids = shell.run("pgrep -f '[m]ac-health sleep hold'").output
            .components(separatedBy: .newlines).filter { !$0.isEmpty }

        print("\n\(ConsoleFormat.bold)😴 mac-health Sleep Guard Status\(ConsoleFormat.reset)")
        print(ConsoleFormat.rule())
        switch mode {
        case .canonical:
            print("  \(ConsoleFormat.bullet) Mode:            \(ConsoleFormat.green)canonical\(ConsoleFormat.reset) (the Mac follows its own configured timers)")
        case .never:
            print("  \(ConsoleFormat.bullet) Mode:            \(ConsoleFormat.yellow)never\(ConsoleFormat.reset) (system and display are pinned awake)")
        case .dim:
            print("  \(ConsoleFormat.bullet) Mode:            \(ConsoleFormat.yellow)dim\(ConsoleFormat.reset) (system pinned awake; display may sleep)")
        }
        if mode != .canonical {
            print("  \(ConsoleFormat.bullet) Agent Plist:     \(agentPlistPath)")
            if holderPids.isEmpty {
                print("  \(ConsoleFormat.bullet) Holder Process:  \(ConsoleFormat.red)Not running\(ConsoleFormat.reset) (launchd should respawn it; see \(logPath))")
            } else {
                print("  \(ConsoleFormat.bullet) Holder Process:  \(ConsoleFormat.green)Active (PID: \(holderPids.joined(separator: ", ")))\(ConsoleFormat.reset)")
            }
        }

        let assertions = shell.run("pmset -g assertions 2>/dev/null").output
        for type in ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep"] {
            if let line = assertions.components(separatedBy: "\n")
                .first(where: { $0.contains(type) && !$0.contains("named:") }) {
                let active = line.trimmingCharacters(in: .whitespaces).hasSuffix("1")
                let tint = active ? ConsoleFormat.yellow : ConsoleFormat.green
                print("  \(ConsoleFormat.bullet) \(type): \(tint)\(active ? "held" : "clear")\(ConsoleFormat.reset)")
            }
        }

        print("\n  Canonical timers (pmset, untouched by the guard):")
        printConfiguredTimers(indent: "  ")
        print(ConsoleFormat.rule() + "\n")
    }

    static func printConfiguredTimers(indent: String) {
        let power = PowerAuditor(shell: shell).audit()
        print("\(indent)\(ConsoleFormat.bullet) AC Power:        system sleep \(describeMinutes(power.acSleepMinutes)), display sleep \(describeMinutes(power.acDisplaySleepMinutes))")
        print("\(indent)\(ConsoleFormat.bullet) Battery Power:   system sleep \(describeMinutes(power.batterySleepMinutes)), display sleep \(describeMinutes(power.batteryDisplaySleepMinutes))")
    }

    static func describeMinutes(_ minutes: Int) -> String {
        return minutes == 0 ? "off" : "\(minutes) min"
    }

    // MARK: holder (runs under launchd)

    /// Creates the mode's IOKit assertions and parks forever. launchd owns
    /// the lifecycle: `sleep canonical` boots the job out, the process dies,
    /// and the kernel releases the assertions with it.
    public static func hold(_ mode: SleepMode) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        var held: [IOPMAssertionID] = []
        for type in SleepPolicy.assertionTypes(for: mode) {
            var assertionID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "mac-health sleep guard (\(mode.rawValue))" as CFString,
                &assertionID
            )
            if result == kIOReturnSuccess {
                held.append(assertionID)
                print("holding \(type) (assertion \(assertionID))")
            } else {
                print("failed to create \(type): IOReturn \(result)")
            }
        }
        guard !held.isEmpty else {
            print("no assertions could be created; exiting so launchd can retry")
            exit(70)
        }
        dispatchMain()
    }
}
