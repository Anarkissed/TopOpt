import XCTest
import simd
@testable import TopOptFlows

/// ★ PROBE (2026-09-23 00:10, his images 1 & 8): which prism selects each voxel of the
/// part, and where the material NO prism selects sits.
final class LatticeStandCoverageProbe: XCTestCase {
    func testWhoSelectsWhat() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let gid = UUID()
        let group = SelectionGroup(id: gid, name: "C", colorIndex: 0, faces: [15, 2, 23], regionIDs: [])
        let key23 = LatticeSelectableRef.face(group: gid, face: 23).key
        let solidGrid = LatticePreviewOccupancy.occupancy(positions: mesh.positions, indices: mesh.indices, bounds: mesh.bounds, maxDim: 128)
        let regions = LatticeRegionEmission.regions(
            groups: [group], roles: [gid: .include], primitives: { _ in [] }, includePrimitives: [],
            faceDepthMM: 12,
            selectableDepthMM: [LatticeSelectableRef.face(group: gid, face: 2).key: 13, key23: 20],
            selectableExpandMM: [key23: 4.15],
            facets: { LatticeFaceFacets.facets(face: $0, in: mesh) },
            solidAt: { p in
                let g = (SIMD3<Float>(p) - solidGrid.origin) / solidGrid.spacing
                let i = Int(g.x.rounded()), j = Int(g.y.rounded()), k = Int(g.z.rounded())
                guard i >= 0, j >= 0, k >= 0, i < solidGrid.nx, j < solidGrid.ny, k < solidGrid.nz else { return false }
                return solidGrid.values[(k * solidGrid.ny + j) * solidGrid.nx + i] > 0.5
            },
            resolve: { LatticeRegionEmission.planeFor(face: $0, in: mesh) }).regions
        let occ = LatticePreviewOccupancy.occupancy(positions: mesh.positions, indices: mesh.indices, bounds: mesh.bounds, maxDim: 128)
        let h = occ.spacing
        print("PROBE bounds \(mesh.bounds.min) … \(mesh.bounds.max), voxel \(h)")
        // per voxel: bit 1 = face 15, 2 = face 2, 4 = face 23 (any facet)
        var total = 0, none = 0, only15 = 0, only2 = 0, both15and2 = 0, any23 = 0
        let zBins = 12
        var zNone = [Int](repeating: 0, count: zBins), zPart = [Int](repeating: 0, count: zBins)
        var noneBox = (lo: SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi: SIMD3<Float>(repeating: -.greatestFiniteMagnitude))
        for k in 0..<occ.nz { for j in 0..<occ.ny { for i in 0..<occ.nx {
            guard occ.values[(k * occ.ny + j) * occ.nx + i] > 0.5 else { continue }
            total += 1
            let p = SIMD3<Double>(occ.origin + SIMD3<Float>(Float(i), Float(j), Float(k)) * h)
            var m = 0
            for r in regions where LatticeRegionMask.contains(p, region: r) {
                if r.faceID == 15 { m |= 1 } else if r.faceID == 2 { m |= 2 } else { m |= 4 }
            }
            let zb = min(zBins - 1, Int(Double(k) / Double(occ.nz) * Double(zBins)))
            zPart[zb] += 1
            if m == 0 { none += 1; zNone[zb] += 1; noneBox.lo = simd_min(noneBox.lo, SIMD3<Float>(p)); noneBox.hi = simd_max(noneBox.hi, SIMD3<Float>(p)) }
            if m & 3 == 1 { only15 += 1 }; if m & 3 == 2 { only2 += 1 }; if m & 3 == 3 { both15and2 += 1 }; if m & 4 != 0 { any23 += 1 }
        } } }
        print("PROBE part voxels \(total): in NO prism \(none) (\(100 * none / max(1, total)) %) · only f15 \(only15) · only f2 \(only2) · f15∧f2 \(both15and2) · any f23 \(any23)")
        print("PROBE unselected by height bin (bottom→top): \(zip(zNone, zPart).map { "\($0)/\($1)" })")
        print("PROBE unselected bbox \(noneBox.lo) … \(noneBox.hi)")
        var colCount = [Int: Int]()
        for k in (2 * occ.nz / 3)..<occ.nz { for j in 0..<occ.ny { for i in 0..<occ.nx where occ.values[(k * occ.ny + j) * occ.nx + i] > 0.5 { colCount[i, default: 0] += 1 } } }
        guard let ix = colCount.max(by: { $0.value < $1.value })?.key else { return }
        // which CAD face owns the surface at the leg's two sides, at several heights; and the
        // world extents of faces 15's and 2's outlines
        func nearestFace(_ p: SIMD3<Float>) -> (face: Int32, dist: Float) {
            var best: (Int32, Float) = (-1, .greatestFiniteMagnitude)
            var t = 0
            while t + 2 < mesh.indices.count {
                let tri = t / 3
                var c = SIMD3<Float>.zero
                for k in 0..<3 { let b = Int(mesh.indices[t + k]) * 3; c += SIMD3<Float>(mesh.positions[b], mesh.positions[b + 1], mesh.positions[b + 2]) }
                c /= 3
                let d = simd_length(c - p)
                if d < best.1 { best = (tri < mesh.faceIDs.count ? mesh.faceIDs[tri] : -1, d) }
                t += 3
            }
            return best
        }
        for zf in [0.9, 0.7, 0.45] {
            let z = Float(mesh.bounds.min.z) + Float(zf) * Float(mesh.bounds.max.z - mesh.bounds.min.z)
            let x = Float(occ.origin.x) + Float(ix) * h.x
            let a = nearestFace(SIMD3(x, mesh.bounds.max.y, z)), b = nearestFace(SIMD3(x, mesh.bounds.min.y, z))
            print(String(format: "PROBE leg side faces at z=%.0f x=%.0f: +y side f%d (%.1f mm off) · -y side f%d (%.1f mm off)", z, x, a.face, a.dist, b.face, b.dist))
        }
        for r in regions where r.faceID == 15 || r.faceID == 2 {
            let n = LatticeRegionMask.unit(r.normal); let (bu, bv) = LatticeRegionMask.basis(n)
            var lo = SIMD3<Double>(repeating: 1e9), hi = SIMD3<Double>(repeating: -1e9)
            for loop in r.outlineLoops { for q in loop { let w = r.origin + bu * q.x + bv * q.y; lo = simd_min(lo, w); hi = simd_max(hi, w) } }
            print(String(format: "PROBE face %d outline world extents: x %.1f…%.1f  z %.1f…%.1f (part x %.1f…%.1f z %.1f…%.1f)", r.faceID ?? -1, lo.x, hi.x, lo.z, hi.z, Double(mesh.bounds.min.x), Double(mesh.bounds.max.x), Double(mesh.bounds.min.z), Double(mesh.bounds.max.z)))
        }
        // a y-profile through the leg at three heights: the row of voxels along y at the leg's x-centre
        // (the leg is the tall part: take x at the column with the most part voxels in the top third)
        for frac in [0.9, 0.7, 0.45, 0.2] {
            let k = Int(Double(occ.nz - 1) * frac)
            var row = ""
            for j in 0..<occ.ny {
                guard occ.values[(k * occ.ny + j) * occ.nx + ix] > 0.5 else { row += "."; continue }
                let p = SIMD3<Double>(occ.origin + SIMD3<Float>(Float(ix), Float(j), Float(k)) * h)
                var m = 0
                for r in regions where LatticeRegionMask.contains(p, region: r) { if r.faceID == 15 { m |= 1 } else if r.faceID == 2 { m |= 2 } else { m |= 4 } }
                row += ["#", "a", "b", "B", "c", "C", "C", "C"][m]   // # = part, no prism; a = f15; b = f2; B = f15+f2; c/C = f23 (+others)
            }
            print(String(format: "PROBE y-profile at z=%.0f mm, x=%.0f mm: ", Double(occ.origin.z) + Double(k) * Double(h.z), Double(occ.origin.x) + Double(ix) * Double(h.x)) + row)
        }
    }
}
