import SwiftUI
import EnergyLab

/// The picture of energy that cannot flow.
///
/// Actors are nodes, wait edges are arrows, and the gate each actor is blocked
/// on rides on its arrow wearing the symbol the `Gate` type itself declares.
/// When `WaitForGraph.deadlocks()` finds a ring, the ring is drawn closed and
/// lit, because that closed loop *is* the deadlock — not a symptom of one.
///
/// Nothing here animates. A view that redraws sixty times a second to look
/// lively would be the wakeup storm on the next page over.
struct WaitForGraphView: View {
    let lab: LabGraph
    /// The pathology colour the rest of the window is already using for this
    /// scenario, so the diagram belongs to the same reading.
    let tint: Color

    var body: some View {
        let cycles = lab.graph.deadlocks()
        let ringEdges = Set(cycles.flatMap { $0.edges })
        let ringActors = Set(cycles.flatMap { $0.edges }.flatMap { [$0.waiter.id, $0.holder.id] })
        let frontier = Set(lab.graph.frontier(among: lab.actors).map { $0.id })

        return VStack(alignment: .leading, spacing: 14) {
            if !cycles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Pill(symbol: Pathology.deadlock.sfSymbol,
                         text: "closed cycle",
                         tint: Theme.alarm)
                    ForEach(Array(cycles.enumerated()), id: \.offset) { _, cycle in
                        Text(cycle.describe())
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            GraphCanvas(lab: lab, tint: tint,
                        ringEdges: ringEdges, ringActors: ringActors, frontier: frontier)
                .frame(height: lab.actors.count > 2 ? 320 : 260)

            Prose(lab.reading, font: Theme.proseSmall)

            GraphLegend(lab: lab, tint: tint, hasCycle: !cycles.isEmpty,
                        hasFrontier: !frontier.isEmpty)

            HStack(spacing: 6) {
                Image(systemName: lab.confidence.sfSymbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tint(for: lab.confidence))
                Text(lab.provenance)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - the drawing

private struct GraphCanvas: View {
    let lab: LabGraph
    let tint: Color
    let ringEdges: Set<WaitEdge>
    let ringActors: Set<String>
    let frontier: Set<String>

    private var gateSymbols: [String] {
        var seen: [String] = []
        for edge in lab.graph.edges where !seen.contains(edge.gate.sfSymbol) {
            seen.append(edge.gate.sfSymbol)
        }
        return seen
    }

    var body: some View {
        Canvas { context, size in
            let places = Sketch.positions(for: lab.actors, in: size)
            let radius = Sketch.nodeRadius

            // The halo goes down first so every stroke that follows sits on top
            // of it rather than being washed out by it.
            for edge in lab.graph.edges where ringEdges.contains(edge) {
                guard let from = places[edge.waiter.id], let to = places[edge.holder.id] else { continue }
                let geometry = Sketch.edge(from: from, to: to, radius: radius,
                                           bow: Sketch.bow(for: lab.actors.count))
                context.stroke(geometry.path, with: .color(Theme.alarm.opacity(0.16)),
                               style: StrokeStyle(lineWidth: 15, lineCap: .round))
            }
            for actor in lab.actors where ringActors.contains(actor.id) {
                guard let centre = places[actor.id] else { continue }
                context.fill(Sketch.circle(centre: centre, radius: radius + 11,
                                           seed: Sketch.seed(actor.label)),
                             with: .color(Theme.alarm.opacity(0.10)))
            }

            for edge in lab.graph.edges {
                guard let from = places[edge.waiter.id], let to = places[edge.holder.id] else { continue }
                let inRing = ringEdges.contains(edge)
                let colour = inRing ? Theme.alarm : Theme.slate
                let geometry = Sketch.edge(from: from, to: to, radius: radius,
                                           bow: Sketch.bow(for: lab.actors.count))

                context.stroke(geometry.path, with: .color(colour),
                               style: StrokeStyle(lineWidth: inRing ? 2.6 : 1.8,
                                                  lineCap: .round, lineJoin: .round))
                context.stroke(Sketch.arrowhead(at: geometry.end, angle: geometry.angle),
                               with: .color(colour),
                               style: StrokeStyle(lineWidth: inRing ? 2.6 : 1.8,
                                                  lineCap: .round, lineJoin: .round))

                // The gate chip: the symbol the Gate type declares, on the
                // exact edge that is blocked on it.
                let chip = CGRect(x: geometry.midpoint.x - 13, y: geometry.midpoint.y - 13,
                                  width: 26, height: 26)
                context.fill(Path(ellipseIn: chip), with: .color(colour))
                if let symbol = context.resolveSymbol(id: edge.gate.sfSymbol) {
                    context.draw(symbol, at: geometry.midpoint, anchor: .center)
                }
                var name = context.resolve(Text(edge.gate.name)
                    .font(.system(size: 10, weight: .medium)))
                name.shading = .color(colour)
                context.draw(name, at: CGPoint(x: geometry.midpoint.x,
                                               y: geometry.midpoint.y + 24), anchor: .center)
            }

            for actor in lab.actors {
                guard let centre = places[actor.id] else { continue }
                let onFrontier = frontier.contains(actor.id)
                let outline = ringActors.contains(actor.id) ? Theme.alarm : tint
                let shape = Sketch.circle(centre: centre, radius: radius,
                                          seed: Sketch.seed(actor.label))
                context.fill(shape, with: .color(outline.opacity(0.13)))
                context.stroke(shape, with: .color(outline),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                                  // Dashes mean the actor is on
                                                  // the run queue: nothing holds it.
                                                  dash: onFrontier ? [5, 4] : []))
                var label = context.resolve(Text(actor.label)
                    .font(.system(size: 12, weight: .semibold)))
                label.shading = .color(Theme.ink)
                context.draw(label, at: centre, anchor: .center)
            }

            if lab.graph.edges.isEmpty {
                var note = context.resolve(Text("no wait edges")
                    .font(.system(size: 11, weight: .medium)))
                note.shading = .color(Theme.slate)
                context.draw(note, at: CGPoint(x: size.width / 2, y: size.height / 2 + Sketch.nodeRadius + 26),
                             anchor: .center)
            }
        } symbols: {
            ForEach(gateSymbols, id: \.self) { name in
                Image(systemName: name)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .tag(name)
            }
        }
        .background(Color.primary.opacity(0.02),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - geometry

/// Layout and the small deliberate irregularities that make the diagram read as
/// drawn rather than generated. The wobble is seeded by each actor's own label,
/// so the same graph always comes out the same way.
private enum Sketch {

    static let nodeRadius: CGFloat = 44

    static func bow(for count: Int) -> CGFloat { count <= 2 ? 42 : 26 }

    static func seed(_ text: String) -> Int {
        var value = 7
        for scalar in text.unicodeScalars {
            value = (value &* 31 &+ Int(scalar.value)) & 0xFF_FFFF
        }
        return value
    }

    static func wobble(_ seed: Int, _ index: Int, amplitude: CGFloat) -> CGFloat {
        let mixed = (seed &+ index &* 40_503) &* 2_654_435_761
        let unit = CGFloat((mixed >> 9) & 0xFFFF) / 65_535.0
        return (unit - 0.5) * 2 * amplitude
    }

    static func positions(for actors: [LabActor], in size: CGSize) -> [String: CGPoint] {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        var out: [String: CGPoint] = [:]
        switch actors.count {
        case 0:
            return out
        case 1:
            out[actors[0].id] = centre
        case 2:
            let dx = min(size.width * 0.26, 165)
            out[actors[0].id] = CGPoint(x: centre.x - dx, y: centre.y)
            out[actors[1].id] = CGPoint(x: centre.x + dx, y: centre.y)
        default:
            let radius = min(size.width, size.height) / 2 - nodeRadius - 34
            for (index, actor) in actors.enumerated() {
                let angle = -Double.pi / 2 + 2 * Double.pi * Double(index) / Double(actors.count)
                out[actor.id] = CGPoint(x: centre.x + CGFloat(cos(angle)) * radius,
                                        y: centre.y + CGFloat(sin(angle)) * radius)
            }
        }
        return out
    }

    static func circle(centre: CGPoint, radius: CGFloat, seed: Int) -> Path {
        var path = Path()
        let steps = 30
        for step in 0...steps {
            let index = step % steps
            let angle = 2 * Double.pi * Double(index) / Double(steps)
            let wobbled = radius + wobble(seed, index, amplitude: radius * 0.035)
            let point = CGPoint(x: centre.x + CGFloat(cos(angle)) * wobbled,
                                y: centre.y + CGFloat(sin(angle)) * wobbled)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    struct EdgeGeometry {
        let path: Path
        let end: CGPoint
        let midpoint: CGPoint
        let angle: CGFloat
    }

    /// Arrows bow to one side so that two actors waiting on each other produce
    /// two visibly separate arcs, which is what makes a two-node cycle look
    /// like a loop instead of a line.
    static func edge(from: CGPoint, to: CGPoint, radius: CGFloat, bow: CGFloat) -> EdgeGeometry {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = max(sqrt(dx * dx + dy * dy), 1)
        let normal = CGPoint(x: -dy / length, y: dx / length)
        let control = CGPoint(x: (from.x + to.x) / 2 + normal.x * bow * 2,
                              y: (from.y + to.y) / 2 + normal.y * bow * 2)

        let start = advance(from, towards: control, by: radius + 3)
        let end = advance(to, towards: control, by: radius + 13)
        var path = Path()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)

        let midpoint = CGPoint(x: 0.25 * start.x + 0.5 * control.x + 0.25 * end.x,
                               y: 0.25 * start.y + 0.5 * control.y + 0.25 * end.y)
        let angle = atan2(end.y - control.y, end.x - control.x)
        return EdgeGeometry(path: path, end: end, midpoint: midpoint, angle: angle)
    }

    static func arrowhead(at point: CGPoint, angle: CGFloat, length: CGFloat = 11) -> Path {
        var path = Path()
        for spread in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
            let theta = angle + spread
            path.move(to: point)
            path.addLine(to: CGPoint(x: point.x + cos(theta) * length,
                                     y: point.y + sin(theta) * length))
        }
        return path
    }

    private static func advance(_ point: CGPoint, towards target: CGPoint, by distance: CGFloat) -> CGPoint {
        let dx = target.x - point.x
        let dy = target.y - point.y
        let length = max(sqrt(dx * dx + dy * dy), 1)
        return CGPoint(x: point.x + dx / length * distance,
                       y: point.y + dy / length * distance)
    }
}

// MARK: - legend

private struct GraphLegend: View {
    let lab: LabGraph
    let tint: Color
    let hasCycle: Bool
    let hasFrontier: Bool

    private var items: [LegendItem] {
        var out: [LegendItem] = [
            LegendItem(kind: .node(tint), text: "an actor — a thread, or a whole process")
        ]
        if !lab.graph.edges.isEmpty {
            out.append(LegendItem(kind: .arrow(Theme.slate), text: "waits for the actor it points at"))
        }
        var seenGates: [Gate] = []
        for edge in lab.graph.edges where !seenGates.contains(edge.gate) {
            seenGates.append(edge.gate)
            out.append(LegendItem(kind: .gate(edge.gate, hasCycle ? Theme.alarm : Theme.slate),
                                  text: "\(kindName(edge.gate)) “\(edge.gate.name)”"))
        }
        if hasFrontier {
            out.append(LegendItem(kind: .dashedNode(tint),
                                  text: "on the run queue — waiting on nothing"))
        }
        if hasCycle {
            out.append(LegendItem(kind: .ring, text: "a closed cycle: nothing in it can ever proceed"))
        }
        return out
    }

    private func kindName(_ gate: Gate) -> String {
        switch gate {
        case .mutex:             return "mutex"
        case .semaphore:         return "semaphore"
        case .conditionVariable: return "condition variable"
        case .pipe:              return "pipe buffer"
        case .fileDescriptor:    return "file descriptor"
        case .externalProcess:   return "external process"
        }
    }

    var body: some View {
        let rows = stride(from: 0, to: items.count, by: 2).map { start in
            Array(items[start..<min(start + 2, items.count)])
        }
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .center, spacing: 20) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 7) {
                            LegendMark(kind: item.kind)
                            Text(item.text)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 300, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

private struct LegendItem {
    enum Kind {
        case node(Color)
        case dashedNode(Color)
        case arrow(Color)
        case gate(Gate, Color)
        case ring
    }
    let kind: Kind
    let text: String
}

private struct LegendMark: View {
    let kind: LegendItem.Kind

    var body: some View {
        switch kind {
        case .node(let colour):
            Circle()
                .fill(colour.opacity(0.13))
                .overlay(Circle().strokeBorder(colour, lineWidth: 1.6))
                .frame(width: 16, height: 16)
        case .dashedNode(let colour):
            Circle()
                .strokeBorder(colour, style: StrokeStyle(lineWidth: 1.6, dash: [3, 3]))
                .frame(width: 16, height: 16)
        case .arrow(let colour):
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(colour)
                .frame(width: 16, height: 16)
        case .gate(let gate, let colour):
            Image(systemName: gate.sfSymbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(colour, in: Circle())
        case .ring:
            Circle()
                .fill(Theme.alarm.opacity(0.18))
                .overlay(Circle().strokeBorder(Theme.alarm, lineWidth: 1.6))
                .frame(width: 16, height: 16)
        }
    }
}
