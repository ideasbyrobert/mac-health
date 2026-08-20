import Foundation

/// How strongly the lab is entitled to state a claim.
///
/// Taken directly from the continuity methodology: "Confidence is not
/// decoration. It determines how strongly the system may present a claim and
/// whether it is allowed to control execution." A pathology observed through an
/// instrumented worker that reports its own wait edges is *known*; the same
/// pathology inferred from counters alone is at best *probable*, because many
/// causes produce one signature.
public enum Confidence: String, Codable, Comparable, CaseIterable, Sendable {
    /// The record does not yet support a conclusion.
    case unknown
    /// A reading is live but weakly supported.
    case possible
    /// The best current explanation, still unproved.
    case probable
    /// Sufficient evidence for the lab's declared standard: the process
    /// reported the edge itself, or the counters are unambiguous.
    case known

    private var rank: Int {
        switch self {
        case .unknown: return 0
        case .possible: return 1
        case .probable: return 2
        case .known: return 3
        }
    }

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.rank < rhs.rank
    }

    /// A claim may drive an automatic action only when it is fully evidenced.
    /// Anything weaker may be shown and explained, never acted on.
    public var mayDriveAction: Bool { self == .known }

    public var sfSymbol: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .possible: return "circle.dotted"
        case .probable: return "circle.lefthalf.filled"
        case .known: return "checkmark.seal.fill"
        }
    }
}

/// A claim the lab makes, carrying the evidence that supports it. Nothing in
/// the UI or the CLI prints a conclusion without one of these behind it.
public struct Claim<Value>: Sendable where Value: Sendable {
    public let value: Value
    public let confidence: Confidence
    /// What was actually observed, in the user's terms — a counter reading, a
    /// reported wait edge, a missing measurement.
    public let evidence: [String]

    public init(_ value: Value, confidence: Confidence, evidence: [String]) {
        self.value = value
        self.confidence = confidence
        self.evidence = evidence
    }
}
