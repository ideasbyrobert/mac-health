import Foundation
import MacHealthKit
import EnergyLab

/// The terminal face of the energy lab. Renders the same claims the SwiftUI app
/// shows, so neither surface can quietly disagree with the other.
enum EnergyCommand {

    static func run(_ argv: [String]) -> Int32 {
        switch argv.first {
        case "scenarios":
            listScenarios()
            return 0
        case "lab":
            return runLab(id: argv.count > 1 ? argv[1] : nil)
        case "watch":
            guard argv.count > 1, let pid = Int32(argv[1]) else {
                FileHandle.standardError.write(Data("mac-health: energy watch needs a pid\n".utf8))
                return 64
            }
            return watch(pid: pid)
        case "top":
            let window = argv.count > 1 ? (Double(argv[1]) ?? 2.0) : 2.0
            return top(window: window)
        default:
            FileHandle.standardError.write(Data("mac-health: energy needs a subcommand (lab, scenarios, watch, top)\n".utf8))
            return 64
        }
    }

    // MARK: rendering

    static func colour(for pathology: Pathology) -> String {
        switch pathology {
        case .healthy, .idleWaiting: return ConsoleFormat.green
        case .deadlock, .livelock: return ConsoleFormat.red
        case .wakeupStorm, .stalled: return ConsoleFormat.yellow
        case .indeterminate: return ConsoleFormat.cyan
        }
    }

    static func listScenarios() {
        print("\n\(ConsoleFormat.bold)Chaos scenarios\(ConsoleFormat.reset)")
        print(ConsoleFormat.rule())
        for scenario in Scenario.all {
            print("\n  \(ConsoleFormat.bold)\(scenario.id)\(ConsoleFormat.reset) — \(scenario.title)")
            print("    \(ConsoleFormat.cyan)predicts\(ConsoleFormat.reset) \(scenario.predicted.rawValue)")
            print("    \(wrap(scenario.teaches, indent: 4))")
            print("    \(ConsoleFormat.green)remedy:\(ConsoleFormat.reset) \(wrap(scenario.remedy, indent: 4))")
        }
        print("")
    }

    static func render(_ result: ScenarioResult) {
        let d = result.diagnosis
        let tint = colour(for: d.pathology)
        let mark = result.predictionHeld
            ? "\(ConsoleFormat.green)prediction held\(ConsoleFormat.reset)"
            : "\(ConsoleFormat.red)PREDICTION FAILED (expected \(result.scenario.predicted.rawValue))\(ConsoleFormat.reset)"

        print("\n  \(ConsoleFormat.bold)\(result.scenario.title)\(ConsoleFormat.reset)  [\(result.scenario.id)]")
        print("    Verdict:     \(tint)\(ConsoleFormat.bold)\(d.pathology.rawValue)\(ConsoleFormat.reset) — \(d.pathology.headline(at: d.confidence))")
        print("    Confidence:  \(d.confidence.rawValue)   \(mark)")
        for line in d.evidence {
            print("      \(ConsoleFormat.cyan)·\(ConsoleFormat.reset) \(line)")
        }
        if let inquiry = d.inquiry {
            print("    \(ConsoleFormat.yellow)Open question:\(ConsoleFormat.reset) \(wrap(inquiry, indent: 6))")
        }
    }

    /// Soft-wraps prose at 76 columns so long explanations stay readable.
    static func wrap(_ text: String, indent: Int, width: Int = 76) -> String {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            if current.count + word.count + 1 > width - indent {
                lines.append(current)
                current = String(word)
            } else {
                current = current.isEmpty ? String(word) : current + " " + word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\n" + String(repeating: " ", count: indent))
    }

    // MARK: commands

    static func runLab(id: String?) -> Int32 {
        let workerPath = ChaosLab.defaultWorkerPath()
        guard FileManager.default.isExecutableFile(atPath: workerPath) else {
            FileHandle.standardError.write(Data(
                "mac-health: chaos-worker not found next to the binary (\(workerPath)).\nBuild it with 'swift build' or 'make build'.\n".utf8))
            return 70
        }

        let scenarios: [Scenario]
        if let id {
            guard let one = Scenario.named(id) else {
                FileHandle.standardError.write(Data("mac-health: no scenario named '\(id)'\n".utf8))
                return 64
            }
            scenarios = [one]
        } else {
            scenarios = Scenario.all
        }

        print("\n\(ConsoleFormat.bold)Energy lab\(ConsoleFormat.reset) — identical work, different coordination")
        print(ConsoleFormat.rule())
        print("Every worker below completes the same nominal job. Any difference in")
        print("the counters is caused purely by how that work is coordinated.")

        let lab = ChaosLab(workerPath: workerPath)
        var results: [ScenarioResult] = []
        for scenario in scenarios {
            guard let result = lab.run(scenario) else {
                print("\n  \(ConsoleFormat.red)\(scenario.id): could not be measured\(ConsoleFormat.reset)")
                continue
            }
            results.append(result)
            render(result)
        }

        summarise(results)
        return results.allSatisfy(\.predictionHeld) ? 0 : 1
    }

    static func summarise(_ results: [ScenarioResult]) {
        guard !results.isEmpty else { return }
        print("\n" + ConsoleFormat.rule())
        print("\(ConsoleFormat.bold)  Cost of coordination, for identical work\(ConsoleFormat.reset)\n")
        func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
            let gap = max(width - text.count, 0)
            let spaces = String(repeating: " ", count: gap)
            return right ? spaces + text : text + spaces
        }

        print("  " + pad("scenario", 16) + pad("cycles/s", 15, right: true)
              + pad("IPC", 8, right: true) + pad("CPU%", 9, right: true)
              + pad("wakeups/s", 12, right: true))

        let baseline = results.first { $0.scenario.id == "healthy" }?.diagnosis.signature.cyclesPerSecond
        for r in results {
            let s = r.diagnosis.signature
            let wakeups = max(s.packageIdleWakeupsPerSecond, s.interruptWakeupsPerSecond)
            print("  " + pad(r.scenario.id, 16)
                  + pad(String(format: "%.0f", s.cyclesPerSecond), 15, right: true)
                  + pad(String(format: "%.2f", s.instructionsPerCycle), 8, right: true)
                  + pad(String(format: "%.2f", s.cpuPercent), 9, right: true)
                  + pad(String(format: "%.1f", wakeups), 12, right: true))
        }

        if let baseline, baseline > 0 {
            print("\n  Relative to a blocking wait doing the same job:")
            for r in results where r.scenario.id != "healthy" {
                let ratio = r.diagnosis.signature.cyclesPerSecond / baseline
                guard ratio >= 1.5 else { continue }
                // An order of magnitude is all a single short window supports.
                // A near-idle baseline varies by 20x between runs on a busy
                // machine, so printing "burns 1213x" would be false precision.
                print("    \(r.scenario.id) burns \(Self.orderOfMagnitude(ratio)) the cycles")
            }
            print("\n  \(ConsoleFormat.cyan)These ratios are order-of-magnitude only: a near-idle baseline")
            print("  varies substantially between runs on a loaded machine.\(ConsoleFormat.reset)")
        }
        print("")
    }

    /// "roughly 10x", "roughly 100x" — never a two-significant-figure claim
    /// that a single three-second window cannot support.
    static func orderOfMagnitude(_ ratio: Double) -> String {
        switch ratio {
        case ..<5: return "a few times"
        case ..<50: return "roughly 10x"
        case ..<500: return "roughly 100x"
        case ..<5000: return "roughly 1000x"
        default: return "more than 1000x"
        }
    }

    /// Where this machine's energy is going right now.
    ///
    /// Every verdict here comes from counters alone — none of these processes
    /// publishes a heartbeat the lab can read — so none of them can reach
    /// `known`, and the census below is deliberately dominated by
    /// `indeterminate`. That is the honest shape of the answer, not a gap to
    /// paper over.
    static func top(window: TimeInterval) -> Int32 {
        let report = EnergyObserver().report(window: window)
        guard !report.observed.isEmpty else {
            FileHandle.standardError.write(Data("mac-health: no processes could be sampled\n".utf8))
            return 70
        }

        print("\n\(ConsoleFormat.bold)Where the energy is going\(ConsoleFormat.reset)  (\(String(format: "%.1f", report.window))s window)")
        print(ConsoleFormat.rule())

        func pad(_ t: String, _ w: Int, right: Bool = false) -> String {
            let gap = max(w - t.count, 0)
            let spaces = String(repeating: " ", count: gap)
            return right ? spaces + t : t + spaces
        }

        print("  " + pad("process", 24) + pad("cycles/s", 15, right: true)
              + pad("share", 8, right: true) + "  " + pad("verdict", 15) + "confidence")
        for entry in report.topConsumers(12) {
            let d = entry.diagnosis
            print("  " + pad(String(entry.process.name.prefix(23)), 24)
                  + pad(String(format: "%.0f", entry.cyclesPerSecond), 15, right: true)
                  + pad(String(format: "%.1f%%", report.share(entry) * 100), 8, right: true)
                  + "  " + pad(d.pathology.rawValue, 15)
                  + "\(colour(for: d.pathology))\(d.confidence.rawValue)\(ConsoleFormat.reset)")
        }

        print("\n  \(ConsoleFormat.bold)Census\(ConsoleFormat.reset)")
        for entry in report.tally() {
            print("    \(pad(entry.pathology.rawValue, 16)) \(entry.count)")
        }
        if report.unreadable > 0 {
            print("\n  \(ConsoleFormat.cyan)\(report.unreadable) process(es) could not be sampled and are omitted")
            print("  rather than counted as idle — not readable is not the same as not working.\(ConsoleFormat.reset)")
        }
        print("\n  \(ConsoleFormat.yellow)None of these processes publishes a progress heartbeat, so no verdict")
        print("  here is settled. 'indeterminate' means the counters cannot separate a")
        print("  stuck process from a patient one — which is the truth, not a shortcoming.\(ConsoleFormat.reset)\n")
        return 0
    }

    static func watch(pid: Int32) -> Int32 {
        let sampler = KernelProcessSampler()
        guard let first = sampler.sample(pid: pid, now: Date()) else {
            FileHandle.standardError.write(Data(
                "mac-health: cannot read counters for pid \(pid) — it may have exited, or you may lack permission.\n".utf8))
            return 70
        }
        Thread.sleep(forTimeInterval: 2.0)
        guard let second = sampler.sample(pid: pid, now: Date()),
              let signature = EnergySignature.between(first, second) else {
            FileHandle.standardError.write(Data("mac-health: pid \(pid) went away during the observation window\n".utf8))
            return 70
        }

        let d = PathologyClassifier().classify(signature)
        let tint = colour(for: d.pathology)
        print("\n\(ConsoleFormat.bold)pid \(pid)\(ConsoleFormat.reset) over \(String(format: "%.1f", signature.window))s")
        print("  Verdict:     \(tint)\(ConsoleFormat.bold)\(d.pathology.rawValue)\(ConsoleFormat.reset) — \(d.pathology.headline(at: d.confidence))")
        print("  Confidence:  \(d.confidence.rawValue)")
        for line in d.evidence { print("    \(ConsoleFormat.cyan)·\(ConsoleFormat.reset) \(line)") }
        if let inquiry = d.inquiry {
            print("  \(ConsoleFormat.yellow)Open question:\(ConsoleFormat.reset) \(wrap(inquiry, indent: 4))")
        }
        print("")
        return 0
    }
}
