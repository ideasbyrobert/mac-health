import Foundation

/// Something that can hold or wait for a resource: a thread inside a process,
/// or a whole process when the lab can only see process granularity.
public struct Actor: Hashable, Codable, Sendable {
    public let pid: Int32
    /// nil when the observation is only process-granular.
    public let threadID: UInt64?
    public let label: String

    public init(pid: Int32, threadID: UInt64? = nil, label: String) {
        self.pid = pid
        self.threadID = threadID
        self.label = label
    }

    public var id: String { threadID.map { "\(pid).\($0)" } ?? "\(pid)" }
}

/// The synchronisation primitive an actor is blocked on. These are the OS's
/// gates: each one is a condition that must become true before the waiter may
/// proceed, which is exactly the methodology's gate semantics.
public enum Gate: Hashable, Codable, Sendable {
    case mutex(String)
    case semaphore(String)
    case conditionVariable(String)
    /// A pipe or socket whose buffer is full (writer blocked) or empty
    /// (reader blocked). This is the primitive behind the deadlock this very
    /// codebase shipped in SystemShell.
    case pipe(String)
    case fileDescriptor(String)
    /// Work controlled outside this process entirely — the methodology's
    /// "external process". Never the waiter's fault, and never something the
    /// waiter can resolve on its own.
    case externalProcess(String)

    public var sfSymbol: String {
        switch self {
        case .mutex: return "lock.fill"
        case .semaphore: return "signpost.right.fill"
        case .conditionVariable: return "bell.badge.fill"
        case .pipe: return "cylinder.split.1x2.fill"
        case .fileDescriptor: return "doc.badge.gearshape.fill"
        case .externalProcess: return "cloud.fill"
        }
    }

    public var name: String {
        switch self {
        case .mutex(let n), .semaphore(let n), .conditionVariable(let n),
             .pipe(let n), .fileDescriptor(let n), .externalProcess(let n):
            return n
        }
    }
}

/// "`waiter` cannot proceed until `holder` releases `gate`."
///
/// The same directed claim the methodology makes about strategy nodes:
/// `prerequisite → dependent`. Here the prerequisite is a release.
public struct WaitEdge: Hashable, Codable, Sendable {
    public let waiter: Actor
    public let holder: Actor
    public let gate: Gate

    public init(waiter: Actor, holder: Actor, gate: Gate) {
        self.waiter = waiter
        self.holder = holder
        self.gate = gate
    }
}

/// A cycle in the wait-for graph: every actor in the ring is waiting on the
/// next, so none of them can ever proceed. This is a deadlock, stated exactly.
public struct DeadlockCycle: Codable, Sendable {
    public let edges: [WaitEdge]

    public init(edges: [WaitEdge]) { self.edges = edges }

    public var actors: [Actor] { edges.map(\.waiter) }

    /// "T1 —(mutex A)→ T2 —(mutex B)→ T1"
    public func describe() -> String {
        guard let first = edges.first else { return "empty cycle" }
        var parts = [first.waiter.label]
        for edge in edges {
            parts.append("—(\(edge.gate.name))→ \(edge.holder.label)")
        }
        return parts.joined(separator: " ")
    }
}

/// The OS's dependency graph, built from wait edges and checked for the one
/// defect that makes forward progress impossible.
///
/// The methodology's central invariant is that the union of non-rejected
/// dependencies stays acyclic, and that a cycle must be rejected with the
/// existing path identified. An operating system cannot reject the edge — the
/// thread has already blocked — so the same algorithm becomes a detector
/// instead of a validator. That is the whole relationship between the two:
/// **a strategy validator run forwards is a deadlock detector run backwards.**
public struct WaitForGraph: Sendable {
    public private(set) var edges: [WaitEdge] = []

    public init(edges: [WaitEdge] = []) { self.edges = edges }

    public mutating func add(_ edge: WaitEdge) { edges.append(edge) }

    /// Adjacency by actor id, preserving insertion order so the reported cycle
    /// is stable across runs.
    private func adjacency() -> [String: [WaitEdge]] {
        var out: [String: [WaitEdge]] = [:]
        for edge in edges { out[edge.waiter.id, default: []].append(edge) }
        return out
    }

    /// Every distinct wait-for cycle currently present.
    ///
    /// Depth-first search over the adjacency structure, exactly the reachability
    /// check the methodology specifies for edge insertion. A cycle is recorded
    /// once, keyed by its canonical rotation, so the same ring found from two
    /// different entry points is not reported twice.
    public func deadlocks() -> [DeadlockCycle] {
        let adjacency = self.adjacency()
        var colour: [String: Int] = [:]   // 0 unvisited, 1 on stack, 2 done
        var stack: [WaitEdge] = []
        var found: [String: DeadlockCycle] = [:]

        func visit(_ actorID: String) {
            colour[actorID] = 1
            for edge in adjacency[actorID] ?? [] {
                let next = edge.holder.id
                stack.append(edge)
                switch colour[next] ?? 0 {
                case 0:
                    visit(next)
                case 1:
                    // Found a back edge: the ring runs from `next` around to here.
                    if let start = stack.firstIndex(where: { $0.waiter.id == next }) {
                        let ring = Array(stack[start...])
                        found[Self.canonicalKey(ring)] = DeadlockCycle(edges: ring)
                    }
                default:
                    break
                }
                stack.removeLast()
            }
            colour[actorID] = 2
        }

        for id in adjacency.keys.sorted() where (colour[id] ?? 0) == 0 {
            visit(id)
        }
        return found.keys.sorted().compactMap { found[$0] }
    }

    /// A ring has as many representations as it has members; rotate to the
    /// smallest actor id so all of them collapse to one key.
    static func canonicalKey(_ ring: [WaitEdge]) -> String {
        let ids = ring.map(\.waiter.id)
        guard let pivot = ids.indices.min(by: { ids[$0] < ids[$1] }) else { return "" }
        let rotated = Array(ids[pivot...] + ids[..<pivot])
        return rotated.joined(separator: "→")
    }

    /// Actors that are blocked but not deadlocked — waiting on something that
    /// can still arrive. The methodology's "Waiting on external process".
    public func blockedButLive() -> [WaitEdge] {
        let doomed = Set(deadlocks().flatMap { $0.edges })
        return edges.filter { !doomed.contains($0) }
    }

    /// The run queue: actors that hold resources and wait on nothing. In the
    /// methodology's terms this is the strategic frontier — the exact boundary
    /// between what the machine currently permits and what it does not.
    public func frontier(among all: [Actor]) -> [Actor] {
        let waiting = Set(edges.map(\.waiter.id))
        return all.filter { !waiting.contains($0.id) }
    }
}
