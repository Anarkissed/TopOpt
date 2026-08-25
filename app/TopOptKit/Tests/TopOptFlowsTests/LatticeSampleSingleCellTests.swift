import XCTest
@testable import TopOptFlows

/// ★ THE SAMPLE ANSWERS THE SINGLE-CELL TOGGLE (his backlog, 2026-08-24), and since
/// 2026-08-25 it answers it in the shape he specified: "a single cell that fits the
/// entire depth and goes all the way through, and the sample should be WIDER than
/// the others to show that it then is graded to 3 then 4 then 5 to fit the shape" —
/// dyadic being "the same but in twos".
final class LatticeSampleSingleCellTests: XCTestCase {

    func testTheDerivedCellChangesTheSample() {
        let model = LatticeWizardModel(settings: LatticeSettings())
        let stored = model.stageMesh()
        let overridden = model.stageMesh(derivedCellMM: model.cellMM * 2)
        XCTAssertFalse(stored.positions.isEmpty)
        XCTAssertFalse(overridden.positions.isEmpty)
        func maxX(_ m: ViewerMesh) -> Float {
            stride(from: 0, to: m.positions.count, by: 3).map { m.positions[$0] }.max() ?? 0
        }
        XCTAssertEqual(maxX(overridden), 2 * maxX(stored), accuracy: 1e-3,
                       "a doubled derived cell must draw a doubled sample")
        XCTAssertEqual(model.stageMesh().positions, stored.positions)
    }

    private func run(_ member: Double, k: Int, dyadic: Bool) -> ViewerMesh {
        LatticeSamplePatch.mesh(lattice: .named("octet"), cellMM: member,
                                cells: 2, relativeDensity: 0.3,
                                boundary: .none, transition: .stepped,
                                sides: 6, steppedCoarsePerHalf: k,
                                dyadicSteps: dyadic)
    }

    private func extent(_ m: ViewerMesh) -> (w: Float, h: Float, d: Float) {
        let xs = stride(from: 0, to: m.positions.count, by: 3).map { m.positions[$0] }
        let ys = stride(from: 1, to: m.positions.count, by: 3).map { m.positions[$0] }
        let zs = stride(from: 2, to: m.positions.count, by: 3).map { m.positions[$0] }
        return ((xs.max() ?? 0) - (xs.min() ?? 0),
                (ys.max() ?? 0) - (ys.min() ?? 0),
                (zs.max() ?? 0) - (zs.min() ?? 0))
    }

    /// ★ WIDER THAN IT IS DEEP, and by the number of steps in the run — the whole
    /// point of the shape he asked for: one cell through the depth, then the grade
    /// marching across the width.
    func testTheRunIsWideAndOneCellDeep() {
        let member = 10.0
        let e = extent(run(member, k: 1, dyadic: false))
        // Four columns, each one cube wide; height and depth stay ONE cube.
        XCTAssertEqual(e.h, e.d, accuracy: 1.5, "the run is square in section")
        XCTAssertGreaterThan(e.w, 3 * e.h,
                             "the run must be much wider than it is deep — "
                             + "w \(e.w) vs h \(e.h)")
        // The hull includes the strut RADIUS, so the tolerance is a strut, not a
        // micron — the failure this guards is a rescale, not a skin.
        XCTAssertEqual(e.w, Float(4 * member), accuracy: 3.0,
                       "four columns, each one derived cell wide")
        XCTAssertEqual(e.h, Float(member), accuracy: 3.0,
                       "one cell spans the whole depth")
    }

    /// ★ THE TOGGLE CHANGES THE STRUCTURE, NOT THE SCALE — floor 2 divides every
    /// column twice as finely inside the SAME run.
    func testTheToggleChangesStructureNotScale() {
        let member = 10.0
        let on = run(member, k: 1, dyadic: false)      // single-cell: 1·3·4·5
        let off = run(member / 2, k: 2, dyadic: false) // floor 2: 2·6·8·10
        let a = extent(on), b = extent(off)
        XCTAssertEqual(a.w, b.w, accuracy: 2.0, "the run must not rescale")
        XCTAssertEqual(a.h, b.h, accuracy: 2.0)
        XCTAssertNotEqual(on.indices.count, off.indices.count,
                          "flipping the floor must change the structure")
        XCTAssertGreaterThan(off.indices.count, on.indices.count,
                             "a finer floor carries more struts")
    }

    /// ★ DYADIC IS "THE SAME BUT IN TWOS" — same envelope, different run.
    func testDyadicKeepsTheEnvelopeAndChangesTheRun() {
        let member = 10.0
        let stepped = run(member, k: 1, dyadic: false)  // 1·3·4·5
        let dyadic = run(member, k: 1, dyadic: true)    // 1·2·4·8
        let a = extent(stepped), b = extent(dyadic)
        XCTAssertEqual(a.w, b.w, accuracy: 2.0, "same envelope")
        XCTAssertEqual(a.h, b.h, accuracy: 2.0)
        XCTAssertNotEqual(stepped.indices.count, dyadic.indices.count,
                          "the step style must change what is drawn")
    }
}
