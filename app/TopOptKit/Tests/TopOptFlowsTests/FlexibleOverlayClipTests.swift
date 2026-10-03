// FlexibleOverlayClipTests — "the hole in the model" (task 2026-09-29-flexible-screens,
// round 3, item 2; his img 2).
//
// ★ THE DEFECT. The overlay dropped every part triangle of a loaded face whose CENTROID
// passed the sector's cuts. On his pad (top split at x = 50, only 'top A' pressed) the top
// triangle (0,0)-(100,0)-(100,100) has its centroid at (66.7, 33.3), inside A, so all of it
// went — including its x < 50 part, which no column quad replaces: a 1250 mm² hole onto the
// inside of the part. Its twin (0,0)-(100,100)-(0,100) stayed whole and covered 1250 mm² of
// A under the quads. The skin-off set and the no-overlay tint path used the same centroid.
//
// ★ THE INSTRUMENT. Sample the top face on a 0.5 mm grid and count, at every point, the
// kept part triangles plus the pressed sector's column quads that cover it (xy, top face
// only). Away from the sector's own edges (core's columns step at the pitch) every point
// must be covered EXACTLY once. The control applies the SAME instrument to the old centroid
// rule and must find the hole — so a green run is not an instrument that sees nothing.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleOverlayClipTests: XCTestCase {

    struct AOnly {
        let part: ViewerMesh
        let topFace: Int
        let region: Int
        let cuts: [RegionCut]
        let key: FlexFaceKey
        let stack: FlexStackInfo
        let geometry: FlexFaceGeometry
        let scene: FlexibleScene
        let overlay: FlexibleOverlayMesh
    }

    /// The pad split at x = 50 with ONLY the right sector ('top A') pressed.
    static func padAOnly() throws -> AOnly {
        let m = try TopOptKit.importMesh(path: FlexibleStageTests.padSTL)
        let part = ViewerMesh(vertices: m.vertices, indices: m.indices, faceIDs: m.faceIDs, pseudoFaces: true)
        let (model, _) = FlexibleRegionsTests.splitTop(part)
        let regions = FlexibleRegions(model: model, mesh: part)
        let topFace = regions.faces(of: FlexibleRegions.wireID(regions.sectors[0]), mesh: part)[0]
        let right = regions.region(at: SIMD3(80, 50, 20), face: topFace, mesh: part)
        var s = FlexibleStageSettings(materialID: "varioshore_tpu", nozzleTempC: 220)
        s.setFace(FlexibleFaceSettings(faceRegionID: right, weightKg: 10, deepestMM: 3))
        var ji = FlexibleJob.Inputs(modelPath: FlexibleStageTests.padSTL, resolution: 50, beadWidthMM: 0.42,
                                    faceCount: 6, settings: s)
        ji.sectorRegions = regions.wire
        let scene = try FlexibleScene(jobJSON: try FlexibleJob.sceneJobJSON(ji, fallbackMaterial: "varioshore_tpu"), jobDir: "/")
        let st = try scene.stack(face: right, rotation: 0)
        let key = FlexFaceKey(region: right, rotation: 0)
        let geo = try FlexFaceGeometry.compute(scene: scene, key: key, stack: st, partFlat: part.flat.positions)
        let o = FlexibleOverlayMesh.build(part: part, faces: [
            FlexibleOverlayFace(key: key, faces: Set(regions.faces(of: right, mesh: part)),
                                cuts: regions.cuts(of: right), stack: st, centres: geo.centres)])
        return AOnly(part: part, topFace: topFace, region: right, cuts: regions.cuts(of: right), key: key,
                     stack: st, geometry: geo, scene: scene, overlay: o)
    }

    // MARK: the instrument

    typealias Tri = (SIMD2<Double>, SIMD2<Double>, SIMD2<Double>)

    /// Triangles bucketed on a 1 mm grid by their bounding box.
    struct Buckets {
        var cells: [SIMD2<Int32>: [Int]] = [:]
        let tris: [Tri]
        init(_ tris: [Tri]) {
            self.tris = tris
            for (i, t) in tris.enumerated() {
                let lo = simd_min(simd_min(t.0, t.1), t.2), hi = simd_max(simd_max(t.0, t.1), t.2)
                for x in Int32(lo.x.rounded(.down))...Int32(hi.x.rounded(.down)) {
                    for y in Int32(lo.y.rounded(.down))...Int32(hi.y.rounded(.down)) {
                        cells[SIMD2(x, y), default: []].append(i)
                    }
                }
            }
        }
        func count(_ p: SIMD2<Double>) -> Int {
            let c = SIMD2<Int32>(Int32(p.x.rounded(.down)), Int32(p.y.rounded(.down)))
            return (cells[c] ?? []).filter { FlexibleOverlayClipTests.contains(tris[$0], p) }.count
        }
    }

    static func contains(_ t: Tri, _ p: SIMD2<Double>) -> Bool {
        func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        let d1 = cross(t.0, t.1, p), d2 = cross(t.1, t.2, p), d3 = cross(t.2, t.0, p)
        let neg = d1 < -1e-12 || d2 < -1e-12 || d3 < -1e-12, pos = d1 > 1e-12 || d2 > 1e-12 || d3 > 1e-12
        return !(neg && pos)
    }

    static func flat(_ o: FlexibleOverlayMesh, _ v: Int) -> SIMD3<Double> {
        let p = o.mesh.flat.positions
        return SIMD3(Double(p[3 * v]), Double(p[3 * v + 1]), Double(p[3 * v + 2]))
    }

    /// The top face as the overlay draws it: kept part triangles of `topFace` + every quad.
    static func topCover(_ o: FlexibleOverlayMesh, topFace: Int, stacks: [FlexFaceKey: FlexStackInfo]) -> [Tri] {
        var out: [Tri] = []
        for i in 0..<o.keptTriangles.count where o.keptFace[i] == topFace {
            let a = flat(o, 3 * i), b = flat(o, 3 * i + 1), c = flat(o, 3 * i + 2)
            out.append((SIMD2(a.x, a.y), SIMD2(b.x, b.y), SIMD2(c.x, c.y)))
        }
        for (k, start) in o.flatStart {
            guard let st = stacks[k] else { continue }
            for c in 0..<st.columns.count {
                for q in [0, 3] {
                    let v = start + c * 6 + q
                    let a = flat(o, v), b = flat(o, v + 1), d = flat(o, v + 2)
                    out.append((SIMD2(a.x, a.y), SIMD2(b.x, b.y), SIMD2(d.x, d.y)))
                }
            }
        }
        return out
    }

    struct Coverage { var interior = 0, zero = 0, twice = 0, band = 0, bandOff = 0 }

    /// Every 0.5 mm sample of the 100 × 100 top face. A point within half a pitch (+ a hair)
    /// of the pressed sector's edges (x = 50, x = 100, y = 0, y = 100 for x > 50) is "band":
    /// core's columns step there; its misses are counted, not asserted.
    static func measure(_ tris: [Tri], pitch: Double) -> Coverage {
        let b = Buckets(tris)
        var cov = Coverage()
        let h = pitch / 2 + 0.01
        // ★ OFF THE GRID LINES: an offset no quad edge or diagonal passes through, so a point
        // is never counted twice for lying ON the boundary two triangles share
        for i in 0..<200 { for j in 0..<200 {
            let p = SIMD2(0.2513 + 0.5 * Double(i), 0.2371 + 0.5 * Double(j))
            let inA = p.x > 50
            let band = abs(p.x - 50) < h || (inA && (abs(p.x - 100) < h || p.y < h || p.y > 100 - h))
            let n = b.count(p)
            if band { cov.band += 1; if n != 1 { cov.bandOff += 1 }; continue }
            cov.interior += 1
            if n == 0 { cov.zero += 1 } else if n > 1 { cov.twice += 1 }
        } }
        return cov
    }

    // MARK: tests

    /// ★ The top face is closed: every interior point covered exactly once.
    func testTheTopFaceIsCoveredExactlyOnceWithOnlyTopAPressed() throws {
        let a = try Self.padAOnly()
        let cov = Self.measure(Self.topCover(a.overlay, topFace: a.topFace, stacks: [a.key: a.stack]), pitch: a.stack.pitchMM)
        // ★ RED CONTROL: the SAME instrument on the old centroid rule (a triangle dropped whole
        // when its centroid passes the cuts) must find his hole, or this measures nothing
        var old: [Tri] = []
        let part = a.part
        func v(_ i: UInt32) -> SIMD3<Double> {
            let b = Int(i) * 3
            return SIMD3(Double(part.positions[b]), Double(part.positions[b + 1]), Double(part.positions[b + 2]))
        }
        for t in 0..<part.triangleCount where Int(part.faceIDs[t]) == a.topFace {
            let p0 = v(part.indices[3 * t]), p1 = v(part.indices[3 * t + 1]), p2 = v(part.indices[3 * t + 2])
            if FaceRegionGeometry.inside((p0 + p1 + p2) / 3, a.cuts) { continue }
            old.append((SIMD2(p0.x, p0.y), SIMD2(p1.x, p1.y), SIMD2(p2.x, p2.y)))
        }
        let quads = Self.topCover(a.overlay, topFace: -999, stacks: [a.key: a.stack])
        let oldCov = Self.measure(old + quads, pitch: a.stack.pitchMM)
        print(String(format: "FLEX-HOLE pad, only top A pressed (pitch %.2f mm): interior %d points — uncovered %d (%.0f mm²), twice %d; band %d, off %d | OLD centroid rule: uncovered %d (%.0f mm²), twice %d",
                     a.stack.pitchMM, cov.interior, cov.zero, Double(cov.zero) * 0.25, cov.twice, cov.band, cov.bandOff,
                     oldCov.zero, Double(oldCov.zero) * 0.25, oldCov.twice))
        XCTAssertGreaterThan(Double(oldCov.zero) * 0.25, 1000, "control: the old rule must leave his ~1250 mm² hole")
        XCTAssertGreaterThan(oldCov.twice, 1000, "control: …and cover A twice under the kept twin")
        XCTAssertGreaterThan(cov.interior, 30_000)
        XCTAssertEqual(cov.zero, 0, "no hole: every interior point of the top face is covered")
        XCTAssertEqual(cov.twice, 0, "no double cover: the quads replace exactly the sector's part")
    }

    /// ★ The dent's ramp on a clipped piece: its uvt is interpolated from the source
    /// triangle's corners by barycentric weights; core's to_uvt is affine, so this must equal
    /// core's own to_uvt at the clipped vertex. RED CONTROL: the old lookup (corner v % 3 of the
    /// source triangle) is off by millimetres on a clipped vertex.
    func testAClippedPiecesRampIsCoresToUVT() throws {
        let a = try Self.padAOnly()
        let o = a.overlay
        let uvt = a.geometry.partUVT
        let w = o.keptWeights
        XCTAssertEqual(w.count, o.partFlatVertices)
        var worst = 0.0, worstOld = 0.0, clipped = 0
        for v in 0..<o.partFlatVertices {
            let src = o.keptTriangles[v / 3]
            let wv = w[v]
            let identity = (0..<3).allSatisfy { abs(wv[$0] - ($0 == v % 3 ? 1 : 0)) < 1e-12 }
            if identity { continue }
            clipped += 1
            var interp = SIMD3<Double>.zero
            for j in 0..<3 { let q = 3 * (src * 3 + j); interp += wv[j] * SIMD3(uvt[q], uvt[q + 1], uvt[q + 2]) }
            let p = Self.flat(o, v)
            let truth = try a.scene.toUVT(face: a.key.region, rotation: 0, [p.x, p.y, p.z])
            let t = SIMD3(truth[0], truth[1], truth[2])
            worst = max(worst, simd_length(interp - t))
            let q = 3 * (src * 3 + v % 3)
            worstOld = max(worstOld, simd_length(SIMD3(uvt[q], uvt[q + 1], uvt[q + 2]) - t))
        }
        print("FLEX-HOLE uvt on \(clipped) clipped flat vertices: worst |interp − core to_uvt| \(worst) mm; old corner lookup \(worstOld) mm (control)")
        XCTAssertGreaterThan(clipped, 0, "premise: the cut must clip part triangles, or this checks nothing")
        XCTAssertLessThan(worst, 1e-3)
        XCTAssertGreaterThan(worstOld, 1, "control: the old lookup must be off on a clipped vertex")
    }

    /// Skin off on 'top A' must not reach x < 50. RED CONTROL: centroid membership does.
    func testSkinOffOnTopADoesNotReachTopB() throws {
        let a = try Self.padAOnly()
        let s = FlexibleLatticeBuilder.skinnedTriangles(part: a.part, skinOffFaces: [(face: a.topFace, cuts: a.cuts)])
        func tris(_ pos: [Float], _ idx: [UInt32]) -> [Tri] {
            stride(from: 0, to: idx.count, by: 3).compactMap { i in
                let p = (0..<3).map { j -> SIMD3<Double> in
                    let b = Int(idx[i + j]) * 3
                    return SIMD3(Double(pos[b]), Double(pos[b + 1]), Double(pos[b + 2]))
                }
                guard p.allSatisfy({ abs($0.z - 20) < 1e-4 }) else { return nil }
                return (SIMD2(p[0].x, p[0].y), SIMD2(p[1].x, p[1].y), SIMD2(p[2].x, p[2].y))
            }
        }
        func skinned(_ t: [Tri]) -> (bUncovered: Int, aCovered: Int) {
            let b = Buckets(t)
            var bu = 0, ac = 0
            for i in 0..<200 { for j in 0..<200 {
                let p = SIMD2(0.25 + 0.5 * Double(i), 0.25 + 0.5 * Double(j))
                let n = b.count(p)
                if p.x < 50, n == 0 { bu += 1 }
                if p.x > 50, n > 0 { ac += 1 }
            } }
            return (bu, ac)
        }
        let now = skinned(tris(s.positions, s.indices))
        // the old rule: whole triangles by centroid
        var oldIdx: [UInt32] = []
        let part = a.part
        for t in 0..<part.triangleCount {
            let c = (0..<3).map { j -> SIMD3<Double> in
                let b = Int(part.indices[3 * t + j]) * 3
                return SIMD3(Double(part.positions[b]), Double(part.positions[b + 1]), Double(part.positions[b + 2]))
            }.reduce(.zero, +) / 3
            if Int(part.faceIDs[t]) == a.topFace, FaceRegionGeometry.inside(c, a.cuts) { continue }
            oldIdx += [part.indices[3 * t], part.indices[3 * t + 1], part.indices[3 * t + 2]]
        }
        let old = skinned(tris(part.positions, oldIdx))
        print("FLEX-HOLE skin off on top A: top B points without skin \(now.bUncovered), top A points still skinned \(now.aCovered) | OLD centroid rule: \(old.bUncovered), \(old.aCovered)")
        XCTAssertGreaterThan(old.bUncovered + old.aCovered, 1000, "control: centroid membership bleeds across the cut")
        XCTAssertEqual(now.bUncovered, 0, "top B keeps its skin")
        XCTAssertEqual(now.aCovered, 0, "top A has none")
    }

    /// ★ HIS PROJECT, restored the way the app restores it, with only 'top A' pressed (img 2's
    /// state): the PAGE's own overlay (FlexiblePageChannels.overlay — what the page calls)
    /// closes the top face.
    @MainActor
    func testHisProjectTopFaceIsClosedWithOnlyTopAPressed() async throws {
        let r = try FlexibleHisProject.restore()
        defer { r.cleanup() }
        let pm = r.project
        var s = try XCTUnwrap(pm.lattice.flexible)
        s.faces = s.faces.filter { $0.faceRegionID == FlexibleHisProject.topA }
        s.checkStamps = []
        XCTAssertEqual(s.loadedFaces.map(\.faceRegionID), [FlexibleHisProject.topA], "premise: only top A pressed")
        pm.lattice.flexible = s
        let m = try await FlexibleHisProject.openedModel(pm, test: self)
        let o = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        let key = FlexFaceKey(region: FlexibleHisProject.topA, rotation: 0)
        let st = try XCTUnwrap(m.stacks[key])
        let cov = Self.measure(Self.topCover(o, topFace: 1, stacks: m.stacks), pitch: st.pitchMM)
        print(String(format: "FLEX-HOLE HIS project 0004, only top A pressed: interior %d — uncovered %d (%.0f mm²), twice %d; band %d, off %d",
                     cov.interior, cov.zero, Double(cov.zero) * 0.25, cov.twice, cov.band, cov.bandOff))
        XCTAssertGreaterThan(cov.interior, 30_000)
        XCTAssertEqual(cov.zero, 0, "his top face must be closed")
        XCTAssertEqual(cov.twice, 0)
    }

    /// ★ THE TINT BEFORE ANY STACK (the page's no-map path): on his project, before a single
    /// stack exists, the page's overlay is already cut along x = 50, so every top-face piece
    /// lies on ONE side of the cut and its tint (by centroid) is exact. RED CONTROL: the part's
    /// own top triangles straddle the cut (what the old per-triangle tint coloured by centroid).
    @MainActor
    func testHisProjectSectorTintStopsAtTheCutBeforeAnyStack() throws {
        let r = try FlexibleHisProject.restore()
        defer { r.cleanup() }
        let m = FlexibleStageModel(project: r.project, materialsPath: FlexibleHisProject.materialsPath,
                                   stampsPath: FlexibleHisProject.stampsPath, persist: {})
        XCTAssertTrue(m.stacks.isEmpty, "premise: no stack yet (the scene is not open)")
        let o = try XCTUnwrap(FlexiblePageChannels.overlay(model: m), "a split face must be cut even with no map")
        func straddles(_ p: [SIMD3<Double>]) -> Bool { p.contains { $0.x < 50 - 1e-6 } && p.contains { $0.x > 50 + 1e-6 } }
        var pieces = 0, straddling = 0
        for i in 0..<o.keptTriangles.count where o.keptFace[i] == 1 {
            pieces += 1
            if straddles([Self.flat(o, 3 * i), Self.flat(o, 3 * i + 1), Self.flat(o, 3 * i + 2)]) { straddling += 1 }
        }
        let part = try XCTUnwrap(r.project.viewerMesh)
        var partStraddling = 0
        for t in 0..<part.triangleCount where part.faceIDs[t] == 1 {
            let p = (0..<3).map { j -> SIMD3<Double> in
                let b = Int(part.indices[3 * t + j]) * 3
                return SIMD3(Double(part.positions[b]), Double(part.positions[b + 1]), Double(part.positions[b + 2]))
            }
            if straddles(p) { partStraddling += 1 }
        }
        print("FLEX-HOLE his top face before any stack: \(pieces) pieces, \(straddling) straddle x = 50 | the part's own: \(partStraddling) straddle (control)")
        XCTAssertGreaterThan(partStraddling, 0, "control: his part's top triangles cross the cut")
        XCTAssertEqual(straddling, 0)
    }

    /// The page builds its overlay through FlexiblePageChannels (so the test above is the
    /// page's overlay, not a copy of it).
    func testThePageBuildsItsOverlayThroughTheSharedFunction() throws {
        let src = try String(contentsOf: FlexibleHisProject.repoRoot
            .appendingPathComponent("app/TopOptKit/Sources/TopOptFlows/FlexibleStagePage.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("FlexiblePageChannels.overlay(model: model)"))
        XCTAssertFalse(src.contains("FlexibleOverlayMesh.build("), "the page must not build a second overlay of its own")
    }
}
