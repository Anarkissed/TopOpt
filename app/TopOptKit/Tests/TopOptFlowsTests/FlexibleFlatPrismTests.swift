// FlexibleFlatPrismTests — round 7, batch R7-E1: the edge/corner FLAT PRISM. His words, 2026-10-18 (binding): "There should be a
// prism that the user can drag to show how far it can squish in … It should also be able to be angled up or down based on the
// user's choice." and "There shouldn't be a strip width. It should be a Flat prism that gets wider as it gets dragged further
// towards the centre of the model from the edge. We should be able to change the angle up/down and left/right of the prism."
// His answers: LEFT/RIGHT = TWIST along the edge (one end deeper); a corner = the same flat cut (a triangle on each face); the
// arrow knob starts at core's halfway and snaps back there; the twist stops when the shallow end reaches 0 mm; the half-face rule
// is DROPPED (each face keeps some of itself).
//
// THE GEOMETRY (FlexibleFlatPrism), THE ANGLES and THE LIMITS (FlexibleFlatPrismAngles), on the 60 mm cube (core's pseudo-faces)
// and on HIS pad (A1_0003, the whole pad latticed through the Top's face-prism — FlexiblePressFixtures.a1Project(3)). Written
// BEFORE the code, against stubs (red run: round7/batch_e1/e1b_red_run.txt). Each RED CONTROL runs inside its test.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
enum FlexibleFlatPrismFixtures {
    typealias M2 = FlexibleM2Fixtures

    /// His pad (A1_0003, his Top's face-prism 20 mm: the whole pad latticed), opened and settled.
    static func hisPad(_ t: XCTestCase, facePrism: Bool = true) async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexiblePressFixtures.a1Project(3, t, facePrism: facePrism)
        let m = try await FlexibleAngledGoldens.openModel(t, r.project, "A1_0003")
        try await FlexibleSquishFixture.settle(m, "A1_0003")
        return (r, m)
    }

    /// His pad with his LIVE lattice (Group C = Face 3 + Face 5, Protect + Lattice, 25 mm), opened and settled.
    static func hisLivePad(_ t: XCTestCase) async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexiblePressFixtures.a1Project(3, t, facePrism: false)
        _ = try FlexibleR7M1Fixtures.hisLiveLattice(r.project)
        let m = try await FlexibleAngledGoldens.openModel(t, r.project, "A1_0003 live")
        try await FlexibleSquishFixture.settle(m, "A1_0003 live")
        return (r, m)
    }

    /// The 60 mm cube (core asked with no face-prism — a test control on its fresh project id), opened.
    static func cube(_ t: XCTestCase) async throws -> (ProjectModel, FlexibleStageModel) {
        let p = try FlexiblePressFixtures.cube60Project()
        let m = try await FlexibleAngledGoldens.openModel(t, p, "cube60")
        try await FlexibleSquishFixture.settle(m, "cube60")
        return (p, m)
    }

    /// A corner candidate whose members lie on exactly `faces`.
    static func corner(_ m: FlexibleStageModel, _ p: FlexibleEdgePick, faces: Set<Int>? = nil) -> FlexibleEdgeCandidates.Candidate? {
        let mesh = m.project.viewerMesh
        return p.candidates.first { c in
            c.kind == .corner && p.greyed[c.number] == nil
                && (faces.map { Set(c.members.flatMap { m.regions.faces(of: $0, mesh: mesh) }) == $0 } ?? true)
        }
    }

    /// Any pickable edge.
    static func anyEdge(_ p: FlexibleEdgePick) -> FlexibleEdgeCandidates.Candidate? {
        p.candidates.first { $0.kind == .edge && p.greyed[$0.number] == nil }
    }

    /// Pick `c` and [Done]: its press.
    static func commit(_ m: FlexibleStageModel, _ c: FlexibleEdgeCandidates.Candidate, kg: Double = 5) async throws -> FlexiblePress {
        m.toggleEdgePick(c.number)
        let why = try await M2.done(m, kg: kg)
        XCTAssertNil(why, "[Done] for \(FlexibleRowCopy.candidateLabel(c))")
        return try XCTUnwrap(m.presses.last { $0.strip?.label == FlexibleRowCopy.candidateLabel(c) }, "its press")
    }

    /// Edge 16 of his pad: Face 3 + Face 2 (the vertical 20 mm edge). Its candidate and its area (strip) as the pick card holds it.
    static func edge16(_ m: FlexibleStageModel) async throws -> (pick: FlexibleEdgePick, c: FlexibleEdgeCandidates.Candidate, strip: FlexibleStrip) {
        let p = try await M2.pickMode(m)
        let c = try XCTUnwrap(M2.edge(m, p, faces: [3, 2]), "Edge 16: Face 3 + Face 2")
        let st = try XCTUnwrap(p.strips[c.number], "its area")
        return (p, c, st)
    }

    /// Each member face's triangles.
    static func faceTris(_ m: FlexibleStageModel, _ s: FlexibleStrip) -> [[[SIMD3<Double>]]] {
        s.members.map { FlexibleEdgeStrips.triangles(face: $0.face, mesh: m.project.viewerMesh!) }
    }

    /// L3 as the stage reads it: the first member whose face would keep none of itself.
    static func keepsRest(_ m: FlexibleStageModel, _ s: FlexibleStrip) -> (SIMD3<Double>, Double) -> Int? {
        let tris = faceTris(m, s)
        return { d, h in
            let c = FlexibleFlatPrism.cut(s, direction: d, depthMM: h)
            return s.members.indices.first { !FlexibleFlatPrism.keepsRest(tris[$0], member: s.members[$0], c) }
        }
    }

    static func bits(_ v: SIMD3<Double>) -> [UInt64] { [v.x.bitPattern, v.y.bitPattern, v.z.bitPattern] }

    /// ★ The edit the re-pinned tests make where they changed the Strip width (round 7 R7-E1, his 2026-10-18 words: "There
    /// shouldn't be a strip width"): the press's flat prism one step deeper or shallower (8 or 6 mm), one undo step.
    @discardableResult
    static func reDepth(_ m: FlexibleStageModel, _ pid: UUID) async -> String? {
        guard let p = m.press(pid) else { return "no such press" }
        let h = FlexibleFlatPrism.depth(of: p) ?? FlexibleFlatPrism.defaultDepthMM
        return await m.setFlatCut(pid, depthMM: h > 6.5 ? 6 : 8, direction: p.direction, snap: p.snap)
    }

    /// The area of a member's footprint under `cuts`.
    static func area(_ tris: [[SIMD3<Double>]], _ cuts: [RegionCut]) -> Double { FlexibleEdgeStrips.area(tris, cuts) }

    /// The complement of a member's IN-FACE cut (its first cut): the rest's side.
    static func flipped(_ c: RegionCut) -> RegionCut { RegionCut(point: c.point, normal: SIMD3<Double>.zero - c.normal) }
}

@MainActor
final class FlexibleFlatPrismTests: XCTestCase {
    typealias F = FlexibleFlatPrismFixtures
    typealias A = FlexibleFlatPrismAngles

    override func tearDown() {
        FlexibleFlatPrism.controlNoConvexity = false
        FlexibleFlatPrism.controlThreeDCut = false
        super.tearDown()
    }

    // MARK: - one plane, cut in each member's own face

    /// cube60 edge, d = halfway, h = 10: each member's in-face cut ⟂ core's n_i; both trace ends on P; the footprint per face
    /// 60·10√2; strip ∪ rest = the face. RED: the strip-width route (legacyHalfSpaces, width 10) presses 600 mm².
    func testOnePlaneCutsEveryMemberInItsOwnFace() async throws {
        let (_, m) = try await F.cube(self)
        let p = try await F.M2.pickMode(m)
        let c = try XCTUnwrap(F.anyEdge(p), "an edge of the cube")
        let st = try XCTUnwrap(p.strips[c.number])
        let d0 = try XCTUnwrap(st.halfway, "★ the halfway stored at pick time")
        let aim = try await m.pressAim(c.members)
        let cut = FlexibleFlatPrism.cut(st, direction: d0, depthMM: 10)
        let cuts = FlexibleFlatPrism.memberCuts(st, cut)
        let tris = F.faceTris(m, st)
        XCTAssertEqual(cuts.count, 2)
        for k in 0..<2 {
            let inFace = try XCTUnwrap(cuts[k].first)
            XCTAssertLessThan(Swift.abs(simd_dot(inFace.normal, aim.memberLoads[k])), 1e-12, "★ member \(k)'s cut lies in its own face (⟂ core's normal)")
            let polys = FlexibleFlatPrism.footprint(tris[k], cuts[k])
            let traces = FlexibleFlatPrism.traces(polys, cut)
            XCTAssertFalse(traces.isEmpty, "member \(k) has a trace")
            for t in traces { for q in t { XCTAssertEqual(cut.height(q), 10, accuracy: 1e-9, "★ the trace lies on the plane") } }
            let a = F.area(tris[k], cuts[k])
            XCTAssertEqual(a, 60 * 10 * 2.0.squareRoot(), accuracy: 1e-9 * a, "★ the footprint on member \(k): 60 · 10√2")
            let rest = F.area(tris[k], [F.flipped(inFace)])
            XCTAssertEqual(a + rest, 3600, accuracy: 1e-6, "strip ∪ rest = the face")
            // ★ RED CONTROL: the strip-width route
            let legacy = F.area(tris[k], FlexibleEdgeStrips.legacyHalfSpaces(st.members[k], width: 10))
            XCTAssertEqual(legacy, 600, accuracy: 1e-6, "★ RED CONTROL: the width route presses 60 × 10")
            print("FLEX-E1-G1 member \(k): flat \(a) mm² · rest \(rest) · width route \(legacy)")
        }
    }

    /// cube60 edge at θ = 20°: the in-face cut classifies core's voxel centres under the face (passes_cuts at voxel centres —
    /// core's cut_voxels rule) with its boundary ON the trace's in-face line, at any depth under the face. RED: a 3D cut with
    /// normal −d moves that boundary by ~half a voxel × the angle's tangent.
    func testTheInFaceCutMatchesCoresVoxelRule() async throws {
        let (_, m) = try await F.cube(self)
        let p = try await F.M2.pickMode(m)
        let c = try XCTUnwrap(F.anyEdge(p))
        let st = try XCTUnwrap(p.strips[c.number])
        let f = try XCTUnwrap(A.frame(st, d0: try XCTUnwrap(st.halfway), up: try XCTUnwrap(m.sceneInfo?.buildDir)))
        let d = A.compose(f, theta: 20, phi: 0)
        let cut = FlexibleFlatPrism.cut(st, direction: d, depthMM: 10)
        let h = try XCTUnwrap(m.sceneInfo?.spacing)
        func boundary(_ cuts: [RegionCut], member k: Int) -> Double {
            // along the in-face direction t̂ from the apex, at the first voxel layer under the face (h/2 deep): where the
            // voxel-centre rule flips from kept to not
            let mb = st.members[k]
            guard let t = FlexibleFlatPrism.inFace(mb, d), let nIn = FlexibleFlatPrism.inwardNormal(mb, toward: d) else { return -1 }
            let mid = cut.apex + (mb.along ?? .zero) * 30
            func kept(_ s: Double) -> Bool { cuts.allSatisfy { simd_dot(mid + t * s + nIn * (h / 2) - $0.point, $0.normal) >= 0 } }
            var lo = 0.0, hi = 60.0
            for _ in 0..<80 { let x = (lo + hi) / 2; if kept(x) { lo = x } else { hi = x } }
            return lo
        }
        for k in 0..<2 {
            let t = try XCTUnwrap(FlexibleFlatPrism.inFace(st.members[k], d), "member \(k)'s in-face direction")
            let trace = 10 / simd_dot(t, d)   // the trace's distance from the edge along t̂
            let inFace = boundary([try XCTUnwrap(FlexibleFlatPrism.memberCuts(st, cut)[k].first)], member: k)
            FlexibleFlatPrism.controlThreeDCut = true
            let threeD = boundary([try XCTUnwrap(FlexibleFlatPrism.memberCuts(st, cut)[k].first)], member: k)
            FlexibleFlatPrism.controlThreeDCut = false
            print("FLEX-E1-G2 member \(k): trace \(trace) mm · in-face boundary \(inFace) · 3D-cut boundary \(threeD) · voxel \(h)")
            XCTAssertLessThan(Swift.abs(inFace - trace), 0.01 * h, "★ member \(k): the voxel-centre boundary is the trace's own line")
            XCTAssertGreaterThan(Swift.abs(threeD - trace), 0.1 * h, "★ RED CONTROL: a 3D −d cut shifts the boundary at the voxel layer")
        }
    }

    /// h = 2 / 4 / 8 → the reach on both faces 2√2 / 4√2 / 8√2; the rest strictly smaller each time. RED: the width route's
    /// reach does not move with depth.
    func testDeeperIsWiderOnEveryFace() async throws {
        let (_, m) = try await F.cube(self)
        let p = try await F.M2.pickMode(m)
        let st = try XCTUnwrap(p.strips[try XCTUnwrap(F.anyEdge(p)).number])
        let d0 = try XCTUnwrap(st.halfway)
        let tris = F.faceTris(m, st)
        var lastRest = [Double](repeating: .infinity, count: 2)
        for h in [2.0, 4, 8] {
            let cut = FlexibleFlatPrism.cut(st, direction: d0, depthMM: h)
            let cuts = FlexibleFlatPrism.memberCuts(st, cut)
            for k in 0..<2 {
                let reach = try XCTUnwrap(FlexibleFlatPrism.reach(st, member: k, cut))
                XCTAssertEqual(reach, h * 2.0.squareRoot(), accuracy: 1e-9, "★ h \(h): member \(k) reaches h√2")
                XCTAssertEqual(F.area(tris[k], cuts[k]) / 60, h * 2.0.squareRoot(), accuracy: 1e-9, "the footprint is 60 × the reach")
                let rest = F.area(tris[k], [F.flipped(try XCTUnwrap(cuts[k].first))])
                XCTAssertLessThan(rest, lastRest[k], "★ deeper: the rest is smaller")
                lastRest[k] = rest
            }
        }
        // ★ RED CONTROL: the width route keeps its reach at every depth
        let w = (0..<3).map { _ in F.area(tris[0], FlexibleEdgeStrips.legacyHalfSpaces(st.members[0], width: 4)) / 60 }
        XCTAssertEqual(Set(w.map { ($0 * 1e6).rounded() }).count, 1, "★ RED CONTROL: the width route never widens")
    }

    /// His Edge 16 (Face 3 + Face 2, vertical, 20 mm). θ = +20° toward the first face named: reach there h/sin 25°, on the other
    /// h/cos 25°. φ = +10°: the named end is the deep one, the ends differ along d by 20·sin 10° = 3.473 mm, each footprint a
    /// trapezoid (L × the mean reach). RED: the width route presses both ends alike whatever the twist.
    func testTiltLeansAndTwistDeepensOneEnd() async throws {
        let (_, m) = try await F.hisPad(self)
        let (_, _, st) = try await F.edge16(m)
        let f = try XCTUnwrap(A.frame(st, d0: try XCTUnwrap(st.halfway), up: try XCTUnwrap(m.sceneInfo?.buildDir)))
        let h = 10.0
        let tilt = FlexibleFlatPrism.cut(st, direction: A.compose(f, theta: 20, phi: 0), depthMM: h)
        let r0 = try XCTUnwrap(FlexibleFlatPrism.reach(st, member: 0, tilt)), r1 = try XCTUnwrap(FlexibleFlatPrism.reach(st, member: 1, tilt))
        print("FLEX-E1-G4 θ +20° toward Face \(st.members[0].face): reach \(r0) / \(r1) (h/sin25 \(h / sin(25 * .pi / 180)), h/cos25 \(h / cos(25 * .pi / 180)))")
        XCTAssertEqual(r0, h / sin(25 * .pi / 180), accuracy: 1e-9, "★ it leans toward Face \(st.members[0].face): its trace moves out")
        XCTAssertEqual(r1, h / cos(25 * .pi / 180), accuracy: 1e-9, "★ the other trace moves in")
        let tw = FlexibleFlatPrism.cut(st, direction: A.compose(f, theta: 0, phi: 10), depthMM: h)
        let line = try XCTUnwrap(FlexibleFlatPrism.line(st))
        let e0 = line.origin + line.dir * line.s0, e1 = line.origin + line.dir * line.s1
        let up = try XCTUnwrap(m.sceneInfo?.buildDir)
        let top = simd_dot(e1, up) > simd_dot(e0, up) ? e1 : e0, bottom = top == e1 ? e0 : e1
        XCTAssertEqual(f.namedEnd, "top end", "a vertical edge names its top end")
        XCTAssertEqual(simd_distance(tw.apex, top), 0, accuracy: 1e-9, "★ + twist: the named (top) end is the deep one")
        XCTAssertEqual(tw.height(bottom) - tw.height(top), 20 * sin(10 * .pi / 180), accuracy: 1e-9, "★ the ends differ by 20·sin 10°")
        let tris = F.faceTris(m, st)
        let cuts = FlexibleFlatPrism.memberCuts(st, tw)
        for k in 0..<2 {
            let deep = try XCTUnwrap(FlexibleFlatPrism.reach(st, member: k, tw, along: simd_dot(top - line.origin, line.dir)))
            let shallow = try XCTUnwrap(FlexibleFlatPrism.reach(st, member: k, tw, along: simd_dot(bottom - line.origin, line.dir)))
            XCTAssertGreaterThan(deep, shallow, "member \(k): deeper at the top end")
            XCTAssertGreaterThan(shallow, 0, "member \(k): the shallow end still squishes")
            XCTAssertEqual(F.area(tris[k], cuts[k]), 20 * (deep + shallow) / 2, accuracy: 1e-6, "★ member \(k): a trapezoid")
            // ★ RED CONTROL: the width route — the same reach at both ends, whatever the twist
            let w = FlexibleEdgeStrips.legacyHalfSpaces(st.members[k], width: 10)
            XCTAssertEqual(F.area(tris[k], w), 20 * 10, accuracy: 1e-6, "★ RED CONTROL: the width route is a rectangle")
        }
    }

    // MARK: - a corner: one plane

    /// cube60 corner at halfway, h = 10: three right isosceles triangles, legs 10√3, 150 mm² each; ONE rest piece per face (only
    /// rest:…:1 keys). RED: the old w × w patch leaves an L in two rest pieces (rest:…:2).
    func testACornerIsOnePlaneATriangleOnEachFaceAndOneRest() async throws {
        let (p, m) = try await F.cube(self)
        let pick = try await F.M2.pickMode(m)
        let c = try XCTUnwrap(F.corner(m, pick), "a corner of the cube")
        var st = try XCTUnwrap(pick.strips[c.number])
        let d0 = try XCTUnwrap(st.halfway)
        let cut = FlexibleFlatPrism.cut(st, direction: d0, depthMM: 10)
        let cuts = FlexibleFlatPrism.memberCuts(st, cut)
        let tris = F.faceTris(m, st)
        for k in 0..<3 {
            XCTAssertEqual(try XCTUnwrap(FlexibleFlatPrism.reach(st, member: k, cut)), 10 * 3.0.squareRoot(), accuracy: 1e-9, "★ legs 10√3")
            XCTAssertEqual(F.area(tris[k], cuts[k]), 150, accuracy: 1e-9 * 150, "★ member \(k): a 150 mm² right triangle")
        }
        let mesh = try XCTUnwrap(p.viewerMesh)
        let id = UUID()
        for k in st.members.indices { st.members[k].root = -1 }
        let flat = FlexibleSectors.resolve(mesh: mesh, faceRegions: p.faceRegions, includes: [], strips: [(id: id, strip: st)],
                                           cuts: [id: cut], newPicks: [id], numbers: FlexibleSectorNumbers())
        let rests = flat.pieces.filter { $0.kind == .rest }.map(\.key)
        print("FLEX-E1-G5 corner rests: \(rests)")
        XCTAssertEqual(rests.count, 3, "★ one rest piece per face")
        XCTAssertTrue(rests.allSatisfy { $0.hasSuffix(":1") }, "★ only rest:…:1 keys")
        // ★ RED CONTROL: the old w × w patch (M2's form, width 10)
        var legacy = st
        legacy.widthMM = 10
        let old = FlexibleSectors.resolve(mesh: mesh, faceRegions: p.faceRegions, includes: [], strips: [(id: id, strip: legacy)],
                                          newPicks: [id], numbers: FlexibleSectorNumbers())
        XCTAssertTrue(old.pieces.contains { $0.kind == .rest && $0.key.hasSuffix(":2") }, "★ RED CONTROL: the patch leaves an L in two pieces")
    }

    // MARK: - inside edges

    /// A synthetic L (its inside edge where the notch's two walls meet): greyed "An inside edge · no flat prism". RED (no
    /// convexity rule): offered, and its flat cut keeps the whole face.
    func testInsideEdgesAreGreyed() async throws {
        let tris = FlexibleR7E1FollowUpTests.lTriangles()
        let path = try FlexiblePressFixtures.write("l_notch.stl", FlexiblePressFixtures.asciiSTL("l_notch", tris))
        let p = try FlexiblePressFixtures.project(path: path, name: "L notch")
        let m = try await FlexibleAngledGoldens.openModel(self, p, "L notch")
        try await FlexibleSquishFixture.settle(m, "L notch")
        let mesh = try XCTUnwrap(p.viewerMesh)
        func on(_ f: Int, _ test: (SIMD3<Double>) -> Bool) -> Bool {
            FlexibleEdgeStrips.triangles(face: f, mesh: mesh).allSatisfy { $0.allSatisfy(test) }
        }
        let faces = Set((0..<mesh.faceIDs.count).map { Int(mesh.faceIDs[$0]) })
        let wallX = try XCTUnwrap(faces.first { f in on(f) { Swift.abs($0.x - 20) < 1e-6 && $0.y >= 20 - 1e-6 } }, "the notch wall x = 20")
        let wallY = try XCTUnwrap(faces.first { f in on(f) { Swift.abs($0.y - 20) < 1e-6 && $0.x >= 20 - 1e-6 } }, "the notch wall y = 20")
        let pick = try await F.M2.pickMode(m)
        let c = try XCTUnwrap(F.M2.edge(m, pick, faces: [wallX, wallY]), "the inside edge")
        print("FLEX-E1-G6 the inside edge \(FlexibleRowCopy.candidateLabel(c)): \(pick.greyed[c.number] ?? "offered")")
        XCTAssertEqual(pick.greyed[c.number], "An inside edge \u{00B7} no flat prism", "★ greyed with its line")
        // ★ RED CONTROL: no convexity rule — offered, and the cut swallows the whole face
        m.cancelEdgePick()
        FlexibleFlatPrism.controlNoConvexity = true
        let pick2 = try await F.M2.pickMode(m)
        let c2 = try XCTUnwrap(F.M2.edge(m, pick2, faces: [wallX, wallY]))
        let st = try XCTUnwrap(pick2.strips[c2.number], "★ RED CONTROL: offered")
        let loads2 = try await m.pressAim(c2.members).memberLoads
        let d0 = try XCTUnwrap(st.halfway ?? FlexiblePressAim.halfway(loads2))
        let cut = FlexibleFlatPrism.cut(st, direction: d0, depthMM: 3)
        let ft = F.faceTris(m, st)
        let whole = F.area(ft[0], []), kept = F.area(ft[0], [try XCTUnwrap(FlexibleFlatPrism.memberCuts(st, cut)[0].first)])
        XCTAssertEqual(kept, whole, accuracy: 1e-6, "★ RED CONTROL: the half-space keeps the whole face")
    }

    // MARK: - the wedge, true size

    /// The wedge's every offset vertex lies on P, the rim's base is its offset, and its depth is h — even when the page's k is 7.
    /// RED: drawn × k.
    func testTheWedgeIsTrueSizeAndEndsOnThePlane() async throws {
        let (_, m) = try await F.cube(self)
        let pick = try await F.M2.pickMode(m)
        let press = try await F.commit(m, try XCTUnwrap(F.anyEdge(pick)))
        m.selectedPress = press.id
        let cut = try XCTUnwrap(FlexibleFlatPrism.cut(of: try XCTUnwrap(m.press(press.id))))
        let items = FlexibleFlatPrismRender.items(model: m, k: 7)
        let item = try XCTUnwrap(items.first, "★ the selected press's wedge")
        guard case .shell(let sh) = item.volume.shape else { return XCTFail("a shell") }
        var rim = 0
        for i in sh.offset.indices {
            XCTAssertEqual(cut.height(SIMD3<Double>(sh.offset[i])), cut.depthMM, accuracy: 1e-4, "★ the offset lies on the plane")
            if Swift.abs(cut.height(SIMD3<Double>(sh.base[i])) - cut.depthMM) < 1e-4 {
                rim += 1
                XCTAssertLessThan(simd_distance(sh.base[i], sh.offset[i]), 1e-4, "★ the rim is its own offset")
            }
        }
        XCTAssertGreaterThan(rim, 0)
        XCTAssertEqual(sh.reachedDepthMM, cut.depthMM, accuracy: 1e-4, "★ true size: h, whatever the page's k")
        // ★ RED CONTROL: drawn × k
        FlexibleFlatPrismRender.controlTimesK = true
        defer { FlexibleFlatPrismRender.controlTimesK = false }
        guard case .shell(let k7) = try XCTUnwrap(FlexibleFlatPrismRender.items(model: m, k: 7).first).volume.shape else { return XCTFail() }
        XCTAssertEqual(k7.reachedDepthMM, 7 * cut.depthMM, accuracy: 1e-3, "★ RED CONTROL: the shell drawn × k")
    }

    // MARK: - the angles

    /// compose(0,0) IS strip.halfway IS loadEdgePick's pressAim(whole members).defaultRelease, bit for bit; any (θ, φ) round-trips;
    /// each angle snaps to exactly 0 within 3° (2.9 → 0, 3.1 stays; (8, 3.5) stays; (2, 20) → (0, 20)). RED: AP3's 12° snap turns
    /// (8°, 3.5°) into the halfway.
    func testAnglesRoundTripAndSnapExactly() async throws {
        let (_, m) = try await F.hisPad(self)
        let (_, c, st) = try await F.edge16(m)
        let d0 = try XCTUnwrap(st.halfway, "★ the halfway is stored on the area at pick time")
        let aim = try await m.pressAim(c.members)
        XCTAssertEqual(F.bits(d0), F.bits(try XCTUnwrap(aim.defaultRelease).direction), "★ core's halfway over the WHOLE member faces")
        let f = try XCTUnwrap(A.frame(st, d0: d0, up: try XCTUnwrap(m.sceneInfo?.buildDir)))
        XCTAssertEqual(F.bits(A.compose(f, theta: 0, phi: 0)), F.bits(d0), "★ (0°, 0°) is the halfway, bit for bit")
        XCTAssertEqual(A.decompose(f, d0).theta, 0); XCTAssertEqual(A.decompose(f, d0).phi, 0)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let t = Double.random(in: -40...40, using: &rng), p = Double.random(in: -30...30, using: &rng)
            let back = A.decompose(f, A.compose(f, theta: t, phi: p))
            XCTAssertEqual(back.theta, t, accuracy: 1e-10); XCTAssertEqual(back.phi, p, accuracy: 1e-10)
        }
        XCTAssertEqual(A.snapped(2.9), 0); XCTAssertEqual(A.snapped(-2.9), 0)
        XCTAssertEqual(A.snapped(3.1), 3.1)
        XCTAssertEqual(A.snapped(8), 8); XCTAssertEqual(A.snapped(3.5), 3.5)
        XCTAssertEqual(A.snapped(2), 0); XCTAssertEqual(A.snapped(20), 20)
        XCTAssertEqual(F.bits(A.compose(f, theta: A.snapped(2.9), phi: A.snapped(-1))), F.bits(d0), "★ snapped back: the halfway exactly")
        // ★ RED CONTROL: AP3's 12° snap swallows (8°, 3.5°)
        let halfway = FlexiblePressAim.Target(kind: .halfway, direction: d0)
        XCTAssertNotNil(FlexiblePressAim.snapped(A.compose(f, theta: 8, phi: 3.5), targets: [halfway]), "★ RED CONTROL: 12° takes it back to halfway")
    }

    // MARK: - the limits

    /// Edge 16 at h = 15·sin 45°: θ toward Face 3 stops where Face 3 keeps 0.5 mm of itself (his rule: the half-face rule
    /// dropped) — acos(h / (W − 0.5)) − 45° — "Stops here · Face 3 keeps the rest"; with L3 lifted, at 44.0° from core's
    /// per-triangle normals ("… Face 2 would be edge-on"); φ stops at asin(h / 20) ("… the far end reaches 0 mm"); a corner needs
    /// all three edges crossed. Every line ≤ 44 and names the face. RED: FlexiblePressAim.clamp alone lets Face 3 lose all of
    /// itself.
    func testTheLimitsStopAndSayWhy() async throws {
        let (_, m) = try await F.hisPad(self)
        let (_, c, st) = try await F.edge16(m)
        let aim = try await m.pressAim(c.members)
        let d0 = try XCTUnwrap(st.halfway)
        let f = try XCTUnwrap(A.frame(st, d0: d0, up: try XCTUnwrap(m.sceneInfo?.buildDir)))
        let h = 15 * sin(Double.pi / 4)
        let W = 2 * st.members[0].capMM   // Face 3 across the edge
        let limits = A.Limits(loads: aim.footprintNormals, keepsRest: F.keepsRest(m, st))
        let name: (Int) -> String = { "Face \(st.members[$0].face)" }
        let t = A.limit(st, frame: f, h: h, at: (0, 0), tilt: true, sign: 1, limits: limits)
        let want = acos(h / (W - FlexibleFlatPrism.restMarginMM)) * 180 / .pi - 45
        print("FLEX-E1-L θ+ stops at \(t.deg)° (want \(want)) · \(t.stop.map { A.line($0, strip: st, name: name) } ?? "-")")
        XCTAssertEqual(t.deg, want, accuracy: 0.05, "★ θ stops where Face 3 keeps some of itself")
        XCTAssertEqual(t.stop, .rest(0))
        XCTAssertEqual(A.line(try XCTUnwrap(t.stop), strip: st, name: name), "Stops here \u{00B7} Face \(st.members[0].face) keeps the rest")
        let noL3 = A.Limits(loads: aim.footprintNormals)
        let t2 = A.limit(st, frame: f, h: h, at: (0, 0), tilt: true, sign: 1, limits: noL3)
        print("FLEX-E1-L θ+ with L3 lifted: \(t2.deg)° · \(t2.stop.map { A.line($0, strip: st, name: name) } ?? "-")")
        XCTAssertEqual(t2.deg, 44.0, accuracy: 0.05, "★ 1° short of edge-on, from core's per-triangle normals")
        XCTAssertEqual(A.line(try XCTUnwrap(t2.stop), strip: st, name: name), "Stops here \u{00B7} Face \(st.members[1].face) would be edge-on")
        let p = A.limit(st, frame: f, h: h, at: (0, 0), tilt: false, sign: 1, limits: limits)
        print("FLEX-E1-L φ+ stops at \(p.deg)° (asin(h/20) \(asin(h / 20) * 180 / .pi)) · \(p.stop.map { A.line($0, strip: st, name: name) } ?? "-")")
        XCTAssertEqual(p.deg, asin(h / 20) * 180 / .pi, accuracy: 0.05, "★ the twist stops when the shallow end reaches 0 mm")
        XCTAssertEqual(A.line(try XCTUnwrap(p.stop), strip: st, name: name), "Stops here \u{00B7} the far end reaches 0 mm")
        for s in [t.stop, t2.stop, p.stop].compactMap({ $0 }) {
            XCTAssertLessThanOrEqual(A.line(s, strip: st, name: name).count, 44, "one line")
        }
        XCTAssertEqual(A.heldLine(32.8, unit: "\u{00B0}", stop: .rest(1), strip: st, name: name), "Held at 32.8\u{00B0} \u{00B7} Face \(st.members[1].face) keeps the rest")
        // ★ RED CONTROL: AP3's clamp alone (1° short of edge-on) lets Face 3 lose all of itself
        let ap3 = FlexiblePressAim.clamp(A.compose(f, theta: 60, phi: 0), from: d0, loads: aim.footprintNormals)
        XCTAssertNotNil(F.keepsRest(m, st)(ap3, h), "★ RED CONTROL: FlexiblePressAim.clamp alone leaves a face with no rest")
    }

    /// A corner needs all three edges crossed (dot(e_j, d) ≥ sin 1°): "The flat prism must cross all 3 faces".
    func testACornerNeedsAllThreeEdgesCrossed() async throws {
        let (_, m) = try await F.cube(self)
        let pick = try await F.M2.pickMode(m)
        let st = try XCTUnwrap(pick.strips[try XCTUnwrap(F.corner(m, pick)).number])
        let es = FlexibleFlatPrism.cornerEdges(st)
        XCTAssertEqual(es.count, 3, "a corner's three edges")
        guard es.count == 3 else { return }
        let along = FlexiblePressAim.unit(es[0] + es[1])!   // in the plane of two edges: ⟂-ish to the third
        let bad = FlexiblePressAim.unit(along - 0.2 * es[2])!
        let stop = A.check(st, d: bad, h: 5, limits: A.Limits(loads: []))
        XCTAssertEqual(stop, .cross(-1))
        XCTAssertEqual(A.line(try XCTUnwrap(stop), strip: st, name: { "Face \($0)" }), "The flat prism must cross all 3 faces")
        XCTAssertNil(A.check(st, d: try XCTUnwrap(st.halfway), h: 5, limits: A.Limits(loads: [])), "the halfway crosses all three")
    }
}
