import Foundation

/// What the thing on the other end of stdout can actually render.
///
/// The tool used to emit colour, box drawing, and emoji unconditionally. Piped
/// into a file, a pager, or a log, that produced `^[[32m` noise wrapped around
/// every value, which is what the sentinel's own LaunchAgent log had been
/// collecting for hours. Deciding once, here, is what lets every renderer stay
/// declarative about meaning and say nothing about escape codes.
public struct TerminalCapabilities: Sendable {

    public let usesColor: Bool
    public let usesUnicode: Bool
    public let width: Int

    /// Narrow enough for a split pane, wide enough to keep the label column
    /// meaningful. Rules and headers clamp into this range.
    public static let minimumWidth = 40
    public static let maximumWidth = 100

    public init(usesColor: Bool, usesUnicode: Bool, width: Int) {
        self.usesColor = usesColor
        self.usesUnicode = usesUnicode
        self.width = min(max(width, Self.minimumWidth), Self.maximumWidth)
    }

    /// Resolves capabilities from the rules terminal programs are expected to
    /// honour, in the order they take precedence.
    ///
    /// - `NO_COLOR` set to anything wins outright: the convention at
    ///   no-color.org is that presence alone disables colour.
    /// - `CLICOLOR_FORCE` keeps colour through a pipe, which is how a CI log
    ///   or `less -R` gets colour on purpose.
    /// - Otherwise colour requires a terminal, and `TERM=dumb` is not one.
    public static func resolve(
        isTTY: Bool,
        environment: [String: String],
        terminalWidth: Int?
    ) -> TerminalCapabilities {
        let term = environment["TERM"] ?? ""
        let isDumb = term == "dumb" || term.isEmpty

        let color: Bool
        if environment["NO_COLOR"] != nil {
            color = false
        } else if let force = environment["CLICOLOR_FORCE"], force != "0" {
            color = true
        } else {
            color = isTTY && !isDumb
        }

        // A terminal that cannot promise UTF-8 renders box drawing as mojibake,
        // which is worse than the ASCII it replaced.
        let locale = environment["LC_ALL"] ?? environment["LC_CTYPE"] ?? environment["LANG"] ?? ""
        let unicode = !isDumb && locale.uppercased().contains("UTF-8")

        return TerminalCapabilities(
            usesColor: color,
            usesUnicode: unicode,
            width: terminalWidth ?? 80
        )
    }

    /// The live terminal, resolved once per run.
    public static let current: TerminalCapabilities = resolve(
        isTTY: isatty(STDOUT_FILENO) == 1,
        environment: ProcessInfo.processInfo.environment,
        terminalWidth: detectedWidth()
    )

    /// Asks the kernel for the window size, then falls back to `COLUMNS`.
    /// Redirected output has no window, and 80 is the historical default.
    public static func detectedWidth() -> Int {
        var window = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &window) == 0, window.ws_col > 0 {
            return Int(window.ws_col)
        }
        if let columns = ProcessInfo.processInfo.environment["COLUMNS"], let value = Int(columns), value > 0 {
            return value
        }
        return 80
    }
}
