import XCTest
import simd
@testable import TopOptFlows

/// The grade-to-shape band, as he asked for it on 2026-09-12 with a screenshot of
/// open 6 mm cells against the solid ring on his stand's curved chamfer:
///
/// > "holes next to the curved outline. This is where I want to see smaller lattice,
/// > to quilt, to solid outline all the way around the lattice - attaching the
/// > lattice to the chamfer outline."
///
/// Before this the band was measured from the OUTLINE, so the solid ring (the first
/// half cell) ate most of a 5 mm band on a 6 mm cell, and whether a row of cells
/// stepped down depended on where the tiling's phase dropped a centre: 125 of 3,369
/// cells on his part, and open cells against the ring round most of the curve.
///
/// Now the band keeps his reading — millimetres from the outline — but is never narrower
/// than the ring plus one row of the base cell, its rows are counted from the ring so a
/// curve reads the same all the way round, and
/// the drawn density climbs row by row to the quilt ceiling in the row against the
/// ring — his "leave the grade to shape alone … I like the look of a quilt as part
/// of the grade to solid". That row is the one place the octet aesthetic ceiling
/// does not apply.
final class LatticeGradeToSolidBandTests: XCTestCase {
    private struct Fixture {
        let occ: LatticeVoxelGrid
        let demand: LatticeVoxelGrid
        let spec: LatticeRegionSpec
        let boundary: [[Double]?]
        let phase: [Float]
        let cell: Double
        let halfMM: Double
    }

    private let lo = 0.073, hi = 0.9, ambient: Float = 0.177   // his Fine project's band
    private let cell = 6.0, finest = 2.6                       // one rung: 6 → 3 mm

    /// A 30 × 30 mm slab face, 12 mm deep, with a square outline half a voxel inside
    /// its occupancy so the ring and the band have an exact outline to measure from.
    private func slab(across nx: Int = 34) -> Fixture {
        let ny = 20, nz = nx
        let origin = SIMD3<Float>(0.37, 0.63, 0.11)
        let spacing = SIMD3<Float>(repeating: 1)
        let faceY = Double(origin.y) + 1.8
        let depth = 12.0
        var vals = [Float](repeating: 0, count: nx * ny * nz)
        for k in 2..<(nz - 2) {
            for j in 0..<ny {
                let y = Double(origin.y) + Double(j)
                guard y >= faceY - 0.5, y <= faceY + depth + 0.5 else { continue }
                for i in 2..<(nx - 2) {
                    vals[(k * ny + j) * nx + i] = 1
                }
            }
        }
        let occ = LatticeVoxelGrid(nx: nx, ny: ny, nz: nz, origin: origin,
                                   spacing: spacing, values: vals)
        let demand = LatticeVoxelGrid(nx: nx, ny: ny, nz: nz, origin: origin,
                                      spacing: spacing,
                                      values: [Float](repeating: ambient, count: vals.count))
        var spec = LatticeRegionSpec(role: .include, kind: .face)
        let centre = Double(nx / 2)
        spec.origin = SIMD3<Double>(Double(origin.x) + centre, faceY, Double(origin.z) + centre)
        spec.normal = SIMD3<Double>(0, 1, 0)
        spec.halfUMM = 40
        spec.halfWMM = 40
        spec.depthMM = depth
        let halfMM = centre - 2.5   // the outline, half a voxel inside the occupancy
        spec.outlineLoops = [[SIMD2(-halfMM, -halfMM), SIMD2(halfMM, -halfMM),
                              SIMD2(halfMM, halfMM), SIMD2(-halfMM, halfMM)]]
        let cand = vals.map { $0 > 0.5 }
        let boundary = LatticeBoundaryDistance.inPlanePerRegion(
            regions: [spec], candidate: cand,
            nx: nx, ny: ny, nz: nz, spacing: spacing)
        let phase = LatticeSDFRenderer.faceTilingPhase(
            regions: [spec], cellMM: [cell], fallbackCellMM: cell, origin: origin)
        return Fixture(occ: occ, demand: demand, spec: spec, boundary: boundary,
                       phase: phase, cell: cell, halfMM: halfMM)
    }

    private func bake(_ f: Fixture, band: Double, dyadic: Bool = true,
                      span: (lo: Double, hi: Double)? = nil) throws -> LatticeCellField {
        try XCTUnwrap(LatticePreviewOccupancy.steppedCellField(
            occupancy: f.occ, demand: f.demand, regions: [f.spec],
            cellMM: [f.cell], baseCellMM: f.cell, regionPhase: f.phase,
            boundaryDistancePerRegion: f.boundary,
            finestCellMM: finest, shapeFitBandMM: band, lineWidthMM: 0.45,
            densityLo: span?.lo ?? lo, densityHi: span?.hi ?? hi, densityGamma: 1,
            latticeID: "octet", shapeFit: true, dyadicSteps: dyadic), "no bake")
    }

    /// One painted texel: how far in from the outline its centre sits (the bake's own
    /// measure), the cell it draws, whether it is solid, and its activation.
    private struct Texel {
        let dOutline: Double
        let cellMM: Double
        let solid: Bool
        let activation: Float
    }

    private func texels(_ baked: LatticeCellField, _ f: Fixture) -> [Texel] {
        let g = baked.field
        let rn = LatticeRegionMask.unit(f.spec.normal)
        let (bu, bv) = LatticeRegionMask.basis(rn)
        var out: [Texel] = []
        var i = 0
        for k in 0..<g.nz {
            for j in 0..<g.ny {
                for x in 0..<g.nx {
                    defer { i += 1 }
                    let s = baked.steppedCellMM[i]
                    guard s > 0 else { continue }
                    let p = SIMD3<Double>(
                        Double(g.origin.x) + Double(x) * Double(g.spacing.x),
                        Double(g.origin.y) + Double(j) * Double(g.spacing.y),
                        Double(g.origin.z) + Double(k) * Double(g.spacing.z))
                    let rel = p - f.spec.origin
                    let u = simd_dot(rel, bu), v = simd_dot(rel, bv)
                    let dOut = f.halfMM - Swift.max(abs(u), abs(v))
                    out.append(Texel(dOutline: dOut, cellMM: Double(s),
                                     solid: baked.level[i] <= 0,
                                     activation: g.values[i]))
                }
            }
        }
        return out
    }

    private var ringDepth: Double { 0.5 * cell }        // one ring: half a base cell
    private var quiltActivation: Float {
        let quilt = Swift.min(hi, LatticeType.named("octet").quiltRowDensity(cellMM: cell / 2))
        return Float((quilt - lo) / (hi - lo))
    }

    // MARK: - The quilt the band lands on

    /// The quilt row's density is where the strut law SATURATES — for the octet the
    /// measured table is flat above ≈ 0.60 (d/L 0.384, windows 7 % open), so 0.60
    /// and 1.0 draw the same strut — and it is the same at every cell size because
    /// the table is linear in the cell. `quiltDensityCeiling` cannot be that
    /// number: its separation target sits above the table's top and answers 1.
    func testTheQuiltRowDensityIsWhereTheOctetLawSaturates() {
        let o = LatticeType.named("octet")
        for c in [2.58, 3.0, 4.0, 6.0, 12.0] {
            let q = o.quiltRowDensity(cellMM: c)
            XCTAssertEqual(q, 0.60, accuracy: 0.02, "cell \(c) mm: \(q)")
            XCTAssertLessThan(q, 0.99, "the quilt row must stop short of solid at \(c) mm")
            XCTAssertEqual(o.strutRadiusMM(relativeDensity: q, cellMM: c),
                           o.strutRadiusMM(relativeDensity: 1.0, cellMM: c),
                           accuracy: 2e-3 * o.strutRadiusMM(relativeDensity: 1.0, cellMM: c),
                           "at the quilt row the law draws its widest strut")
            XCTAssertEqual(o.quiltDensityCeiling(cellMM: c), 1, accuracy: 1e-9,
                           "the separation ceiling is unreachable for the octet — why it is not used")
        }
    }

    // MARK: - The row against the ring

    /// A 5 mm band on a 6 mm cell used to catch a row only by phase. Now EVERY
    /// non-solid texel whose centre lies within one base cell of the ring's inner
    /// face steps down to the finest rung and is drawn at the quilt ceiling.
    func testTheRowAgainstTheRingAlwaysStepsDownAndQuilts() throws {
        let f = slab()
        let all = texels(try bake(f, band: 5), f)
        let ring = all.filter { $0.dOutline < ringDepth && $0.dOutline > -1e-6 }
        let row0 = all.filter { !$0.solid && $0.dOutline >= ringDepth && $0.dOutline < ringDepth + cell }
        let beyond = all.filter { !$0.solid && $0.dOutline >= ringDepth + cell }
        XCTAssertFalse(ring.isEmpty, "the fixture must have a ring — vacuous otherwise")
        XCTAssertFalse(row0.isEmpty, "the fixture must have a row against the ring — vacuous otherwise")
        XCTAssertFalse(beyond.isEmpty, "the fixture must have cells beyond the band — vacuous otherwise")
        XCTAssertTrue(ring.allSatisfy { $0.solid },
                      "the ring is still solid: \(ring.filter { !$0.solid }.count) of \(ring.count) open")
        for t in row0 {
            XCTAssertEqual(t.cellMM, cell / 2, accuracy: 0.02,
                           "the row against the ring must step down to \(cell / 2) mm; "
                           + "at \(String(format: "%.2f", t.dOutline)) mm in it drew \(t.cellMM)")
            XCTAssertGreaterThanOrEqual(t.activation, quiltActivation - 0.02,
                           "the row against the ring must be drawn at the quilt ceiling "
                           + "(activation \(quiltActivation)); at \(String(format: "%.2f", t.dOutline)) mm "
                           + "it is \(t.activation)")
        }
        for t in beyond {
            XCTAssertEqual(t.cellMM, cell, accuracy: 0.02,
                           "beyond the band the base cell stands; at \(t.dOutline) mm it drew \(t.cellMM)")
            XCTAssertEqual(t.activation, ambient, accuracy: 0.01,
                           "beyond the band the cell's own density stands; at \(t.dOutline) mm it is \(t.activation)")
        }
    }

    /// Band 0 is his "grade only where a cell will not fit": no row is forced, and
    /// nothing is thickened.
    func testBandZeroLeavesTheRowAgainstTheRingAlone() throws {
        let f = slab()
        let all = texels(try bake(f, band: 0), f)
        let open = all.filter { !$0.solid && $0.dOutline >= ringDepth }
        XCTAssertFalse(open.isEmpty, "vacuous")
        XCTAssertTrue(open.allSatisfy { abs($0.cellMM - cell) < 0.02 },
                      "band 0 must not step a row down: \(Set(open.map { $0.cellMM }))")
        XCTAssertTrue(open.allSatisfy { abs($0.activation - ambient) < 0.01 },
                      "band 0 must not thicken anything: \(Set(open.map { $0.activation }))")
    }

    /// A band wider than one row grades row by row: the row against the ring is the
    /// quilt, each row further in is thinner, and past the band the cell's own
    /// density stands.
    func testAWiderBandGradesRowByRowTowardTheRing() throws {
        let f = slab(across: 60)   // 56 mm across: room for three rows and a middle
        let all = texels(try bake(f, band: 21), f)   // 21 mm from the outline: the 3 mm ring + three rows
        func row(_ r: Int) -> [Texel] {
            all.filter { !$0.solid
                && $0.dOutline >= ringDepth + Double(r) * cell
                && $0.dOutline < ringDepth + Double(r + 1) * cell }
        }
        let r0 = row(0), r1 = row(1), r2 = row(2)
        XCTAssertFalse(r0.isEmpty); XCTAssertFalse(r1.isEmpty)
        XCTAssertFalse(r2.isEmpty, "the fixture is too small for three rows — vacuous")
        func act(_ ts: [Texel]) -> (min: Float, max: Float) {
            (ts.map { $0.activation }.min() ?? -1, ts.map { $0.activation }.max() ?? -1)
        }
        let a0 = act(r0), a1 = act(r1), a2 = act(r2)
        XCTAssertGreaterThanOrEqual(a0.min, quiltActivation - 0.02, "row 0 is the quilt: \(a0)")
        XCTAssertGreaterThan(a1.min, ambient + 0.05, "row 1 is thickened: \(a1)")
        XCTAssertLessThan(a1.max, a0.min, "row 1 is thinner than row 0: \(a1) vs \(a0)")
        XCTAssertGreaterThan(a2.min, ambient + 0.02, "row 2 is thickened: \(a2)")
        XCTAssertLessThan(a2.max, a1.min, "row 2 is thinner than row 1: \(a2) vs \(a1)")
        for t in r0 + r1 + r2 {
            XCTAssertEqual(t.cellMM, cell / 2, accuracy: 0.02,
                           "with one rung the whole band steps down; at \(t.dOutline) mm it drew \(t.cellMM)")
        }
    }

    /// His Fine project hands the bake a POINT span — manual thickness, lo == hi ==
    /// 0.219 — and a point span cannot express a row thicker than the rest (the
    /// device's first build: bandRows=1950, quiltRaised=0). The field must widen
    /// the span it is drawn over to reach the quilt, say so in `drawnDensityHi`, and
    /// re-encode every other cell so it still draws at the stated density.
    func testAPointSpanIsWidenedToReachTheQuilt() throws {
        let f = slab()
        let stated = 0.21887
        let baked = try bake(f, band: 5, span: (stated, stated))
        let quilt = Swift.min(1, LatticeType.named("octet").quiltRowDensity(cellMM: cell))
        XCTAssertGreaterThan(quilt, stated + 0.1, "the quilt must sit well above the stated density — vacuous otherwise")
        XCTAssertEqual(baked.drawnDensityHi, quilt, accuracy: 1e-6,
                       "the field must carry the widened top out for the renderer and the callout")
        let all = texels(baked, f)
        let row0 = all.filter { !$0.solid && $0.dOutline >= ringDepth && $0.dOutline < ringDepth + cell }
        let beyond = all.filter { !$0.solid && $0.dOutline >= ringDepth + cell }
        XCTAssertFalse(row0.isEmpty); XCTAssertFalse(beyond.isEmpty)
        func rho(_ t: Texel) -> Double { stated + (quilt - stated) * Double(t.activation) }
        for t in row0 {
            let want = Swift.min(quilt, LatticeType.named("octet").quiltRowDensity(cellMM: cell / 2))
            XCTAssertEqual(rho(t), want, accuracy: 0.01,
                           "the row against the ring draws at the quilt over the widened span; "
                           + "at \(t.dOutline) mm it draws \(rho(t))")
        }
        for t in beyond {
            XCTAssertEqual(rho(t), stated, accuracy: 0.005,
                           "beyond the band the STATED density still draws; at \(t.dOutline) mm it draws \(rho(t))")
        }
    }

    /// With a real span the field does not widen, and says so.
    func testARealSpanIsLeftAlone() throws {
        let f = slab()
        let baked = try bake(f, band: 5)
        XCTAssertEqual(baked.drawnDensityHi, 0, "a span that already reaches the quilt is not widened")
    }

    /// The band and the ring use the SAME measure, so the row that steps down is the
    /// row that touches the solid — never a row with open base cells between them.
    func testNoOpenBaseCellSitsBetweenTheRingAndTheSteppedRow() throws {
        let f = slab()
        let all = texels(try bake(f, band: 5), f)
        let openBase = all.filter { !$0.solid && abs($0.cellMM - cell) < 0.02 }
        let nearest = openBase.map { $0.dOutline }.min() ?? .infinity
        XCTAssertGreaterThanOrEqual(nearest, ringDepth + cell - 1e-6,
            "an open base cell sits \(nearest) mm in, inside the row that must touch the ring")
    }
}
