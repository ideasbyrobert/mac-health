import Testing
@testable import MacHealthKit

struct SleepPolicyTests {

    @Test func neverPinsSystemAndDisplay() {
        #expect(SleepPolicy.assertionTypes(for: .never) ==
            ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep"])
    }

    @Test func dimPinsOnlyTheSystem() {
        #expect(SleepPolicy.assertionTypes(for: .dim) == ["PreventUserIdleSystemSleep"])
    }

    @Test func canonicalHoldsNothingAndInstallsNothing() {
        #expect(SleepPolicy.assertionTypes(for: .canonical).isEmpty)
        #expect(SleepPolicy.holdArguments(for: .canonical) == nil)
        #expect(SleepPolicy.agentPlist(
            label: "l", binary: "/b", mode: .canonical, logPath: "/tmp/x") == nil)
    }

    @Test func agentPlistInvokesTheHolderWithItsMode() throws {
        let plist = try #require(SleepPolicy.agentPlist(
            label: "com.example.guard",
            binary: "/usr/local/bin/mac-health",
            mode: .never,
            logPath: "/tmp/guard.log"))
        #expect(plist.contains("<string>com.example.guard</string>"))
        #expect(plist.contains("<string>/usr/local/bin/mac-health</string>"))
        #expect(plist.contains("<string>sleep</string>"))
        #expect(plist.contains("<string>hold</string>"))
        #expect(plist.contains("<string>--mode</string>"))
        #expect(plist.contains("<string>never</string>"))
        #expect(plist.contains("<key>RunAtLoad</key>"))
        #expect(plist.contains("<key>KeepAlive</key>"))
    }

    @Test func installedPlistRoundTripsItsMode() throws {
        for mode in [SleepMode.never, .dim] {
            let plist = try #require(SleepPolicy.agentPlist(
                label: "l", binary: "/b", mode: mode, logPath: "/tmp/x"))
            #expect(SleepPolicy.mode(fromInstalledPlist: plist) == mode)
        }
    }

    @Test func unrelatedPlistYieldsNoMode() {
        #expect(SleepPolicy.mode(fromInstalledPlist: "<plist><string>sentinel</string></plist>") == nil)
    }
}
