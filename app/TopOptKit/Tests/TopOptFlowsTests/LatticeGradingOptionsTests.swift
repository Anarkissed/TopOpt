import XCTest
import simd
@testable import TopOptFlows

/// ★ THE GRADING OPTIONS (his request, 2026-08-25): "No grade" and "Grade to fit
/// Shape", with stepped or dyadic stepping, and a per-face Cell the user states.
/// Each mode's contract is pinned through the REAL bake on the same synthetic slab
/// the shrunk-phase test uses.
final class LatticeGradingOptionsTests: XCTestCase {

    private struct Fixture {
        let occ: LatticeVoxelGrid
        let spec: LatticeRegionSpec
        let boundary: [[Double]?]
        let phase: [Float]
        let cell: Double
    }

    private func slab() -> Fixture {
        let nx = 34, ny = 20, nz = 34
        let origin = SIMD3<Float>(0.37, 0.63, 0.11)
        let spacing = SIMD3<Float>(repeating: 1)
        let cell = 6.0
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
        var spec = LatticeRegionSpec(role: .include, kind: .face)
        spec.origin = SIMD3<Double>(Double(origin.x) + 17, faceY, Double(origin.z) + 17)
        spec.normal = SIMD3<Double>(0, 1, 0)
        spec.halfUMM = 40
        spec.halfWMM = 40
        spec.depthMM = depth
        let cand = vals.map { $0 > 0.5 }
        let boundary = LatticeBoundaryDistance.inPlanePerRegion(
            regions: [spec], candidate: cand,
            nx: nx, ny: ny, nz: nz, spacing: spacing)
        let phase = LatticeSDFRenderer.faceTilingPhase(
            regions: [spec], cellMM: [cell], fallbackCellMM: cell, origin: origin)
        return Fixture(occ: occ, spec: spec, boundary: boundary,
                       phase: phase, cell: cell)
    }

    private func sizes(_ baked: LatticeCellField) -> Set<Double> {
        Set(baked.steppedCellMM.filter { $0 > 0 }.map { Double($0) })
    }

    /// "No grade": the outline never subdivides — every painted cell keeps the
    /// region's own cell (the slab is uniform, so the per-spot rule is inert).
    func testNoGradeDrawsOneCellSize() throws {
        let f = slab()
        guard let baked = LatticePreviewOccupancy.steppedCellField(
            occupancy: f.occ, demand: nil, regions: [f.spec],
            cellMM: [f.cell], baseCellMM: f.cell, regionPhase: f.phase,
            boundaryDistancePerRegion: f.boundary,
            finestCellMM: 1.5, shapeFitBandMM: 6,
            shapeFit: false) else { return XCTFail("no bake") }
        XCTAssertEqual(sizes(baked).count, 1,
                       "No grade must draw ONE cell size; got \(sizes(baked))")
        // And the rim distance still bakes — No grade keeps the solid outline.
        XCTAssertTrue(baked.level.contains { $0 > 0 && $0 < 1e3 },
                      "the outline distance must still bake under No grade")
    }

    /// Dyadic stepping: every division of the region cell is a power of two.
    func testDyadicStepsHalve() throws {
        let f = slab()
        guard let baked = LatticePreviewOccupancy.steppedCellField(
            occupancy: f.occ, demand: nil, regions: [f.spec],
            cellMM: [f.cell], baseCellMM: f.cell, regionPhase: f.phase,
            boundaryDistancePerRegion: f.boundary,
            finestCellMM: 1.5, shapeFitBandMM: 6,
            dyadicSteps: true) else { return XCTFail("no bake") }
        let all = sizes(baked)
        XCTAssertGreaterThan(all.count, 1, "the band graded nothing — vacuous")
        for s in all {
            let ratio = f.cell / s
            let rounded = pow(2.0, log2(ratio).rounded())
            XCTAssertEqual(ratio, rounded, accuracy: 0.02,
                           "cell \(s) is not a dyadic division of \(f.cell)")
        }
    }

    /// A user-stated cell is honoured as stated: never divided by the floor,
    /// only CAPPED at min(declared depth, local wall).
    func testStatedCellIsCappedNotDerived() throws {
        let f = slab()
        // The user types 4 mm; the wall holds 12 — the 4 must survive verbatim.
        guard let baked = LatticePreviewOccupancy.steppedCellField(
            occupancy: f.occ, demand: nil, regions: [f.spec],
            cellMM: [4.0], baseCellMM: 4.0, regionPhase: f.phase,
            boundaryDistancePerRegion: f.boundary,
            widthPerRegion: [
                [Double](repeating: 12.0, count: f.occ.values.count)],
            finestCellMM: 1.5, shapeFitBandMM: 0,
            shapeFit: false,
            cellIsUserStated: [true]) else { return XCTFail("no bake") }
        XCTAssertEqual(sizes(baked), [4.0],
                       "a stated 4 mm cell inside a 12 mm wall must stay 4 mm; "
                       + "got \(sizes(baked))")
        // And a stated cell PAST the wall is capped, never honoured into an
        // overshoot: 11 mm typed where the material measures 9 draws 9 at most.
        // (A number past the DECLARED depth cannot even be stored —
        // `writeLatticeCellMM` clamps at write time.)
        guard let capped = LatticePreviewOccupancy.steppedCellField(
            occupancy: f.occ, demand: nil, regions: [f.spec],
            cellMM: [11.0], baseCellMM: 11.0, regionPhase: f.phase,
            boundaryDistancePerRegion: f.boundary,
            widthPerRegion: [
                [Double](repeating: 9.0, count: f.occ.values.count)],
            finestCellMM: 1.5, shapeFitBandMM: 0,
            shapeFit: false,
            cellIsUserStated: [true]) else { return XCTFail("no bake") }
        for s in sizes(capped) {
            XCTAssertLessThanOrEqual(s, 9.0 + 1e-6,
                                     "a stated 11 mm cell must cap at its 9 mm wall")
        }
    }

    /// The settings round-trip: absent keys decode to the defaults, and an
    /// untouched project's encoding carries none of the new keys.
    func testSettingsRoundTripAndWireHygiene() throws {
        var s = LatticeSettings()
        s.enabled = true
        let bytes = try JSONEncoder().encode(s)
        let text = String(data: bytes, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("gradingMode"),
                       "an untouched project must not carry the key")
        XCTAssertFalse(text.contains("selectableCellMM"))
        let back = try JSONDecoder().decode(LatticeSettings.self, from: bytes)
        XCTAssertEqual(back.gradingMode, .full)
        XCTAssertEqual(back.gradeStepStyle, .stepped)
        XCTAssertTrue(back.selectableCellMM.isEmpty)

        s.gradingMode = .none
        s.gradeStepStyle = .dyadic
        s.selectableCellMM["f:x:15"] = 4.5
        let moved = try JSONDecoder().decode(LatticeSettings.self,
                                             from: JSONEncoder().encode(s))
        XCTAssertEqual(moved.gradingMode, LatticeGradingMode.none)
        XCTAssertEqual(moved.gradeStepStyle, .dyadic)
        XCTAssertEqual(moved.selectableCellMM["f:x:15"], 4.5)
    }
}
