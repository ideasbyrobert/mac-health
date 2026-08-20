import Foundation
@testable import MacHealthKit

/// Serves recorded diagnostic-report text by path so attribution is exercised
/// against real report shapes instead of whatever happens to sit in
/// /Library/Logs/DiagnosticReports on the machine running the suite.
/// An unregistered path returns nil, which is exactly what an unreadable or
/// missing report looks like to the auditor.
final class FakeFileReader: FileReading {
    private(set) var requestedPaths: [String] = []
    private var byPath: [String: String] = [:]
    private var byFileName: [String: String] = [:]

    init() {}

    /// Registers report text under a full path.
    func stub(path: String, _ contents: String) {
        byPath[path] = contents
    }

    /// Registers report text under a bare file name, so a test does not have to
    /// repeat the directory the incident listing puts the report in.
    func stub(fileName: String, _ contents: String) {
        byFileName[fileName] = contents
    }

    func readPrefix(ofFileAt path: String, maxBytes: Int) -> String? {
        requestedPaths.append(path)
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        guard let contents = byPath[path] ?? byFileName[fileName] else { return nil }
        // Fixtures are ASCII, so truncating by character is the same truncation
        // the real reader performs by byte.
        return String(contents.prefix(maxBytes))
    }

    func wasAsked(for fragment: String) -> Bool {
        requestedPaths.contains { $0.contains(fragment) }
    }
}
