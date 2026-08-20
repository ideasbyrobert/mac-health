import SwiftUI
import EnergyLab

/// What the operating system is doing while nobody watches, and why it is worth
/// admiring rather than fearing.
///
/// Every principle here is anchored to a figure the lab actually measured, so
/// none of it has to be taken on faith. Where a number is general knowledge
/// rather than something this machine reported, it says so.
struct PrinciplesView: View {

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Principles")
                        .font(.system(size: 26, weight: .semibold, design: .serif))
                    Prose("A modern machine runs thousands of threads on a handful of cores, hands each of them the illusion of a private processor, takes that processor back thousands of times a second without any of them noticing, and still finds enough quiet moments to put the hardware to sleep between your keystrokes. Almost all of that works. These pages are about how — and about the small number of ways a program can decline the help.",
                          font: Theme.proseLead)
                }

                ForEach(Array(Principle.all.enumerated()), id: \.offset) { entry in
                    PrincipleCard(principle: entry.element)
                }

                Card("One algorithm, two directions", symbol: "arrow.triangle.branch", tint: Theme.dusk) {
                    VStack(alignment: .leading, spacing: 12) {
                        Prose("A plan is valid when the union of everything it depends on stays acyclic: no piece of work may be, however indirectly, its own prerequisite. Run that check forwards, before an edge is added, and it is a strategy validator — the edge that would close a ring gets rejected and the existing path named.")
                        Prose("Run the same check backwards, over edges that already exist because threads have already blocked, and it is a deadlock detector. The operating system cannot reject the edge; the thread is committed. So the same depth-first search that would have prevented the cycle can now only report it. That is the whole relationship, and it is why this lab has one graph type rather than two.")
                        Prose("The rest follows the same way. A gate is a condition that must hold before work may proceed, whether it is a mutex or a signed contract. The frontier is whatever is waiting on nothing, which in an operating system has a name already: the run queue. And confidence is not decoration — a claim the lab merely infers may be shown and explained, but only a claim it can prove is allowed to act.")
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - the principles

struct Principle {
    let title: String
    /// Symbols that carry the idea. Where a pathology or a gate already has a
    /// symbol declared on its own type, that one is used.
    let symbols: [String]
    let tint: Color
    let prose: String
    let figure: String
    let unit: String
    let figureName: String
    /// The measurement the principle rests on, in the user's terms.
    let grounding: String

    static let all: [Principle] = [
        Principle(
            title: "Time-sharing and preemption",
            symbols: ["rectangle.split.3x1.fill"],
            tint: Theme.dusk,
            prose: "No thread decides when it stops. A timer interrupt arrives, the kernel takes the core back, and hands it to whichever runnable thread is next in line. Every thread is left with the impression that it had the processor the whole time. This is the single mechanism that keeps one badly behaved program from taking the machine with it.",
            figure: "99.36", unit: "% CPU", figureName: "spin loop",
            grounding: "The spinning worker held a core at full clock for the entire window and never once yielded. It did not have to be asked: five other workers ran alongside it, the lab kept sampling, and the window kept drawing."
        ),
        Principle(
            title: "What a context switch costs",
            symbols: ["arrow.left.arrow.right"],
            tint: Theme.slate,
            prose: "Switching threads means saving registers, swapping stacks, and then paying the quieter half of the bill: the next thread has to refill the caches and address translations the previous one evicted. The direct cost is on the order of a few thousand cycles — that figure is general knowledge, not something this lab measured — and the disturbance to cache is often the larger part. None of it appears in CPU percentage.",
            figure: "30,599", unit: "cycles", figureName: "one unit of work",
            grounding: "That is the blocking-wait worker's entire measured cost for one work unit: 152,996 cycles a second, five units a second. Parking a thread and waking it again fits comfortably inside that. Blocking is affordable precisely because the switch is cheap relative to the work being waited for."
        ),
        Principle(
            title: "Process and thread",
            symbols: [Gate.mutex("").sfSymbol, Gate.pipe("").sfSymbol],
            tint: Theme.ochre,
            prose: "Threads in one process share an address space, so a mutex between them is just a word in memory they can both reach. Separate processes share nothing by default, so anything passed between them has to go through the kernel — a pipe, a socket, a file. The isolation is the point: a process is the unit the system can lose without losing the others.",
            figure: "0.00", unit: "% CPU", figureName: "both deadlocks",
            grounding: "The two-thread lock-order deadlock and the two-process pipe deadlock produced identical counters. Only the gate differed: a mutex in shared memory in one case, roughly 64 KB of kernel pipe buffer in the other. Both closed the same ring. A deadlock is a property of the graph, not of the primitive — though the lab could prove only the first of them, and reports the second as probable."
        ),
        Principle(
            title: "Why blocking is cheaper than polling",
            symbols: [Pathology.idleWaiting.sfSymbol, Pathology.wakeupStorm.sfSymbol],
            tint: Theme.amber,
            prose: "Two workers, the same output, two ways of finding out that work has arrived. One asks the kernel to remove it from the run queue until an event arrives. The other wakes up on a timer and asks. Asking is the expensive part, and the cost lands somewhere CPU percentage barely reports — which is how this pathology survives code review.",
            figure: "roughly 100x", unit: "", figureName: "the cycles, same job",
            grounding: "152,996 cycles a second for the blocking wait against 21,746,369 for the poll, for identical completed work. CPU percentage moved only from 0.01 to 1.29. Order of magnitude is all a three-second window supports, and all that is needed."
        ),
        Principle(
            title: "C-states, and what a wakeup denies",
            symbols: ["powersleep"],
            tint: Theme.sage,
            prose: "An idle processor package does not simply stop. It descends through progressively deeper sleep states, each one cheaper to hold and more expensive to leave — clocks stop, then caches flush, then voltage drops. A deep state only repays the cost of entering it if the package gets to stay there for a while. This is where a laptop's battery life actually comes from.",
            figure: "804.5", unit: "wakeups/s", figureName: "polling worker",
            grounding: "One wakeup roughly every 1.2 milliseconds, against 1.0 a second for the worker doing the same job by blocking. The package never got far enough down to earn back the descent. Nothing was wrong with the code's output; it simply never let the hardware rest."
        ),
        Principle(
            title: "The run queue is the frontier",
            symbols: ["list.number"],
            tint: Theme.dusk,
            prose: "The run queue holds exactly those threads that are waiting on nothing — the boundary between what the machine can do this instant and what it cannot do yet. Blocked, ready, waiting on an external process, at risk, complete: these are not project-management words that happen to fit a scheduler. They are the scheduler's own states, and a thread moves between them for reasons anyone can name.",
            figure: "99.36 vs 0.00", unit: "% CPU", figureName: "on and off the queue",
            grounding: "The spin loop sits on the run queue permanently and costs everything. The deadlocked pair sit off it permanently and cost nothing. Neither will ever finish. Being on the frontier is not the same as making progress, and that distinction is the reason this lab measures work completed rather than time spent."
        )
    ]
}

private struct PrincipleCard: View {
    let principle: Principle

    var body: some View {
        Card(principle.title, symbol: principle.symbols.first ?? "circle", tint: principle.tint) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 18) {
                    HStack(spacing: 8) {
                        ForEach(principle.symbols, id: \.self) { symbol in
                            Image(systemName: symbol)
                                .symbolRenderingMode(.hierarchical)
                                .font(.system(size: 24, weight: .regular))
                                .foregroundStyle(principle.tint)
                        }
                    }
                    .frame(width: 74, alignment: .leading)

                    Prose(principle.prose)
                    Spacer(minLength: 0)
                }

                HStack(alignment: .top, spacing: 18) {
                    FigureCell(value: principle.figure, unit: principle.unit,
                               name: principle.figureName, tint: principle.tint)
                        .frame(width: 150, alignment: .leading)
                    Text(principle.grounding)
                        .font(Theme.proseSmall)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 620, alignment: .leading)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
                .padding(.leading, 92)
            }
        }
    }
}
