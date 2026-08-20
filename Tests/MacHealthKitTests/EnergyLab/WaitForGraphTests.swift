import Testing
import Foundation
@testable import EnergyLab

/// The wait-for graph is the load-bearing piece of the lab: it is the one place
/// where a deadlock is *proved* rather than inferred from counters. These tests
/// pin the cycle detector, its de-duplication, and the frontier it derives.
struct WaitForGraphTests {

    // MARK: two-actor rings

    @Test func twoActorCycleIsDetected() {
        let t1 = thread("T1", 1)
        let t2 = thread("T2", 2)
        let graph = WaitForGraph(edges: [
            waits(t1, on: t2, .mutex("A")),
            waits(t2, on: t1, .mutex("B"))
        ])

        let cycles = graph.deadlocks()
        #expect(cycles.count == 1)
        #expect(Set(cycles[0].actors.map(\.label)) == ["T1", "T2"])
        #expect(cycles[0].edges.count == 2)
    }

    /// Lock-order inversion is the textbook shape, and it is what the
    /// `deadlock` chaos worker constructs by hand.
    @Test func lockOrderInversionClosesTheRing() {
        let t1 = thread("T1", 1)
        let t2 = thread("T2", 2)
        let graph = WaitForGraph(edges: [
            waits(t1, on: t2, .mutex("second")),
            waits(t2, on: t1, .mutex("first"))
        ])

        let gates = graph.deadlocks().flatMap { $0.edges.map(\.gate.name) }
        #expect(Set(gates) == ["first", "second"])
    }

    // MARK: longer rings

    @Test func threeActorCycleIsDetected() {
        let t1 = thread("T1", 1)
        let t2 = thread("T2", 2)
        let t3 = thread("T3", 3)
        let graph = WaitForGraph(edges: [
            waits(t1, on: t2, .mutex("A")),
            waits(t2, on: t3, .mutex("B")),
            waits(t3, on: t1, .mutex("C"))
        ])

        let cycles = graph.deadlocks()
        #expect(cycles.count == 1)
        #expect(cycles[0].edges.count == 3)
        #expect(Set(cycles[0].actors.map(\.label)) == ["T1", "T2", "T3"])
    }

    @Test func selfEdgeIsACycle() {
        let t1 = thread("T1", 1)
        let graph = WaitForGraph(edges: [waits(t1, on: t1, .mutex("recursive"))])

        let cycles = graph.deadlocks()
        #expect(cycles.count == 1)
        #expect(cycles[0].actors == [t1])
    }

    // MARK: acyclic graphs

    @Test func acyclicChainReportsNoDeadlock() {
        let a = thread("A", 1)
        let b = thread("B", 2)
        let c = thread("C", 3)
        let graph = WaitForGraph(edges: [
            waits(a, on: b, .mutex("A")),
            waits(b, on: c, .semaphore("B"))
        ])

        #expect(graph.deadlocks().isEmpty)
    }

    /// Two paths that reconverge are not a cycle. The distinction matters
    /// because a naive "have I seen this node" check would call this a
    /// deadlock; only a node still on the DFS stack closes a ring.
    @Test func diamondIsAcyclic() {
        let a = thread("A", 1)
        let b = thread("B", 2)
        let c = thread("C", 3)
        let d = thread("D", 4)
        let graph = WaitForGraph(edges: [
            waits(a, on: b, .mutex("ab")),
            waits(a, on: c, .mutex("ac")),
            waits(b, on: d, .mutex("bd")),
            waits(c, on: d, .mutex("cd"))
        ])

        #expect(graph.deadlocks().isEmpty)
        #expect(graph.blockedButLive().count == 4)
    }

    @Test func emptyGraphHasNoDeadlocks() {
        #expect(WaitForGraph().deadlocks().isEmpty)
        #expect(WaitForGraph().blockedButLive().isEmpty)
    }

    // MARK: several rings at once

    @Test func twoIndependentCyclesAreBothReported() {
        let t1 = thread("T1", 1)
        let t2 = thread("T2", 2)
        let t3 = thread("T3", 3)
        let t4 = thread("T4", 4)
        let graph = WaitForGraph(edges: [
            waits(t1, on: t2, .mutex("A")),
            waits(t2, on: t1, .mutex("B")),
            waits(t3, on: t4, .pipe("stdout")),
            waits(t4, on: t3, .externalProcess("swift build"))
        ])

        let rings = graph.deadlocks().map { Set($0.actors.map(\.label)) }
        #expect(rings.count == 2)
        #expect(rings.contains(["T1", "T2"]))
        #expect(rings.contains(["T3", "T4"]))
    }

    // MARK: de-duplication

    /// The same ring can be closed by more than one back edge. It is one
    /// deadlock, so it must be reported once; that is the whole reason
    /// `canonicalKey` exists.
    @Test func oneRingClosedByTwoGatesIsReportedOnce() {
        let t1 = thread("T1", 1)
        let t2 = thread("T2", 2)
        let graph = WaitForGraph(edges: [
            waits(t1, on: t2, .mutex("A")),
            waits(t2, on: t1, .mutex("B")),
            waits(t2, on: t1, .semaphore("tokens"))
        ])

        #expect(graph.deadlocks().count == 1)
    }

    /// Entering the ring from an outside actor must not produce a second copy
    /// of it, and must not drag the outsider into the ring: that actor is
    /// blocked, not deadlocked.
    @Test func ringReachedFromOutsideIsStillOneCycleWithoutTheOutsider() {
        let outsider = thread("X", 0)
        let t1 = thread("T1", 1)
        let t2 = thread("T2", 2)
        let graph = WaitForGraph(edges: [
            waits(outsider, on: t1, .mutex("A")),
            waits(t1, on: t2, .mutex("B")),
            waits(t2, on: t1, .mutex("C"))
        ])

        let cycles = graph.deadlocks()
        #expect(cycles.count == 1)
        #expect(Set(cycles[0].actors.map(\.label)) == ["T1", "T2"])
        #expect(graph.blockedButLive().map(\.waiter.label) == ["X"])
    }

    @Test func rotationsOfARingShareOneCanonicalKey() {
        let t1 = thread("T1", 1)
        let t2 = thread("T2", 2)
        let t3 = thread("T3", 3)
        let e12 = waits(t1, on: t2, .mutex("A"))
        let e23 = waits(t2, on: t3, .mutex("B"))
        let e31 = waits(t3, on: t1, .mutex("C"))

        let fromT1 = WaitForGraph.canonicalKey([e12, e23, e31])
        #expect(WaitForGraph.canonicalKey([e23, e31, e12]) == fromT1)
        #expect(WaitForGraph.canonicalKey([e31, e12, e23]) == fromT1)
        #expect(fromT1 == "\(labPID).1→\(labPID).2→\(labPID).3")
    }

    @Test func differentRingsGetDifferentCanonicalKeys() {
        let t1 = thread("T1", 1)
        let t2 = thread("T2", 2)
        let t3 = thread("T3", 3)
        let t4 = thread("T4", 4)
        let first = [waits(t1, on: t2, .mutex("A")), waits(t2, on: t1, .mutex("B"))]
        let second = [waits(t3, on: t4, .mutex("A")), waits(t4, on: t3, .mutex("B"))]

        #expect(WaitForGraph.canonicalKey(first) != WaitForGraph.canonicalKey(second))
    }

    @Test func canonicalKeyOfAnEmptyRingIsEmpty() {
        #expect(WaitForGraph.canonicalKey([]) == "")
    }

    // MARK: separating the doomed from the merely waiting

    /// The methodology's distinction between a rejected dependency and
    /// "Waiting on external process": one can never resolve, the other is
    /// simply not resolved yet.
    @Test func deadlockedAndLiveWaitersAreSeparated() {
        let t1 = thread("T1", 1)
        let t2 = thread("T2", 2)
        let t3 = thread("T3", 3)
        let t4 = thread("T4", 4)
        let live = waits(t3, on: t4, .externalProcess("xcodebuild"))
        let graph = WaitForGraph(edges: [
            waits(t1, on: t2, .mutex("A")),
            waits(t2, on: t1, .mutex("B")),
            live
        ])

        #expect(graph.deadlocks().count == 1)
        #expect(graph.blockedButLive() == [live])
    }

    @Test func withoutACycleEveryWaiterIsLive() {
        let a = thread("A", 1)
        let b = thread("B", 2)
        let graph = WaitForGraph(edges: [waits(a, on: b, .conditionVariable("work ready"))])

        #expect(graph.blockedButLive().count == 1)
        #expect(graph.blockedButLive()[0].gate.name == "work ready")
    }

    // MARK: the frontier

    /// The strategic frontier, in an operating system, is the run queue:
    /// exactly those actors that wait on nothing.
    @Test func frontierIsTheActorsWaitingOnNothing() {
        let t1 = thread("T1", 1)
        let t2 = thread("T2", 2)
        let t3 = thread("T3", 3)
        let t4 = thread("T4", 4)
        let graph = WaitForGraph(edges: [
            waits(t1, on: t2, .mutex("A")),
            waits(t2, on: t1, .mutex("B")),
            waits(t3, on: t4, .pipe("stdout"))
        ])

        #expect(graph.frontier(among: [t1, t2, t3, t4]) == [t4])
    }

    @Test func emptyGraphPutsEveryActorOnTheFrontier() {
        let all = [thread("T1", 1), thread("T2", 2), thread("T3", 3)]
        #expect(WaitForGraph().frontier(among: all) == all)
    }

    @Test func anActorHoldingAndWaitingIsNotOnTheFrontier() {
        let holder = thread("holder", 1)
        let middle = thread("middle", 2)
        let tail = thread("tail", 3)
        let graph = WaitForGraph(edges: [
            waits(middle, on: holder, .mutex("A")),
            waits(tail, on: middle, .mutex("B"))
        ])

        #expect(graph.frontier(among: [holder, middle, tail]) == [holder])
    }

    // MARK: mutation and description

    @Test func addAppendsAnEdgeAndCanCloseARing() {
        let t1 = thread("T1", 1)
        let t2 = thread("T2", 2)
        var graph = WaitForGraph()
        graph.add(waits(t1, on: t2, .mutex("A")))
        #expect(graph.deadlocks().isEmpty)

        graph.add(waits(t2, on: t1, .mutex("B")))
        #expect(graph.edges.count == 2)
        #expect(graph.deadlocks().count == 1)
    }

    @Test func describeNamesEveryActorInTheRing() {
        let t1 = thread("T1", 1)
        let t2 = thread("T2", 2)
        let t3 = thread("T3", 3)
        let graph = WaitForGraph(edges: [
            waits(t1, on: t2, .mutex("alpha")),
            waits(t2, on: t3, .mutex("beta")),
            waits(t3, on: t1, .mutex("gamma"))
        ])

        let text = graph.deadlocks()[0].describe()
        #expect(text.contains("T1"))
        #expect(text.contains("T2"))
        #expect(text.contains("T3"))
        #expect(text.contains("alpha"))
        #expect(text.contains("beta"))
        #expect(text.contains("gamma"))
    }

    @Test func describeOfAnEmptyCycleSaysSo() {
        #expect(DeadlockCycle(edges: []).describe() == "empty cycle")
        #expect(DeadlockCycle(edges: []).actors.isEmpty)
    }

    // MARK: identity and encoding

    /// Process-granular observations carry no thread id, so two processes must
    /// still be told apart, and a thread must not collide with its own process.
    @Test func actorIDDistinguishesProcessFromThread() {
        #expect(Actor(pid: 501, label: "proc").id == "501")
        #expect(Actor(pid: 501, threadID: 7, label: "thread").id == "501.7")
        #expect(Actor(pid: 501, label: "a").id != Actor(pid: 502, label: "b").id)
    }

    @Test func everyGateHasANameAndASymbol() {
        let gates: [Gate] = [
            .mutex("m"), .semaphore("s"), .conditionVariable("c"),
            .pipe("p"), .fileDescriptor("fd"), .externalProcess("x")
        ]
        for gate in gates {
            #expect(!gate.name.isEmpty)
            #expect(!gate.sfSymbol.isEmpty)
        }
        #expect(Set(gates.map(\.sfSymbol)).count == gates.count)
    }

    @Test func waitEdgeSurvivesACodableRoundTrip() throws {
        let edge = waits(thread("T1", 1), on: thread("T2", 2), .pipe("stdout"))
        let data = try JSONEncoder().encode(edge)
        let decoded = try JSONDecoder().decode(WaitEdge.self, from: data)
        #expect(decoded == edge)
        #expect(decoded.gate.name == "stdout")
    }
}

// MARK: helpers

/// One process, several threads: the granularity a real deadlock lives at.
private let labPID: Int32 = 501

/// Explicit thread ids keep actor ids, and therefore canonical keys, stable
/// across runs — a hashed id would make the key assertions flaky.
private func thread(_ label: String, _ threadID: UInt64) -> Actor {
    Actor(pid: labPID, threadID: threadID, label: label)
}

private func waits(_ waiter: Actor, on holder: Actor, _ gate: Gate) -> WaitEdge {
    WaitEdge(waiter: waiter, holder: holder, gate: gate)
}
