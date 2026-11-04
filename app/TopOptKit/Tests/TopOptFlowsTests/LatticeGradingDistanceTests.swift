import XCTest
import simd
@testable import TopOptFlows

/// ★★★ THE DOUBLED LADDER'S SHAPE CEILING MUST READ THE OUTLINE, NOT THE WALL'S
/// THICKNESS (2026-08-24) — the same correction the stepped path already took.
///
/// A face region is an extrusion, so the 3-D distance to the edge of the latticed
/// material reaches 0 at the DEPTH CAPS as much as at the face's outline: through the
/// middle of a 12 mm wall it reads ~6 mm everywhere. At the one-cell sizes
/// single-cell now produces (12–13 mm), the `S ≤ 2d` ceiling then binds mid-wall and
/// cuts the very cells the mode exists to keep. `perVoxelForGrading` hands the
/// doubled path each voxel's OWNING region's in-plane distance instead, with the 3-D
/// field only where no axis-aligned face region owns the voxel.
final class LatticeGradingDistanceTests: XCTestCase {

    func testInPlaneDistanceGovernsInsideAFaceRegion() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var specs: [LatticeRegionSpec] = []
        for (face, depth) in [(FaceID(15), 12.0), (FaceID(2), 13.0)] {
            guard let r = LatticeRegionEmission.planeFor(face: face, in: mesh),
                  let spec = LatticeRegionEmission.spec(for: r, role: .include,
                                                        depthMM: depth, faceID: Int(face))
            else { throw XCTSkip("face \(face) has no planar geometry") }
            specs.append(spec)
        }
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: specs, whenEmpty: .latticeNothing)
        let occ = scene.occupancy
        let cand = occ.values.map { $0 > 0.5 }
        let volume = LatticeBoundaryDistance.millimetres(
            candidate: cand, nx: occ.nx, ny: occ.ny, nz: occ.nz, spacing: occ.spacing)
        let combined = LatticeBoundaryDistance.perVoxelForGrading(
            regions: specs, candidate: cand,
            nx: occ.nx, ny: occ.ny, nz: occ.nz, spacing: occ.spacing,
            origin: occ.origin)
        XCTAssertEqual(combined.count, volume.count)

        // Dropping the thickness axis can only push the boundary AWAY, so inside a
        // region the in-plane distance is never below the 3-D one.
        var owned = 0, raised = 0
        var vMax = 0.0, cMax = 0.0
        for i in 0..<combined.count where cand[i] {
            if combined[i] > volume[i] + 1e-9 { raised += 1 }
            XCTAssertGreaterThanOrEqual(combined[i], volume[i] - 1e-9,
                                        "in-plane must never be closer than 3-D")
            owned += 1
            vMax = Swift.max(vMax, volume[i]); cMax = Swift.max(cMax, combined[i])
        }
        XCTAssertGreaterThan(owned, 0)
        // The 3-D field is capped near half the wall thickness (~6–7 mm on these
        // walls); the in-plane field spans the face. If the swap did nothing, the
        // ceiling is still reading the thickness.
        XCTAssertGreaterThan(raised, owned / 4,
                             "most of a thin wall should read farther in-plane")
        XCTAssertGreaterThan(cMax, vMax + 5,
                             "the in-plane reach must exceed the wall's half-thickness cap")
    }

    /// No regions ⇒ the 3-D field, byte-identical — a whole-part lattice keeps the
    /// behaviour it has always had.
    func testNoRegionsFallsBackToTheVolumeField() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: [], whenEmpty: .latticeEverything)
        let occ = scene.occupancy
        let cand = occ.values.map { $0 > 0.5 }
        let volume = LatticeBoundaryDistance.millimetres(
            candidate: cand, nx: occ.nx, ny: occ.ny, nz: occ.nz, spacing: occ.spacing)
        let combined = LatticeBoundaryDistance.perVoxelForGrading(
            regions: [], candidate: cand,
            nx: occ.nx, ny: occ.ny, nz: occ.nz, spacing: occ.spacing,
            origin: occ.origin)
        XCTAssertEqual(combined, volume)
    }
}
