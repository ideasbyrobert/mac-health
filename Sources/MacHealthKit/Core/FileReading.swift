import Foundation

/// Abstraction over reading diagnostic reports off disk, so incident
/// attribution can be exercised against recorded report text in tests.
public protocol FileReading {
    /// Returns at most `maxBytes` from the head of the file, or nil when the
    /// file is unreadable. Reports are ~90 KB each and every field used for
    /// attribution sits in the header, so callers only ever ask for a prefix.
    func readPrefix(ofFileAt path: String, maxBytes: Int) -> String?
}

public struct SystemFileReader: FileReading {
    public init() {}

    public func readPrefix(ofFileAt path: String, maxBytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else { return nil }
        // Reports are ASCII, but a prefix can split a multi-byte sequence and
        // panic logs embed raw hex dumps, so decode leniently rather than
        // dropping an otherwise perfectly attributable report.
        return String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
    }
}
