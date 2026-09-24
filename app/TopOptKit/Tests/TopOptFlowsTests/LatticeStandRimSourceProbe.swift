import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★ PROBE (2026-09-23 20:10, his images at 7:44–8:07 PM): where every skin/rim voxel of the
/// stand comes from — which unselected face, or which region's solid-backed outline — and
/// how every unselected face was classified. Numbers before any fix.
final class LatticeStandRimSourceProbe: XCTestCase {
    func testWhereTheRimComesFrom() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let gid = UUID()
        let group = SelectionGroup(id: gid, name: "C", colorIndex: 0, faces: [15, 2, 23], regionIDs: [])
        let key23 = LatticeSelectableRef.face(group: gid, face: 23).key
        let solidGrid = LatticePreviewOccupancy.occupancy(positions: mesh.positions, indices: mesh.indices, bounds: mesh.bounds, maxDim: 128)
        func solidAt(_ p: SIMD3<Double>) -> Bool {
            let g = (SIMD3<Float>(p) - solidGrid.origin) / solidGrid.spacing
            let i = Int(g.x.rounded()), j = Int(g.y.rounded()), k = Int(g.z.rounded())
            guard i >= 0, j >= 0, k >= 0, i < solidGrid.nx, j < solidGrid.ny, k < solidGrid.nz else { return false }
            return solidGrid.values[(k * solidGrid.ny + j) * solidGrid.nx + i] > 0.5
        }
        let regions = LatticeRegionEmission.regions(
            groups: [group], roles: [gid: .include], primitives: { _ in [] }, includePrimitives: [],
            faceDepthMM: 12,
            selectableDepthMM: [LatticeSelectableRef.face(group: gid, face: 2).key: 13, key23: 20],
            selectableExpandMM: [key23: 4.15],
            facets: { LatticeFaceFacets.facets(face: $0, in: mesh) },
            solidAt: solidAt,
            resolve: { LatticeRegionEmission.planeFor(face: $0, in: mesh) }).regions
        let inc = regions.filter { $0.role == .include && $0.kind == .face && $0.isValid }
        for (i, r) in inc.enumerated() {
            print(String(format: "PROBE r%d face %d n=(%.2f,%.2f,%.2f) depth %.2f expand %.2f origin (%.1f,%.1f,%.1f) seams %d", i, r.faceID ?? -1, r.normal.x, r.normal.y, r.normal.z, r.depthMM, r.inPlaneOffsetMM, r.origin.x, r.origin.y, r.origin.z, r.outlineSeams.first?.filter { $0 }.count ?? 0))
        }
        // ── every face: normal, extents, and how its triangles were classified
        struct F { var tris = 0; var across = 0; var n = SIMD3<Double>(0, 0, 0); var lo = SIMD3<Double>(repeating: 1e9); var hi = SIMD3<Double>(repeating: -1e9); var area = 0.0 }
        var faces: [Int: F] = [:]
        let acrossCos = cos(30.0 * Double.pi / 180)
        let selected: Set<Int> = [2, 15, 23]
        var t = 0
        var unselTris: [(Int, SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            let fid = tri < mesh.faceIDs.count ? Int(mesh.faceIDs[tri]) : -1
            let i0 = Int(mesh.indices[t]) * 3, i1 = Int(mesh.indices[t + 1]) * 3, i2 = Int(mesh.indices[t + 2]) * 3
            let p0 = SIMD3<Double>(Double(mesh.positions[i0]), Double(mesh.positions[i0 + 1]), Double(mesh.positions[i0 + 2]))
            let p1 = SIMD3<Double>(Double(mesh.positions[i1]), Double(mesh.positions[i1 + 1]), Double(mesh.positions[i1 + 2]))
            let p2 = SIMD3<Double>(Double(mesh.positions[i2]), Double(mesh.positions[i2 + 1]), Double(mesh.positions[i2 + 2]))
            t += 3
            let cr = simd_cross(p1 - p0, p2 - p0)
            let a2 = simd_length(cr)
            guard a2 > 1e-12 else { continue }
            let nOut = cr / a2
            var f = faces[fid] ?? F()
            f.tris += 1; f.n += nOut * a2; f.area += 0.5 * a2
            for q in [p0, p1, p2] { f.lo = simd_min(f.lo, q); f.hi = simd_max(f.hi, q) }
            if !selected.contains(fid) {
                let across = LatticeSDFScene.prismPassesThrough(p0, p1, p2, outward: nOut, regions: inc, acrossCos: acrossCos)
                if across, [4, 21, 58].contains(fid) {
                    let c = (p0 + p1 + p2) / 3
                    let per = inc.enumerated().map { ri, r -> String in
                        let nr = LatticeRegionMask.unit(r.normal)
                        let s = [p0, p1, p2].map { simd_dot($0 - r.origin, nr) }
                        return String(format: "r%d facing %.2f s[%.1f,%.1f,%.1f]", ri, simd_dot(nOut, nr), s[0], s[1], s[2])
                    }.joined(separator: " · ")
                    print(String(format: "ACROSS f%d n=(%.2f,%.2f,%.2f) c=(%.1f,%.1f,%.1f) · ", fid, nOut.x, nOut.y, nOut.z, c.x, c.y, c.z) + per)
                }
                if across { f.across += 1 } else { unselTris.append((fid, p0, p1, p2)) }
            }
            faces[fid] = f
        }
        print("PROBE faces (id · tris · area mm² · mean normal · bbox · passed-through tris):")
        for (fid, f) in faces.sorted(by: { $0.key < $1.key }) {
            let n = simd_length(f.n) > 0 ? f.n / simd_length(f.n) : f.n
            print(String(format: "  f%-3d %4d tris %8.0f mm² n=(%+.2f,%+.2f,%+.2f) x[%.0f,%.0f] y[%.0f,%.0f] z[%.0f,%.0f] %@ across %d", fid, f.tris, f.area, n.x, n.y, n.z, f.lo.x, f.hi.x, f.lo.y, f.hi.y, f.lo.z, f.hi.z, selected.contains(fid) ? "SELECTED" : "", f.across))
        }
        // ── the scene, organic rim 3.41 as his bake
        let n = 8
        var tensor = [Double](repeating: 0, count: 6 * n * n * n)
        for i in 0..<(n * n * n) { tensor[6 * i] = 10; tensor[6 * i + 1] = 3; tensor[6 * i + 2] = 1 }
        var o = LatticeOrganicInput(tensor: tensor, dims: (n, n, n), originMM: SIMD3(Double(mesh.bounds.min.x), Double(mesh.bounds.min.y), Double(mesh.bounds.min.z)),
                                    spacingMM: 30, minExtrudableWidthMM: 0.45, buildDirection: SIMD3(0, 0, 1),
                                    separationMinMM: 3, separationMaxMM: 3, rhoMin: 0.05, rhoMax: 0.9, showRepairs: false)
        o.solidRimMM = 3.41
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", stageMode: .aesthetic,
                                    algorithm: "organic", organic: o, regions: regions, whenEmpty: .latticeNothing)
        guard let f = scene.regionSDF, let sk = scene.skinInSDF, let pr = scene.prismSDF else { XCTFail("no field"); return }
        let h = Double(f.spacing.x)
        print(String(format: "PROBE scene: skin %.2f rim %.2f outlineRim(organic) %.2f · voxel %.2f · grid %dx%dx%d", scene.unselectedSkinMM, scene.unselectedRimMM, scene.organicSolidRimMM, h, f.nx, f.ny, f.nz))
        func at(_ g: LatticeVoxelGrid, _ i: Int, _ j: Int, _ k: Int) -> Float { g.values[(k * g.ny + j) * g.nx + i] }
        func pos(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Double> {
            SIMD3<Double>(Double(f.origin.x) + Double(i) * h, Double(f.origin.y) + Double(j) * h, Double(f.origin.z) + Double(k) * h)
        }
        // ── attribute every solid voxel inside a prism
        func nearestUnselected(_ p: SIMD3<Double>) -> (Int, Double) {
            var best = (fid: -1, d2: Double.greatestFiniteMagnitude)
            let pf = SIMD3<Float>(p)
            for (fid, a, b, c) in unselTris {
                let d2 = Double(LatticePreviewOccupancy.pointTriangleDistSq(pf, SIMD3<Float>(a), SIMD3<Float>(b), SIMD3<Float>(c)))
                if d2 < best.d2 { best = (fid, d2) }
            }
            return (best.fid, best.d2.squareRoot())
        }
        struct Src { var n = 0; var lo = SIMD3<Double>(repeating: 1e9); var hi = SIMD3<Double>(repeating: -1e9) }
        var bySrc: [String: Src] = [:]
        var kinds: [String: Int] = [:]
        let outlineRim = scene.organicSolidRimMM
        for k in 0..<f.nz { for j in 0..<f.ny { for i in 0..<f.nx {
            guard at(pr, i, j, k) < 0, at(f, i, j, k) >= 0, solidGrid.values[(k * f.ny + j) * f.nx + i] > 0.5 else { continue }
            let p = pos(i, j, k)
            let s = at(sk, i, j, k)
            let kind = s >= 900 ? "solid-no-source" : (s < 0 ? "skin" : "rim")
            kinds[kind, default: 0] += 1
            var src = "?"
            // outline first: which region's solid-backed outline is within the rim
            var bestOut = (ri: -1, d: 1e3)
            for (ri, r) in inc.enumerated() {
                let d = LatticeRegionMask.solidBackedOutlineDistance(p, regions: [r], slabMarginMM: 2 * h, stepMM: max(1.0, h), prisms: inc, solidAt: solidAt)
                if d < bestOut.d { bestOut = (ri, d) }
            }
            let (fid, dFace) = nearestUnselected(p)
            if outlineRim > 0, bestOut.d < outlineRim, bestOut.d <= dFace - scene.unselectedSkinMM {
                src = "outline r\(bestOut.ri) (f\(inc[bestOut.ri].faceID ?? -1))"
            } else if dFace < scene.unselectedSkinMM + scene.unselectedRimMM + 1e-6 {
                src = "face f\(fid) \(kind)"
            } else {
                src = "NONE (nearest f\(fid) at \(String(format: "%.1f", dFace)) mm, outline \(String(format: "%.1f", bestOut.d)))"
            }
            var e = bySrc[src] ?? Src()
            e.n += 1; e.lo = simd_min(e.lo, p); e.hi = simd_max(e.hi, p)
            bySrc[src] = e
        } } }
        print("PROBE solid voxels inside prisms by kind: \(kinds)")
        // ── the column at z≈20 in wall A's pocket: what carves it?
        var colSrc: [String: Int] = [:]
        for k in 0..<f.nz { for j in 0..<f.ny { for i in 0..<f.nx {
            let p = pos(i, j, k)
            guard p.z > 17, p.z < 23, p.y > -6.5, p.y < 4.5, p.x > 25, p.x < 60 else { continue }
            guard at(pr, i, j, k) < 0, at(f, i, j, k) >= 0, solidGrid.values[(k * f.ny + j) * f.nx + i] > 0.5 else { continue }
            let (fid, dFace) = nearestUnselected(p)
            var bestOut = (ri: -1, d: 1e3)
            for (ri, r) in inc.enumerated() {
                let d = LatticeRegionMask.solidBackedOutlineDistance(p, regions: [r], slabMarginMM: 2 * h, stepMM: max(1.0, h), prisms: inc, solidAt: solidAt)
                if d < bestOut.d { bestOut = (ri, d) }
            }
            let key = String(format: "x%.0f y%.0f: nearest f%d %.1f mm · outline r%d %.1f · skinIn %.1f", p.x, p.y, fid, dFace, bestOut.ri, bestOut.d, at(sk, i, j, k))
            colSrc[key, default: 0] += 1
        } } }
        // which triangle's COLUMN reaches two of those voxels (perpendicular + footprint + margin)?
        for target in [SIMD3<Double>(33, 3, 20), SIMD3<Double>(37, 1, 20), SIMD3<Double>(32, -1, 20)] {
            // snap to the grid
            let gi = Int(((target.x - Double(f.origin.x)) / h).rounded()), gj = Int(((target.y - Double(f.origin.y)) / h).rounded()), gk = Int(((target.z - Double(f.origin.z)) / h).rounded())
            let p = pos(gi, gj, gk)
            var hits: [String] = []
            for (fid, a, b, c) in unselTris {
                let n0 = simd_normalize(simd_cross(b - a, c - a))
                let hh = simd_dot(p - a, n0)
                guard abs(hh) < 5 else { continue }
                let q = p - n0 * hh
                func out(_ p0: SIMD3<Double>, _ p1: SIMD3<Double>, _ opp: SIMD3<Double>) -> Double {
                    var o = simd_cross(p1 - p0, n0); if simd_dot(o, opp - p0) > 0 { o = -o }
                    return simd_dot(q - p0, simd_normalize(o))
                }
                let e = [out(a, b, c), out(b, c, a), out(c, a, b)]
                if e.allSatisfy({ $0 <= h }) {
                    hits.append(String(format: "f%d perp %.2f edges [%.1f %.1f %.1f] n=(%.2f,%.2f,%.2f) a=(%.1f,%.1f,%.1f) b=(%.1f,%.1f,%.1f) c=(%.1f,%.1f,%.1f) q=(%.1f,%.1f,%.1f)", fid, hh, e[0], e[1], e[2], n0.x, n0.y, n0.z, a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z, q.x, q.y, q.z))
                }
            }
            print(String(format: "PROBE column hit at (%.1f,%.1f,%.1f): skinIn %.2f · ", p.x, p.y, p.z, at(sk, gi, gj, gk)) + hits.joined(separator: " | "))
        }
        print("PROBE wall-A column near z=20:")
        for (k, v) in colSrc.sorted(by: { $0.key < $1.key }) { print("  \(k) ×\(v)") }
        // ── the chamfers: does the field close the AIR just outside them? (the shell samples
        // the region field at the surface; a negative air voxel beside a solid one cuts it)
        for fid in [48, 68, 73, 56, 57, 76, 77] {
            let tris = unselTris.filter { $0.0 == fid }
            guard !tris.isEmpty else { print("PROBE chamfer f\(fid): no alongside triangles"); continue }
            var air = 0, airSolid = 0, inside = 0, insideSolid = 0
            for k in 0..<f.nz { for j in 0..<f.ny { for i in 0..<f.nx {
                let p = pos(i, j, k)
                let pf = SIMD3<Float>(p)
                var near = false
                for (_, a, b, c) in tris where LatticePreviewOccupancy.pointTriangleDistSq(pf, SIMD3<Float>(a), SIMD3<Float>(b), SIMD3<Float>(c)) < 2.0 * 2.0 { near = true; break }
                guard near else { continue }
                let isSolid = solidGrid.values[(k * f.ny + j) * f.nx + i] > 0.5
                let carved = at(f, i, j, k) >= 0
                if isSolid { inside += 1; if carved { insideSolid += 1 } } else { air += 1; if carved { airSolid += 1 } }
            } } }
            print("PROBE chamfer f\(fid): within 2 mm — part voxels \(inside) (solid in field \(insideSolid)), air voxels \(air) (solid in field \(airSolid))")
        }
        print("PROBE by source (count · bbox):")
        for (k, v) in bySrc.sorted(by: { $0.value.n > $1.value.n }) {
            print(String(format: "  %-40@ %6d  x[%.0f,%.0f] y[%.0f,%.0f] z[%.0f,%.0f]", k as NSString, v.n, v.lo.x, v.hi.x, v.lo.y, v.hi.y, v.lo.z, v.hi.z))
        }
        // ── cross-sections: chars ' ' air · '.' solid outside every prism · 'L' lattice · 'S' skin · 'R' rim · 'X' solid in prism, no source
        func ch(_ i: Int, _ j: Int, _ k: Int) -> String {
            guard solidGrid.values[(k * f.ny + j) * f.nx + i] > 0.5 else { return " " }
            if at(pr, i, j, k) >= 0 { return "." }
            if at(f, i, j, k) < 0 { return "L" }
            let s = at(sk, i, j, k)
            return s >= 900 ? "X" : (s < 0 ? "S" : "R")
        }
        func slabIndex(_ w: Double, _ o0: Float) -> Int { Int(((w - Double(o0)) / h).rounded()) }
        // (a) x–y slice through the base, z = 20 mm
        let kz = min(f.nz - 1, max(0, slabIndex(20, f.origin.z)))
        print("PROBE slice z=20 (rows y from top y=\(f.origin.y + Float(f.ny - 1) * Float(h)) down; cols x every 2nd voxel):")
        for j in stride(from: f.ny - 1, through: 0, by: -1) { print("  " + stride(from: 0, to: f.nx, by: 2).map { ch($0, j, kz) }.joined()) }
        // (b) y–z slice through the leg, x = -5 mm (rows z every 3rd voxel from top)
        let ix = min(f.nx - 1, max(0, slabIndex(-5, f.origin.x)))
        print("PROBE slice x=-5 (rows z from top, every 3rd; cols y):")
        for k in stride(from: f.nz - 1, through: 0, by: -3) { print("  " + (0..<f.ny).map { ch(ix, $0, k) }.joined()) }
        // (c) y–z slice through the base at x = 100
        let ix2 = min(f.nx - 1, max(0, slabIndex(100, f.origin.x)))
        print("PROBE slice x=100 (rows z from top; cols y):")
        for k in stride(from: f.nz - 1, through: 0, by: -1) { let row = (0..<f.ny).map { ch(ix2, $0, k) }.joined(); if row.trimmingCharacters(in: .whitespaces).isEmpty { continue }; print("  " + row) }
    }
}
