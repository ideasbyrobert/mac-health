import Foundation

public struct GPUAuditor {
    /// Emitted by the listing command when the reports directory cannot be read,
    /// so "no incidents" and "no permission" stay distinguishable.
    static let unreadableMarker = "MACHEALTH_REPORTS_UNREADABLE"
    static let reportsDirectory = "/Library/Logs/DiagnosticReports"

    let shell: CommandRunning
    let reader: FileReading
    let inventory: GPUInventory
    let now: () -> Date

    public init(
        shell: CommandRunning = SystemShell(),
        reader: FileReading = SystemFileReader(),
        now: @escaping () -> Date = Date.init
    ) {
        self.shell = shell
        self.reader = reader
        self.inventory = GPUInventory(shell: shell)
        self.now = now
    }

    public func audit() -> GPUMetrics {
        let devices = inventory.devices()
        let scan = recentIncidents(knownGPUs: devices)
        let incidents = scan.incidents

        let active1h = incidents.filter { $0.ageHours < 1.0 }.count
        let historical24h = incidents.count
        let hoursSince = incidents.map(\.ageHours).min() ?? 999.0
        let latest = incidents.min { $0.ageHours < $1.ageHours }
        let latestName = latest?.fileName
        let latestTimeStr = latest.map { incident -> String in
            let df = DateFormatter()
            df.dateFormat = "h:mm a"
            return df.string(from: now().addingTimeInterval(-incident.ageHours * 3600.0))
        }

        var incidentsByGPU: [String: Int] = [:]
        var unattributed = 0
        // Only reports that are themselves GPU evidence may cast suspicion when
        // they name no hardware. A `.spin` or `.shutdownStall` is a stall — a
        // symptom that has many causes — so counting it as GPU blame would let
        // one unrelated shutdown hang recommend a mux change.
        var unattributedGPUEvidence = 0
        var channels: [String] = []
        for incident in incidents {
            if let gpu = incident.attributedGPU {
                incidentsByGPU[gpu, default: 0] += 1
            } else {
                unattributed += 1
                if incident.kind == .gpuRestart || incident.kind == .panic {
                    unattributedGPUEvidence += 1
                }
            }
            if let channel = incident.restartChannel, !channels.contains(channel) {
                channels.append(channel)
            }
        }

        // The worst offender by count; ties break alphabetically so the verdict
        // is stable across runs.
        let faultingGPU = incidentsByGPU
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .first?.key
        let faultingIsDiscrete = faultingGPU.map { Self.isDiscrete($0, in: devices) } ?? false

        let faultingDiscrete = incidentsByGPU.keys.contains { Self.isDiscrete($0, in: devices) }
        let faultingIntegrated = incidentsByGPU.keys.contains { !Self.isDiscrete($0, in: devices) }

        let onACPower = shell.run("pmset -g batt").output.contains("AC Power")
        let gpuSwitchVal = Self.gpuSwitchValue(from: shell.run("pmset -g custom").output, onACPower: onACPower)
        let mux = Self.muxVerdict(
            gpuSwitchValue: gpuSwitchVal,
            faultingDiscrete: faultingDiscrete,
            faultingIntegrated: faultingIntegrated,
            unattributedGPUEvidence: scan.available ? unattributedGPUEvidence : 0,
            hasDiscreteGPU: devices.contains(where: \.isDiscrete)
        )

        let status: String
        if !scan.available {
            status = "INCIDENT_SCAN_UNAVAILABLE"
        } else if active1h > 0 {
            status = "ACTIVE_HANGS_LAST_HOUR"
        } else if historical24h > 0 && hoursSince < 24.0 {
            status = "HISTORICAL_PANICS_RECORDED"
        } else if !mux.safe {
            status = "DYNAMIC_SWITCHING_UNSAFE"
        } else {
            status = "STABLE"
        }

        return GPUMetrics(
            activeIncidentsLastHour: active1h,
            historicalIncidents24h: historical24h,
            hoursSinceLastCrash: hoursSince,
            gpuSwitchMode: mux.mode,
            gpuSwitchSafe: mux.safe,
            status: status,
            latestIncidentName: latestName,
            latestIncidentTime: latestTimeStr,
            installedGPUs: devices,
            incidentsByGPU: incidentsByGPU,
            unattributedIncidents: unattributed,
            faultingGPU: faultingGPU,
            faultingGPUIsDiscrete: faultingIsDiscrete,
            restartChannels: channels,
            incidentScanAvailable: scan.available
        )
    }

    /// Unknown hardware defaults to discrete: it is the part that fails this way
    /// on the overwhelming majority of affected machines, and it is the reading
    /// whose mitigation (park the dGPU) is the safe direction to be wrong in.
    static func isDiscrete(_ name: String, in devices: [GPUDevice]) -> Bool {
        devices.first { $0.name == name }?.isDiscrete ?? true
    }

    /// Lists the last 24h of GPU-relevant reports and asks each one which
    /// hardware it blames. `available` is false when the reports directory
    /// cannot be read at all — a standard (non-admin) user is not in the
    /// `_analyticsusers` group that owns it, and silently reporting a clean
    /// bill of health on a machine that is actively crashing would be the
    /// worst failure this tool could have.
    func recentIncidents(knownGPUs: [GPUDevice]) -> (incidents: [GPUIncident], available: Bool) {
        let find = "find \(Self.reportsDirectory)/ -type f \\( -name \"*.gpuRestart\" -o -name \"*.spin\" -o -name \"*.panic\" -o -name \"*.shutdownStall\" \\) -mtime -1 -exec stat -f \"%m %N\" {} \\; 2>/dev/null | sort -rn"
        let logsCmd = "if [ -r '\(Self.reportsDirectory)' ]; then \(find); else echo '\(Self.unreadableMarker)'; fi"
        let logsOut = shell.run(logsCmd).output

        if logsOut.contains(Self.unreadableMarker) {
            return ([], false)
        }

        let nowDate = now()
        let nowSeconds = nowDate.timeIntervalSince1970
        var incidents: [GPUIncident] = []
        for line in logsOut.components(separatedBy: "\n") where !line.isEmpty {
            // Split on the first space only — report filenames can contain spaces.
            guard let sep = line.firstIndex(of: " "), let mtime = Double(line[..<sep]) else { continue }
            let path = String(line[line.index(after: sep)...])
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            let header = reader.readPrefix(ofFileAt: path, maxBytes: GPUIncidentParser.headerBytes) ?? ""

            incidents.append(
                GPUIncident(
                    path: path,
                    fileName: fileName,
                    ageHours: Self.ageHours(fileName: fileName, mtime: mtime, now: nowDate, nowSeconds: nowSeconds),
                    kind: GPUIncidentKind(fileName: fileName),
                    attributedGPU: header.isEmpty
                        ? nil
                        : GPUIncidentParser.attribute(header: header, knownGPUs: knownGPUs),
                    restartChannel: header.isEmpty ? nil : GPUIncidentParser.restartChannel(in: header)
                )
            )
        }
        return (incidents, true)
    }

    /// Prefers the incident time embedded in the report filename over the file's
    /// mtime, which macOS rewrites in bulk. The filename is only trusted when it
    /// agrees with reality — not in the future, not more than 30 days old — so a
    /// skewed or unparsed name falls back to mtime instead of poisoning the age.
    static func ageHours(fileName: String, mtime: Double, now: Date, nowSeconds: Double) -> Double {
        let fromMtime = (nowSeconds - mtime) / 3600.0
        guard let stamped = GPUIncidentParser.timestamp(fromFileName: fileName) else { return fromMtime }
        let fromName = (nowSeconds - stamped.timeIntervalSince1970) / 3600.0
        guard fromName >= 0, fromName <= 24.0 * 30.0 else { return fromMtime }
        return fromName
    }

    /// `pmset -g custom` prints a "Battery Power:" block and an "AC Power:"
    /// block, each with its own gpuswitch. Taking the first match always
    /// returned the battery value, which can be the opposite of the mode the
    /// machine is actually in. Machines without a switchable mux (Apple Silicon,
    /// single-GPU Intel) have no gpuswitch key at all; -1 stands for "absent".
    public static func gpuSwitchValue(from pmsetCustom: String, onACPower: Bool) -> Int {
        var batteryValue: Int?
        var acValue: Int?
        var inACBlock = false

        for rawLine in pmsetCustom.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("AC Power:") { inACBlock = true; continue }
            if line.hasPrefix("Battery Power:") { inACBlock = false; continue }
            guard line.contains("gpuswitch") else { continue }
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2, let val = Int(parts[1]) else { continue }
            if inACBlock { acValue = acValue ?? val } else { batteryValue = batteryValue ?? val }
        }

        let preferred = onACPower ? acValue : batteryValue
        return preferred ?? acValue ?? batteryValue ?? -1
    }

    /// Evidence-based mux safety. A mode is unsafe only when it engages a GPU
    /// this machine's own reports have blamed in the last 24h — so a healthy
    /// dual-GPU Mac stays green in every mode, and a machine whose *integrated*
    /// part is faulting is told to leave the discrete GPU on rather than being
    /// handed the AMD-specific advice this project started with.
    ///
    /// GPU-shaped reports that name no hardware fall back to suspecting the
    /// discrete GPU, but only on a machine that actually has one.
    public static func muxVerdict(
        gpuSwitchValue: Int,
        faultingDiscrete: Bool,
        faultingIntegrated: Bool,
        unattributedGPUEvidence: Int,
        hasDiscreteGPU: Bool
    ) -> (mode: String, safe: Bool) {
        let suspectDiscrete = (faultingDiscrete || unattributedGPUEvidence > 0) && hasDiscreteGPU

        switch gpuSwitchValue {
        case -1:
            return ("No switchable mux (Apple Silicon / single-GPU)", true)
        case 0:
            // Integrated only: the discrete GPU is parked, so only a faulting
            // integrated GPU makes this mode unsafe.
            return faultingIntegrated
                ? ("Integrated Only (Faulting iGPU Engaged!)", false)
                : ("Integrated Only (discrete GPU kept idle)", true)
        case 1:
            return suspectDiscrete
                ? ("Discrete Only (Faulting dGPU Engaged!)", false)
                : ("Discrete Only (dGPU forced)", true)
        default:
            // Dynamic switching engages both parts, so either one faulting is
            // enough to make the mode unsafe.
            return (suspectDiscrete || faultingIntegrated)
                ? ("Dynamic Switching (Faulting GPU Engaged!)", false)
                : ("Dynamic Switching", true)
        }
    }
}
