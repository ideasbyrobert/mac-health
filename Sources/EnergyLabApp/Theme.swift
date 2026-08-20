import SwiftUI
import EnergyLab

/// Colour, type and small shared containers for the lab's window.
///
/// The palette is deliberately calm. Alarm red belongs to exactly one
/// pathology — `deadlock`, the only state from which a process can never
/// return — so that seeing it means something. Everything else gets a colour
/// that describes what the energy is doing, not how worried anyone should be.
enum Theme {

    // A SwiftPM executable target ships no asset catalog, so the palette is
    // written out in literal components rather than named colours.
    static let sage  = Color(red: 0.36, green: 0.62, blue: 0.46)
    static let dusk  = Color(red: 0.38, green: 0.51, blue: 0.74)
    static let amber = Color(red: 0.85, green: 0.65, blue: 0.25)
    static let ochre = Color(red: 0.80, green: 0.50, blue: 0.27)
    static let rose  = Color(red: 0.80, green: 0.36, blue: 0.52)
    static let alarm = Color(red: 0.76, green: 0.24, blue: 0.22)
    static let slate = Color(red: 0.48, green: 0.53, blue: 0.60)
    static let ink   = Color(red: 0.20, green: 0.22, blue: 0.26)

    /// One colour per pathology, used everywhere the pathology appears.
    static func tint(for pathology: Pathology) -> Color {
        switch pathology {
        case .healthy:       return sage
        case .idleWaiting:   return dusk
        case .wakeupStorm:   return amber
        case .stalled:       return ochre
        case .livelock:      return rose
        case .deadlock:      return alarm
        case .indeterminate: return slate
        }
    }

    /// Confidence is shown as weight, never as alarm: a weak claim is quieter,
    /// not redder.
    static func tint(for confidence: Confidence) -> Color {
        switch confidence {
        case .unknown:  return slate.opacity(0.65)
        case .possible: return slate
        case .probable: return dusk
        case .known:    return sage
        }
    }

    static func phrase(for confidence: Confidence) -> String {
        switch confidence {
        case .unknown:  return "not yet knowable from these counters"
        case .possible: return "possible — weakly supported"
        case .probable: return "probable — the best explanation, still unproved"
        case .known:    return "known — the evidence settles it"
        }
    }

    // Prose is set in a serif face at a readable size, because the teaching
    // text is meant to be read as writing rather than scanned as a label.
    static let prose      = Font.system(size: 15, weight: .regular, design: .serif)
    static let proseLead  = Font.system(size: 17, weight: .regular, design: .serif)
    static let proseSmall = Font.system(size: 13, weight: .regular, design: .serif)
    static let figure     = Font.system(size: 21, weight: .medium, design: .rounded).monospacedDigit()
    static let figureSmall = Font.system(size: 15, weight: .medium, design: .rounded).monospacedDigit()
    static let label      = Font.system(size: 10, weight: .semibold).smallCaps()

    static let proseLineSpacing: CGFloat = 5
    /// Prose stops growing here so lines stay at a comfortable measure even in
    /// a wide window.
    static let proseWidth: CGFloat = 720
}

/// Number formatting for figures the user is meant to compare at a glance.
/// Exact values stay available in tooltips; the visible form is rounded to
/// what a three-second window can actually support.
enum Figures {

    static func compact(_ value: Double) -> String {
        let magnitude = abs(value)
        switch magnitude {
        case 0:                    return "0"
        case ..<1:                 return String(format: "%.2f", value)
        case ..<1_000:             return String(format: "%.0f", value)
        case ..<1_000_000:         return String(format: "%.1f K", value / 1_000)
        case ..<1_000_000_000:     return String(format: "%.1f M", value / 1_000_000)
        default:                   return String(format: "%.2f B", value / 1_000_000_000)
        }
    }

    static func grouped(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value < 10 ? 2 : 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func fixed(_ value: Double, _ places: Int) -> String {
        String(format: "%.\(places)f", value)
    }

    /// Percentages below a tenth of a point are reported as a bound, not as a
    /// number a short window cannot justify.
    static func percent(_ fraction: Double) -> String {
        let pct = fraction * 100
        if pct <= 0 { return "0%" }
        if pct < 0.1 { return "<0.1%" }
        if pct >= 99.95 { return "100%" }
        return String(format: pct < 10 ? "%.1f%%" : "%.0f%%", pct)
    }

    /// Order of magnitude only. A near-idle baseline varies substantially
    /// between runs on a loaded machine, so "1213x" would be false precision.
    static func orderOfMagnitude(_ ratio: Double) -> String {
        switch ratio {
        case ..<5:    return "a few times"
        case ..<50:   return "roughly 10x"
        case ..<500:  return "roughly 100x"
        case ..<5000: return "roughly 1000x"
        default:      return "more than 1000x"
        }
    }
}

// MARK: - shared containers

/// A titled panel. The symbol in the header always carries meaning: it is the
/// symbol the model type itself declares, never a decoration chosen here.
struct Card<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    let content: Content

    init(_ title: String, symbol: String, tint: Color = Theme.slate,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(Theme.label)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}

/// One measured quantity: the number large, the name small, the exact value in
/// the tooltip.
struct FigureCell: View {
    let value: String
    let unit: String
    let name: String
    var tint: Color = Theme.ink
    var exact: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(Theme.figure)
                    .foregroundStyle(tint)
                Text(unit)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(name)
                .font(Theme.label)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 96, alignment: .leading)
        .help(exact ?? "\(value) \(unit)")
    }
}

/// A small tinted capsule carrying a symbol and a word.
struct Pill: View {
    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

/// Body text, set once so every explanation in the app reads the same way.
struct Prose: View {
    let text: String
    var font: Font = Theme.prose

    init(_ text: String, font: Font = Theme.prose) {
        self.text = text
        self.font = font
    }

    var body: some View {
        Text(text)
            .font(font)
            .lineSpacing(Theme.proseLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Theme.proseWidth, alignment: .leading)
            .textSelection(.enabled)
    }
}
