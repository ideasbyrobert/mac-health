import Testing
@testable import MacHealthKit

struct TerminalCapabilitiesTests {

    private static let utf8Terminal = ["TERM": "xterm-256color", "LANG": "en_US.UTF-8"]

    // MARK: Colour

    @Test func colourOnARealTerminal() {
        let caps = TerminalCapabilities.resolve(isTTY: true, environment: Self.utf8Terminal, terminalWidth: 80)
        #expect(caps.usesColor)
    }

    /// The defect this type exists for: escape codes written into a file or a
    /// log, where nothing will ever interpret them.
    @Test func noColourWhenRedirected() {
        let caps = TerminalCapabilities.resolve(isTTY: false, environment: Self.utf8Terminal, terminalWidth: 80)
        #expect(!caps.usesColor)
    }

    @Test func noColorVariableWinsOverATerminal() {
        var env = Self.utf8Terminal
        env["NO_COLOR"] = ""
        let caps = TerminalCapabilities.resolve(isTTY: true, environment: env, terminalWidth: 80)
        // no-color.org: presence disables colour, whatever the value.
        #expect(!caps.usesColor)
    }

    @Test func forceKeepsColourThroughAPipe() {
        var env = Self.utf8Terminal
        env["CLICOLOR_FORCE"] = "1"
        let caps = TerminalCapabilities.resolve(isTTY: false, environment: env, terminalWidth: 80)
        #expect(caps.usesColor)
    }

    @Test func forceSetToZeroDoesNotCount() {
        var env = Self.utf8Terminal
        env["CLICOLOR_FORCE"] = "0"
        let caps = TerminalCapabilities.resolve(isTTY: false, environment: env, terminalWidth: 80)
        #expect(!caps.usesColor)
    }

    @Test func dumbTerminalGetsNeitherColourNorUnicode() {
        let caps = TerminalCapabilities.resolve(
            isTTY: true, environment: ["TERM": "dumb", "LANG": "en_US.UTF-8"], terminalWidth: 80)
        #expect(!caps.usesColor)
        #expect(!caps.usesUnicode)
    }

    // MARK: Unicode

    @Test func unicodeNeedsAUTF8Locale() {
        let caps = TerminalCapabilities.resolve(
            isTTY: true, environment: ["TERM": "xterm", "LANG": "C"], terminalWidth: 80)
        #expect(!caps.usesUnicode)
    }

    @Test func lcAllOutranksLang() {
        let caps = TerminalCapabilities.resolve(
            isTTY: true,
            environment: ["TERM": "xterm", "LC_ALL": "en_GB.UTF-8", "LANG": "C"],
            terminalWidth: 80
        )
        #expect(caps.usesUnicode)
    }

    // MARK: Width

    @Test func widthClampsToAReadableRange() {
        #expect(TerminalCapabilities(usesColor: true, usesUnicode: true, width: 5).width
            == TerminalCapabilities.minimumWidth)
        #expect(TerminalCapabilities(usesColor: true, usesUnicode: true, width: 5_000).width
            == TerminalCapabilities.maximumWidth)
        #expect(TerminalCapabilities(usesColor: true, usesUnicode: true, width: 72).width == 72)
    }
}

/// Serialized because these tests swap `ConsoleFormat.capabilities`, which is
/// process wide. Run in parallel they clobber each other's terminal, and the
/// first version of this suite duly failed that way rather than passing by
/// luck.
@Suite(.serialized)
struct ConsoleFormatCapabilityTests {

    /// Restores the shared capabilities so one test cannot colour another.
    private func withCapabilities(
        _ caps: TerminalCapabilities, _ body: () -> Void
    ) {
        let previous = ConsoleFormat.capabilities
        ConsoleFormat.capabilities = caps
        body()
        ConsoleFormat.capabilities = previous
    }

    @Test func plainTerminalEmitsNoEscapeBytes() {
        withCapabilities(TerminalCapabilities(usesColor: false, usesUnicode: false, width: 60)) {
            #expect(ConsoleFormat.green.isEmpty)
            #expect(ConsoleFormat.bold.isEmpty)
            #expect(ConsoleFormat.reset.isEmpty)
            #expect(!ConsoleFormat.rule().contains("\u{001B}"))
        }
    }

    @Test func colourTerminalEmitsTheSequences() {
        withCapabilities(TerminalCapabilities(usesColor: true, usesUnicode: true, width: 60)) {
            #expect(ConsoleFormat.green == "\u{001B}[32m")
            #expect(ConsoleFormat.rule().contains("\u{001B}[36m"))
        }
    }

    @Test func ruleMatchesTerminalWidth() {
        withCapabilities(TerminalCapabilities(usesColor: false, usesUnicode: true, width: 47)) {
            #expect(ConsoleFormat.rule().count == 47)
        }
    }

    @Test func glyphsFallBackToASCIIWithoutUTF8() {
        withCapabilities(TerminalCapabilities(usesColor: false, usesUnicode: false, width: 60)) {
            #expect(ConsoleFormat.tick == "OK")
            #expect(ConsoleFormat.bullet == "-")
            #expect(ConsoleFormat.rule().allSatisfy { $0 == "-" })
        }
    }

    @Test func glyphsUseBoxDrawingWhenUTF8IsPromised() {
        withCapabilities(TerminalCapabilities(usesColor: false, usesUnicode: true, width: 60)) {
            #expect(ConsoleFormat.tick == "\u{2713}")
            #expect(ConsoleFormat.rule().allSatisfy { $0 == "\u{2500}" })
        }
    }
}
