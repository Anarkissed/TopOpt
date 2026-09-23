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

/// ★ THE FLARE (2026-09-22): adjacent prisms meet at the bisector plane, so a concave wall's
/// facets leave no wedge of material between them.
final class LatticeSeamFlareTests: XCTestCase {
    func testAPointBeyondADivergingSeamIsInsideUpToDepthTimesTilt() {
        let square: [SIMD2<Double>] = [SIMD2(-10, -10), SIMD2(10, -10), SIMD2(10, 10), SIMD2(-10, 10)]
        let seams = [[false, true, false, false]]      // the +x edge is a seam
        let tilts = [[0.0, 1.0, 0.0, 0.0]]              // 45°: flare = depth
        XCTAssertTrue(LatticeFaceOutline.insideWithFlare(SIMD2(11.5, 0), loops: [square], seams: seams, tilts: tilts, depth: 2), "1.5 beyond, depth 2")
        XCTAssertFalse(LatticeFaceOutline.insideWithFlare(SIMD2(12.5, 0), loops: [square], seams: seams, tilts: tilts, depth: 2), "2.5 beyond")
        XCTAssertFalse(LatticeFaceOutline.insideWithFlare(SIMD2(11.5, 0), loops: [square], seams: seams, tilts: tilts, depth: 0), "no flare at the surface")
        XCTAssertFalse(LatticeFaceOutline.insideWithFlare(SIMD2(0, 11.5), loops: [square], seams: seams, tilts: tilts, depth: 2), "a true outline edge does not flare")
        // converging: the bisector cuts the prism short of the seam
        let conv = [[0.0, -1.0, 0.0, 0.0]]
        XCTAssertFalse(LatticeFaceOutline.insideWithFlare(SIMD2(9, 0), loops: [square], seams: seams, tilts: conv, depth: 2), "1 mm inside a converging seam at depth 2 is cut off")
        XCTAssertTrue(LatticeFaceOutline.insideWithFlare(SIMD2(7, 0), loops: [square], seams: seams, tilts: conv, depth: 2))
        // the in-plane reader: beyond a seam reads inside, at the distance to the true outline
        XCTAssertLessThan(LatticeFaceOutline.signedDistanceAcrossSeams(SIMD2(11, 0), loops: [square], seams: seams), 0)
        XCTAssertGreaterThan(LatticeFaceOutline.signedDistanceAcrossSeams(SIMD2(0, 11), loops: [square], seams: seams), 0)
    }

    func testTheEmissionGivesFacetSeamsATiltOfOneSignAndTheSizeOfTheirDihedral() {
        var v: [Float] = [], idx: [Int32] = [], fid: [Int32] = []
        let r: Float = 50, steps = 18
        for i in 0...steps { let a = Float(i) / Float(steps) * .pi / 2; v += [r * cos(a), r * sin(a), 0, r * cos(a), r * sin(a), 20] }
        for i in 0..<steps { let a = Int32(2 * i); idx += [a, a + 2, a + 1, a + 1, a + 2, a + 3]; fid += [7, 7] }
        let mesh = ViewerMesh(vertices: v, indices: idx, faceIDs: fid)
        let gid = UUID()
        let group = SelectionGroup(id: gid, name: "C", colorIndex: 0, faces: [7], regionIDs: [])
        let res = LatticeRegionEmission.regions(groups: [group], roles: [gid: .include], primitives: { _ in [] },
                                                includePrimitives: [], faceDepthMM: 5,
                                                facets: { LatticeFaceFacets.facets(face: $0, in: mesh) },
                                                resolve: { _ in nil })
        XCTAssertGreaterThan(res.regions.count, 1)
        var signs = Set<Int>(), count = 0
        for reg in res.regions {
            XCTAssertEqual(reg.outlineSeams.count, reg.outlineSeamTilt.count)
            for (l, sl) in reg.outlineSeams.enumerated() { for (i, isSeam) in sl.enumerated() where isSeam {
                let t = reg.outlineSeamTilt[l][i]
                XCTAssertGreaterThan(abs(t), 1e-6, "a seam carries a tilt")
                XCTAssertLessThan(abs(t), tan(20 * Double.pi / 180), "no facet pair is more than 40° apart")
                signs.insert(t > 0 ? 1 : -1); count += 1
            } }
        }
        XCTAssertGreaterThan(count, 0)
        XCTAssertEqual(signs.count, 1, "★ one curvature ⇒ one sign everywhere")
    }

    /// ★ A SEAM BY GEOMETRY (his 2026-09-22 14:55): his STEP tessellation shares no edge
    /// vertices between adjacent faces, so the raw neighbour is nil on both sides; two
    /// latticed walls meeting at a corner are still seams — the corner edge of one lies
    /// along the (differently split) corner edge of the other.
    func testTwoLatticedWallsMeetingAtACornerAreSeamsEvenWhenTheMeshSharesNoEdge() {
        var a = LatticeRegionSpec(role: .include, kind: .face)
        a.rawFaceID = 1; a.faceID = 1; a.origin = SIMD3(0, 0, 10); a.normal = SIMD3(0, 0, -1); a.depthMM = 8
        a.outlineLoops = [[SIMD2(-10, -10), SIMD2(10, -10), SIMD2(10, 10), SIMD2(-10, 10)]]
        var b = LatticeRegionSpec(role: .include, kind: .face)
        b.rawFaceID = 2; b.faceID = 2; b.origin = SIMD3(10, 0, 0); b.normal = SIMD3(-1, 0, 0); b.depthMM = 6
        // b's outline splits the shared corner edge (world x = 10, z = 10) into three
        let (bu, bv) = LatticeRegionMask.basisForTests(LatticeRegionMask.unit(b.normal))
        func uv(_ p: SIMD3<Double>) -> SIMD2<Double> { let d = p - b.origin; return SIMD2(simd_dot(d, bu), simd_dot(d, bv)) }
        b.outlineLoops = [[uv(SIMD3(10, -10, -10)), uv(SIMD3(10, 10, -10)), uv(SIMD3(10, 10, 10)),
                           uv(SIMD3(10, 3, 10)), uv(SIMD3(10, -4, 10)), uv(SIMD3(10, -10, 10))]]
        var out = [a, b]
        LatticeRegionEmission.finishSeams(&out, runFaceID: { Int($0) })
        let sa = out[0].outlineSeams.first ?? [], sb = out[1].outlineSeams.first ?? []
        XCTAssertEqual(sa.filter { $0 }.count, 1, "a's one corner edge is a seam: \(sa)")
        XCTAssertEqual(sb.filter { $0 }.count, 3, "b's three corner pieces are seams: \(sb)")
        XCTAssertEqual(out[0].outlineSeamFaces.first?.compactMap { $0 }, [2])
        XCTAssertEqual(Set(out[1].outlineSeamFaces.first?.compactMap { $0 } ?? []), [1])
        for t in (out[0].outlineSeamTilt.first ?? []) where abs(t) > 1e-9 { XCTAssertEqual(abs(t), 1, accuracy: 1e-6, "90° ⇒ tan 45°") }
        // the other edges are not seams, and a far-away wall is not one either
        var c = b; c.rawFaceID = 3; c.faceID = 3; c.origin = SIMD3(60, 0, 0)
        var out2 = [a, c]
        LatticeRegionEmission.finishSeams(&out2, runFaceID: { Int($0) })
        XCTAssertTrue(out2[0].outlineSeams.isEmpty, "no seam to a wall 50 mm away")
    }

    /// ★ A SEAM BY THE PRISM BEYOND THE EDGE (his stand, 2026-09-22 15:25): a fillet face
    /// separates two latticed walls, so neither mesh edges nor outline geometry meet — but
    /// the other wall's prism lies just beyond the edge. Opposite walls never pair.
    func testTwoWallsJoinedThroughAFilletAreSeamsBecauseTheOthersPrismLiesBeyondTheEdge() {
        // wall A: the +z face of a block, its outline stopping 2 mm short of the corner (the fillet)
        var a = LatticeRegionSpec(role: .include, kind: .face)
        a.rawFaceID = 1; a.faceID = 1; a.origin = SIMD3(0, 0, 10); a.normal = SIMD3(0, 0, -1); a.depthMM = 8
        a.outlineLoops = [[SIMD2(-10, -10), SIMD2(8, -10), SIMD2(8, 10), SIMD2(-10, 10)]]
        // wall B: the +x face (x = 10), 20 deep, its outline also 2 mm short of the corner
        var b = LatticeRegionSpec(role: .include, kind: .face)
        b.rawFaceID = 2; b.faceID = 2; b.origin = SIMD3(10, 0, 0); b.normal = SIMD3(-1, 0, 0); b.depthMM = 20
        let (bu, bv) = LatticeRegionMask.basisForTests(LatticeRegionMask.unit(b.normal))
        func uv(_ p: SIMD3<Double>) -> SIMD2<Double> { let d = p - b.origin; return SIMD2(simd_dot(d, bu), simd_dot(d, bv)) }
        b.outlineLoops = [[uv(SIMD3(10, -10, -10)), uv(SIMD3(10, 10, -10)), uv(SIMD3(10, 10, 8)), uv(SIMD3(10, -10, 8))]]
        var out = [a, b]
        LatticeRegionEmission.finishSeams(&out, runFaceID: { Int($0) })
        XCTAssertEqual(out[0].outlineSeams.first?.filter { $0 }.count, 1, "A's edge toward the corner is a seam: \(out[0].outlineSeams)")
        XCTAssertEqual(out[1].outlineSeams.first?.filter { $0 }.count, 1, "B's edge toward the corner is a seam: \(out[1].outlineSeams)")
        // the cap: the neighbour's depth less the probe gap at which its prism was found (0.5 mm)
        XCTAssertEqual(out[0].outlineSeamDepthMM.first?.max(), 19.5, "A's seam is capped at B's depth less the gap")
        XCTAssertEqual(out[1].outlineSeamDepthMM.first?.max(), 7.5, "B's seam is capped at A's depth less the gap")
        // ★ and only where the part has MATERIAL beyond the edge (2026-09-23): the same
        // two walls with air beyond A's corner edge are not seams
        var out3 = [a, b]
        LatticeRegionEmission.finishSeams(&out3, runFaceID: { Int($0) }, solidAt: { _ in false })
        XCTAssertTrue(out3[0].outlineSeams.isEmpty, "a prism reaching across air is not a lattice beyond the edge")
        var out4 = [a, b]
        LatticeRegionEmission.finishSeams(&out4, runFaceID: { Int($0) }, solidAt: { _ in true })
        XCTAssertEqual(out4[0].outlineSeams.first?.filter { $0 }.count, 1)
        // opposite walls in a thin leg: never a seam
        var c = a; c.rawFaceID = 3; c.faceID = 3; c.origin = SIMD3(0, 0, 0); c.normal = SIMD3(0, 0, 1); c.depthMM = 8
        var out2 = [a, c]
        LatticeRegionEmission.finishSeams(&out2, runFaceID: { Int($0) })
        XCTAssertTrue(out2[0].outlineSeams.isEmpty && out2[1].outlineSeams.isEmpty, "opposite walls never pair")
    }

    /// The cap on the flare: beyond the neighbour's depth the prism keeps its full width.
    func testTheFlareIsCappedAtTheNeighboursDepth() {
        let square: [SIMD2<Double>] = [SIMD2(-10, -10), SIMD2(10, -10), SIMD2(10, 10), SIMD2(-10, 10)]
        let seams = [[false, true, false, false]], tilts = [[0.0, -1.0, 0.0, 0.0]]
        // converging 45° seam, neighbour 6 mm deep: at depth 15 the cut is 6, not 15
        XCTAssertFalse(LatticeFaceOutline.insideWithFlare(SIMD2(9, 0), loops: [square], seams: seams, tilts: tilts, caps: [[0, 6, 0, 0]], depth: 15))
        XCTAssertTrue(LatticeFaceOutline.insideWithFlare(SIMD2(3, 0), loops: [square], seams: seams, tilts: tilts, caps: [[0, 6, 0, 0]], depth: 15), "7 mm in is kept with the cap")
        XCTAssertFalse(LatticeFaceOutline.insideWithFlare(SIMD2(3, 0), loops: [square], seams: seams, tilts: tilts, depth: 15), "uncapped, depth 15 cuts 15")
    }

    /// ★ THE WIRE CARRIES THE SELECTION (his 2026-09-22 15:50): a diverging seam edge is
    /// pushed out by depth × tilt (capped at the neighbour's depth) so core's flat slabs
    /// union to the bisector pocket; converging seams and true edges do not move.
    func testTheWireOutlineIsGrownAcrossDivergingSeamsOnly() {
        var r = LatticeRegionSpec(role: .include, kind: .face)
        r.origin = .zero; r.normal = SIMD3(0, 0, -1); r.depthMM = 5; r.halfUMM = 10; r.halfWMM = 10
        r.outlineLoops = [[SIMD2(-10, -10), SIMD2(10, -10), SIMD2(10, 10), SIMD2(-10, 10)]]
        r.outlineSeams = [[false, true, false, true]]
        r.outlineSeamTilt = [[0, 1.0, 0, -1.0]]          // +x edge diverging (45°), −x edge converging
        r.outlineSeamDepthMM = [[0, 20, 0, 20]]
        let w = r.wireOutlineLoops[0]
        XCTAssertEqual(w.map { $0.x }.max()!, 15, accuracy: 1e-9, "+x edge out by 5 × tan 45°")
        XCTAssertEqual(w.map { $0.x }.min()!, -10, accuracy: 1e-9, "the converging edge stays")
        XCTAssertEqual(w.map { $0.y }.max()!, 10, accuracy: 1e-9); XCTAssertEqual(w.map { $0.y }.min()!, -10, accuracy: 1e-9)
        let d = r.wireDictionary(frameAxes: false)["geometry"] as! [String: Any]
        XCTAssertEqual(d["half_u_mm"] as! Double, 15, accuracy: 1e-9, "the bounding box holds the grown outline")
        // capped at the neighbour's depth: a 2 mm neighbour caps the growth at 2
        r.outlineSeamDepthMM = [[0, 2, 0, 20]]
        XCTAssertEqual(r.wireOutlineLoops[0].map { $0.x }.max()!, 12, accuracy: 1e-9)
        // the preview's own loops are untouched
        XCTAssertEqual(r.outlineLoops[0].map { $0.x }.max()!, 10, accuracy: 1e-9)
    }

    /// ★ EXPAND GROWS THE OUTLINE AND THE DEPTH, NEVER THE MOUTH (his 2026-09-23: "every
    /// direction" and "the face should always be the position of the face-prism's face"):
    /// the far end moves deeper by the expand, the outline widens by it, the origin stays
    /// on the face — and the wire carries the growth as geometry.
    func testExpandGrowsTheDepthAndTheOutlineAndTheMouthStaysOnTheFace() {
        let face = LatticeRegionEmission.ResolvedFace.plane(
            center: SIMD3(0, 0, 10), normal: SIMD3(0, 0, 1), halfUMM: 10, halfWMM: 10,
            outlineLoops: [[SIMD2(-10, -10), SIMD2(10, -10), SIMD2(10, 10), SIMD2(-10, 10)]],
            neighbours: [[nil, nil, nil, nil]])
        let plain = LatticeRegionEmission.spec(for: face, role: .include, depthMM: 8, faceID: 1)!
        let grown = LatticeRegionEmission.spec(for: face, role: .include, depthMM: 8, faceID: 1, expandMM: 2)!
        XCTAssertEqual(plain.depthMM, 8); XCTAssertEqual(plain.origin.z, 10, accuracy: 1e-9)
        XCTAssertEqual(grown.depthMM, 10, accuracy: 1e-9, "8 + 2")
        XCTAssertEqual(grown.origin.z, 10, accuracy: 1e-9, "★ the mouth stays ON the face")
        XCTAssertEqual(grown.inPlaneOffsetMM, 2, accuracy: 1e-9)
        // the region: a point 1 mm outside the old outline, 9.5 mm below the mouth, is inside now
        XCTAssertTrue(LatticeRegionMask.contains(SIMD3(11, 0, 10 - 9.5), region: grown))
        XCTAssertFalse(LatticeRegionMask.contains(SIMD3(11, 0, 10 - 9.5), region: plain))
        XCTAssertFalse(LatticeRegionMask.contains(SIMD3(0, 0, 10.5), region: grown), "nothing ahead of the face")
        // the wire outline is 2 mm wider all round, and the wire carries the grown depth from the same mouth
        let w = grown.wireOutlineLoops[0]
        XCTAssertEqual(w.map { $0.x }.max()!, 12, accuracy: 1e-9); XCTAssertEqual(w.map { $0.y }.min()!, -12, accuracy: 1e-9)
        let d = grown.wireDictionary(frameAxes: false)["geometry"] as! [String: Any]
        XCTAssertEqual(d["depth_mm"] as! Double, 10, accuracy: 1e-9)
        XCTAssertEqual((d["origin"] as! [Double])[2], 10, accuracy: 1e-9)
        // a shrink does the mirror: the mouth still on the face, depth 7, outline 1 mm narrower
        let shrunk = LatticeRegionEmission.spec(for: face, role: .include, depthMM: 8, faceID: 1, expandMM: -1)!
        XCTAssertEqual(shrunk.depthMM, 7, accuracy: 1e-9); XCTAssertEqual(shrunk.origin.z, 10, accuracy: 1e-9)
        XCTAssertEqual(shrunk.wireOutlineLoops[0].map { $0.x }.max()!, 9, accuracy: 1e-9)
    }
}
