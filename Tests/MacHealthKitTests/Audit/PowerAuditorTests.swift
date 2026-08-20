import Testing
@testable import MacHealthKit

struct PowerAuditorTests {

    @Test func acPowerWithCoherentTimersIsOptimal() {
        let metrics = PowerAuditor(shell: intelShell()).audit()
        #expect(metrics.powerSource == "AC Charger")
        #expect(metrics.batteryPercentage == 100)
        #expect(metrics.sleepTimingsCoherent)
        #expect(metrics.status == "OPTIMAL_AC")
        #expect(metrics.batteryDisplaySleepMinutes == 10)
        #expect(metrics.batterySleepMinutes == 15)
        #expect(metrics.acDisplaySleepMinutes == 20)
        #expect(metrics.acSleepMinutes == 0)
    }

    @Test func batteryPercentageParsesOnBattery() {
        let metrics = PowerAuditor(shell: intelShell(batt: Fix.battOnBattery87)).audit()
        #expect(metrics.powerSource == "Battery")
        #expect(metrics.batteryPercentage == 87)
        #expect(metrics.status == "BATTERY_ACTIVE")
    }

    @Test func invertedSleepTimersAreIncoherent() {
        let custom = Fix.custom(gpuswitch: 0, battDisplay: 20, battSleep: 15)
        let metrics = PowerAuditor(shell: intelShell(custom: custom)).audit()
        #expect(!metrics.sleepTimingsCoherent)
        #expect(metrics.status == "INCOHERENT_SLEEP_TIMINGS")
    }

    @Test func neverSleepOnACIsCoherentDespiteDisplayTimer() {
        let custom = Fix.custom(gpuswitch: 0, acDisplay: 20, acSleep: 0)
        let metrics = PowerAuditor(shell: intelShell(custom: custom)).audit()
        #expect(metrics.sleepTimingsCoherent)
    }

    @Test func serviceRecommendedBatteryIsDegraded() {
        let metrics = PowerAuditor(shell: intelShell(condition: Fix.conditionService)).audit()
        #expect(metrics.isBatteryDegraded)
        #expect(metrics.batteryCondition == "Service Recommended")
        #expect(metrics.status == "SERVICE_RECOMMENDED")
    }
}
