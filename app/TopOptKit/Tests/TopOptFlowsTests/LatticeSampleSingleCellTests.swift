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
        XCTAssertFalse(stored.positions.isEmpty)
        XCTAssertFalse(overridden.positions.isEmpty)
        // Same topology, twice the cell: the block spans twice the extent.
        func maxX(_ m: ViewerMesh) -> Float {
            stride(from: 0, to: m.positions.count, by: 3).map { m.positions[$0] }.max() ?? 0
        }
        XCTAssertEqual(maxX(overridden), 2 * maxX(stored), accuracy: 1e-3,
                       "a doubled derived cell must draw a doubled sample")
        // And nil is byte-identical to the stored cell — the toggle-less modes keep
        // the sample they have always had.
        XCTAssertEqual(model.stageMesh().positions, stored.positions)
    }

    /// ★★★ THE RE-MADE STEPPED SAMPLE (his verdict: "still looks awful. Please
    /// re-make from scratch") is his own sentence built literally: "a single cell
    /// filling half the cube, with a grade around". The block is pinned to the
    /// MEMBER — flipping the floor between 1 and 2 keeps the envelope and changes
    /// the STRUCTURE, which is exactly what every previous rescaling version
    /// failed to do.
    func testCentreAndShellHoldsTheEnvelopeAcrossTheToggle() {
        let member = 10.0
        // Single-cell ON: derived cell == member, one coarse cell per half.
        let on = LatticeSamplePatch.mesh(lattice: .named("octet"), cellMM: member,
                                         cells: 2, relativeDensity: 0.3,
                                         boundary: .none, transition: .stepped,
                                         sides: 6, steppedCoarsePerHalf: 1)
        // OFF (floor 2): derived cell == member / 2, two coarse cells per half.
        let off = LatticeSamplePatch.mesh(lattice: .named("octet"), cellMM: member / 2,
                                          cells: 4, relativeDensity: 0.3,
                                          boundary: .none, transition: .stepped,
                                          sides: 6, steppedCoarsePerHalf: 2)
        func bounds(_ m: ViewerMesh) -> (Float, Float) {
            let xs = stride(from: 0, to: m.positions.count, by: 3).map { m.positions[$0] }
            return (xs.min() ?? 0, xs.max() ?? 0)
        }
        XCTAssertFalse(on.positions.isEmpty)
        XCTAssertFalse(off.positions.isEmpty)
        let bOn = bounds(on), bOff = bounds(off)
        // Strut RADIUS pads the hull past the lattice extent, and it scales
        // with the shell's own cell — so the envelope agrees to within a strut
        // diameter, not to a micron. The failure this guards against was a 2x
        // rescale, not a 0.8 mm skin.
        XCTAssertEqual(bOn.1 - bOn.0, bOff.1 - bOff.0, accuracy: 2.0,
                       "the toggle must not rescale the sample block")
        XCTAssertEqual(bOn.1 - bOn.0, Float(2 * member), accuracy: 2.0,
                       "the block is two members across")
        // Different structure, not a different size: OFF subdivides the centre.
        XCTAssertNotEqual(on.indices.count, off.indices.count,
                          "flipping the floor must change the structure")
        // The grade around: both samples carry geometry OUTSIDE the central
        // member cube (the shell) and INSIDE it (the centre cell(s)).
        func counts(_ m: ViewerMesh) -> (core: Int, shell: Int) {
            var core = 0, shell = 0
            let lo = Float(member) / 2, hi = Float(member) * 1.5
            var t = 0
            while t + 2 < m.indices.count {
                let i = Int(m.indices[t])
                let x = m.positions[i * 3], y = m.positions[i * 3 + 1]
                let z = m.positions[i * 3 + 2]
                if x > lo, x < hi, y > lo, y < hi, z > lo, z < hi { core += 1 }
                else { shell += 1 }
                t += 3
            }
            return (core, shell)
        }
        let cOn = counts(on), cOff = counts(off)
        XCTAssertGreaterThan(cOn.core, 0); XCTAssertGreaterThan(cOn.shell, 0)
        XCTAssertGreaterThan(cOff.core, 0); XCTAssertGreaterThan(cOff.shell, 0)
        XCTAssertGreaterThan(cOff.core, cOn.core,
                             "2×2×2 centre cells carry more triangles than one")
    }
}
