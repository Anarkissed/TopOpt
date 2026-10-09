// FlexibleMeetTests — which faces meet (task 2026-10-07, angled presses, batch AP2; final spec §5 "FlexibleMeet",
// §6 "Core's inward normals"; round 6 item 2's candidates, r6 spec §3 "Candidates"). The batch's seven spec tests
// plus the candidates' (every edge and corner of the part, numbered stably, the 15° tangent rule) and the guard's.
//
// Every RED control the spec names is run INSIDE its test against the instrument it names (FaceTopology's
// index-keyed adjacency, core's face-level touches, a fixed-mm handle, ViewerMesh.faceNormal, the footprint's
// area centroid, the candidates without the 15° rule, the triangle-order numbering), so a green run also shows
// each check can fail. The tests-first commit's red run is recorded beside the evidence (ap2_red_runs.txt).
//
// STEP parts (core's cube, his l bracket, the M2 stand) need OCCT: a part the importer refuses is a COUNTED skip
// ("FLEX-AP SKIP …" printed, and the test's own tally printed), never a silent pass.
import XCTest
import CoreGraphics
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleMeetTests: XCTestCase {
    typealias G = FlexibleAngledGoldens
    typealias Pair = FlexibleMeet.Pair

    // MARK: - fixtures

    /// A part's model with its scene open (no presses), and a label.
    @MainActor
    struct Part {
        let label: String
        let m: FlexibleStageModel
        var meet: FlexibleMeet { m.meet! }
    }

    /// The parts every whole-part check runs on. STEP parts the importer refuses are counted in `skips`.
    func parts(_ test: String, skips: inout [String], include: Set<String>? = nil) async throws -> [Part] {
        var out: [Part] = []
        func want(_ l: String) -> Bool { include?.contains(l) ?? true }
        func add(_ label: String, _ make: () throws -> ProjectModel) async throws {
            guard want(label) else { return }
            do {
                let pm = try make()
                out.append(Part(label: label, m: try await G.openModel(self, pm, label)))
            } catch let s as XCTSkip {
                skips.append("\(label): \(s.message ?? "skipped")")
            }
        }
        try await add("cube60") { try FlexiblePressFixtures.cube60Project() }
        try await add("C1 pad") { try FlexiblePressFixtures.padProject() }
        if want("A1_0003") {
            let r = try FlexiblePressFixtures.a1Project(3, self)
            out.append(Part(label: "A1_0003", m: try await G.openModel(self, r.project, "A1_0003")))
        }
        if want("his r5") {
            let r = try FlexiblePressFixtures.hisRound5(self)
            out.append(Part(label: "his r5", m: try await G.openModel(self, r.project, "his r5")))
        }
        try await add("STEP cube") { try FlexiblePressFixtures.stepCubeProject(test) }
        try await add("l bracket") { try FlexiblePressFixtures.lBracketProject(test) }
        try await add("M2 stand") { try FlexiblePressFixtures.m2Project(test) }
        return out
    }

    func printSkips(_ test: String, _ skips: [String]) {
        print("FLEX-AP2 \(test): STEP skips \(skips.count)" + (skips.isEmpty ? "" : " — " + skips.joined(separator: "; ")))
    }

    /// The pad's faces by position: top (z = 20), x = 100, y = 0, x = 0, y = 100, bottom.
    static func padFaces(_ mesh: ViewerMesh) -> (top: Int, x100: Int, y0: Int, x0: Int, y100: Int, bottom: Int) {
        (FlexibleSquishFixture.face(mesh, axis: 2, value: 20), FlexibleSquishFixture.face(mesh, axis: 0, value: 100),
         FlexibleSquishFixture.face(mesh, axis: 1, value: 0), FlexibleSquishFixture.face(mesh, axis: 0, value: 0),
         FlexibleSquishFixture.face(mesh, axis: 1, value: 100), FlexibleSquishFixture.face(mesh, axis: 2, value: 0))
    }

    static func bits(_ v: SIMD3<Double>) -> [UInt64] { [v.x.bitPattern, v.y.bitPattern, v.z.bitPattern] }

    /// Distance from `p` to triangle (a, b, c) (Ericson's closest point).
    static func distance(_ p: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> Double {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return simd_distance(p, a) }
        let bp = p - b, d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return simd_distance(p, b) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { return simd_distance(p, a + ab * (d1 / (d1 - d3))) }
        let cp = p - c, d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return simd_distance(p, c) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { return simd_distance(p, a + ac * (d2 / (d2 - d6))) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 { return simd_distance(p, b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))) }
        let den = 1 / (va + vb + vc)
        return simd_distance(p, a + ab * (vb * den) + ac * (vc * den))
    }

    /// The smallest distance from `p` to a triangle of the regions' faces (inside the region's cuts).
    static func distanceToMembers(_ p: SIMD3<Double>, _ regions: [Int], _ meet: FlexibleMeet) -> Double {
        var best = Double.infinity
        for r in regions {
            for t in meet.memberTriangles(r) {
                let (a, b, c) = meet.triangle(t)
                best = min(best, distance(p, a, b, c))
            }
        }
        return best
    }

    // MARK: - (1) core and the app agree which faces touch

    /// ★ SPEC AP2-1. The app's position-keyed shared-edge map (1e-4 mm, over the viewer mesh) gives exactly core's
    /// face_adjacency pairs on the cube STL, C1's pad, his A1_0003 and r5, core's STEP cube, his l bracket and the
    /// M2 stand. RED (run here): FaceTopology.adjacency, keyed by vertex INDEX, finds 0 pairs on the per-face-vertex
    /// box (FlexibleLatticeFixtures.boxMesh), where the position-keyed map finds its 12.
    func testCoreAndAppAgreeWhichFacesTouch() async throws {
        var skips: [String] = []
        let ps = try await parts("FlexibleMeetTests.testCoreAndAppAgreeWhichFacesTouch", skips: &skips)
        XCTAssertGreaterThanOrEqual(ps.count, 4, "the STL parts always run")
        for p in ps {
            let core = FlexibleMeet.pairs(coreAdjacency: try await p.m.coreAdjacency())
            let app = p.meet.facePairs
            print("FLEX-AP2 ADJ \(p.label): app \(app.count) pairs, core \(core.count) pairs, faces \(p.meet.faceCount)"
                  + (app == core ? " · equal" : " · app-only \(app.subtracting(core).sorted()) core-only \(core.subtracting(app).sorted())"))
            XCTAssertEqual(app, core, "\(p.label): the app's shared-edge map is core's face_adjacency")
            XCTAssertFalse(core.isEmpty, "\(p.label): the part has touching faces")
        }
        printSkips("ADJ", skips)

        // ★ RED CONTROL: the index-keyed map is blind on a per-face-vertex mesh
        let box = FlexibleLatticeFixtures.boxMesh(subdiv: 1).mesh
        let byIndex = FaceTopology.adjacency(in: box).values.reduce(0) { $0 + $1.count } / 2
        let byPosition = FlexibleMeet(mesh: box, regions: FlexibleRegions(model: FaceRegionModel(), mesh: box)).facePairs
        print("FLEX-AP2 ADJ control: per-face-vertex box — FaceTopology.adjacency \(byIndex) pairs, position-keyed \(byPosition.count)")
        XCTAssertEqual(byIndex, 0, "control: the index-keyed map finds nothing on a per-face-vertex mesh")
        XCTAssertEqual(byPosition.count, 12, "the position-keyed map finds the box's 12 edges")
    }

    // MARK: - (2) sectors touch only where their cuts reach the edge

    /// ★ SPEC AP2-2. On his r5 (the top split at x = 50 into Top A, x ≥ 50, and Top B): Top A and face 3 (x = 100)
    /// touch along 100 mm; Top B and face 3 do not; Top A and Top B meet along their cut (100 mm across the top);
    /// Top A and Top B each touch face 2 (y = 0) along 50 mm. RED (run here): core's face-level adjacency says
    /// the top face touches face 3, so a face-level test would say Top B touches it.
    func testSectorsTouchOnlyWhereTheirCutsReachTheEdge() async throws {
        let r = try FlexiblePressFixtures.hisRound5(self)
        let m = try await G.openModel(self, r.project, "his r5")
        let meet = try XCTUnwrap(m.meet)
        let mesh = try XCTUnwrap(r.project.viewerMesh)
        let f = Self.padFaces(mesh)
        let topA = FlexibleHisProject.topA, topB = FlexibleHisProject.topB
        XCTAssertEqual(f.x100, 3, "premise: face 3 is x = 100")
        XCTAssertEqual(f.y0, 2, "premise: face 2 is y = 0")
        func len(_ a: Int, _ b: Int) -> Double { meet.seam(a, b)?.length ?? 0 }
        print(String(format: "FLEX-AP2 SECTORS his r5: A–3 %.4f mm · B–3 %.4f mm · A–B %.4f mm (%@) · A–2 %.4f · B–2 %.4f · pieces %@",
                     len(topA, 3), len(topB, 3), len(topA, topB), meet.seam(topA, topB).map { "\($0.kind)" } ?? "none",
                     len(topA, 2), len(topB, 2), "\(meet.pieces.map(\.id))"))
        XCTAssertTrue(meet.touches(topA, 3), "Top A reaches the x = 100 edge")
        XCTAssertEqual(len(topA, 3), 100, accuracy: 1e-3)
        XCTAssertFalse(meet.touches(topB, 3), "Top B stops at x = 50: it never reaches face 3")
        XCTAssertTrue(meet.touches(topA, topB), "the two sectors meet along their cut")
        XCTAssertEqual(meet.seam(topA, topB)?.kind, .cut)
        XCTAssertEqual(len(topA, topB), 100, accuracy: 1e-3, "the cut runs across the top")
        XCTAssertEqual(len(topA, 2), 50, accuracy: 1e-3)
        XCTAssertEqual(len(topB, 2), 50, accuracy: 1e-3)
        XCTAssertFalse(meet.pieces.contains { $0.id == f.top }, "the split top is its two sectors, not the whole face")
        XCTAssertEqual(meet.uncovered, [:], "Top A and Top B cover the top")
        XCTAssertTrue(meet.connected([topA, 3, 2]))
        XCTAssertFalse(meet.connected([topB, 3]))

        // ★ RED CONTROL: core's adjacency is face-level — the top touches face 3, so Top B would
        let core = try await m.coreAdjacency()
        XCTAssertTrue(core[f.top].contains(3), "control: at face level the top (and so Top B) touches face 3")
    }

    // MARK: - (3) the corners of a box

    /// ★ SPEC AP2-3. The cube and the pad each have 8 corners where three regions meet; on his r5 the corner at
    /// (100, 0, 20) is {Top A, 3, 2}. The cut's ends on the top's edges ((50, 0, 20), (50, 100, 20)) are where
    /// three REGIONS meet but only two sides do (Top A and Top B are one face): geometric meeting points, never a
    /// corner candidate — r5 still has 8. RED (run here): counting every point where 3+ regions meet gives 10.
    func testCornersOfABox() async throws {
        var skips: [String] = []
        let ps = try await parts("FlexibleMeetTests.testCornersOfABox", skips: &skips, include: ["cube60", "C1 pad", "his r5"])
        for p in ps {
            let c = try await p.m.edgeCandidates()
            print("FLEX-AP2 CORNERS \(p.label): meeting points \(p.meet.corners.count) · corner candidates \(c.corners.count): "
                  + c.corners.map { "#\($0.number) \($0.members) (\(String(format: "%.1f %.1f %.1f", $0.point.x, $0.point.y, $0.point.z)))" }.joined(separator: " "))
            XCTAssertEqual(c.corners.count, 8, "\(p.label): a box has 8 corners")
            XCTAssertTrue(c.corners.allSatisfy { $0.members.count == 3 }, "\(p.label): three regions at each")
            if p.label == "his r5" {
                let at = try XCTUnwrap(c.corners.first { simd_distance($0.point, SIMD3(100, 0, 20)) < 1e-3 }, "the corner at (100, 0, 20)")
                XCTAssertEqual(Set(at.members), [FlexibleHisProject.topA, 3, 2])
                // ★ RED CONTROL: every point where 3+ regions meet, without the sides rule
                XCTAssertEqual(p.meet.corners.count, 10, "control: 3+ regions also meet at the cut's two ends")
                XCTAssertTrue(p.meet.corners.contains { simd_distance($0.point, SIMD3(50, 0, 20)) < 1e-3 })
            } else {
                XCTAssertEqual(p.meet.corners.count, 8)
            }
        }
    }

    // MARK: - (4) handles are sized in points

    /// ★ SPEC AP2-4. Every handle's target (corner dots, edge pills) is at least 44 × 44 pt at every zoom, through
    /// the page's CameraProjection. RED (run here): a fixed 4 mm target is under 10 pt zoomed out.
    func testHandlesAreSizedInPoints() throws {
        let pm = try FlexiblePressFixtures.cube60Project()
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let meet = FlexibleMeet(mesh: mesh, regions: FlexibleRegions(model: pm.faceRegions, mesh: mesh))
        var spots: [FlexibleMeet.Spot] = meet.corners.enumerated().map { .init(id: $0.offset + 1, kind: .corner, point: $0.element.point) }
        for (k, s) in meet.seams.values.sorted(by: { $0.pair < $1.pair }).enumerated() {
            if let mid = FlexibleMeet.midpoint(s.polylines) { spots.append(.init(id: 100 + k, kind: .edge, point: mid)) }
        }
        XCTAssertEqual(spots.count, 20, "8 corner dots and 12 edge pills")
        let viewport = CGSize(width: 1180, height: 820)
        var smallestMM = CGFloat.infinity
        for distance: Float in [90, 250, 800, 3000, 9000] {
            var cam = OrbitCamera(target: SIMD3(30, 30, 30), distance: distance)
            cam.maxDistance = 20_000
            let proj = CameraProjection(camera: cam, viewportSize: viewport)
            let hs = FlexibleMeet.handles(spots, projection: proj)
            XCTAssertEqual(hs.count, spots.count, "every handle is in front of the camera at \(distance) mm")
            for h in hs {
                XCTAssertGreaterThanOrEqual(h.target.width, 44, "\(h.kind) \(h.id) at \(distance) mm")
                XCTAssertGreaterThanOrEqual(h.target.height, 44, "\(h.kind) \(h.id) at \(distance) mm")
                XCTAssertTrue(h.target.contains(h.centre))
            }
            // ★ RED CONTROL: a 4 mm target, projected
            for s in spots {
                guard let c = proj.project(SIMD3<Float>(s.point)), let e = proj.project(SIMD3<Float>(s.point) + SIMD3(4, 0, 0)),
                      let e2 = proj.project(SIMD3<Float>(s.point) + SIMD3(0, 4, 0)) else { continue }
                smallestMM = min(smallestMM, 2 * max(hypot(e.x - c.x, e.y - c.y), hypot(e2.x - c.x, e2.y - c.y)))
            }
            print(String(format: "FLEX-AP2 HANDLES at %.0f mm: smallest target %.1f pt; a 4 mm target so far %.1f pt",
                         distance, hs.map { min($0.target.width, $0.target.height) }.min() ?? 0, smallestMM))
        }
        XCTAssertLessThan(smallestMM, 10, "control: a fixed-mm target shrinks under 10 pt zoomed out")
    }

    // MARK: - (5) fillet chains and wrapped faces

    /// ★ SPEC AP2-5. On the M2 stand (STEP; a counted skip) the chain of curved regions between two flats is
    /// returned whole, through core's 15° verdict at the seams and core's normal spread: the bottom (face 18) and
    /// the −Y wall (face 2) meet through the r 3 fillet (face 61), and so on for every flat pair a fillet joins
    /// (printed). On the slabs: the one-fillet slab's face 0 (flat + fillet + flat) is flagged by core's
    /// normal_spread_flag; the rounded slab's whole side wall is ONE face whose normals cancel (core frames no
    /// direction for it) — so its fillets give no edge at all (the recorded fact) and no edge or corner of either
    /// face that wraps is offered.
    func testAFilletChainIsFound() async throws {
        // the slabs
        let one = try await G.openModel(self, try FlexiblePressFixtures.oneFilletSlabProject(), "one-fillet slab")
        let oneC = try await one.edgeCandidates()
        let f0 = try await one.regionFrame(0)
        print("FLEX-AP2 WRAP one-fillet slab: face 0 spread \(f0.normalSpreadDeg)° flag \(f0.normalSpreadFlag) · candidates "
              + oneC.candidates.map { "#\($0.number) \($0.kind) \($0.members) \($0.offered ? "offered" : "not offered: \($0.why ?? "")")" }.joined(separator: " | "))
        XCTAssertTrue(f0.normalSpreadFlag, "core flags the flat + fillet + flat face")
        let oneFacts = try await one.meetFacts()
        XCTAssertTrue(try XCTUnwrap(one.meet).wraps(0, facts: oneFacts))
        XCTAssertFalse(oneC.candidates.contains { $0.offered && $0.members.contains(0) }, "nothing of the wrapped face is offered")
        XCTAssertEqual(oneC.edges.filter(\.offered).count, 5, "top–3, top–4, bottom–3, bottom–4, 3–4")
        XCTAssertEqual(oneC.corners.filter(\.offered).count, 2, "the sharp −X−Y corner, top and bottom")

        let rounded = try await G.openModel(self, try FlexiblePressFixtures.roundedSlabProject(), "rounded slab")
        let rc = try await rounded.edgeCandidates()
        let side = try await rounded.regionFrame(0)
        print("FLEX-AP2 WRAP rounded slab: faces \(try XCTUnwrap(rounded.meet).faceCount) · side wall valid \(side.valid) '\(side.reason)' · candidates "
              + rc.candidates.map { "#\($0.number) \($0.kind) \($0.members) \($0.offered ? "offered" : "not offered: \($0.why ?? "")")" }.joined(separator: " | "))
        XCTAssertEqual(try XCTUnwrap(rounded.meet).faceCount, 3, "the fillets are inside one face: top, bottom, the side wall")
        XCTAssertFalse(side.valid, "core frames no direction for a wall whose normals cancel")
        let roundedFacts = try await rounded.meetFacts()
        XCTAssertTrue(try XCTUnwrap(rounded.meet).wraps(0, facts: roundedFacts))
        XCTAssertEqual(rc.edges.filter(\.offered).count, 0, "the rounded slab offers no edge")
        XCTAssertEqual(rc.corners.count, 0, "and has no corner")

        // the M2 stand: fillet chains (STEP — a counted skip)
        let m2: FlexibleStageModel
        do {
            m2 = try await G.openModel(self, try FlexiblePressFixtures.m2Project("FlexibleMeetTests.testAFilletChainIsFound"), "M2 stand")
        } catch let s as XCTSkip {
            printSkips("FILLET", [s.message ?? "M2"])
            throw s
        }
        let meet = try XCTUnwrap(m2.meet)
        let facts = try await m2.meetFacts()
        XCTAssertNil(facts.mismatch, "the viewer mesh is core's model, triangle for triangle")
        let chain = meet.blendChain(18, 2, facts: facts)
        print("FLEX-AP2 FILLET M2: blendChain(18, 2) = \(chain.map { "\($0)" } ?? "nil")")
        XCTAssertEqual(chain, [61], "the bottom and the −Y wall meet through the r 3 fillet, whole")
        let c = try await m2.edgeCandidates()
        let blends = c.candidates.filter { $0.kind == .blend }
        print("FLEX-AP2 FILLET M2 blends \(blends.count): " + blends.map { "#\($0.number) \($0.members)" }.joined(separator: " "))
        XCTAssertTrue(blends.contains { $0.members == [18, 61, 2] || $0.members == [2, 61, 18] }, "one candidate for the filleted edge")
        for b in blends {
            let ends = (b.members.first!, b.members.last!)
            XCTAssertEqual(meet.blendChain(ends.0, ends.1, facts: facts), Array(b.members.dropFirst().dropLast()),
                           "\(b.members): the candidate holds its whole chain")
            XCTAssertFalse(c.edges.contains { $0.kind == .edge && Set($0.members) == [ends.0, b.members[1]] },
                           "\(b.members): the tangent seam flat–fillet is not offered as an edge")
        }
        printSkips("FILLET", [])
    }

    // MARK: - (6) region frames are core's stack loads

    /// ★ SPEC AP2-6. regionFrame(r).load == stack(face: r).load bit for bit on every stackable region of C1's pad
    /// (its top split at x = 99.5) and of the one-fillet slab; the 0.5 mm sector, narrower than one pitch, has a
    /// valid frame where core's stack throws "no column". RED (run here): ViewerMesh.faceNormal (Float) differs in
    /// bits from core's load on the slab's slanted face.
    func testRegionFramesAreCoresStackLoads() async throws {
        let pm = try FlexiblePressFixtures.padProject()
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let top = FlexibleHisProject.topFace(mesh)
        var fr = pm.faceRegions
        let topID = fr.union(faces: [FaceID(top)], named: "top")
        let halves = fr.splitManual(topID, point: SIMD3(99.5, 0, 20), normal: SIMD3(1, 0, 0))
        XCTAssertEqual(halves.count, 2)
        pm.faceRegions = fr
        let narrow = FlexibleRegions.wireID(try XCTUnwrap(fr.region(halves[0])))
        var narrowSeen = false, compared = 0
        let splitPad = try await G.openModel(self, pm, "the split pad")
        let slabModel = try await G.openModel(self, try FlexiblePressFixtures.oneFilletSlabProject(), "one-fillet slab")
        for (label, model) in [("C1 pad split at 99.5", splitPad), ("one-fillet slab", slabModel)] {
            let info = try XCTUnwrap(model.sceneInfo)
            let sceneRef = await model.workerForTests.sceneRef()
            let scene = try XCTUnwrap(sceneRef)
            for r in info.regions {
                let frame = try await model.regionFrame(r.id)
                do {
                    let st = try scene.stack(face: r.id, rotation: 0)
                    XCTAssertEqual(Self.bits(frame.load), Self.bits(st.load), "\(label) region \(r.id): core's load, bit for bit")
                    XCTAssertEqual(Self.bits(frame.centroid), Self.bits(st.centroid), "\(label) region \(r.id): centroid")
                    XCTAssertEqual(frame.normalSpreadDeg.bitPattern, st.normalSpreadDeg.bitPattern)
                    XCTAssertEqual(frame.side, st.side)
                    XCTAssertEqual(frame.buildAngleDeg.bitPattern, st.buildAngleDeg.bitPattern)
                    compared += 1
                } catch {
                    print("FLEX-AP2 FRAMES \(label) region \(r.id): stack refused — \(error) · frame valid \(frame.valid)")
                    if "\(error)".contains("no column") {
                        XCTAssertTrue(frame.valid, "\(label) region \(r.id): framed without a column")
                        if r.id == narrow { narrowSeen = true }
                    } else {
                        XCTAssertFalse(frame.valid, "\(label) region \(r.id): a stack core refuses for its frame has no frame either")
                    }
                }
            }
        }
        print("FLEX-AP2 FRAMES compared \(compared) stack loads bit for bit; narrow sector framed \(narrowSeen)")
        XCTAssertGreaterThanOrEqual(compared, 10)
        XCTAssertTrue(narrowSeen, "the 0.5 mm sector: no column, still a frame")

        // ★ RED CONTROL: the viewer's Float normal is not core's load
        let slab = try FlexiblePressFixtures.oneFilletSlabProject()
        let sm = try await G.openModel(self, slab, "one-fillet slab (control)")
        let smRef = await sm.workerForTests.sceneRef()
        let scene = try XCTUnwrap(smRef)
        let st = try scene.stack(face: 0, rotation: 0)
        let viewer = try XCTUnwrap(try XCTUnwrap(slab.viewerMesh).faceNormal(0))
        let viewerLoad = -SIMD3<Double>(Double(viewer.x), Double(viewer.y), Double(viewer.z))
        print("FLEX-AP2 FRAMES control: core \(Self.bits(st.load)) viewer \(Self.bits(viewerLoad))")
        XCTAssertNotEqual(Self.bits(viewerLoad), Self.bits(st.load), "control: the viewer's Float normal differs in bits")
    }

    // MARK: - (7) the anchor sits on the faces

    /// ★ SPEC AP2-7. For an edge, a corner and a tilt — on the cube and on his r5's sectors — the anchor lies on a
    /// member triangle (under 1e-6 mm). RED (run here): the corner footprint's area centroid lies more than 1 mm
    /// inside the part.
    func testTheAnchorSitsOnTheFaces() async throws {
        let cube = try FlexiblePressFixtures.cube60Project()
        let cmesh = try XCTUnwrap(cube.viewerMesh)
        let cm = FlexibleMeet(mesh: cmesh, regions: FlexibleRegions(model: cube.faceRegions, mesh: cmesh))
        let top = FlexibleSquishFixture.face(cmesh, axis: 2, value: 60), x = FlexibleSquishFixture.face(cmesh, axis: 0, value: 60)
        let y = FlexibleSquishFixture.face(cmesh, axis: 1, value: 60)
        let r = try FlexiblePressFixtures.hisRound5(self)
        let rmesh = try XCTUnwrap(r.project.viewerMesh)
        let rm = FlexibleMeet(mesh: rmesh, regions: FlexibleRegions(model: r.project.faceRegions, mesh: rmesh))
        let topA = FlexibleHisProject.topA, topB = FlexibleHisProject.topB
        let cases: [(String, FlexibleMeet, [Int], SIMD3<Double>)] = [
            ("cube edge", cm, [top, x], simd_normalize(SIMD3(-1, 0, -1))),
            ("cube corner", cm, [top, x, y], simd_normalize(SIMD3(-1, -1, -1))),
            ("cube tilt", cm, [top], simd_normalize(SIMD3(0.3, -0.2, -1))),
            ("r5 edge", rm, [topA, 3], simd_normalize(SIMD3(-1, 0, -1))),
            ("r5 corner", rm, [topA, 3, 2], simd_normalize(SIMD3(-1, 1, -1))),
            ("r5 tilt of Top B", rm, [topB], simd_normalize(SIMD3(0.2, 0.1, -1))),
        ]
        for (label, meet, regions, d) in cases {
            let a = try XCTUnwrap(meet.anchor(regions: regions, direction: d), label)
            let dist = Self.distanceToMembers(a, regions, meet)
            print(String(format: "FLEX-AP2 ANCHOR %@ %@: (%.4f, %.4f, %.4f) %.3g mm from a member triangle", label, "\(regions)", a.x, a.y, a.z, dist))
            XCTAssertLessThan(dist, 1e-6, "\(label): on the faces")
        }
        // the tilt of Top B lands inside Top B (x < 50)
        let tb = try XCTUnwrap(rm.anchor(regions: [topB], direction: simd_normalize(SIMD3(0.2, 0.1, -1))))
        XCTAssertLessThan(tb.x, 50, "the ray lands on Top B, not on Top A")

        // ★ RED CONTROL: the corner footprint's area centroid is inside the part
        let corner = [top, x, y]
        var sum = SIMD3<Double>.zero, area = 0.0
        for rg in corner {
            for t in cm.memberTriangles(rg) {
                let (a, b, c) = cm.triangle(t)
                let w = simd_length(simd_cross(b - a, c - a)) / 2
                sum += (a + b + c) / 3 * w
                area += w
            }
        }
        let centroid = sum / area
        let off = Self.distanceToMembers(centroid, corner, cm)
        print(String(format: "FLEX-AP2 ANCHOR control: the corner footprint's area centroid is %.3f mm off its faces", off))
        XCTAssertGreaterThan(off, 1, "control: an area centroid is not on the faces")
    }

    // MARK: - (8) every edge and corner, the 15° rule

    /// ★ R6 ITEM 2 / AP2. Every edge and corner of the part, from core's adjacency and core's 15° verdict at each
    /// seam: the cube STL and core's STEP cube 12 edges and 8 corners; his A1_0003 (the pad) 12 and 8; his r5 (its
    /// top split) 14 and 8 — the cut between Top A and Top B is never an edge; his l bracket and the M2 stand are
    /// printed (every count recorded, tangent seams counted). RED (run here): with no 15° rule every tangent seam of
    /// the M2 stand would be offered as an edge.
    func testEveryEdgeAndCornerOfThePartWithTheFifteenDegreeRule() async throws {
        var skips: [String] = []
        let ps = try await parts("FlexibleMeetTests.testEveryEdgeAndCornerOfThePartWithTheFifteenDegreeRule", skips: &skips,
                                 include: ["cube60", "A1_0003", "his r5", "STEP cube", "l bracket", "M2 stand"])
        let expected: [String: (edges: Int, corners: Int)] = ["cube60": (12, 8), "STEP cube": (12, 8), "A1_0003": (12, 8), "his r5": (14, 8)]
        for p in ps {
            let facts = try await p.m.meetFacts()
            XCTAssertNil(facts.mismatch, "\(p.label): the viewer mesh is core's model")
            let c = FlexibleEdgeCandidates.make(meet: p.meet, facts: facts)
            let noRule = FlexibleEdgeCandidates.make(meet: p.meet, facts: facts, creaseCos: 2)
            let smooth = p.meet.seams.values.filter { $0.kind == .edge && !c.creased($0.pair) }.count
            print("FLEX-AP2 EDGES \(p.label): pieces \(p.meet.pieces.count) · seams \(p.meet.seams.count) (tangent \(smooth)) · "
                  + "edges \(c.edges.filter { $0.kind == .edge }.count) blends \(c.edges.filter { $0.kind == .blend }.count) "
                  + "corners \(c.corners.count) · offered \(c.candidates.filter(\.offered).count) · without the 15° rule "
                  + "edges \(noRule.edges.filter { $0.kind == .edge }.count) corners \(noRule.corners.count)")
            if let e = expected[p.label] {
                XCTAssertEqual(c.edges.count, e.edges, "\(p.label): edges")
                XCTAssertEqual(c.corners.count, e.corners, "\(p.label): corners")
                XCTAssertEqual(c.candidates.filter(\.offered).count, e.edges + e.corners, "\(p.label): every one offered")
            }
            if p.label == "his r5" {
                XCTAssertFalse(c.edges.contains { Set($0.members) == [FlexibleHisProject.topA, FlexibleHisProject.topB] },
                               "two sectors of one face are never an edge")
            }
            var whys: [String: Int] = [:]
            for k in c.candidates where !k.offered {
                let w = (k.why ?? "").replacingOccurrences(of: #"face \d+"#, with: "face N", options: .regularExpression)
                whys[w, default: 0] += 1
            }
            if !whys.isEmpty { print("FLEX-AP2 EDGES \(p.label) not offered: " + whys.sorted { $0.key < $1.key }.map { "\($0.value) × '\($0.key)'" }.joined(separator: " · ")) }
            if p.label == "M2 stand" {
                XCTAssertGreaterThan(smooth, 0, "premise: the stand has tangent seams")
                // ★ RED CONTROL: without the rule, the tangent seams are counted as edges
                XCTAssertGreaterThan(noRule.edges.filter { $0.kind == .edge }.count, c.edges.filter { $0.kind == .edge }.count,
                                     "control: no 15° rule offers the tangent seams")
            }
            // every candidate: a number, members that touch, a point on its faces
            XCTAssertEqual(c.candidates.map(\.number), Array(1...max(1, c.candidates.count)).prefix(c.candidates.count).map { $0 })
            for k in c.candidates {
                XCTAssertTrue(p.meet.connected(k.members), "\(p.label) #\(k.number): its members touch")
                XCTAssertLessThan(Self.distanceToMembers(k.point, k.members, p.meet), 1e-6, "\(p.label) #\(k.number): its point is on its faces")
            }
        }
        printSkips("EDGES", skips)
    }

    // MARK: - (9) stable numbers

    /// ★ R6 ITEM 2. Numbers are stable across opens: corners first, then edges, each ordered by position (−z, y, x)
    /// — the same numbers on a second open, and on the same part whose triangles arrive in the opposite order.
    /// RED (run here): numbering in the order the seams are first met in the triangle list changes when the order
    /// of the triangles does.
    func testNumbersAreStableAcrossOpens() async throws {
        let pm = try FlexiblePressFixtures.cube60Project()
        let a = try await G.openModel(self, pm, "cube60 (first open)")
        let b = try await G.openModel(self, try FlexiblePressFixtures.cube60Project(), "cube60 (second open)")
        let ca = try await a.edgeCandidates(), cb = try await b.edgeCandidates()
        func sig(_ c: FlexibleEdgeCandidates) -> [String] {
            c.candidates.map { "#\($0.number) \($0.kind) \($0.members) \(Self.bits($0.point))" }
        }
        XCTAssertEqual(sig(ca), sig(cb), "a second open numbers them the same")
        print("FLEX-AP2 NUMBERS cube60: " + ca.candidates.map { "#\($0.number) \($0.kind) \($0.members)" }.joined(separator: " "))
        // corners first, then edges; each by (−z, y, x)
        let kinds = ca.candidates.map { $0.kind == .corner }
        XCTAssertEqual(kinds, kinds.sorted { $0 && !$1 }, "corners first")
        func key(_ p: SIMD3<Double>) -> [Int64] { [Int64((-p.z * 1e4).rounded()), Int64((p.y * 1e4).rounded()), Int64((p.x * 1e4).rounded())] }
        for group in [ca.corners, ca.edges] {
            let keys = group.map { key($0.point) }
            XCTAssertEqual(keys, keys.sorted { $0.lexicographicallyPrecedes($1) }, "ordered by (−z, y, x)")
        }

        // the same part, its triangles reversed: the same numbers for the same members
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let n = mesh.triangleCount
        var idx: [Int32] = [], fid: [Int32] = []
        for t in (0..<n).reversed() {
            idx += [Int32(mesh.indices[3 * t]), Int32(mesh.indices[3 * t + 1]), Int32(mesh.indices[3 * t + 2])]
            fid.append(mesh.faceIDs[t])
        }
        let reversed = ViewerMesh(vertices: mesh.positions, indices: idx, faceIDs: fid, pseudoFaces: mesh.pseudoFaces)
        let rmeet = FlexibleMeet(mesh: reversed, regions: FlexibleRegions(model: pm.faceRegions, mesh: reversed))
        let facts = try await a.meetFacts()
        var rf = facts
        rf.triangleLoads = Dictionary(uniqueKeysWithValues: facts.triangleLoads.map { (n - 1 - $0.key, $0.value) })
        let cr = FlexibleEdgeCandidates.make(meet: rmeet, facts: rf)
        XCTAssertEqual(cr.candidates.map { "#\($0.number) \($0.kind) \($0.members)" }, ca.candidates.map { "#\($0.number) \($0.kind) \($0.members)" },
                       "the triangle order does not move a number")

        // ★ RED CONTROL: number the edges in the order their seam is first met in the triangle list
        func firstMet(_ meet: FlexibleMeet) -> [[Int]] {
            meet.seams.values.filter { $0.kind == .edge }
                .sorted { ($0.segments.map { min($0.triA, $0.triB) }.min() ?? 0) < ($1.segments.map { min($0.triA, $0.triB) }.min() ?? 0) }
                .map { [$0.pair.a, $0.pair.b] }
        }
        XCTAssertNotEqual(firstMet(a.meet!), firstMet(rmeet), "control: discovery order follows the triangle order")
    }

    // MARK: - (10) the pass-throughs never let core's exception cross

    /// The three pass-throughs run under bridge.cpp's one guard: core's refusal arrives as a thrown error with
    /// core's words (an undeclared region; a zero press direction — core's press_unit throws), and the last refusal
    /// carries them; an index out of range is a value (face −1, no load). Source pin: each body runs through
    /// bridge_guard_run, which bridge.cpp defines on its `guarded`.
    func testThePassThroughsRunUnderTheOneGuard() async throws {
        let m = try await G.openModel(self, try FlexiblePressFixtures.cube60Project(), "cube60")
        let ref = await m.workerForTests.sceneRef()
        let scene = try XCTUnwrap(ref)
        XCTAssertThrowsError(try scene.regionFrame(987_654)) { e in
            print("FLEX-AP2 GUARD undeclared: \(e)")
            XCTAssertTrue("\(e)".contains("not declared"), "core's words")
        }
        XCTAssertNotNil(TopOptKit.lastCoreRefusal)
        XCTAssertThrowsError(try scene.regionFrame(0, direction: SIMD3(0, 0, 0))) { e in
            print("FLEX-AP2 GUARD zero direction: \(e)")
            XCTAssertTrue("\(e)".contains("press_direction"), "core's press_unit refuses a zero direction")
        }
        let ok = try scene.regionFrame(0, direction: SIMD3(0, 0, -3))
        XCTAssertTrue(ok.valid)
        XCTAssertEqual(Self.bits(ok.load), Self.bits(SIMD3(0, 0, -1)), "core normalises the stated direction")
        XCTAssertNil(TopOptKit.lastCoreRefusal, "an answer clears the last refusal")
        let loads = try scene.triangleLoads([0, -1, 1_000_000])
        XCTAssertEqual(loads.faces[1], -1)
        XCTAssertEqual(loads.faces[2], -1)
        XCTAssertNil(loads.loads[1])
        XCTAssertNotNil(loads.loads[0])
        XCTAssertEqual(loads.triangleCount, 12)

        let src = try String(contentsOf: FlexibleHisProject.repoRoot.appendingPathComponent(
            "app/TopOptKit/Sources/TopOptBridge/flexible_bridge.cpp"), encoding: .utf8)
        for fn in ["flexible_scene_face_adjacency", "flexible_scene_region_frame", "flexible_scene_triangle_loads"] {
            XCTAssertTrue(src.contains("bridge_guard_run(\"\(fn)\""), "\(fn) runs under the one guard")
        }
        let bridge = try String(contentsOf: FlexibleHisProject.repoRoot.appendingPathComponent(
            "app/TopOptKit/Sources/TopOptBridge/bridge.cpp"), encoding: .utf8)
        XCTAssertTrue(bridge.contains("std::string bridge_guard_run(const char* where, const std::function<void()>& body) noexcept {\n  return guarded("),
                      "bridge_guard_run is bridge.cpp's guarded")
    }
}
