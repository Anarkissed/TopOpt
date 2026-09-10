// LatticePreviewBodyAlphaTests — ★ THE PART MUST BE DRAWN (maintainer, 2026-08-20:
// his new `M2 verticalStand THICK` opened to "a shadow on the stage floor but NOTHING
// drawn", and "rotating doesn't help, so it isn't framing").
//
// ★★ IT WAS NOT THE FILE, AND IT WAS NOT STEP. The import is clean on macOS AND on the
// iPad Pro 13-inch simulator — identical counts on both, 3,324 triangles, indices
// exactly 3× the triangles, watertight, wound OUTWARD (signed volume +978,349 mm³), and
// the renderer draws MORE pixels for it than for the fixture that renders correctly
// (9,590 vs 7,989 at 256²). Two hypotheses were tested and refuted on the way — a
// tessellation that produced points and no faces, and an inverted winding that the
// rasteriser would cull while the (non-culling) shadow pass survived. Both are recorded
// as refuted in `StepImportProbeTests` so nobody spends the afternoon re-testing them.
//
// ★ WHAT IT ACTUALLY WAS: `latticePreviewBodyAlpha` returned 0 — "do not draw the body"
// — for ANY project with no declared lattice include region. That is every project
// before the user declares one. His had an anchor and a load and no lattice role, which
// is what made a brand-new file the trigger and made it look like a property of the
// thickened part. Measured at the renderer on his own mesh:
//
//     bodyAlpha 1 .... 9,590 lit pixels of 65,536
//     bodyAlpha 0 ....     0
//
// The contact shadow survives either way because the shadow pass never reads it. That
// is exactly the picture he photographed.
//
// ★ AND WHY IT ONLY BIT NOW. The 0 had been computed for a long time and was silently
// DROPPED: until PR 341's confetti fix (dc0cb620, "The preview was drawing struts behind
// an opaque part") the coordinator only delivered a body alpha inside its load-flow
// block, and no other stage has a load flow. Making that delivery unconditional was the
// right fix; it uncovered a caller that had been wrong the whole time.

import XCTest
@testable import TopOptFlows

final class LatticePreviewBodyAlphaTests: XCTestCase {

    /// ★★★ THE REGRESSION. With no lattice layer being drawn, the body is OPAQUE — no
    /// matter what the project declares. This is the assertion whose absence cost him a
    /// part he could not see.
    func testTheBodyIsOpaqueWheneverNoLatticeLayerIsDrawn() {
        for hasRegion in [true, false] {
            XCTAssertEqual(
                LatticePreviewBodyAlpha.value(latticeLayerDrawn: false,
                                              hasIncludeRegion: hasRegion), 1,
                "★ HIS REPORT: with no lattice layer on screen there is nothing for a "
                + "hidden shell to reveal, so the part must be drawn. It was not, for "
                + "every project that had not yet declared a lattice region — which is "
                + "every NEW project. hasIncludeRegion=\(hasRegion)")
        }
    }

    /// ★ THE CONCESSION IS STILL MADE WHERE IT WAS EARNED. The settings-page sample —
    /// lattice layer up, nothing declared to cut the shell against — still hides the
    /// body, or the preview is a lattice behind an opaque wall, which is the defect
    /// `testTheStrutPreviewSurvivesTheSharedDepthBuffer` exists to catch.
    func testTheSampleWithNothingDeclaredStillHidesTheBody() {
        XCTAssertEqual(
            LatticePreviewBodyAlpha.value(latticeLayerDrawn: true,
                                          hasIncludeRegion: false), 0,
            "★ with the lattice up and NO region to cut the shell to, an opaque body "
            + "hides the preview completely — this is the case the rule exists for")
    }

    /// ★ AND A DECLARED REGION KEEPS THE BODY, which is the maintainer's own earlier
    /// correction ("the rest of the body isn't visible. They need to be combined.
    /// Looking like they are part of the same model"). Asserted so this fix cannot be
    /// read as licence to hide the shell again whenever a lattice is up.
    func testADeclaredRegionKeepsTheBodyWhileTheLatticeIsDrawn() {
        XCTAssertEqual(
            LatticePreviewBodyAlpha.value(latticeLayerDrawn: true,
                                          hasIncludeRegion: true), 1,
            "★ the shell is cut to the declared region, so the two surfaces are "
            + "complementary and BOTH are drawn")
    }

    /// ★★ THE TRUTH TABLE, WHOLE. Four inputs, four answers, and exactly one of them is
    /// 0 — written out so a future edit that widens the hidden case has to change a
    /// table rather than slip past a pair of examples.
    func testOnlyOneOfTheFourCasesHidesTheBody() {
        let cases: [(Bool, Bool, Float)] = [
            (false, false, 1), (false, true, 1),
            (true,  true,  1), (true,  false, 0)]
        for (drawn, region, want) in cases {
            XCTAssertEqual(
                LatticePreviewBodyAlpha.value(latticeLayerDrawn: drawn,
                                              hasIncludeRegion: region), want,
                "latticeLayerDrawn=\(drawn) hasIncludeRegion=\(region)")
        }
        XCTAssertEqual(cases.filter { $0.2 == 0 }.count, 1,
                       "★ exactly ONE case may hide the part")
    }

    /// ★ AND THE VIEW ASKS THE SHARED EXPRESSION, not a second copy of it. The frame
    /// where "hide the shell" and "draw the lattice" disagreed is the frame that drew
    /// neither, so the call site must read one property for both.
    func testTheViewGatesBothOnOneExpression() throws {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent(); url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        let src = try String(
            contentsOf: url.appendingPathComponent(
                "Sources/TopOptFlows/WorkspacePlaceholder.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("latticeLayer: latticeLayerIsDrawn"),
                      "the lattice layer must be gated by the shared expression")
        XCTAssertTrue(src.contains("latticeLayerDrawn: latticeLayerIsDrawn"),
                      "★ …and the body alpha must be gated by the SAME one")
    }
}
