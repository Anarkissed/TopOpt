import XCTest
@testable import TopOptFlows

/// ★★★ THE SKIN IS THE SAME WIDTH ON EVERY WALL.
///
/// His report, 2026-08-23: one wall carried the skin and the other did not — *"the same
/// fucking setting but just turned around"* — and he was right that no setting could
/// produce it.
///
/// ★ THE BAND WAS `0.12 * cellHere`, A FRACTION OF THE LOCAL CELL. His two walls derive
/// different cells, so out of ONE bake a 12 mm wall got a 1.44 mm dressing band and a
/// 6 mm wall got 0.72 mm — half the skin, nothing in the project differing. It was never
/// present-or-absent; it was twice as wide on one side, so a tap landed in it on one
/// wall and outside it on the other.
///
/// ★ AND IT WOULD HAVE GOT WORSE. The shape fit now grades the cell WITHIN a face, so a
/// cell-relative band would breathe across a single wall as well as between two.
///
/// A finish is a physical thickness, so the band is one — `faceSkinMM`, floored at two
/// extrusions so it stays drawable. These pin that it cannot drift back.
final class LatticeDressingBandTests: XCTestCase {

    func testTheDressingBandIsAPhysicalWidthNotAFractionOfTheCell() {
        // ★ MATCHED AS AN ASSIGNMENT, NOT AS PROSE. The first cut banned the literal
        // `0.12 * cellHere` anywhere in the source and promptly failed on the COMMENT
        // that explains the defect — a test that forbids naming the bug it guards.
        XCTAssertFalse(latticeFieldSource.contains("float band = max(0.12"),
                       "★ the dressing band is cell-relative again — two walls with "
                       + "different cells will get different amounts of skin from one "
                       + "bake, which is the asymmetry he photographed")
        XCTAssertTrue(latticeFieldSource.contains("float band = max(U.rimParams.x"),
                      "the dressing band no longer reads its millimetre width from the "
                      + "uniform")
    }

    /// The band still has to be POSITIVE for the dressing to exist at all — a zero band
    /// makes `1 - abs(d)/band` explode rather than vanish, so the floor is load-bearing.
    func testTheBandIsFlooredSoItCanNeverBeZero() {
        XCTAssertTrue(latticeFieldSource.contains("max(U.rimParams.x, 1e-4)"),
                      "the band's floor is gone; a zero band divides by zero in the "
                      + "dressing falloff")
    }

    /// ★ AND THE SOLID OUTLINE IS NOT DRIVEN BY THE REGION'S DEPTH. Four shader attempts
    /// drove it off `dRegion`, which for an extruded face region reaches 0 at the DEPTH
    /// CAPS as much as at the outline — it banded the wall's surfaces instead of tracing
    /// the face. It lives in the cell field now (`steppedCellField`), off the in-plane
    /// distance, where an inactive cell already renders solid.
    func testTheSolidOutlineIsNotDrivenByTheRegionDepth() {
        XCTAssertFalse(latticeFieldSource.contains("-(dRegion + rim)"),
                       "★ the solid outline is back on the region's 3-D field — that is "
                       + "the depth, and he ruled it is the SHAPE OF THE FACE")
    }
}
