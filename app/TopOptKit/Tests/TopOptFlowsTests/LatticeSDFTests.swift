// LatticeSDFTests — headless correctness for the raymarched-lattice model (no GPU,
// the /app/ standard). Pins the pieces the picture depends on: the segment soup is
// faithful to the worker's cell, the occupancy voxelisation actually contains the
// part, the grading map round-trips, and the honesty flag is set.

import XCTest
import simd
import TopOptDesign
@testable import TopOptFlows

final class LatticeSDFTests: XCTestCase {

    // MARK: segment soup

    func testOctetSegmentsCoverAndAreFaithful() {
        let p = LatticeSDFPreview(latticeID: "octet")
        // Every canonical strut has a copy in the centred soup (faithful geometry).
        XCTAssertGreaterThanOrEqual(p.segments.count, LatticeType.octet.struts.count)
        // All endpoints lie within one padded cell of the origin (bounded soup).
        for s in p.segments {
            for c in [s.a, s.b] {
                XCTAssertLessThanOrEqual(abs(c.x), 1.51)
                XCTAssertLessThanOrEqual(abs(c.y), 1.51)
                XCTAssertLessThanOrEqual(abs(c.z), 1.51)
            }
        }
        // Seamless-tiling sanity: no interior point of the central cell is far from a
        // strut (an empty centre would render as a hole). Sample the folded field on a
        // grid; the max min-distance must be well under half a cell.
        var worst: Float = 0
        let rn: Float = 0.08
        for gz in 0...6 { for gy in 0...6 { for gx in 0...6 {
            let q = SIMD3<Float>(Float(gx) / 6 - 0.5, Float(gy) / 6 - 0.5, Float(gz) / 6 - 0.5)
            var d = Float.greatestFiniteMagnitude
            for s in p.segments { d = min(d, capsule(q, s.a, s.b, rn)) }
            worst = max(worst, d)
        } } }
        XCTAssertLessThan(worst, 0.30, "a point in the cell is too far from any strut — soup has a gap")
    }

    // MARK: grading map

    func testGradingRoundTrips() {
        let p = LatticeSDFPreview(latticeID: "octet")
        for rho in [0.05, 0.2, 0.4, 0.6] {
            let rn = Double(p.normalizedRadius(relativeDensity: rho))
            XCTAssertEqual(p.relativeDensity(normalizedRadius: rn), rho, accuracy: 1e-6)
        }
        // Denser → fatter strut.
        XCTAssertGreaterThan(p.normalizedRadius(relativeDensity: 0.6),
                             p.normalizedRadius(relativeDensity: 0.1))
    }

    func testAlwaysApproximateAndLabelled() {
        let p = LatticeSDFPreview(latticeID: "octet")
        XCTAssertTrue(p.isApproximate)
        XCTAssertTrue(p.previewLabel.lowercased().contains("not the exported"))
    }

    // MARK: occupancy

    func testOccupancyContainsAUnitCube() {
        // A 10 mm cube at the origin → interior voxels inside, corners of the box outside.
        let (v, i) = cubeMesh(side: 10)
        let bounds = MeshGeometry.bounds(vertices: v)
        let occ = LatticePreviewOccupancy.occupancy(positions: v, indices: i, bounds: bounds, maxDim: 24)
        func at(_ x: Int, _ y: Int, _ z: Int) -> Float { occ.values[(z * occ.ny + y) * occ.nx + x] }
        XCTAssertEqual(at(occ.nx / 2, occ.ny / 2, occ.nz / 2), 1, "centre must be inside")
        // A large fraction of voxels are filled (a solid cube fills its own box).
        let filled = occ.values.reduce(0) { $0 + ($1 > 0.5 ? 1 : 0) }
        XCTAssertGreaterThan(Double(filled) / Double(occ.count), 0.5)
    }

    // MARK: part signed distance (the round-3 flush trim)

    func testSignedDistanceOfCube() {
        let (v, i) = cubeMesh(side: 10)
        let bounds = MeshGeometry.bounds(vertices: v)
        let occ = LatticePreviewOccupancy.occupancy(positions: v, indices: i, bounds: bounds, maxDim: 24)
        let sdf = LatticePreviewOccupancy.signedDistance(positions: v, indices: i, like: occ)
        func at(_ x: Int, _ y: Int, _ z: Int) -> Float { sdf.values[(z * sdf.ny + y) * sdf.nx + x] }
        // Centre is inside (negative), clamped to the band.
        XCTAssertLessThan(at(sdf.nx / 2, sdf.ny / 2, sdf.nz / 2), 0)
        // A voxel one step inside a face has exact distance ≈ its offset from x=0:
        // voxel (1, mid, mid) sits at x = spacing.x, i.e. distance spacing.x inside.
        let d = at(1, sdf.ny / 2, sdf.nz / 2)
        XCTAssertEqual(d, -sdf.spacing.x, accuracy: sdf.spacing.x * 0.05,
                       "near-face distance must be EXACT (plane accuracy → straight trimmed edges)")
        // Corner voxel (0,0,0) lies ON the surface: |d| ≈ 0.
        XCTAssertEqual(abs(at(0, 0, 0)), 0, accuracy: sdf.spacing.x * 0.05)
        // Sign flips across the surface and magnitudes clamp to the band.
        let band = 3 * Swift.min(sdf.spacing.x, Swift.min(sdf.spacing.y, sdf.spacing.z))
        for val in sdf.values { XCTAssertLessThanOrEqual(abs(val), band + 1e-4) }
    }

    func testDemandNilWithoutField() {
        let (v, i) = cubeMesh(side: 10)
        let bounds = MeshGeometry.bounds(vertices: v)
        let occ = LatticePreviewOccupancy.occupancy(positions: v, indices: i, bounds: bounds, maxDim: 16)
        XCTAssertNil(LatticePreviewOccupancy.demand(like: occ, field: nil))
    }

    // MARK: helpers

    private func capsule(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ r: Float) -> Float {
        let pa = p - a, ba = b - a
        let h = max(0, min(1, simd_dot(pa, ba) / simd_dot(ba, ba)))
        return simd_length(pa - ba * h) - r
    }

    /// An axis-aligned solid cube [0,side]³ as a triangle soup (12 tris).
    private func cubeMesh(side s: Float) -> ([Float], [UInt32]) {
        let c: [SIMD3<Float>] = [
            [0,0,0],[s,0,0],[s,s,0],[0,s,0],
            [0,0,s],[s,0,s],[s,s,s],[0,s,s]]
        let faces = [[0,1,2,3],[5,4,7,6],[4,0,3,7],[1,5,6,2],[4,5,1,0],[3,2,6,7]]
        var verts: [Float] = []; var idx: [UInt32] = []
        for f in faces {
            let base = UInt32(verts.count / 3)
            for vi in f { verts += [c[vi].x, c[vi].y, c[vi].z] }
            idx += [base, base+1, base+2, base, base+2, base+3]
        }
        return (verts, idx)
    }
}
