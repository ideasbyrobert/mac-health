import Foundation

public struct ProactiveSentinel {

    public static let label = "com.fundamentalapplications.mac-health.sentinel"
    public static let legacyLabel = "com.robert.mac-health.sentinel"

    static var shell: CommandRunning { SystemShell() }

    // Resolve the console (GUI) user rather than the process user: when the
    // tool runs under sudo/root, HOME points at /var/root and the LaunchAgent
    // must still land in the logged-in user's domain.
    public static var consoleUser: String {
        let u = shell.run("stat -f %Su /dev/console 2>/dev/null").output
        if !u.isEmpty && u != "root" { return u }
        if let su = ProcessInfo.processInfo.environment["SUDO_USER"], !su.isEmpty { return su }
        return NSUserName()
    }

    public static var userHome: String {
        let out = shell.run("dscl . -read /Users/\(consoleUser) NFSHomeDirectory 2>/dev/null").output
        if let path = out.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces), path.hasPrefix("/") {
            return path
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    public static var agentPlistPath: String {
        return "\(userHome)/Library/LaunchAgents/\(label).plist"
    }

    public static var legacyPlistPath: String {
        return "\(userHome)/Library/LaunchAgents/\(legacyLabel).plist"
    }

    public static var userUID: String {
        let uidOut = shell.run("id -u '\(consoleUser)' 2>/dev/null || id -u").output.trimmingCharacters(in: .whitespacesAndNewlines)
        return uidOut.isEmpty ? String(getuid()) : uidOut
    }

    public static func runDaemon(intervalSec: UInt32 = 5, verbose: Bool = true) {
        // Under launchd, stdout is redirected to a file and becomes fully buffered,
        // so events would sit invisible in a 64KB buffer for hours. Line-buffer it.
        setvbuf(stdout, nil, _IOLBF, 0)
        if verbose {
            print("\n\(ConsoleFormat.bold)🛡️ mac-health Proactive Sentinel Daemon Active\(ConsoleFormat.reset)")
            print(ConsoleFormat.rule())
            print("  \(ConsoleFormat.bullet) Heartbeat Interval:  \(intervalSec) seconds")
            print("  \(ConsoleFormat.bullet) Proactive Monitors:  WindowServer IPC, GPU Watchdog, Thermal Headroom, Swap Thrashing")
            print("  \(ConsoleFormat.bullet) Auto-Healing:        Dynamic QoS Pacing, Priority Shedding, Sleep Timings")
            print(ConsoleFormat.rule() + "\n")
            print("Sentinel is actively guarding the system. Press Ctrl+C to stop.\n")
        }

        let sysShell = SystemShell()
        let wsAuditor = WindowServerAuditor(shell: sysShell)
        let governor = UniversalGovernor(shell: sysShell)
        var streak = 0

        while true {
            let wsMetrics = wsAuditor.audit()
            let thermOut = sysShell.run("pmset -g therm 2>/dev/null").output
            let (cpuSpeedLimit, _, _) = CPUAuditor.speedLimit(from: thermOut)
            // pmset only reports hard throttling; ProcessInfo surfaces the OS
            // thermal pressure level well before the speed limit drops (fans
            // maxed, die near Tjmax), which is when shedding load actually
            // prevents the stall instead of reacting to it.
            let thermalState = ProcessInfo.processInfo.thermalState
            let thermalPressure = thermalState == .serious || thermalState == .critical

            let decision = SentinelPolicy.decide(
                latencyMs: wsMetrics.latencyMs,
                responsive: wsMetrics.isResponsive,
                cpuSpeedLimit: cpuSpeedLimit,
                thermalPressure: thermalPressure,
                previousStreak: streak
            )
            streak = decision.streak

            for action in decision.actions {
                let timestamp = ConsoleFormat.timeString(Date())
                switch action {
                case .reportSpike(let latency, let spikeStreak):
                    print("[\(timestamp)] \(ConsoleFormat.red)\(ConsoleFormat.warn) WindowServer Latency Spike: \(String(format: "%.1f", latency))ms (Streak: \(spikeStreak))\(ConsoleFormat.reset)")
                    print("  \(ConsoleFormat.arrow) Proactively shedding CPU contention and pacing heavy background processes...")
                case .reportRecovery(let latency):
                    print("[\(timestamp)] \(ConsoleFormat.green)\(ConsoleFormat.tick) WindowServer Recovered: \(String(format: "%.1f", latency))ms latency (Normal)\(ConsoleFormat.reset)")
                case .reportThermal(let reason):
                    print("[\(timestamp)] \(ConsoleFormat.yellow)\(ConsoleFormat.warn) Thermal Event (\(reason)) → Auto-pacing heavy compilers & agents...\(ConsoleFormat.reset)")
                case .paceAll:
                    governor.paceAll(verbose: false)
                }
            }

            sleep(intervalSec)
        }
    }

    public static func installLaunchAgent() {
        let resolvedBinary = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            .resolvingSymlinksInPath().path

        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(resolvedBinary)</string>
                <string>sentinel</string>
                <string>--daemon</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>/tmp/mac-health-sentinel.log</string>
            <key>StandardErrorPath</key>
            <string>/tmp/mac-health-sentinel.err</string>
        </dict>
        </plist>
        """

        let dir = URL(fileURLWithPath: agentPlistPath).deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)

        do {
            try plistContent.write(toFile: agentPlistPath, atomically: true, encoding: .utf8)
            let uid = userUID
            // `launchctl asuser` requires root; when running as the target user,
            // talk to launchd directly.
            let prefix = getuid() == 0 ? "launchctl asuser \(uid) " : ""
            // Migrate away from the legacy label if a previous install left one.
            if FileManager.default.fileExists(atPath: legacyPlistPath) {
                shell.run("\(prefix)launchctl bootout gui/\(uid) '\(legacyPlistPath)' 2>/dev/null")
                try? FileManager.default.removeItem(atPath: legacyPlistPath)
            }
            shell.run("\(prefix)launchctl bootout gui/\(uid) '\(agentPlistPath)' 2>/dev/null")
            let bootstrap = shell.run("\(prefix)launchctl bootstrap gui/\(uid) '\(agentPlistPath)'")

            print("\n\(ConsoleFormat.green)\(ConsoleFormat.tick) Proactive Sentinel LaunchAgent Installed Successfully!\(ConsoleFormat.reset)")
            print("  \(ConsoleFormat.bullet) Plist Location:  \(agentPlistPath)")
            print("  \(ConsoleFormat.bullet) Binary Path:     \(resolvedBinary)")
            print("  \(ConsoleFormat.bullet) Service Target:  gui/\(uid) (\(consoleUser))")
            if bootstrap.exitCode == 0 {
                print("  \(ConsoleFormat.bullet) Status:          Running in Background")
            } else {
                print("  \(ConsoleFormat.bullet) Status:          \(ConsoleFormat.yellow)Bootstrap failed — \(bootstrap.output)\(ConsoleFormat.reset)")
                print("    \(ConsoleFormat.arrow) If running over SSH, run: launchctl bootstrap gui/\(uid) '\(agentPlistPath)' from a GUI terminal session.")
            }
            print("  \(ConsoleFormat.bullet) Logs:            /tmp/mac-health-sentinel.log\n")
        } catch {
            print("\(ConsoleFormat.red)✗ Failed to write LaunchAgent plist: \(error.localizedDescription)\(ConsoleFormat.reset)")
        }
    }

    public static func uninstallLaunchAgent() {
        let uid = userUID
        let prefix = getuid() == 0 ? "launchctl asuser \(uid) " : ""
        shell.run("\(prefix)launchctl bootout gui/\(uid) '\(agentPlistPath)' 2>/dev/null")
        shell.run("\(prefix)launchctl bootout gui/\(uid) '\(legacyPlistPath)' 2>/dev/null")
        try? FileManager.default.removeItem(atPath: legacyPlistPath)
        shell.run("pkill -f '[m]ac-health sentinel --daemon' 2>/dev/null")
        try? FileManager.default.removeItem(atPath: agentPlistPath)
        print("\n\(ConsoleFormat.green)\(ConsoleFormat.tick) Proactive Sentinel LaunchAgent Removed Successfully.\(ConsoleFormat.reset)\n")
    }

    public static func statusLaunchAgent() {
        // The [m] regex trick stops pgrep -f from matching the shell that is
        // running this very pgrep (its command line contains the pattern text),
        // which previously made status report "Active" even with no daemon.
        let psOut = shell.run("pgrep -f '[m]ac-health sentinel --daemon'").output.trimmingCharacters(in: .whitespacesAndNewlines)
        let exists = FileManager.default.fileExists(atPath: agentPlistPath)
            || FileManager.default.fileExists(atPath: legacyPlistPath)

        print("\n\(ConsoleFormat.bold)🛡️ mac-health Sentinel LaunchAgent Status\(ConsoleFormat.reset)")
        print(ConsoleFormat.rule())
        print("  \(ConsoleFormat.bullet) Installed on Disk: \(exists ? "\(ConsoleFormat.green)Yes (\(agentPlistPath))\(ConsoleFormat.reset)" : "\(ConsoleFormat.yellow)No\(ConsoleFormat.reset)")")
        let pids = psOut.components(separatedBy: .newlines).filter { !$0.isEmpty }
        if pids.isEmpty {
            print("  \(ConsoleFormat.bullet) Service Status:    \(ConsoleFormat.yellow)Inactive / Stopped\(ConsoleFormat.reset)")
        } else {
            print("  \(ConsoleFormat.bullet) Service Status:    \(ConsoleFormat.green)Active (PID: \(pids.joined(separator: ", ")))\(ConsoleFormat.reset)")
        }
        print(ConsoleFormat.rule() + "\n")
    }
}
