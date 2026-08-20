import Foundation

/// What the machine is being told about sleep. `never` pins both the system
/// and the display awake; `dim` lets the display rest while the system stays
/// up; `canonical` is the Mac's own configured behavior, with nothing pinned.
public enum SleepMode: String, CaseIterable, Sendable {
    case never
    case dim
    case canonical
}

/// The pure half of the sleep guard: which IOKit assertions each mode holds,
/// what the launchd holder is invoked with, and the LaunchAgent plist itself.
/// No side effects, so every mapping is exercised in tests.
public struct SleepPolicy {

    /// IOKit power assertion types the holder must create for a mode.
    /// Canonical holds nothing: the guard never edits pmset timers, so
    /// dropping the assertions IS the restore.
    public static func assertionTypes(for mode: SleepMode) -> [String] {
        switch mode {
        case .never: return ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep"]
        case .dim: return ["PreventUserIdleSystemSleep"]
        case .canonical: return []
        }
    }

    /// Arguments the LaunchAgent passes back into mac-health to hold the
    /// assertions. Canonical installs no agent, so it has none.
    public static func holdArguments(for mode: SleepMode) -> [String]? {
        switch mode {
        case .never, .dim: return ["sleep", "hold", "--mode", mode.rawValue]
        case .canonical: return nil
        }
    }

    /// Renders the LaunchAgent plist for a mode, or nil for canonical.
    /// RunAtLoad + KeepAlive make the guard survive logout and reboot until
    /// `sleep canonical` removes it.
    public static func agentPlist(label: String, binary: String, mode: SleepMode, logPath: String) -> String? {
        guard let arguments = holdArguments(for: mode) else { return nil }
        let argumentLines = ([binary] + arguments)
            .map { "        <string>\($0)</string>" }
            .joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
        \(argumentLines)
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(logPath)</string>
            <key>StandardErrorPath</key>
            <string>\(logPath)</string>
        </dict>
        </plist>
        """
    }

    /// Reads the engaged mode back out of an installed agent plist. The plist
    /// is the single source of truth for what the guard was asked to hold.
    public static func mode(fromInstalledPlist content: String) -> SleepMode? {
        guard content.contains("<string>--mode</string>") else { return nil }
        for candidate in SleepMode.allCases where candidate != .canonical {
            if content.contains("<string>\(candidate.rawValue)</string>") {
                return candidate
            }
        }
        return nil
    }
}
