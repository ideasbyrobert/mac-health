import Foundation

/// Finds processes that are burning CPU right now, whatever they are called.
///
/// The name driven rules in `UniversalGovernor` can only pace what someone
/// thought to list in advance, which makes them structurally unable to handle
/// the case the governor exists for: a runaway nobody has seen before. The
/// motivating incident was `mediaanalysisd` inside an iOS Simulator, holding
/// eight cores for two hours and forty minutes while the CPU sat thermally
/// clamped to 44 percent of its rated speed. The sentinel detected the stall
/// correctly and paced eleven unrelated processes, because the offender
/// appeared in no pattern list.
///
/// Detection here is behavioural, so a process qualifies by what it is doing
/// rather than by its name.
public struct RunawayDetector {

    /// One `ps` observation: total CPU seconds consumed since the process
    /// started, which is a counter rather than an average.
    public struct Sample: Equatable {
        public let pid: Int
        public let cpuSeconds: Double
        public let command: String

        public init(pid: Int, cpuSeconds: Double, command: String) {
            self.pid = pid
            self.cpuSeconds = cpuSeconds
            self.command = command
        }
    }

    public struct Runaway: Equatable {
        public let pid: Int
        public let name: String
        /// CPU percent over the observation window, where 100 is one core
        /// saturated. Twelve logical cores can therefore reach 1200.
        public let cpuPercent: Double

        public init(pid: Int, name: String, cpuPercent: Double) {
            self.pid = pid
            self.name = name
            self.cpuPercent = cpuPercent
        }
    }

    /// Two cores held for a full window. Below this a compile, an export, or a
    /// test run looks identical to a runaway, and pacing those would punish
    /// work the person is waiting on.
    public static let defaultThresholdPercent = 200.0

    /// Processes the governor must never touch, whatever they are doing.
    /// `kernel_task` is the thermal governor itself, and renicing it would
    /// fight the very mechanism cooling the machine. The rest own the login
    /// session or the display, so degrading them degrades the interface the
    /// person is using to ask for help.
    public static let neverPace: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow",
        "Finder", "Dock", "SystemUIServer", "coreaudiod", "hidd",
    ]

    /// Parses `ps -Ao pid=,time=,comm=`.
    ///
    /// The time column is elapsed CPU time, `MM:SS.ss` or `HH:MM:SS`, not the
    /// `%cpu` column. `%cpu` is an average over the whole lifetime of the
    /// process, so a daemon that spun for two hours and then stopped still
    /// reports a high figure long after it went quiet. A counter differenced
    /// across a known interval says what happened during that interval and
    /// nothing else.
    public static func parseSamples(_ psOutput: String) -> [Sample] {
        var samples: [Sample] = []

        for rawLine in psOutput.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3,
                  let pid = Int(fields[0]),
                  let cpuSeconds = parseCPUTime(String(fields[1]))
            else { continue }

            let command = String(fields[2]).trimmingCharacters(in: .whitespaces)
            let name = URL(fileURLWithPath: command).lastPathComponent
            samples.append(Sample(pid: pid, cpuSeconds: cpuSeconds, command: name.isEmpty ? command : name))
        }

        return samples
    }

    /// Accepts `MM:SS.ss` and `HH:MM:SS.ss`, the two shapes `ps` emits.
    public static func parseCPUTime(_ field: String) -> Double? {
        let parts = field.split(separator: ":")
        guard !parts.isEmpty, parts.count <= 3 else { return nil }

        var seconds = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    /// Differences two samples and returns everything that held more CPU than
    /// `thresholdPercent` for the whole window.
    ///
    /// A process missing from `second` exited during the window and is not
    /// reported: it is no longer burning anything, and pacing a dead pid would
    /// at best do nothing and at worst hit a pid the kernel has since reused.
    /// A negative delta means the same reuse already happened, so it is
    /// discarded rather than trusted.
    public static func runaways(
        first: [Sample],
        second: [Sample],
        intervalSeconds: Double,
        thresholdPercent: Double = defaultThresholdPercent,
        exemptPIDs: Set<Int> = [],
        exemptNames: Set<String> = neverPace
    ) -> [Runaway] {
        guard intervalSeconds > 0 else { return [] }

        var baseline: [Int: Sample] = [:]
        for sample in first { baseline[sample.pid] = sample }

        var found: [Runaway] = []
        for current in second {
            guard let previous = baseline[current.pid] else { continue }
            if exemptPIDs.contains(current.pid) { continue }
            if exemptNames.contains(current.command) { continue }

            let burned = current.cpuSeconds - previous.cpuSeconds
            guard burned > 0 else { continue }

            let percent = (burned / intervalSeconds) * 100
            guard percent >= thresholdPercent else { continue }

            found.append(Runaway(pid: current.pid, name: current.command, cpuPercent: percent))
        }

        return found.sorted { $0.cpuPercent > $1.cpuPercent }
    }

    /// Parses the pids `lsappinfo list` reports.
    ///
    /// Every registered GUI application is exempt. This is what keeps the
    /// governor's promise that interactive apps run unrestricted: a video
    /// export or a render legitimately holds every core for minutes, and is
    /// exactly the work a person is sitting there waiting for. A daemon with
    /// no window has nobody waiting on it.
    public static func guiApplicationPIDs(_ lsappinfoOutput: String) -> Set<Int> {
        var pids: Set<Int> = []
        for line in lsappinfoOutput.components(separatedBy: "\n") {
            guard let range = line.range(of: "pid = ") else { continue }
            let rest = line[range.upperBound...]
            let digits = rest.prefix { $0.isNumber }
            if let pid = Int(digits) { pids.insert(pid) }
        }
        return pids
    }
}
