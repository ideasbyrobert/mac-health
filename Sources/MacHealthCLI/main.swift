import Foundation
import MacHealthKit
import EnergyLab

let args = CommandLine.arguments

if args.contains("--version") || args.contains("-V") {
    print("mac-health \(macHealthVersion)")
    exit(0)
}

if args.contains("--help") || args.contains("-h") {
    print("""
    OVERVIEW: mac-health — Native macOS Hardware Health, Watchdog Sentinel & Resource Governor

    USAGE: mac-health [subcommand / options]

    SUBCOMMANDS:
      energy lab            Run every chaos scenario and show its energy signature
      energy lab <id>       Run one scenario (see 'energy scenarios')
      energy scenarios      List the scenarios and what each one teaches
      energy watch <pid>    Diagnose a live process from its kernel counters
      energy top [sec]      Rank every live process by the energy it is consuming
      pace                  Scan and pace ALL AI agents, compilers, runtimes, and indexers
      sentinel              Run proactive real-time watchdog sentinel & auto-healing monitor
      sentinel install      Install persistent background LaunchAgent service across reboots
      sentinel uninstall    Remove persistent background LaunchAgent service
      sentinel status       Check status of the background sentinel service

    OPTIONS:
      --json                Output diagnostic metrics as structured JSON
      --watch <sec>         Continuously poll and render health telemetry every N seconds
      -V, --version         Show version
      -h, --help            Show help information

    EXIT CODES (audit runs):
      0                     OPTIMAL
      1                     DEGRADED_OR_WARNING
      2                     CRITICAL_ATTENTION_NEEDED
      64                    Usage error
    """)
    exit(0)
}

if args.contains("energy") {
    exit(EnergyCommand.run(Array(args.drop { $0 != "energy" }.dropFirst())))
}

if args.contains("pace") {
    UniversalGovernor().paceAll(verbose: true)
    exit(0)
}

if args.contains("sentinel") {
    if args.contains("install") {
        ProactiveSentinel.installLaunchAgent()
        exit(0)
    }
    if args.contains("uninstall") {
        ProactiveSentinel.uninstallLaunchAgent()
        exit(0)
    }
    if args.contains("status") {
        ProactiveSentinel.statusLaunchAgent()
        exit(0)
    }

    let isDaemon = args.contains("--daemon")
    ProactiveSentinel.runDaemon(intervalSec: 5, verbose: !isDaemon)
    exit(0)
}

let auditor = HealthAuditor()

if args.contains("--json") {
    let report = auditor.audit()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(report), let str = String(data: data, encoding: .utf8) {
        print(str)
    } else {
        FileHandle.standardError.write(Data("mac-health: failed to encode diagnostic report\n".utf8))
        exit(70)
    }
    exit(report.severity.exitCode)
}

if let watchIndex = args.firstIndex(of: "--watch") {
    guard watchIndex + 1 < args.count, let sec = UInt32(args[watchIndex + 1]), sec > 0 else {
        FileHandle.standardError.write(Data("mac-health: --watch needs a positive interval in seconds\n".utf8))
        exit(64)
    }
    // A dashboard never terminates, so it has no verdict to report; the exit
    // code contract applies to one-shot audits.
    while true {
        print("\u{001B}[2J\u{001B}[H", terminator: "")
        ConsoleFormat.render(auditor.audit())
        sleep(sec)
    }
}

let report = auditor.audit()
ConsoleFormat.render(report)
exit(report.severity.exitCode)
