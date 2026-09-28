import XCTest
@testable import TopOptFlows

/// ★★★ THE LADDER MUST NEVER TRAP — his crash, 2026-08-24.
///
/// Switching the settings sample from "One cell" to "In the part" took the app down
/// every time, in `LatticeSetupWizard.shapeFitSteps`:
///
///     Thread 0 Crashed:  EXC_BREAKPOINT
///     libswiftCore.dylib  _assertionFailure(_:_:file:line:flags:)
///     TopOpt.debug.dylib  LatticeSetupWizard.shapeFitSteps.getter (LatticeSetupWizard.swift:392)
///
/// ★ THE EXIT TEST COULD NEVER FIRE. It read `printabilityDensityFloor(...) > 1`, and
/// that function is `min(1, ...)` — CLAMPED to 1. So the loop halved the cell until it
/// underflowed to a denormal, and `Int((cell / finest).rounded(.down))` then overflowed
/// `Int`, which traps rather than saturating.
///
/// ★ AND IT FIRED ON A **VIEW BODY READ**, so it was not a rare edge — every rebuild of
/// that panel re-read the property. Which is why a note I added to explain a limit
/// became the most reliable crash in the app.
final class LatticeShapeFitLadderTests: XCTestCase {

    /// ★ THE EXACT SHAPE THAT CRASHED: a density ceiling of 1, where a clamped floor can
    /// only ever EQUAL the ceiling and never exceed it.
    func testACeilingOfOneTerminatesInsteadOfTrapping() {
        let n = LatticeShapeFitLadder.steps(cellMM: 6, lineWidthMM: 0.45,
                                            topologyID: "octet", densityCeiling: 1)
        XCTAssertNotNil(n)
        XCTAssertGreaterThanOrEqual(n!, 1)
        XCTAssertLessThanOrEqual(n!, LatticeShapeFitLadder.maxSteps,
                                 "the ladder ran past its own bound")
    }

    /// The count is bounded whatever is thrown at it — the bound is the loop's, not a
    /// property of any particular input.
    func testItIsBoundedForEveryPlausibleInput() {
        for cell in [0.5, 1.0, 4.33, 6.0, 12.0, 50.0, 1000.0] {
            for bead in [0.1, 0.2, 0.45, 0.8, 2.0] {
                for ceiling in [0.05, 0.5, 0.9, 1.0, 2.0, -1.0] {
                    let n = LatticeShapeFitLadder.steps(
                        cellMM: cell, lineWidthMM: bead,
                        topologyID: "octet", densityCeiling: ceiling)
                    if let n {
                        XCTAssertGreaterThanOrEqual(n, 1)
                        XCTAssertLessThanOrEqual(n, LatticeShapeFitLadder.maxSteps,
                                                 "cell \(cell) bead \(bead) ceiling \(ceiling)")
                    }
                }
            }
        }
    }

    /// Nonsense in, nil out — never a crash and never a fabricated number.
    func testDegenerateInputsReturnNil() {
        XCTAssertNil(LatticeShapeFitLadder.steps(cellMM: 0, lineWidthMM: 0.45,
                                                 topologyID: "octet"))
        XCTAssertNil(LatticeShapeFitLadder.steps(cellMM: 6, lineWidthMM: 0,
                                                 topologyID: "octet"))
        XCTAssertNil(LatticeShapeFitLadder.steps(cellMM: .nan, lineWidthMM: 0.45,
                                                 topologyID: "octet"))
        XCTAssertNil(LatticeShapeFitLadder.steps(cellMM: .infinity, lineWidthMM: 0.45,
                                                 topologyID: "octet"))
        XCTAssertNil(LatticeShapeFitLadder.steps(cellMM: 6, lineWidthMM: .nan,
                                                 topologyID: "octet"))
    }

    /// ★ AND IT SAYS SOMETHING TRUE. A coarse cell at a fine bead has room to step down;
    /// a cell already near the bead does not. That is the whole content of the note this
    /// feeds, so a ladder that always answered 1 (or always 16) would be useless even
    /// while never crashing.
    func testACoarseCellHasMoreRoomThanAFineOne() {
        let coarse = LatticeShapeFitLadder.steps(cellMM: 12, lineWidthMM: 0.2,
                                                 topologyID: "octet", densityCeiling: 0.9)
        let fine = LatticeShapeFitLadder.steps(cellMM: 2, lineWidthMM: 0.45,
                                               topologyID: "octet", densityCeiling: 0.9)
        XCTAssertNotNil(coarse); XCTAssertNotNil(fine)
        XCTAssertGreaterThan(coarse!, fine!,
                             "the ladder is not responding to the cell or the bead")
    }

    /// The finest size agrees with the count — one number, two readings.
    func testTheFinestCellAgreesWithTheStepCount() {
        let cell = 6.0
        guard let n = LatticeShapeFitLadder.steps(cellMM: cell, lineWidthMM: 0.45,
                                                  topologyID: "octet",
                                                  densityCeiling: 0.9) else {
            return XCTFail("no ladder")
        }
        let finest = LatticeShapeFitLadder.finestCellMM(cellMM: cell, lineWidthMM: 0.45,
                                                        topologyID: "octet",
                                                        densityCeiling: 0.9)
        XCTAssertEqual(finest, cell / pow(2, Double(n - 1)), accuracy: 1e-9)
        XCTAssertGreaterThan(finest, 0)
    }
}

/// ★★★ THE LADDER MUST SURVIVE THE HALF-FLOAT ROUNDING OF THE CELL.
///
/// His report, 2026-08-24: band set to 10 mm, "no grade and no solid either".
///
/// ★ THE BAKE AND THE DIAGNOSTIC DISAGREED, WHICH IS WHY IT LOOKED INERT. The stepped
/// cell is stored `halfRepresentable` — the size the SHADER can hold exactly — so a
/// 4.3333 mm cell arrives as 4.33203. Against an unrounded 2.16667 floor that ratio is
/// 1.99940, and flooring it gives **1**: no subdivision permitted, the ramp's `levels`
/// collapses to 0, and every cell on the face comes out at the base size. The log said
/// `nCap=2` because it computed the ratio from the UNROUNDED cell.
final class LatticeHalfFloatRungTests: XCTestCase {

    /// The exact numbers off his part.
    func testAHalfRoundedCellStillYieldsItsRung() {
        let cell = Double(LatticePreviewOccupancy.halfRepresentable(Float(13.0 / 3.0)))
        let finest = 13.0 / 6.0                       // exactly half the unrounded cell
        XCTAssertLessThan(cell / finest, 2.0,
                          "★ the premise: half-rounding puts the ratio just UNDER 2")
        // The bake's rule, with its tolerance.
        let nCap = Swift.max(1, Int((cell / finest * (1 + 2e-3)).rounded(.down)))
        XCTAssertEqual(nCap, 2,
                       "the half-float step ate a whole rung — the grade is inert and "
                       + "the log will still claim nCap=2")
    }

    /// ★ AND THE TOLERANCE CANNOT INVENT A RUNG. It is three orders of magnitude below
    /// a real rung ratio, so a cell genuinely short of two rungs must stay at one.
    func testTheToleranceCannotManufactureARung() {
        let cell = 4.0, finest = 2.4          // 1.667 — nowhere near 2
        let nCap = Swift.max(1, Int((cell / finest * (1 + 2e-3)).rounded(.down)))
        XCTAssertEqual(nCap, 1, "the tolerance granted a rung the cell cannot hold")
    }
}
