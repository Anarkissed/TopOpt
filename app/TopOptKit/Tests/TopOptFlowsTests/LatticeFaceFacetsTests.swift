import XCTest
import simd
@testable import TopOptFlows

/// ★ A curved face becomes planar facets (his 2026-09-22 01:05: face 23, the stand's inner
/// curve, got no lattice at all — `planeFor` gave nothing and the face was skipped).
final class LatticeFaceFacetsTests: XCTestCase {

    /// A quarter-cylinder strip (radius 50, 90° in 18 steps, 20 mm tall) as one face id.
    private func arcMesh(steps: Int = 18) -> ViewerMesh {
        var v: [Float] = [], idx: [Int32] = [], fid: [Int32] = []
        let r: Float = 50
        for i in 0...steps {
            let a = Float(i) / Float(steps) * .pi / 2
            v += [r * cos(a), r * sin(a), 0, r * cos(a), r * sin(a), 20]
        }
        for i in 0..<steps {
            let a = Int32(2 * i), b = a + 1, c = a + 2, d = a + 3
            idx += [a, c, b, b, c, d]
            fid += [7, 7]
        }
        return ViewerMesh(vertices: v, indices: idx, faceIDs: fid)
    }

    func testAQuarterCylinderBecomesAFanOfPlanarFacetsWithOutlines() {
        let mesh = arcMesh()
        let facets = LatticeFaceFacets.facets(face: 7, in: mesh, toleranceDeg: 12)
        XCTAssertGreaterThanOrEqual(facets.count, 4, "90° at ±12° per facet ⇒ at least four")
        XCTAssertLessThanOrEqual(facets.count, 18)
        var normals: [SIMD3<Double>] = []
        for f in facets {
            guard case let .plane(center, normal, hu, hw, loops, _) = f else { XCTFail("planar facets"); continue }
            XCTAssertEqual(simd_length(normal), 1, accuracy: 1e-6)
            XCTAssertEqual(abs(normal.z), 0, accuracy: 1e-6, "the normal is radial")
            XCTAssertEqual(simd_length(SIMD2(center.x, center.y)), 50, accuracy: 1.5, "the centre sits on the arc")
            XCTAssertFalse(loops.isEmpty, "every facet has its own outline")
            XCTAssertGreaterThan(hu, 0); XCTAssertGreaterThan(hw, 0)
            normals.append(normal)
        }
        // the fan spans the arc: the two most different facet normals are ~90° apart
        // (facets come out in seed order — by area — not in arc order)
        var spread = 0.0
        for a in normals { for b in normals { spread = max(spread, acos(max(-1, min(1, simd_dot(a, b)))) * 180 / .pi) } }
        XCTAssertGreaterThan(spread, 60)
        // and together the facets cover the strip's area (each ≈ 20 mm tall, r·Δθ wide)
        var area = 0.0
        for f in facets { if case let .plane(_, _, _, _, loops, _) = f {
            for loop in loops {
                var a = 0.0
                for i in loop.indices { let p = loop[i], q = loop[(i + 1) % loop.count]; a += p.x * q.y - q.x * p.y }
                area += abs(a) / 2
            }
        } }
        XCTAssertEqual(area, Double(50) * .pi / 2 * 20, accuracy: 0.08 * Double(50) * .pi / 2 * 20, "the facets' outlines add up to the strip")
    }

    func testAPlaneStaysOneFacetAndAnUnknownFaceHasNone() {
        let mesh = arcMesh(steps: 1)   // one flat quad
        XCTAssertEqual(LatticeFaceFacets.facets(face: 7, in: mesh).count, 1)
        XCTAssertTrue(LatticeFaceFacets.facets(face: 99, in: mesh).isEmpty)
    }

    /// The packer's slab test: a cell is laid only where its whole depth is inside the band.
    func testACellIsLaidOnlyInsideTheDrawnBand() {
        var r = LatticeRegionSpec(role: .include, kind: .face)
        r.origin = .zero; r.normal = SIMD3(0, 0, 1); r.depthMM = 12
        r.outlineLoops = [[SIMD2(-20, -20), SIMD2(20, -20), SIMD2(20, 20), SIMD2(-20, 20)]]
        r.selectableKey = "f:g:1"
        XCTAssertTrue(LatticePreviewOccupancy.boxInsideSlab(SIMD3(0, 0, 0), 12, region: r, axis: 2), "no map: the whole prism")
        r.thickness = LatticeWallThickness(depthBySim: false, density: .manualSingle, pct: 50, faces: ["f:g:1": .init()])
        r.thicknessMap = LatticeWallThicknessBuilder.build(region: r, spec: r.thickness!, field: nil, referenceMPa: 0, floorMM: 0)
        XCTAssertEqual(r.slabRange(uv: .zero).end, 6, accuracy: 1e-9)
        XCTAssertFalse(LatticePreviewOccupancy.boxInsideSlab(SIMD3(0, 0, 0), 12, region: r, axis: 2), "a whole-wall cell pokes out of a 6 mm band")
        XCTAssertTrue(LatticePreviewOccupancy.boxInsideSlab(SIMD3(0, 0, 0), 6, region: r, axis: 2), "the next rung fits")
        XCTAssertFalse(LatticePreviewOccupancy.boxInsideSlab(SIMD3(0, 0, 6), 6, region: r, axis: 2), "not behind the band")
    }
}

/// ★ SEAMS (his 2026-09-22 01:58): an outline edge shared with another latticed prism is
/// not a rim — no distance is measured to it, no beam is swept along it.
final class LatticeOutlineSeamTests: XCTestCase {
    func testASeamEdgeIsNotAnOutlineForTheDistance() {
        let square: [SIMD2<Double>] = [SIMD2(-10, -10), SIMD2(10, -10), SIMD2(10, 10), SIMD2(-10, 10)]
        // edge 1 (10,-10 → 10,10), the +x side, is a seam
        let seams = [[false, true, false, false]]
        let p = SIMD2<Double>(9, 0)
        XCTAssertEqual(LatticeFaceOutline.signedDistance(p, loops: [square]), -1, accuracy: 1e-9, "1 mm from the +x edge")
        XCTAssertEqual(LatticeFaceOutline.signedDistance(p, loops: [square], seams: seams), -10, accuracy: 1e-9,
                       "★ with the +x edge a seam the nearest true outline is 10 mm away")
        XCTAssertGreaterThan(LatticeFaceOutline.signedDistance(SIMD2(11, 0), loops: [square], seams: seams), 0, "outside is still outside")
        XCTAssertEqual(LatticeFaceOutline.signedDistance(p, loops: [square], seams: [[true, true, true, true]]), -1e6, accuracy: 1,
                       "all seams ⇒ far from any rim, inside")
    }

    func testTheFacetsOfOneFaceMeetAtSeamsAndTheStripEdgesAreFree() {
        var v: [Float] = [], idx: [Int32] = [], fid: [Int32] = []
        let r: Float = 50, steps = 18
        for i in 0...steps { let a = Float(i) / Float(steps) * .pi / 2; v += [r * cos(a), r * sin(a), 0, r * cos(a), r * sin(a), 20] }
        for i in 0..<steps { let a = Int32(2 * i); idx += [a, a + 2, a + 1, a + 1, a + 2, a + 3]; fid += [7, 7] }
        let mesh = ViewerMesh(vertices: v, indices: idx, faceIDs: fid)
        let facets = LatticeFaceFacets.facets(face: 7, in: mesh)
        XCTAssertGreaterThan(facets.count, 1)
        var seamEdges = 0, freeEdges = 0
        for f in facets {
            guard case let .plane(_, _, _, _, loops, neighbours) = f else { continue }
            XCTAssertEqual(loops.count, neighbours.count)
            for (l, nb) in zip(loops, neighbours) {
                XCTAssertEqual(l.count, nb.count, "one neighbour per edge")
                for n in nb { if n == 7 { seamEdges += 1 } else if n == nil { freeEdges += 1 } else { XCTFail("a neighbour that is not this face: \(String(describing: n))") } }
            }
        }
        XCTAssertGreaterThan(seamEdges, 0, "facets meet each other")
        XCTAssertGreaterThan(freeEdges, 0, "the strip's top, bottom and ends are free")
        // and the emission turns them into seams under the face's own id
        let spec = LatticeRegionEmission.spec(for: facets[0], role: .include, depthMM: 5, faceID: 7, seamWith: { $0 == 7 })
        XCTAssertNotNil(spec)
        XCTAssertTrue(spec!.outlineSeams.contains { $0.contains(true) }, "★ the seam edges are marked")
        XCTAssertTrue(spec!.outlineSeams.contains { $0.contains(false) }, "and the free edges are not")
    }
}

/// ★ THE CORNER PLATE (his 2.2, 2026-09-22 02:30: "thin plate, rim width"): where two
/// latticed faces share an edge, a plate the rim's thickness runs inward along their bisector.
final class LatticeCornerPlateTests: XCTestCase {
    func testTwoLatticedFacesMeetingAtACornerGetOnePlateAlongTheBisector() {
        // face 1: the +z face of a block, 20 × 20, inward −z; face 2: the +x face, inward −x;
        // they share the edge x = 10, z = 10 (in world), y ∈ [−10, 10]
        var a = LatticeRegionSpec(role: .include, kind: .face)
        a.faceID = 1; a.origin = SIMD3(0, 0, 10); a.normal = SIMD3(0, 0, -1); a.depthMM = 8
        var b = LatticeRegionSpec(role: .include, kind: .face)
        b.faceID = 2; b.origin = SIMD3(10, 0, 0); b.normal = SIMD3(-1, 0, 0); b.depthMM = 6
        func square(_ r: LatticeRegionSpec) -> [SIMD2<Double>] {
            [SIMD2(-10, -10), SIMD2(10, -10), SIMD2(10, 10), SIMD2(-10, 10)]
        }
        a.outlineLoops = [square(a)]; b.outlineLoops = [square(b)]
        // find which of a's edges is the shared one: the edge whose world points sit at x = 10
        let (au, av) = LatticeRegionMask.basisForTests(LatticeRegionMask.unit(a.normal))
        func world(_ r: LatticeRegionSpec, _ uv: SIMD2<Double>, _ bu: SIMD3<Double>, _ bv: SIMD3<Double>) -> SIMD3<Double> {
            r.origin + bu * uv.x + bv * uv.y
        }
        var seamsA = [false, false, false, false]
        var facesA: [Int?] = [nil, nil, nil, nil]
        for i in 0..<4 {
            let p = world(a, a.outlineLoops[0][i], au, av), q = world(a, a.outlineLoops[0][(i + 1) % 4], au, av)
            if abs(p.x - 10) < 1e-9, abs(q.x - 10) < 1e-9 { seamsA[i] = true; facesA[i] = 2 }
        }
        XCTAssertEqual(seamsA.filter { $0 }.count, 1, "exactly one shared edge")
        a.outlineSeams = [seamsA]; a.outlineSeamFaces = [facesA]
        let m = LatticeOutlineRibbon.build(regions: [a, b], widthMM: 1.5) { _, _ in 8 }
        // the plate's far edge lies along the bisector of (−z) and (−x) from the corner (10, y, 10):
        // dir = (−1, 0, −1)/√2, length = min(8, 6)/cos45° ⇒ the far edge at x = z = 10 − 6
        let verts = stride(from: 0, to: m.interleaved.count, by: 6).map {
            SIMD3<Double>(Double(m.interleaved[$0]), Double(m.interleaved[$0 + 1]), Double(m.interleaved[$0 + 2]))
        }
        let far = verts.filter { abs($0.x - 4) < 0.8 && abs($0.z - 4) < 0.8 }
        XCTAssertGreaterThan(far.count, 0, "★ the plate reaches (4, y, 4): 6 mm in along the 45° bisector")
        let near = verts.filter { abs($0.x - 10) < 0.8 && abs($0.z - 10) < 0.8 }
        XCTAssertGreaterThan(near.count, 0, "and starts at the shared edge")
        // no plate from b's side (b has no seams marked) and none twice
        let mb = LatticeOutlineRibbon.build(regions: [b, a], widthMM: 1.5) { _, _ in 8 }
        XCTAssertEqual(mb.interleaved.count, m.interleaved.count, "order does not change the mesh size")
    }
}
