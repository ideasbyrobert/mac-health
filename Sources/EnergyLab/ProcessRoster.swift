import Foundation
import Darwin

/// A process the observer is allowed to name.
///
/// Deliberately thin: the roster's job is to say *who exists right now*, not to
/// describe them. Everything expensive or privileged is left to the sampler, so
/// enumerating the machine stays cheap enough to do on a timer forever.
public struct RunningProcess: Sendable, Hashable, Identifiable {
    public let pid: Int32
    /// The executable's file name where the kernel will disclose it, otherwise
    /// the short accounting name. Never empty: a process with no readable name
    /// is dropped from the roster rather than reported as a blank row.
    public let name: String

    public var id: Int32 { pid }

    public init(pid: Int32, name: String) {
        self.pid = pid
        self.name = name
    }
}

/// Substitutable so the observer can be tested against a fixed cast of
/// processes instead of whatever the machine happens to be running.
public protocol ProcessEnumerating: Sendable {
    func running() -> [RunningProcess]
}

/// Enumerates the live process table through libproc.
///
/// The kernel's list is a snapshot that is stale the instant it is returned.
/// Every failure mode here — the table growing between the sizing call and the
/// read, a pid exiting before it can be named — is treated as "not observed
/// this cycle" rather than as an error, because on a healthy machine processes
/// appear and vanish constantly and that is not a fault to report.
public struct LibprocRoster: ProcessEnumerating {
    public init() {}

    public func running() -> [RunningProcess] {
        let pids = Self.livePIDs()
        var result: [RunningProcess] = []
        result.reserveCapacity(pids.count)
        for pid in pids {
            // pid 0 is the kernel task; it has no user-space executable and no
            // rusage worth attributing to anyone.
            guard pid > 0 else { continue }
            // A pid that exits between enumeration and naming is dropped. An
            // unnamed row would be indistinguishable from a real process the
            // observer simply could not describe.
            guard let name = Self.name(of: pid) else { continue }
            result.append(RunningProcess(pid: pid, name: name))
        }
        return result
    }

    /// The two-call sizing pattern: ask for the byte count with a nil buffer,
    /// then read into an allocation of that size.
    private static func livePIDs() -> [pid_t] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }

        // Slack on top of what the kernel just reported, because processes can
        // be spawned between the two calls. Anything that still does not fit is
        // missed this cycle and picked up on the next one.
        let capacity = Int(byteCount) / MemoryLayout<pid_t>.size + 64
        var buffer = [pid_t](repeating: 0, count: capacity)
        let written = buffer.withUnsafeMutableBufferPointer { slot -> Int32 in
            proc_listpids(
                UInt32(PROC_ALL_PIDS), 0,
                slot.baseAddress,
                Int32(slot.count * MemoryLayout<pid_t>.size)
            )
        }
        guard written > 0 else { return [] }

        // proc_listpids returns bytes written, not entries, and never more than
        // the buffer holds — clamp anyway rather than trust it with a bound.
        let count = min(Int(written) / MemoryLayout<pid_t>.size, capacity)
        return Array(buffer[0..<count])
    }

    /// Prefers the executable path's last component because `proc_name` reports
    /// only the first bytes of the accounting name, which collapses distinct
    /// helpers into the same truncated string. Falls back to `proc_name` when
    /// the path is not disclosed, and gives up when neither is: unnamed is a
    /// reason to omit a process, not to invent a label for it.
    private static func name(of pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE, spelled out: the macro does not survive the
        // Swift importer, and proc_pidpath will refuse a smaller buffer.
        var path = [CChar](repeating: 0, count: 4 * Int(PATH_MAX))
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let full = String(cString: path)
            let leaf = (full as NSString).lastPathComponent
            if !leaf.isEmpty { return leaf }
        }

        var short = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &short, UInt32(short.count)) > 0 {
            let name = String(cString: short)
            if !name.isEmpty { return name }
        }

        return nil
    }
}
