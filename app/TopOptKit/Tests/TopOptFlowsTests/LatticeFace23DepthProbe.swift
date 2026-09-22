import XCTest
import simd
@testable import TopOptFlows

/// ★ PROBE (2026-09-22 15:00): his three walls on the stand — face 15 (12 mm), face 2
/// (13 mm) and the curved face 23 as facets (20 mm, expand +4.15) — measured, not read.
final class LatticeFace23DepthProbe: XCTestCase {
    func testWhereTheCandidatesOfFace23Go() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let gid = UUID()
        let group = SelectionGroup(id: gid, name: "C", colorIndex: 0, faces: [15, 2, 23], regionIDs: [])
        let key23 = LatticeSelectableRef.face(group: gid, face: 23).key
        let res = LatticeRegionEmission.regions(
            groups: [group], roles: [gid: .include], primitives: { _ in [] }, includePrimitives: [],
            faceDepthMM: 12,
            selectableDepthMM: [LatticeSelectableRef.face(group: gid, face: 2).key: 13, key23: 20],
            selectableExpandMM: [key23: 4.15],
            facets: { LatticeFaceFacets.facets(face: $0, in: mesh) },
            resolve: { LatticeRegionEmission.planeFor(face: $0, in: mesh) })
        let regions = res.regions
        print("PROBE regions: \(regions.map { "f\($0.faceID ?? -1) d=\($0.depthMM) exp=\($0.inPlaneOffsetMM) n=\(LatticeRegionMask.unit($0.normal)) seams=\($0.outlineSeams.flatMap { $0 }.filter { $0 }.count) tilts=\($0.outlineSeamTilt.flatMap { $0 }.filter { abs($0) > 1e-9 }.map { String(format: "%.2f", $0) })" })")
        let occ = LatticePreviewOccupancy.occupancy(positions: mesh.positions, indices: mesh.indices, bounds: mesh.bounds, maxDim: 128)
        let sdf = LatticePreviewOccupancy.signedDistance(positions: mesh.positions, indices: mesh.indices, like: occ)
        let h = Double(occ.spacing.x)
        func partAt(_ p: SIMD3<Double>) -> Bool {
            let g = (SIMD3<Float>(p) - occ.origin) / occ.spacing
            let i = Int(g.x.rounded()), j = Int(g.y.rounded()), k = Int(g.z.rounded())
            guard i >= 0, j >= 0, k >= 0, i < occ.nx, j < occ.ny, k < occ.nz else { return false }
            return occ.values[(k * occ.ny + j) * occ.nx + i] > 0.5
        }
        // ★ THE JOB FOR CORE NOTE 7: face 23 as it stands (facets, frame axes on the wire)
        do {
            let dicts = regions.map { $0.wireDictionary(frameAxes: true) }
            let data = try JSONSerialization.data(withJSONObject: dicts, options: [.prettyPrinted, .sortedKeys])
            let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FACE23_REGIONS_OUT"] ?? "/tmp/face23_regions.json")
            try data.write(to: url)
            print("PROBE wrote \(dicts.count) region dicts to \(url.path)")
        } catch { print("PROBE write failed: \(error)") }
        // who is across each outline edge, per the mesh (nil = no shared edge / free)
        for f: FaceID in [15, 2, 23] {
            guard let pl = LatticeRegionEmission.planeFor(face: f, in: mesh), case let .plane(c, n, _, _, _, _) = pl else { continue }
            let lw = LatticeFaceOutline.loopsWithNeighbours(face: f, in: mesh, normal: n, origin: c)
            var hist: [String: Int] = [:]
            for e in lw { for nb in e.neighbours { hist[nb.map { "f\($0)" } ?? "nil", default: 0] += 1 } }
            print("PROBE neighbours across face \(f)'s outline edges: \(hist.sorted { $0.key < $1.key })")
        }
        // for each facet edge of face 23: the in-plane outward offset at which a probe (half-way down) enters another wall's prism
        for (ri, r) in regions.enumerated() where r.faceID == 23 {
            let n = LatticeRegionMask.unit(r.normal); let (bu, bv) = LatticeRegionMask.basis(n)
            var hist: [String: Int] = [:]
            for loop in r.outlineLoops {
                let m = loop.count
                var area = 0.0
                for i in 0..<m { let a = loop[i], b = loop[(i + 1) % m]; area += a.x * b.y - b.x * a.y }
                for i in 0..<m {
                    let a = loop[i], b = loop[(i + 1) % m], d = b - a
                    guard simd_length(d) > 1e-9 else { continue }
                    let out2 = (area > 0 ? SIMD2(d.y, -d.x) : SIMD2(-d.y, d.x)) / simd_length(d)
                    var found = "none"
                    var off = 0.5
                    while off <= 12 {
                        let uv = (a + b) * 0.5 + out2 * off
                        var hit: Int? = nil
                        for (rj, o) in regions.enumerated() where rj != ri && o.faceID != 23 {
                            let s = 0.5 * min(r.depthMM, o.depthMM)
                            let pw = r.origin + bu * uv.x + bv * uv.y + n * s
                            if LatticeRegionMask.containsWholePrism(pw, region: o) { hit = o.faceID; break }
                        }
                        if let hit { found = "f\(hit)@\(off)"; break }
                        off += 0.5
                    }
                    hist[found, default: 0] += 1
                }
            }
            print("PROBE r\(ri) facet edges → another wall's prism at offset: \(hist.sorted { $0.key < $1.key })")
        }
        // the ribbon under the attached-edges rule, as the scene builds it
        var census: [Int: (Int, Int, Int)] = [:]
        let ribbon = LatticeOutlineRibbon.build(
            regions: regions, widthMM: 3.41,
            attached: { _, p in partAt(p) },
            surfaceAt: { ri, p in
                let n = LatticeRegionMask.unit(regions[ri].normal)
                var s = 0.0
                while s <= 4.0 { if partAt(p + n * s) { return s }; s += 0.25 }
                return 0
            },
            census: { ri, a, o, s in let c = census[ri] ?? (0, 0, 0); census[ri] = (c.0 + a, c.1 + o, c.2 + s) }) { ri, _ in regions[ri].depthMM }
        print("PROBE outline beam: " + census.keys.sorted().map { ri in "r\(ri) f\(regions[ri].faceID ?? -1): attached \(census[ri]!.0) open \(census[ri]!.1) seam \(census[ri]!.2)" }.joined(separator: " | ") + " · \(ribbon.vertexCount) verts")
        for (ri, r) in regions.enumerated() {
            let n = LatticeRegionMask.unit(r.normal)
            let (bu, bv) = LatticeRegionMask.basis(n)
            var lo = SIMD2<Double>(1e9, 1e9), hi = SIMD2<Double>(-1e9, -1e9)
            for loop in r.outlineLoops { for q in loop { lo = simd_min(lo, q); hi = simd_max(hi, q) } }
            var noFlare = r; noFlare.outlineSeamTilt = []
            var whole = r; whole.outlineSeamTilt = []; whole.outlineSeams = []; whole.inPlaneOffsetMM = 0
            var flare = [Int](repeating: 0, count: 10), plain = [Int](repeating: 0, count: 10)
            var ideal = [Int](repeating: 0, count: 10), inPart = [Int](repeating: 0, count: 10), flareInPart = [Int](repeating: 0, count: 10)
            var u = lo.x - 6
            while u <= hi.x + 6 {
                var v = lo.y - 6
                while v <= hi.y + 6 {
                    var s = 0.5 * h
                    while s < r.depthMM {
                        let p = r.origin + bu * u + bv * v + n * s
                        let dec = min(9, Int(s / r.depthMM * 10))
                        let inPolygon = LatticeFaceOutline.contains(SIMD2(u, v), loops: r.outlineLoops)
                        let part = partAt(p)
                        if inPolygon { ideal[dec] += 1; if part { inPart[dec] += 1 } }
                        if LatticeRegionMask.contains(p, region: noFlare) { plain[dec] += 1 }
                        if LatticeRegionMask.contains(p, region: r) { flare[dec] += 1; if part { flareInPart[dec] += 1 } }
                        s += h
                    }
                    v += h
                }
                u += h
            }
            let width = LatticeMeasuredRegionWidth.wallWidthAlongNormalMM(region: whole, occupancy: LatticeRegionMask.clipped(occ, to: [whole]), partSDF: sdf, percentile: 0.5)
            let w05 = LatticeMeasuredRegionWidth.wallWidthAlongNormalMM(region: whole, occupancy: LatticeRegionMask.clipped(occ, to: [whole]), partSDF: sdf, percentile: 0.05)
            print(String(format: "PROBE r%d f%d depth %.0f expand %.2f · measured wall along n: p05 %.2f p50 %.2f mm · voxel %.2f", ri, r.faceID ?? -1, r.depthMM, r.inPlaneOffsetMM, w05, width, h))
            print("PROBE   ideal prism  by decile: \(ideal)  total \(ideal.reduce(0, +))")
            print("PROBE   ideal ∩ part by decile: \(inPart)  total \(inPart.reduce(0, +))")
            print("PROBE   contains, no flare:     \(plain)  total \(plain.reduce(0, +))")
            print("PROBE   contains, flare:        \(flare)  total \(flare.reduce(0, +))")
            print("PROBE   flare ∩ part:           \(flareInPart)  total \(flareInPart.reduce(0, +))")
        }
    }
}
