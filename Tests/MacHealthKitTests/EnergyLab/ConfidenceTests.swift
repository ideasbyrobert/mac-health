import Testing
import Foundation
@testable import EnergyLab

/// Confidence is the gate between "the lab may say this" and "the lab may act
/// on this". Its ordering and its single permission are load-bearing, so both
/// are pinned here rather than left to the call sites that consult them.
struct ConfidenceTests {

    // MARK: ordering

    @Test func unknownIsWeakerThanPossible() {
        #expect(Confidence.unknown < Confidence.possible)
    }

    @Test func possibleIsWeakerThanProbable() {
        #expect(Confidence.possible < Confidence.probable)
    }

    @Test func probableIsWeakerThanKnown() {
        #expect(Confidence.probable < Confidence.known)
    }

    @Test func orderingIsTransitiveAcrossTheWholeScale() {
        #expect(Confidence.unknown < Confidence.known)
        #expect(Confidence.unknown < Confidence.probable)
        #expect(Confidence.possible < Confidence.known)
    }

    /// The cases are declared weakest first, so the declaration order is itself
    /// the scale. A reordering that broke this would silently change what the
    /// lab is allowed to assert.
    @Test func declarationOrderIsAscending() {
        #expect(Confidence.allCases.sorted() == Confidence.allCases)
        #expect(Confidence.allCases.count == 4)
    }

    @Test func comparisonIsStrictSoEqualCasesDoNotOutrankEachOther() {
        for level in Confidence.allCases {
            #expect(!(level < level))
        }
    }

    @Test func maxPicksTheStrongerClaim() {
        #expect(max(Confidence.possible, Confidence.probable) == .probable)
        #expect(min(Confidence.unknown, Confidence.known) == .unknown)
    }

    // MARK: the permission

    /// "Confidence is not decoration. It determines whether the system is
    /// allowed to control execution." Only a fully evidenced claim may.
    @Test func onlyKnownMayDriveAction() {
        for level in Confidence.allCases {
            #expect(level.mayDriveAction == (level == .known))
        }
    }

    @Test func probableIsStillNotEnoughToAct() {
        #expect(!Confidence.probable.mayDriveAction)
        #expect(Confidence.known.mayDriveAction)
    }

    // MARK: presentation

    @Test func everyCaseHasASymbol() {
        for level in Confidence.allCases {
            #expect(!level.sfSymbol.isEmpty)
        }
    }

    /// Two confidence levels sharing an icon would make the interface lie about
    /// how strongly a claim is held.
    @Test func symbolsAreDistinct() {
        let symbols = Confidence.allCases.map(\.sfSymbol)
        #expect(Set(symbols).count == symbols.count)
    }

    // MARK: encoding

    @Test func rawValuesAreStable() {
        #expect(Confidence.unknown.rawValue == "unknown")
        #expect(Confidence.possible.rawValue == "possible")
        #expect(Confidence.probable.rawValue == "probable")
        #expect(Confidence.known.rawValue == "known")
    }

    @Test func everyCaseSurvivesACodableRoundTrip() throws {
        let data = try JSONEncoder().encode(Confidence.allCases)
        let decoded = try JSONDecoder().decode([Confidence].self, from: data)
        #expect(decoded == Confidence.allCases)
    }

    @Test func anUnknownRawValueDecodesToNil() {
        #expect(Confidence(rawValue: "certain") == nil)
    }

    // MARK: claims

    @Test func aClaimCarriesItsValueConfidenceAndEvidence() {
        let claim = Claim(42, confidence: .probable, evidence: ["counted 42 wakeups"])

        #expect(claim.value == 42)
        #expect(claim.confidence == .probable)
        #expect(claim.evidence == ["counted 42 wakeups"])
        #expect(!claim.confidence.mayDriveAction)
    }

    /// Evidence may be empty, but only for a claim that admits it knows nothing.
    @Test func anUnknownClaimNeedNotCarryEvidence() {
        let claim = Claim("no reading", confidence: .unknown, evidence: [])
        #expect(claim.evidence.isEmpty)
        #expect(claim.confidence == .unknown)
    }
}
