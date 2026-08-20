import Testing
import Foundation
@testable import EnergyLab

/// The catalogue is the lab's curriculum: each scenario is a claim about what a
/// worker mode will do, stated before it runs. These tests keep the catalogue
/// honest and keep it aligned with the modes the chaos worker actually has.
struct ScenarioCatalogTests {

    // MARK: the catalogue

    @Test func scenarioIDsAreUnique() {
        let ids = Scenario.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyScenarioIsFullyDescribed() {
        for scenario in Scenario.all {
            #expect(!scenario.id.isEmpty)
            #expect(!scenario.title.isEmpty, "\(scenario.id) has no title")
            #expect(!scenario.teaches.isEmpty, "\(scenario.id) teaches nothing")
            #expect(!scenario.remedy.isEmpty, "\(scenario.id) offers no remedy")
            #expect(!scenario.sfSymbol.isEmpty, "\(scenario.id) has no symbol")
        }
    }

    /// The ids are the argv the chaos worker dispatches on, so a rename here is
    /// a silent break of the C worker rather than a compile error.
    @Test func theCatalogueMatchesTheWorkerModes() {
        #expect(Set(Scenario.all.map(\.id)) == [
            "healthy", "wakeup-storm", "livelock", "deadlock", "pipe-deadlock", "stalled"
        ])
    }

    /// A prediction that cannot fail teaches nothing, and "we will not be able
    /// to tell" cannot fail. No scenario is allowed to predict it.
    @Test func noScenarioPredictsIndeterminate() {
        for scenario in Scenario.all {
            #expect(scenario.predicted != .indeterminate, "\(scenario.id) predicts nothing falsifiable")
        }
    }

    /// Both deadlock scenarios reach the same state through different gates —
    /// one through mutexes, one through a full pipe buffer — which is the point
    /// of shipping both.
    @Test func twoDifferentRoutesReachDeadlock() {
        let deadlocking = Scenario.all.filter { $0.predicted == .deadlock }
        #expect(deadlocking.count == 2)
        #expect(Set(deadlocking.map(\.id)) == ["deadlock", "pipe-deadlock"])
    }

    @Test func theBaselineScenarioPredictsCheapWaiting() throws {
        let baseline = try #require(Scenario.named("healthy"))
        #expect(baseline.predicted == .idleWaiting)
    }

    // MARK: lookup

    @Test func namedRoundTripsForEveryID() throws {
        for scenario in Scenario.all {
            let found = try #require(Scenario.named(scenario.id), "\(scenario.id) is not findable by id")
            #expect(found.id == scenario.id)
            #expect(found.title == scenario.title)
            #expect(found.predicted == scenario.predicted)
        }
    }

    @Test func namedReturnsNilForAnUnknownID() {
        #expect(Scenario.named("thermal-runaway") == nil)
        #expect(Scenario.named("") == nil)
    }

    @Test func namedIsCaseSensitive() {
        #expect(Scenario.named("Livelock") == nil)
        #expect(Scenario.named("livelock") != nil)
    }

    // MARK: predictions meeting observations

    @Test func predictionHoldsWhenObservationMatches() throws {
        let scenario = try #require(Scenario.named("livelock"))
        let result = ScenarioResult(scenario: scenario, diagnosis: diagnosis(.livelock, .known))
        #expect(result.predictionHeld)
    }

    @Test func predictionFailsWhenObservationContradicts() throws {
        let scenario = try #require(Scenario.named("livelock"))
        let result = ScenarioResult(scenario: scenario, diagnosis: diagnosis(.healthy, .known))
        #expect(!result.predictionHeld)
    }

    /// A deadlocked process and a healthy blocked one read the same counters,
    /// so when the progress signal is missing the lab reports indeterminate.
    /// That refusal is the design working, not the prediction failing.
    @Test func aDeadlockPredictionSurvivesAnHonestIndeterminate() throws {
        let scenario = try #require(Scenario.named("pipe-deadlock"))
        let result = ScenarioResult(scenario: scenario, diagnosis: diagnosis(.indeterminate, .unknown))
        #expect(result.predictionHeld)
    }

    /// The tolerance is granted only to deadlock predictions. Anything else
    /// observed as indeterminate is a scenario that failed to demonstrate
    /// itself.
    @Test func indeterminateDoesNotRescueANonDeadlockPrediction() {
        for scenario in Scenario.all where scenario.predicted != .deadlock {
            let result = ScenarioResult(scenario: scenario, diagnosis: diagnosis(.indeterminate, .unknown))
            #expect(!result.predictionHeld, "\(scenario.id) was excused an indeterminate result")
        }
    }

    @Test func everyScenarioHoldsAgainstItsOwnPrediction() {
        for scenario in Scenario.all {
            let result = ScenarioResult(scenario: scenario, diagnosis: diagnosis(scenario.predicted, .known))
            #expect(result.predictionHeld, "\(scenario.id) does not match its own prediction")
        }
    }

    // MARK: the taxonomy itself

    @Test func everyPathologyHasASymbolAndAHeadline() {
        for pathology in Pathology.allCases {
            #expect(!pathology.sfSymbol.isEmpty, "\(pathology.rawValue) has no symbol")
            for confidence in Confidence.allCases {
                #expect(!pathology.headline(at: confidence).isEmpty,
                        "\(pathology.rawValue) has no headline at \(confidence.rawValue)")
            }
        }
    }

    @Test func pathologySymbolsAndHeadlinesAreDistinct() {
        let symbols = Pathology.allCases.map(\.sfSymbol)
        let headlines = Pathology.allCases.map { $0.headline(at: .known) }
        #expect(Set(symbols).count == symbols.count)
        #expect(Set(headlines).count == headlines.count)
    }

    /// A headline that names a *structure* — a cycle in the wait-for graph — may
    /// only appear on a settled verdict. Below `.known` the sentence must
    /// describe the reading instead, or it contradicts the label beside it.
    @Test func structuralClaimsAppearOnlyAtKnownConfidence() {
        for confidence in Confidence.allCases where confidence < .known {
            let sentence = Pathology.deadlock.headline(at: confidence).lowercased()
            #expect(!sentence.contains("cycle"),
                    "deadlock asserts a graph property at \(confidence.rawValue): \(sentence)")
            #expect(!sentence.contains("wait-for"))
        }
        #expect(Pathology.deadlock.headline(at: .known).contains("cycle"))
    }

    /// The headlines describe what the energy is doing, so none of them may
    /// read as a verdict on the person who wrote the code.
    @Test func headlinesDescribeEnergyRatherThanBlame() {
        let scolding = ["bug", "wrong", "bad", "fault", "your"]
        for pathology in Pathology.allCases {
            for confidence in Confidence.allCases {
                let headline = pathology.headline(at: confidence).lowercased()
                for word in scolding {
                    #expect(!headline.contains(word),
                            "\(pathology.rawValue) scolds at \(confidence.rawValue): \(headline)")
                }
            }
        }
    }

    @Test func pathologyRawValuesAreStable() {
        #expect(Pathology.healthy.rawValue == "healthy")
        #expect(Pathology.idleWaiting.rawValue == "idleWaiting")
        #expect(Pathology.deadlock.rawValue == "deadlock")
        #expect(Pathology.livelock.rawValue == "livelock")
        #expect(Pathology.wakeupStorm.rawValue == "wakeupStorm")
        #expect(Pathology.stalled.rawValue == "stalled")
        #expect(Pathology.indeterminate.rawValue == "indeterminate")
    }

    @Test func everyPathologySurvivesACodableRoundTrip() throws {
        let data = try JSONEncoder().encode(Pathology.allCases)
        let decoded = try JSONDecoder().decode([Pathology].self, from: data)
        #expect(decoded == Pathology.allCases)
    }
}

// MARK: helpers

/// A signature the tests never inspect: these cases are about how a stated
/// prediction meets an observed pathology, not about the counters behind it.
private let inertSignature = EnergySignature(
    pid: 501, window: 3.0, cyclesPerSecond: 0, instructionsPerCycle: 0,
    cpuPercent: 0, interruptWakeupsPerSecond: 0, packageIdleWakeupsPerSecond: 0,
    progressPerSecond: nil
)

private func diagnosis(_ pathology: Pathology, _ confidence: Confidence) -> Diagnosis {
    Diagnosis(
        signature: inertSignature, pathology: pathology,
        confidence: confidence, evidence: ["constructed for a prediction test"]
    )
}
