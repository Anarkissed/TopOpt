// LatticeDepthDetentTests.swift — ★ MAGNETIC DETENTS ON THE LATTICE DEPTH
// (maintainer, 2026-08-17: "One thing I'd like is for the primitive to have
// magnetic detents").
//
// ★ THE DETENT THAT EARNS ITS PLACE is at the depth the region STARTS TO
// CERTIFY. His 4 mm slab missed the 5-cells floor; the depth that clears it is
// N* × (nozzle / φ(ρ_max)) = 5 × 1.173 = 5.87 mm at a 0.45 mm bead — a number he
// had no way to find, because the card did not show it and the card's own
// arithmetic implied 24.65 mm (4.2× wrong). So these tests assert that the
// CERTIFYING depth is a candidate and that snapping to it really does certify —
// asked of core, not of this file's arithmetic.

import XCTest
import TopOptKit
@testable import TopOptFlows

final class LatticeDepthDetentTests: XCTestCase {

    static let w = 0.45                       // his bead

    // MARK: the candidate that matters

    /// ★ THE CERTIFYING DEPTH IS CORE'S OWN PRODUCT, not a Swift derivation.
    func testTheCertifyingDepthIsCoresMinCertifiableMemberWidth() throws {
        let d = try XCTUnwrap(LatticeDepthDetent.certifyingDepthMM(
            topology: "octet", minExtrudableWidthMM: Self.w))
        let b = TopOptKit.latticeCellBounds(topology: "octet",
                                            minExtrudableWidthMM: Self.w)
        XCTAssertEqual(d, b.cellsPerMemberFloor * b.printabilityFloorDensestMM,
                       accuracy: 1e-12)
        XCTAssertEqual(d, 5.87, accuracy: 0.01, "his part's number")
    }

    /// ★★ AND SNAPPING TO IT ACTUALLY CERTIFIES. A magnet that lands one ULP
    /// short of the floor would click and still refuse — the exact defect
    /// `LatticeFaceDiagnosis` records for a rounded-down fix ("24.6 mm still
    /// fails"). Asked of CORE at the snapped depth.
    func testSnappingToTheCertifyingDetentActuallyCertifies() throws {
        let d = try XCTUnwrap(LatticeDepthDetent.certifyingDepthMM(
            topology: "octet", minExtrudableWidthMM: Self.w))
        let at = TopOptKit.latticeRegionDerivation(
            topology: "octet", memberWidthMM: d, minExtrudableWidthMM: Self.w)
        XCTAssertTrue(at.valid)
        XCTAssertGreaterThanOrEqual(at.cellsPerMember, 5.0 - 1e-9,
                                    "★ the detent lands ON the floor, not under it")
        XCTAssertFalse(at.outOfRegime, "★ …so it certifies")
        XCTAssertTrue(at.prints)
        // …and one snap-radius BELOW it does not, so the magnet sits on a real
        // frontier rather than in the middle of a certifying range.
        let below = TopOptKit.latticeRegionDerivation(
            topology: "octet",
            memberWidthMM: d - LatticeDepthDetent.snapThresholdMM,
            minExtrudableWidthMM: Self.w)
        XCTAssertTrue(below.outOfRegime,
                      "the frontier is real: a snap-radius shallower still fails")
    }

    /// It is in the candidate list, tagged as the reason it is there.
    func testTheCertifyingDepthIsACandidateAndIsTagged() throws {
        let cs = LatticeDepthDetent.candidates(topology: "octet",
                                               minExtrudableWidthMM: Self.w)
        let c = try XCTUnwrap(cs.first { $0.kind == .certifies })
        XCTAssertEqual(c.mm, try XCTUnwrap(LatticeDepthDetent.certifyingDepthMM(
            topology: "octet", minExtrudableWidthMM: Self.w)), accuracy: 1e-12)
        XCTAssertGreaterThan(cs.filter { $0.kind == .round }.count, 10,
                             "the ordinary magnets are there too")
    }

    /// ★ NO NOZZLE ⇒ NO CERTIFYING DETENT. Printability is user input and has no
    /// default; inventing a magnet from a guessed bead would be the same silent
    /// fallback the band floor was.
    func testAnUnknownNozzleOffersNoCertifyingDetent() {
        XCTAssertNil(LatticeDepthDetent.certifyingDepthMM(topology: "octet",
                                                          minExtrudableWidthMM: 0))
        let cs = LatticeDepthDetent.candidates(topology: "octet",
                                               minExtrudableWidthMM: 0)
        XCTAssertFalse(cs.contains { $0.kind == .certifies })
        XCTAssertFalse(cs.isEmpty, "…the round magnets still work")
    }

    /// A different nozzle moves the magnet, because the floor moves with it.
    func testACoarserNozzleMovesTheCertifyingDetentDeeper() throws {
        let fine = try XCTUnwrap(LatticeDepthDetent.certifyingDepthMM(
            topology: "octet", minExtrudableWidthMM: 0.25))
        let coarse = try XCTUnwrap(LatticeDepthDetent.certifyingDepthMM(
            topology: "octet", minExtrudableWidthMM: 0.80))
        XCTAssertLessThan(fine, coarse)
        XCTAssertEqual(fine, 3.26, accuracy: 0.02)
        XCTAssertEqual(coarse, 10.43, accuracy: 0.02)
    }

    // MARK: the feel — one hysteresis rule, not two

    private func cands(_ mms: [Double]) -> [LatticeDepthDetent.Candidate] {
        mms.map { .init(mm: $0, kind: .round) }
    }

    func testItSnapsWhenFreeAndHoldsUntilTheEscapeBand() {
        let cs = cands([4, 6, 8])
        // FREE, inside the snap band → snaps.
        let a = LatticeDepthDetent.resolve(rawMM: 6.2, candidates: cs, current: nil)
        XCTAssertEqual(a.mm, 6, accuracy: 1e-12)
        XCTAssertEqual(a.snapped?.mm, 6)
        XCTAssertTrue(a.didSnap, "a fresh entry ticks the haptic")

        // HELD, still inside the escape band → stays, and does NOT re-tick.
        let held = LatticeDepthDetent.resolve(rawMM: 6.0 + 0.7, candidates: cs,
                                              current: a.snapped)
        XCTAssertEqual(held.mm, 6, accuracy: 1e-12)
        XCTAssertFalse(held.didSnap, "a held detent must not buzz every frame")

        // PAST the escape band, away from every candidate → free.
        let free = LatticeDepthDetent.resolve(rawMM: 7.0, candidates: cs,
                                              current: a.snapped)
        XCTAssertEqual(free.mm, 7.0, accuracy: 1e-12)
        XCTAssertNil(free.snapped)
    }

    /// ★ FREE ONLY *OUTSIDE* THE SNAP BAND. The escape band is wider than the
    /// snap band, which is the whole of the hysteresis — without it the value
    /// chatters in and out at the boundary.
    func testTheEscapeBandIsWiderThanTheSnapBand() {
        XCTAssertGreaterThan(LatticeDepthDetent.releaseThresholdMM,
                             LatticeDepthDetent.snapThresholdMM)
        let cs = cands([6])
        let held = LatticeDepthDetent.Candidate(mm: 6, kind: .round)
        // 0.6 mm away: OUTSIDE the 0.4 snap band, INSIDE the 0.8 escape band.
        let a = LatticeDepthDetent.resolve(rawMM: 6.6, candidates: cs, current: held)
        XCTAssertEqual(a.mm, 6, accuracy: 1e-12, "still held")
        let b = LatticeDepthDetent.resolve(rawMM: 6.6, candidates: cs, current: nil)
        XCTAssertEqual(b.mm, 6.6, accuracy: 1e-12, "…but would not snap from free")
    }

    /// ★★ ONE RULE, TWO CALLERS. The design box's face detent and this one must
    /// behave identically given the same thresholds — this type exists to carry
    /// FINER thresholds (0.4 mm vs 1.5 mm, because a 4 mm slab and a 5.9 mm one
    /// are different answers), NOT a second behaviour. Drive both over the same
    /// sweep and assert they agree.
    /// ★ COMPARED IN EACH TYPE'S OWN UNITS, at offsets expressed as FRACTIONS of
    /// its own thresholds — not by scaling one coordinate space onto the other.
    /// The scaled version of this test landed exactly on threshold boundaries,
    /// where `Float` and `Double` disagree about `d < threshold` and both answers
    /// are defensible; it measured the arithmetic type, not the rule.
    func testTheHysteresisRuleIsTheDesignBoxsRule() {
        // One candidate each, far from anything else, at a round position.
        let mineC = cands([6])
        let theirsC: [Float] = [6]
        let held = LatticeDepthDetent.Candidate(mm: 6, kind: .round)

        // (offset as a fraction of the type's own snap radius, what must happen)
        let cases: [(k: Double, fromFree: Bool, whileHeld: Bool, label: String)] = [
            (0.5,  true,  true,  "half a snap radius: snaps from free, held stays"),
            (1.5,  false, true,  "1.5 radii: no snap from free, but still HELD "
                               + "(inside the 2x escape band)"),
            (2.5,  false, false, "2.5 radii: outside both — free either way"),
        ]
        for c in cases {
            let mineOffset = c.k * LatticeDepthDetent.snapThresholdMM
            let theirOffset = Float(c.k) * DesignBoxDetent.snapThresholdMM

            let mFree = LatticeDepthDetent.resolve(rawMM: 6 + mineOffset,
                                                   candidates: mineC, current: nil)
            let tFree = DesignBoxDetent.resolve(rawCoord: 6 + theirOffset,
                                                candidates: theirsC, current: nil)
            XCTAssertEqual(mFree.snapped != nil, c.fromFree, "FREE — \(c.label)")
            XCTAssertEqual(mFree.snapped != nil, tFree.snapped != nil,
                           "★ same rule from FREE — \(c.label)")

            let mHeld = LatticeDepthDetent.resolve(rawMM: 6 + mineOffset,
                                                   candidates: mineC, current: held)
            let tHeld = DesignBoxDetent.resolve(rawCoord: 6 + theirOffset,
                                                candidates: theirsC, current: 6)
            XCTAssertEqual(mHeld.snapped != nil, c.whileHeld, "HELD — \(c.label)")
            XCTAssertEqual(mHeld.snapped != nil, tHeld.snapped != nil,
                           "★ same rule while HELD — \(c.label)")
            // …and neither re-ticks a haptic for a detent it was already on.
            XCTAssertFalse(mHeld.didSnap && mHeld.snapped == held,
                           "no re-tick on a held detent — \(c.label)")
            XCTAssertEqual(mHeld.didSnap, tHeld.didSnap,
                           "★ same fresh-entry edge — \(c.label)")
        }
        // And the ratio between the two radii is the only intended difference.
        XCTAssertEqual(LatticeDepthDetent.releaseMultiple,
                       Double(DesignBoxDetent.releaseMultiple), accuracy: 1e-12,
                       "★ the same 2x hysteresis; only the radius differs")
        XCTAssertLessThan(LatticeDepthDetent.snapThresholdMM,
                          Double(DesignBoxDetent.snapThresholdMM),
                          "a depth is a finer quantity than a design-box face")
    }

    /// The certifying magnet outranks a round one at the same depth — "it clicks
    /// when it starts working" and "it clicks at 6 mm" are not the same sentence.
    func testTheCertifyingKindWinsATieWithARoundMillimetre() {
        // 0.25 mm bead ⇒ 3.2585… mm. Use a round step that lands on it exactly.
        let d = LatticeDepthDetent.certifyingDepthMM(topology: "octet",
                                                     minExtrudableWidthMM: 0.25) ?? 0
        let cs = LatticeDepthDetent.candidates(
            topology: "octet", minExtrudableWidthMM: 0.25, roundStepMM: d)
        let at = cs.filter { abs($0.mm - d) < 1e-9 }
        XCTAssertEqual(at.count, 1, "de-duplicated to one candidate")
        XCTAssertEqual(at.first?.kind, .certifies, "★ and it is the meaningful one")
    }

    /// Candidates stay inside the depth control's own clamp, so a magnet can
    /// never pull the value somewhere the card could not.
    func testEveryCandidateIsInsideTheDepthClamp() {
        for c in LatticeDepthDetent.candidates(topology: "octet",
                                               minExtrudableWidthMM: Self.w,
                                               extentMM: 1e6) {
            XCTAssertGreaterThanOrEqual(c.mm, LatticeSlabDepth.minMM)
            XCTAssertLessThanOrEqual(c.mm, LatticeSlabDepth.maxMM)
        }
    }
}
