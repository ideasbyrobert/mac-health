import Foundation

public enum GPUIncidentKind: String, Codable {
    case gpuRestart
    case spin
    case panic
    case shutdownStall
    case other

    public init(fileName: String) {
        // Reports carry compound suffixes such as
        // "WindowServer_….userspace_watchdog_timeout.spin", so match the tail
        // rather than splitting on the first dot.
        if fileName.hasSuffix(".gpuRestart") { self = .gpuRestart }
        else if fileName.hasSuffix(".spin") { self = .spin }
        else if fileName.hasSuffix(".panic") { self = .panic }
        else if fileName.hasSuffix(".shutdownStall") { self = .shutdownStall }
        else { self = .other }
    }
}

/// A single diagnostic report, attributed to the GPU that produced it when the
/// report names its hardware.
public struct GPUIncident: Equatable {
    public let path: String
    public let fileName: String
    public let ageHours: Double
    public let kind: GPUIncidentKind
    /// Canonical device name from the machine's inventory, or the raw string
    /// the report used when it names hardware this machine does not list.
    public let attributedGPU: String?
    /// e.g. "VMPT" — the hardware channel that hung, from a gpuRestart report.
    public let restartChannel: String?
}

/// Turns raw report text into an attribution. The roadmap's rule is that no
/// mitigation is recommended without a diagnostic artifact naming the part, so
/// everything here is evidence read out of the report itself.
public enum GPUIncidentParser {

    /// Attribution only ever needs the report header; gpuRestart logs put the
    /// hardware name in the first ~400 bytes and panics in the leading JSON.
    public static let headerBytes = 16_384

    /// Driver-bundle families that appear in panic backtraces and driver state
    /// dumps when the report has no explicit `Graphics Hardware:` line.
    /// Each pattern must be graphics-specific. A bare "AppleIntel" would match
    /// AppleIntelPCH, AppleIntelLpssI2C and a long tail of unrelated Intel
    /// kexts, attributing an incident to the iGPU and inverting the mux
    /// recommendation on the strength of a coincidence. Intel's GPU kexts are
    /// named by generation (AppleIntelUHD630Graphics, AppleIntelICLGraphics,
    /// AppleIntelFramebufferController), so the family is matched by shape
    /// rather than by enumerating every model.
    private static let driverPatterns: [(pattern: String, vendor: String)] = [
        ("AMD(RadeonX|Navi|Framebuffer|MTLBronze)[A-Za-z0-9_]*", "AMD"),
        ("ATIRadeon[A-Za-z0-9_]*", "AMD"),
        ("AppleIntel[A-Za-z0-9]*(Graphics|Framebuffer|Accelerator)[A-Za-z0-9_]*", "Intel"),
        ("IntelAccelerator[A-Za-z0-9_]*", "Intel"),
        ("(AGXAccelerator|AGXG[0-9]|AppleParavirtGPU)[A-Za-z0-9_]*", "Apple"),
        ("(NVDAResman|nvAccelerator|GeForce)[A-Za-z0-9_]*", "NVIDIA")
    ]

    private static let compiledDriverPatterns: [(regex: NSRegularExpression, vendor: String)] = {
        driverPatterns.compactMap { entry in
            guard let re = try? NSRegularExpression(pattern: entry.pattern, options: [.caseInsensitive]) else { return nil }
            return (re, entry.vendor)
        }
    }()

    private static let vendorAliases: [(vendor: String, needles: [String])] = [
        ("AMD", ["amd", "radeon"]),
        ("Intel", ["intel"]),
        ("Apple", ["apple m", "apple gpu"]),
        ("NVIDIA", ["nvidia", "geforce", "quadro"])
    ]

    /// The value of `Graphics Hardware:` if the report carries one.
    public static func graphicsHardware(in header: String) -> String? {
        for raw in header.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("Graphics Hardware:") else { continue }
            let value = String(line.dropFirst("Graphics Hardware:".count))
                .trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// `Restart Channel: 18 VMPT` → "VMPT". This is the signature that
    /// distinguishes a page-table hang from an ordinary compute reset.
    public static func restartChannel(in header: String) -> String? {
        for raw in header.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("Restart Channel:") else { continue }
            let parts = String(line.dropFirst("Restart Channel:".count))
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            return parts.last
        }
        return nil
    }

    /// Attributes a report to one of the machine's GPUs.
    ///
    /// Evidence is used strongest-first: an explicit `Graphics Hardware:` line,
    /// then a verbatim device name anywhere in the header, then the vendor
    /// implied by a driver bundle in a panic backtrace. Returns nil when the
    /// report names no hardware — an unattributed incident must never be used
    /// to condemn a GPU.
    public static func attribute(header: String, knownGPUs: [GPUDevice]) -> String? {
        if let named = graphicsHardware(in: header) {
            return canonicalize(named, knownGPUs: knownGPUs) ?? named
        }
        for device in knownGPUs where header.range(of: device.name, options: .caseInsensitive) != nil {
            return device.name
        }
        // Pick the driver family that appears EARLIEST in the report rather than
        // the first entry of this array. The header is ordered fault-first, so
        // position is evidence; array order would simply mean AMD always beats
        // Intel on a dual-vendor machine no matter which driver actually faulted.
        var earliest: (offset: Int, vendor: String)?
        let full = NSRange(header.startIndex..., in: header)
        for entry in compiledDriverPatterns {
            guard let match = entry.regex.firstMatch(in: header, options: [], range: full) else { continue }
            let offset = match.range.location
            if earliest == nil || offset < earliest!.offset {
                earliest = (offset, entry.vendor)
            }
        }
        if let vendor = earliest?.vendor, let device = device(forVendor: vendor, in: knownGPUs) {
            return device.name
        }
        return nil
    }

    /// Report filenames embed the true incident time as `…_YYYY-MM-DD-HHMMSS_…`.
    /// This matters because macOS rewrites report mtimes in bulk — on the
    /// development machine twenty reports timestamped 05:54–06:08 all carry an
    /// mtime of 18:36 — so mtime is a filing date, not an incident time.
    public static func timestamp(fromFileName fileName: String, calendar: Calendar = .current) -> Date? {
        let digits = Array(fileName)
        // Scan for the first `dddd-dd-dd-dddddd` run.
        for start in 0..<max(0, digits.count - 16) {
            let slice = digits[start..<min(start + 17, digits.count)]
            let s = String(slice)
            guard s.count == 17 else { continue }
            let chars = Array(s)
            let isDigit: (Int) -> Bool = { chars[$0].isNumber }
            guard (0..<4).allSatisfy(isDigit), chars[4] == "-",
                  (5..<7).allSatisfy(isDigit), chars[7] == "-",
                  (8..<10).allSatisfy(isDigit), chars[10] == "-",
                  (11..<17).allSatisfy(isDigit) else { continue }
            var comps = DateComponents()
            comps.year = Int(String(chars[0..<4]))
            comps.month = Int(String(chars[5..<7]))
            comps.day = Int(String(chars[8..<10]))
            comps.hour = Int(String(chars[11..<13]))
            comps.minute = Int(String(chars[13..<15]))
            comps.second = Int(String(chars[15..<17]))
            return calendar.date(from: comps)
        }
        return nil
    }

    /// Maps a name a report used onto this machine's inventory, so
    /// "AMD Radeon Pro 5300M" and a driver-derived "AMD" collapse to one key.
    public static func canonicalize(_ reported: String, knownGPUs: [GPUDevice]) -> String? {
        for device in knownGPUs where device.name.caseInsensitiveCompare(reported) == .orderedSame {
            return device.name
        }
        for device in knownGPUs
        where reported.range(of: device.name, options: .caseInsensitive) != nil
            || device.name.range(of: reported, options: .caseInsensitive) != nil {
            return device.name
        }
        if let vendor = vendor(of: reported), let device = device(forVendor: vendor, in: knownGPUs) {
            return device.name
        }
        return nil
    }

    static func vendor(of name: String) -> String? {
        let lowered = name.lowercased()
        for alias in vendorAliases where alias.needles.contains(where: { lowered.contains($0) }) {
            return alias.vendor
        }
        return nil
    }

    /// Prefers the discrete part when a vendor ships both halves of a mux pair,
    /// which cannot happen on shipping Macs but keeps the choice deterministic.
    static func device(forVendor vendor: String, in knownGPUs: [GPUDevice]) -> GPUDevice? {
        let matches = knownGPUs.filter { self.vendor(of: $0.name) == vendor }
        return matches.first(where: { $0.isDiscrete }) ?? matches.first
    }
}
