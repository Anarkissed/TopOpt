import XCTest
@testable import TopOptFlows

/// ★ THE SAMPLE ANSWERS THE SINGLE-CELL TOGGLE (his backlog, 2026-08-24: "the
/// settings-page sample patch does not change when the single-cell/member toggle
/// moves"). The page derives the sample's cell through core's own derivation at the
/// mode's floor — floor 2 → 1 doubles the derived cell on the same member — and
/// hands it to `stageMesh(derivedCellMM:)`. This asserts the handoff is real: a
/// different derived cell is a different sample, and nil keeps the stored cell.
final class LatticeSampleSingleCellTests: XCTestCase {

    func testTheDerivedCellChangesTheSample() {
        let model = LatticeWizardModel(settings: LatticeSettings())
        let stored = model.stageMesh()
        let overridden = model.stageMesh(derivedCellMM: model.cellMM * 2)
        XCTAssertFalse(stored.vertices.isEmpty)
        XCTAssertFalse(overridden.vertices.isEmpty)
        // Same topology, twice the cell: the block spans twice the extent.
        func maxX(_ m: ViewerMesh) -> Float {
            stride(from: 0, to: m.vertices.count, by: 3).map { m.vertices[$0] }.max() ?? 0
        }
        XCTAssertEqual(maxX(overridden), 2 * maxX(stored), accuracy: 1e-3,
                       "a doubled derived cell must draw a doubled sample")
        // And nil is byte-identical to the stored cell — the toggle-less modes keep
        // the sample they have always had.
        XCTAssertEqual(model.stageMesh().vertices, stored.vertices)
    }
}
