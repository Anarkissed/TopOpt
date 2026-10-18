// FlexibleEdgeGroupsTests — round 6 item 2 (task 2026-10-08, built as approved: his OK of the design, the reviewer's
// "build it as posted", 2026-10-09 19:41): [+ New] asks [Faces] [Edges/corners]; a squeeze group holds faces OR
// edges/corners, never both; pick mode lists, colours and numbers every edge and corner (core's adjacency, the 15°
// rule) and picks them by the list or by a tap (the nearest corner, then edge; a repeat tap cycles); [Done] cuts each
// pick's STRIP / PATCH on its faces through the Surface tool's own cut in ONE edit and ONE undo step, the face's own
// group KEEPS THE REST (its settings re-expressed through core's frames), where two picks meet the first keeps the
// shared corner (a corner its square), and each pick becomes an AP1 FlexiblePress at AP3's default — core's halfway on
// its strips — saved, NEVER written to a job. The main page's Selections are not touched (two separate lists, his
// 2026-10-10 reversal). Judged on HIS pad (A1_0003, his img1–4) restored as he saved it.
//
// Written BEFORE the code (the after-s1 table, item 2). Every RED CONTROL the table names is run INSIDE its test, so a
// green run also shows each check can fail: colours by number round the palette (touching ones share), the edge-first
// tap and no cycling (a candidate under its corners cannot be picked on the model), whole-face regions (a region in
// two entries — core's refusal), a ViewerMesh-normal halfway (other bits than core's), a mixed group left mixed.
import XCTest
import CoreGraphics
import MetalKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleEdgeGroupsTests: XCTestCase {
    typealias G = FlexibleAngledGoldens
    typealias Candidate = FlexibleEdgeCandidates.Candidate
    typealias Rules = FlexibleEdgePickRules

    // MARK: - fixtures

    /// HIS pad, A1_0003 as he saved it: Group 1 = the top (face 1, linked to the main page's Top), Group 2 = faces 4
    /// and 2, Group 3 = faces 3 and 5, face 0 rests. Opened, every pressed stack built.
    func hisPad() async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let m = try await G.openModel(self, r.project, "A1_0003")
        try await FlexibleSquishFixture.settle(m, "A1_0003")
        XCTAssertEqual(m.squeezeGroups.map(\.regions), [[1], [4, 2], [3, 5]], "premise: his three groups")
        return (r, m)
    }

    /// [+ New] → [Edges/corners], the list read and core's verdicts asked.
    @discardableResult
    func pickMode(_ m: FlexibleStageModel) async throws -> FlexibleEdgePick {
        m.rail = .newGroup
        m.startEdgePick()
        try await FlexibleHisProject.waitFor(240, "the edges and corners listed") {
            m.edgePick.map { !$0.loading && !$0.checking } ?? false
        }
        await m.waitForIdle()
        return try XCTUnwrap(m.edgePick, "pick mode")
    }

    /// [Done], at `kg`, then the part open again on the cut regions.
    func done(_ m: FlexibleStageModel, kg: Double = 5) async throws -> String? {
        m.setEdgePickWeight(kg)
        let why = await m.finishEdgePick()
        try await FlexibleHisProject.waitFor(240, "the part open again") {
            m.sceneState == .ready && m.openedKey == m.currentSceneKey
        }
        await m.waitForIdle()
        return why
    }

    func candidate(_ p: FlexibleEdgePick, _ members: Set<Int>, kind: FlexibleEdgeCandidates.Kind = .edge) -> Candidate? {
        p.candidates.first { $0.kind == kind && Set($0.members) == members }
    }

    static func bits(_ v: SIMD3<Double>) -> [UInt64] { [v.x.bitPattern, v.y.bitPattern, v.z.bitPattern] }

    /// The area (mm²) of region `r` on face `face` (its cuts over the face's triangles).
    static func area(_ m: FlexibleStageModel, _ r: Int, face: Int) -> Double {
        FlexibleEdgeStrips.area(FlexibleEdgeStrips.triangles(face: face, mesh: m.project.viewerMesh!), m.regions.cuts(of: r))
    }

    /// The page's projection at a camera (the shipping renderer's clip-from-model over a 900 pt frame).
    func projection(_ p: ProjectModel, _ cam: FlexibleRound6Tests.Cam, size: CGFloat = 900) throws -> CameraProjection {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 1))
        mr.setMesh(try XCTUnwrap(p.viewerMesh))
        mr.beginSettle(to: p.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0)), duration: 0)
        mr.camera.setOrientation(azimuth: cam.azimuth, elevation: cam.elevation)
        mr.camera.distance *= cam.zoom
        return CameraProjection(viewProjection: mr.clipFromModel(aspect: 1), viewportSize: CGSize(width: size, height: size))
    }

    // MARK: - (1) a group holds faces OR edges/corners

    /// ★ HIS ANSWER: a group is EITHER faces OR edges/corners, never mixed. `kind` is `.edges` iff it holds an edge or
    /// corner press (2+ regions); `normalise` SPLITS a mixed group (its edge presses go to a new group after the last; a
    /// tilted face press stays with the faces); a face never moves into an edges group, and a removed group's members
    /// join a group of their own kind. RED (run here): `controlNoSplit` leaves the mixed group mixed.
    func testAGroupHoldsFacesOrEdgesNeverBoth() {
        func face(_ r: Int, _ g: Int?, role: String = "loaded") -> FlexibleFaceSettings {
            FlexibleFaceSettings(faceRegionID: r, role: role, weightKg: 5, squeezeGroup: g)
        }
        var mixed = FlexibleStageSettings(materialID: "varioshore_tpu")
        mixed.faces = [face(1, nil), face(2, 2), face(0, nil, role: "resting")]
        let edge = FlexiblePress(regions: [1_000_101, 1_000_102], direction: SIMD3(0, 0.6, -0.8), snap: "halfway",
                                 settings: FlexibleFaceSettings(faceRegionID: 1_000_101, weightKg: 5, squeezeGroup: 2))
        let tilt = FlexiblePress(regions: [3], direction: SIMD3(0, 0.1, -0.99), snap: nil,
                                 settings: FlexibleFaceSettings(faceRegionID: 3, weightKg: 5, squeezeGroup: 2))
        mixed.presses = [edge, tilt]
        XCTAssertEqual(FlexibleSqueezeGroups.groups(mixed).first { $0.id == 2 }?.kind, .edges,
                       "premise: a group holding an edge press reads as edges — and it also holds face 2: mixed")
        var s = mixed
        FlexibleSqueezeGroups.normalise(&s)
        let gs = FlexibleSqueezeGroups.groups(s)
        print("FLEX-I2-1 split: " + gs.map { "Group \($0.number) \($0.kind) faces \($0.regions) presses \($0.presses.count)" }.joined(separator: " · "))
        XCTAssertEqual(gs.map(\.kind), [.faces, .faces, .edges], "the mixed group split: its edge press in a group of its own")
        guard gs.count == 3 else { return }
        XCTAssertEqual(gs[1].regions, [2])
        XCTAssertEqual(gs[1].presses, [tilt.id], "a tilted face press is one face: it stays with the faces")
        XCTAssertEqual(gs[2].regions, [])
        XCTAssertEqual(gs[2].presses, [edge.id])
        var again = s
        FlexibleSqueezeGroups.normalise(&again)
        XCTAssertEqual(again, s, "normalise is idempotent")
        // never into an edges group
        var moved = s
        FlexibleSqueezeGroups.move(1, to: gs[2].id, in: &moved)
        XCTAssertEqual(moved, s, "a face is never moved into an edges group")
        var into = s
        FlexibleSqueezeGroups.remove(group: gs[1].id, into: gs[2].id, in: &into)
        XCTAssertEqual(into, s, "a faces group never hands its faces to an edges group")
        var removed = s
        FlexibleSqueezeGroups.remove(group: gs[1].id, in: &removed)
        XCTAssertEqual(FlexibleSqueezeGroups.group(of: 2, in: removed)?.kind, .faces, "removed: its faces join a FACES group")
        XCTAssertEqual(FlexibleSqueezeGroups.groups(removed).filter { $0.kind == .edges }.map(\.presses), [[edge.id]],
                       "the edges group keeps its press")
        // ★ RED CONTROL: left mixed
        FlexibleSqueezeGroups.controlNoSplit = true
        defer { FlexibleSqueezeGroups.controlNoSplit = false }
        var left = mixed
        FlexibleSqueezeGroups.normalise(&left)
        let lg = FlexibleSqueezeGroups.groups(left)
        print("FLEX-I2-1 control (no split): " + lg.map { "Group \($0.number) \($0.kind) faces \($0.regions) presses \($0.presses.count)" }.joined(separator: " · "))
        XCTAssertTrue(lg.contains { $0.kind == .edges && !$0.regions.isEmpty }, "control: a group holding a face AND an edge press")
    }

    // MARK: - (2) listed, numbered, coloured

    /// ★ PICK MODE ON HIS PAD: every edge and corner (12 and 8, core's adjacency and the 15° rule) is listed, numbered
    /// 1…20 as the tags on the model; each wears a colour that is never the new group's own, and TOUCHING ones (an
    /// edge and the corner at its end, two edges meeting there) never share one. [+ New] asks [Faces | Edges/corners];
    /// pick mode hides the other groups' walls; [Faces] leaves it. The cube too. RED (run here): colours by number
    /// round the palette — touching ones share.
    func testEveryEdgeAndCornerIsListedNumberedAndColouredSoTouchingOnesNeverMatch() async throws {
        let (r, m) = try await hisPad()
        let tabs = FlexibleSettingsRailView.tabs(model: m).map(\.tab)
        XCTAssertTrue(tabs.contains(.newGroup), "[+ New] is on the rail")
        let p = try await pickMode(m)
        XCTAssertEqual(p.candidates.filter { $0.kind == .corner }.count, 8, "his pad: 8 corners")
        XCTAssertEqual(p.candidates.filter { $0.kind == .edge }.count, 12, "his pad: 12 edges")
        XCTAssertEqual(p.candidates.map(\.number), Array(1...20), "numbered 1…20, as listed")
        XCTAssertEqual(p.groupID, 4, "the new group is stored after his three")
        XCTAssertFalse(m.squeezeGroups.map { m.groupColour($0) }.contains(p.colour.rgba), "the new group takes a colour no group wears")
        XCTAssertTrue(FlexibleGroupWalls.shown(model: m, views: []).isEmpty, "pick mode hides the other groups' walls")
        func check(_ cs: [Candidate], _ colours: [Int: FlexibleGroupColour], own: FlexibleGroupColour) -> (pairs: Int, shared: Int) {
            var pairs = 0, shared = 0
            for a in cs { for b in cs where a.number < b.number && Rules.touching(a, b) {
                pairs += 1
                if colours[a.number] == colours[b.number] { shared += 1 }
            } }
            return (pairs, shared)
        }
        XCTAssertEqual(Set(p.colours.keys), Set(1...20), "every candidate has a colour")
        XCTAssertFalse(p.colours.values.contains(p.colour), "never the group's own colour")
        let c = check(p.candidates, p.colours, own: p.colour)
        print("FLEX-I2-2 his pad: \(p.candidates.count) candidates, touching pairs \(c.pairs), sharing a colour \(c.shared) · "
              + p.candidates.map { "#\($0.number) \($0.kind) \($0.members) \(p.colours[$0.number]?.rawValue ?? "-")" }.joined(separator: " "))
        XCTAssertEqual(c.pairs, 48, "a box: each corner touches its 3 edges (24), each edge 4 others at its ends (24)")
        XCTAssertEqual(c.shared, 0, "★ touching candidates never share a colour")
        // the tags on the model carry the list's numbers, in the list's colours
        let proj = try projection(r.project, FlexibleRound6Tests.iso)
        let marks = FlexibleEdgePickOverlay.marks(model: m, projection: proj)
        XCTAssertEqual(marks.map(\.number), p.candidates.map(\.number), "one mark per candidate, the list's numbers")
        for mk in marks {
            XCTAssertEqual(mk.colour, p.colours[mk.number]?.rgba, "#\(mk.number): its list colour on the model")
            if mk.target != nil { XCTAssertEqual(mk.text, "\(mk.number)") }
        }
        XCTAssertGreaterThan(marks.filter { $0.target != nil }.count, 0, "front-facing candidates are tagged")
        XCTAssertTrue(marks.filter { !$0.front }.allSatisfy { $0.target == nil }, "a candidate facing away has no tag")
        // ★ RED CONTROL: colours by number, round the palette
        Rules.controlRoundRobin = true
        let rr = Rules.colours(p.candidates, excluding: p.colour)
        Rules.controlRoundRobin = false
        let rc = check(p.candidates, rr, own: p.colour)
        print("FLEX-I2-2 control (round robin): touching pairs sharing a colour \(rc.shared)")
        XCTAssertGreaterThan(rc.shared, 0, "control: round robin puts one colour on touching candidates")
        // [Faces] leaves pick mode; nothing was stored
        let before = m.settings
        m.cancelEdgePick()
        XCTAssertNil(m.edgePick)
        XCTAssertEqual(m.settings, before, "pick mode stores nothing")
        // the cube
        let cube = try await G.openModel(self, try FlexiblePressFixtures.cube60Project(), "cube60")
        let cp = try await pickMode(cube)
        let cc = check(cp.candidates, cp.colours, own: cp.colour)
        print("FLEX-I2-2 cube60: \(cp.candidates.count) candidates, touching pairs \(cc.pairs), sharing \(cc.shared)")
        XCTAssertEqual(cp.candidates.count, 20)
        XCTAssertEqual(cc.shared, 0, "the cube: touching candidates never share a colour")
    }

    // MARK: - (3) the tap

    /// ★ THE TAP: the nearest CORNER within 22 pt, else the nearest EDGE within 22 pt, else nothing; a REPEAT tap within
    /// 22 pt of the last one cycles through every candidate there; a candidate facing away is not tapped. Synthetic
    /// first, then HIS pad at his img3 camera and a camera looking straight down (where each vertical edge lies under
    /// its two corners): every front-facing candidate is reached by taps at its own spot. RED (run here): the edge-first
    /// rule picks the edge; with no cycling the vertical edges under their corners are never reached.
    func testATapPicksTheNearestCornerThenEdgeAndARepeatTapCycles() async throws {
        let corner = Rules.Projected(number: 1, kind: .corner, point: CGPoint(x: 100, y: 100), lines: [], front: true, tag: nil)
        let edge = Rules.Projected(number: 2, kind: .edge, point: CGPoint(x: 104, y: 130),
                                   lines: [[CGPoint(x: 104, y: 60), CGPoint(x: 104, y: 160)]], front: true, tag: nil)
        let far = Rules.Projected(number: 3, kind: .edge, point: CGPoint(x: 300, y: 250),
                                  lines: [[CGPoint(x: 300, y: 0), CGPoint(x: 300, y: 500)]], front: true, tag: nil)
        let back = Rules.Projected(number: 4, kind: .corner, point: CGPoint(x: 102, y: 100), lines: [], front: false, tag: nil)
        let all = [corner, edge, far, back]
        let tap = CGPoint(x: 103, y: 101)   // the edge 1 pt away, the corner 3.2 pt away, the back-facing corner 1.4 pt
        let h1 = Rules.hit(all, at: tap, last: nil)
        XCTAssertEqual(h1.toggle, 1, "the nearest CORNER first (the edge is nearer); never the one facing away")
        XCTAssertNil(h1.untoggle)
        let h2 = Rules.hit(all, at: CGPoint(x: 104, y: 102), last: h1.cycle)
        XCTAssertEqual(h2.toggle, 2, "a repeat tap: the next one there")
        XCTAssertEqual(h2.untoggle, 1, "…and the last one back")
        let h3 = Rules.hit(all, at: tap, last: h2.cycle)
        XCTAssertEqual(h3.toggle, 1, "round again")
        XCTAssertEqual(Rules.hit(all, at: CGPoint(x: 300, y: 260), last: h3.cycle).toggle, 3, "elsewhere: a fresh tap")
        XCTAssertNil(Rules.hit(all, at: CGPoint(x: 600, y: 600), last: nil).toggle, "nothing within 22 pt: nothing")
        // ★ RED CONTROLS (synthetic)
        Rules.controlEdgeFirst = true
        let ef = Rules.hit(all, at: tap, last: nil).toggle
        Rules.controlEdgeFirst = false
        XCTAssertEqual(ef, 2, "control: the edge-first rule picks the edge")
        Rules.controlNoCycle = true
        let nc = Rules.hit(all, at: CGPoint(x: 104, y: 102), last: h1.cycle).toggle
        Rules.controlNoCycle = false
        XCTAssertEqual(nc, 1, "control: no cycling — the repeat tap picks the corner again")

        // HIS pad
        let (r, m) = try await hisPad()
        let p = try await pickMode(m)
        let straightDown = FlexibleRound6Tests.Cam(name: "straight down", azimuth: .pi / 5, elevation: 1.5, zoom: 1)
        var controlUnreached = 0
        for cam in [FlexibleRound6Tests.topCam, straightDown] {
            let proj = try projection(r.project, cam)
            let shown = Rules.project(p.candidates, loads: p.loads, projection: proj)
            func spot(_ c: Rules.Projected) -> CGPoint? {
                if c.kind == .corner { return c.point }
                guard let pl = c.lines.max(by: { FlexibleEdgeGroupsTests.length($0) < FlexibleEdgeGroupsTests.length($1) }) else { return nil }
                return FlexibleEdgeGroupsTests.middle(pl)
            }
            func reached(_ c: Rules.Projected) -> Int? {
                guard let at = spot(c) else { return nil }
                var last: Rules.Cycle? = nil
                for k in 1...12 {
                    let h = Rules.hit(shown, at: at, last: last)
                    if h.toggle == c.number { return k }
                    last = h.cycle
                }
                return nil
            }
            let front = shown.filter(\.front)
            let taps = front.map { ($0.number, reached($0)) }
            let unreached = taps.filter { $0.1 == nil }.map(\.0)
            print("FLEX-I2-3 \(cam.name): \(front.count) of \(shown.count) facing the camera · taps to reach each: "
                  + taps.map { "#\($0.0)×\($0.1.map(String.init) ?? "never")" }.joined(separator: " "))
            XCTAssertEqual(unreached, [], "\(cam.name): every candidate facing the camera is reached on the model")
            XCTAssertGreaterThan(front.count, 0)
            Rules.controlNoCycle = true
            let ctl = front.filter { reached($0) == nil }.map(\.number)
            Rules.controlNoCycle = false
            print("FLEX-I2-3 \(cam.name) control (no cycling): never reached \(ctl)")
            controlUnreached += ctl.count
            // every tag a finger can hit
            for mk in FlexibleEdgePickOverlay.marks(model: m, projection: proj) {
                if let t = mk.target { XCTAssertGreaterThanOrEqual(min(t.width, t.height), 44, "#\(mk.number)'s tag ≥ 44 pt") }
            }
        }
        XCTAssertGreaterThan(controlUnreached, 0, "control: without cycling some candidate under its corners is never reached")
        // the list reaches every candidate, facing the camera or not
        for c in p.candidates where p.pickable(c.number) {
            m.toggleEdgePick(c.number)
            XCTAssertTrue(m.edgePick?.picks.contains(c.number) ?? false, "#\(c.number): its row picks it")
            m.toggleEdgePick(c.number)
        }
        // through the model's own tap
        let proj = try projection(r.project, FlexibleRound6Tests.topCam)
        let firstCorner = try XCTUnwrap(Rules.project(p.candidates, loads: p.loads, projection: proj).first { $0.kind == .corner && $0.front })
        XCTAssertNil(m.edgePickTap(at: firstCorner.point!, projection: proj), "a tap on a corner picks it")
        XCTAssertEqual(m.edgePick?.picks, [firstCorner.number])
        XCTAssertEqual(m.edgePickTap(at: CGPoint(x: 2, y: 2), projection: proj), FlexibleRowCopy.edgePickMiss, "a miss says so")
        let tapsBefore = m.settings
        m.tapFace(1, point: SIMD3(50, 50, 20))
        XCTAssertEqual(m.settings, tapsBefore)
        XCTAssertEqual(m.rail, .newGroup, "in pick mode a tap on the part never selects a face")
    }

    static func length(_ pl: [CGPoint]) -> CGFloat {
        guard pl.count >= 2 else { return 0 }
        return (1..<pl.count).reduce(0) { $0 + hypot(pl[$1].x - pl[$1 - 1].x, pl[$1].y - pl[$1 - 1].y) }
    }
    static func middle(_ pl: [CGPoint]) -> CGPoint {
        let half = length(pl) / 2
        var run: CGFloat = 0
        for i in 1..<pl.count {
            let l = hypot(pl[i].x - pl[i - 1].x, pl[i].y - pl[i - 1].y)
            if run + l >= half, l > 0 {
                let t = (half - run) / l
                return CGPoint(x: pl[i - 1].x + (pl[i].x - pl[i - 1].x) * t, y: pl[i - 1].y + (pl[i].y - pl[i - 1].y) * t)
            }
            run += l
        }
        return pl.last!
    }

    // MARK: - (4) the strip, and the face keeps the rest

    /// ★ THE AREA ON HIS PAD: the Top–Face 2 edge (Top in Group 1, Face 2 in Group 2, both stamped). [Done] presses a
    /// STRIP on each face — the face within w of the edge, area L × w within 0.1 % — and each face's group KEEPS THE
    /// REST: the face's settings on its rest (its group, weight link, curves, deepest), the stamp where he drew it on
    /// the part (core's frames: its point on the surface unmoved within 1e-6 mm); strip + rest = the face. Before
    /// [Done] one line per face: "Face 1 keeps the rest · strip taken for Edge N" (≤ 44). No region in two entries, no
    /// two entries sharing surface; the main page's Selections untouched; ONE undo step. The cut is the Surface tool's
    /// own: the same regions as ProjectModel.commitSurfaceCut for that plane, without its Selections join. RED (run
    /// here): whole-face regions — faces 1 and 2 in two entries (core's refusal).
    func testAnEdgePickPressesAStripOnEachFaceAndTheFaceGroupKeepsTheRest() async throws {
        let (r, m) = try await hisPad()
        let mesh = try XCTUnwrap(r.project.viewerMesh)
        let before = r.project.editSnapshot
        let settingsBefore = m.settings
        let selectionBefore = r.project.selection.groups
        let p = try await pickMode(m)
        let c = try XCTUnwrap(candidate(p, [1, 2]), "the Top–Face 2 edge")
        let st = try XCTUnwrap(p.strips[c.number], "its area")
        m.toggleEdgePick(c.number)
        let lines = m.edgePickKeepsTheRest()
        print("FLEX-I2-4 before [Done]: " + lines.joined(separator: " | "))
        XCTAssertEqual(lines.count, 2, "Face 1 and Face 2 are both in face groups: one line each")
        for l in lines {
            XCTAssertLessThanOrEqual(l.count, 44, "'\(l)' is one line")
            XCTAssertTrue(l.contains("keeps the rest") && l.contains("Edge \(c.number)"), l)
        }
        XCTAssertTrue(lines.contains("Face 1 keeps the rest \u{00B7} strip taken for Edge \(c.number)") ||
                      lines.contains("Face 1 keeps the rest \u{00B7} strip for Edge \(c.number)"), "the line names the face and the edge")
        // ★ RE-PINNED (round 7, R7-E1 — his 2026-10-18 words: "There shouldn't be a strip width. It should be a Flat prism that
        // gets wider as it gets dragged further towards the centre of the model from the edge."): was the DEFAULT WIDTH (core's
        // lattice depth under the members, capped at half the face). A pick carries no width now: it carries core's halfway
        // over its whole member faces, and the press starts at the flat prism's default depth (3 mm — a face's default).
        let widthText: String = st.widthMM.map { "\($0)" } ?? "none"
        let halfwayText: String = st.halfway.map { "\($0)" } ?? "none"
        print("FLEX-I2-4 area: no width (\(widthText)) · halfway \(halfwayText) · cap \(st.capMM)")
        XCTAssertNil(st.widthMM, "★ no strip width")
        XCTAssertNotNil(st.halfway, "★ core's halfway, stored at pick time")
        XCTAssertEqual(st.capMM, 10, accuracy: 1e-6, "Face 2 is 20 mm across the edge (half of it, kept for M2's read-through)")
        let why1 = try await done(m)
        XCTAssertNil(why1, "[Done] cut the strips")
        let press = try XCTUnwrap(m.presses.first { $0.strip != nil }, "one press")
        XCTAssertEqual(m.presses.filter { $0.strip != nil }.count, 1)
        XCTAssertEqual(press.regions.count, 2, "a strip on each face")
        XCTAssertTrue(press.regions.allSatisfy(FlexibleRegions.isSector), "each strip is a sector")
        // ★ RE-PINNED (R7-E1): the reach w is the flat prism's implied reach (h / dot(a, d) — h√2 on this right-angled edge)
        let cutDone = try XCTUnwrap(FlexibleFlatPrism.cut(of: press))
        XCTAssertEqual(cutDone.depthMM, FlexibleFlatPrism.defaultDepthMM, accuracy: 1e-12, "★ a new pick starts at 3 mm")
        let w = try XCTUnwrap(FlexibleFlatPrism.reach(try XCTUnwrap(press.strip), member: 0, cutDone))
        for (k, reg) in press.regions.enumerated() {
            let face = press.strip!.members[k].face
            XCTAssertEqual(m.regions.faces(of: reg, mesh: mesh), [face], "strip \(k) lies on face \(face)")
            let got = Self.area(m, reg, face: face)
            let whole = FlexibleEdgeStrips.area(FlexibleEdgeStrips.triangles(face: face, mesh: mesh), [])
            print("FLEX-I2-4 strip on face \(face): \(got) mm² (100 × \(w) = \(100 * w)) of \(whole)")
            XCTAssertEqual(got, 100 * w, accuracy: 1e-3 * 100 * w, "face \(face): the face within w of the edge (L × w)")
            // the rest: the face's other piece, holding the face's settings
            let rests = m.settings.faces.filter { FlexibleRegions.isSector($0.faceRegionID)
                && m.regions.faces(of: $0.faceRegionID, mesh: mesh) == [face] }
            XCTAssertEqual(rests.count, 1, "face \(face): one rest beside a strip")
            let rest = try XCTUnwrap(rests.first)
            XCTAssertEqual(got + Self.area(m, rest.faceRegionID, face: face), whole, accuracy: 1e-6 * whole, "strip + rest = the face")
            let old = try XCTUnwrap(settingsBefore.face(face))
            XCTAssertEqual(rest.squeezeGroup, old.squeezeGroup, "face \(face)'s group keeps the rest")
            XCTAssertEqual(rest.role, old.role)
            XCTAssertEqual(rest.weightFrom, old.weightFrom, "its weight's link kept")
            XCTAssertEqual(rest.deepestMM, old.deepestMM)
            XCTAssertEqual(rest.shape, old.shape)
            XCTAssertNil(m.settings.face(face), "face \(face) itself is no longer an entry: its rest is")
            // the stamp where he drew it ON THE PART (core's frames, the scene open on the cut)
            if let s0 = old.designStamp, let s1 = rest.designStamp {
                let p0 = try await m.frameWorker.withScene { try FlexibleSceneFrames($0).fromUV(.face(face), [SIMD2(s0.centreU, s0.centreV)]) }
                let p1 = try await m.frameWorker.withScene { try FlexibleSceneFrames($0).fromUV(.face(rest.faceRegionID), [SIMD2(s1.centreU, s1.centreV)]) }
                print("FLEX-I2-4 face \(face) stamp: (\(s0.centreU), \(s0.centreV)) → (\(s1.centreU), \(s1.centreV)) · on the part \(p0[0]) → \(p1[0])")
                XCTAssertLessThan(simd_distance(p0[0], p1[0]), 1e-6, "face \(face): the stamp stays where he drew it")
            }
        }
        XCTAssertEqual(FlexibleEdgeStrips.regionsInTwoEntries(m.settings), [], "no region in two entries")
        XCTAssertTrue(FlexibleEdgeStrips.sharedSurface(m.settings, regions: m.regions, mesh: mesh).isEmpty, "no two entries share surface")
        XCTAssertEqual(r.project.selection.groups, selectionBefore, "★ the main page's Selections are not touched")
        // ONE undo step
        r.project.performUndo()
        XCTAssertEqual(r.project.faceRegions, before.faceRegions, "undo: the regions as they were")
        XCTAssertEqual(m.settings, settingsBefore, "undo: the Flexible setup as it was")
        r.project.performRedo()
        XCTAssertEqual(m.presses.filter { $0.strip != nil }.count, 1, "redo: the press back")

        // ── the Surface tool's own cut: Face 1's strip plane through ProjectModel.commitSurfaceCut on a second copy
        // ★ RE-PINNED (round 7, M2 — the reviewer's ruling 3: "FLEXIBLE-ONLY sectors carried in the job, NOT Surface-stage
        // sectors"): the strip is a Flexible sector now — its cut lives in the Flexible store (derived on a scratch copy of
        // the regions, with the Surface tool's own calls) and the Surface stage's regions are UNTOUCHED; the cuts are still
        // the Surface tool's, compared here piece for piece (the strip and its rest on Face 1)
        XCTAssertEqual(r.project.faceRegions, before.faceRegions, "★ the Surface stage's regions are not touched (M2)")
        let twin = try FlexiblePressFixtures.a1Project(3, self).project
        // ★ RE-PINNED (R7-E1): the strip's plane is the flat prism's in-face cut (was the width's half-space)
        let h = FlexibleFlatPrism.memberCuts(press.strip!, cutDone)[0][0]
        let leaves = twin.commitSurfaceCut(SurfaceCut(point: h.point, normal: h.normal, faceID: FaceID(press.strip!.members[0].face),
                                                      faceNormal: SIMD3(0, 0, 1)))
        XCTAssertEqual(leaves.count, 2)
        func order(_ c: [[RegionCut]]) -> [[RegionCut]] { c.sorted { $0.count < $1.count || ($0.count == $1.count && "\($0)" < "\($1)") } }
        let face0 = press.strip!.members[0].face
        let ours = (m.regions.flexible?.pieces ?? []).filter { m.regions.faces(of: $0.wireID, mesh: mesh) == [face0] }
        XCTAssertEqual(order(ours.map(\.region.cuts)), order(leaves.compactMap { twin.faceRegions.region($0)?.cuts }),
                       "the same cuts as the Surface tool's (the strip and its rest)")
        XCTAssertEqual(ours.first?.region.add, twin.faceRegions.region(twin.faceRegions.region(leaves[0])!.parentID)?.add,
                       "the same identity region's faces")
        let joined = twin.selection.groups.flatMap(\.regionIDs).count - selectionBefore.flatMap(\.regionIDs).count
        print("FLEX-I2-4 parity: commitSurfaceCut's leaves \(leaves) · ours \(ours.map(\.wireID)) · its Selections join added \(joined) region(s); ours 0")
        var helper = before.faceRegions
        let hl = FlexibleEdgeStrips.surfaceCut(&helper, face: press.strip!.members[0].face, point: h.point, normal: h.normal, mesh: mesh)
        XCTAssertEqual(helper, twin.faceRegions, "FlexibleEdgeStrips.surfaceCut is commitSurfaceCut's region edit, exactly")
        XCTAssertEqual(hl, leaves)

        // ★ RED CONTROL: whole-face regions
        let (_, m2) = try await hisPad()
        let p2 = try await pickMode(m2)
        m2.toggleEdgePick(try XCTUnwrap(candidate(p2, [1, 2])).number)
        FlexibleEdgeStrips.controlWholeFaces = true
        defer { FlexibleEdgeStrips.controlWholeFaces = false }
        let why2 = try await done(m2)
        XCTAssertNil(why2)
        let twice = FlexibleEdgeStrips.regionsInTwoEntries(m2.settings)
        print("FLEX-I2-4 control (whole faces): regions in two entries \(twice)")
        XCTAssertEqual(twice, [1, 2], "control: faces 1 and 2 in their face groups AND in the press — core refuses")
    }

    // MARK: - (5) picks never overlap

    /// ★ PICK ORDER ON HIS PAD: the four edges round the Top in turn (A, B, C, D — each meeting the next) and the corner
    /// where A and B meet. No region is in two presses, no press holds two sectors of one face, no two pieces share
    /// surface; on the Top the corner takes its square out of A's and B's ends, and where two picked edges meet the
    /// FIRST keeps the shared square (A over D, B over C, C over D).
    func testPickOrderCutsNeverOverlap() async throws {
        let (r, m) = try await hisPad()
        let mesh = try XCTUnwrap(r.project.viewerMesh)
        let p = try await pickMode(m)
        let top = 1
        var ring = p.candidates.filter { $0.kind == .edge && $0.members.contains(top) }
        XCTAssertEqual(ring.count, 4, "premise: four edges round the Top")
        guard ring.count == 4 else { return }
        var ordered: [Candidate] = [ring.removeFirst()]
        while !ring.isEmpty {
            guard let i = ring.firstIndex(where: { Rules.touching($0, ordered.last!) }) else { break }
            ordered.append(ring.remove(at: i))
        }
        XCTAssertEqual(ordered.count, 4)
        guard ordered.count == 4 else { return }
        let (a, b) = (ordered[0], ordered[1])
        let corner = try XCTUnwrap(p.candidates.first { $0.kind == .corner && Set($0.members).isSuperset(of: Set(a.members + b.members)) },
                                   "the corner where A and B meet")
        for c in ordered + [corner] { m.toggleEdgePick(c.number) }
        XCTAssertEqual(m.edgePick?.picks, ordered.map(\.number) + [corner.number])
        let why3 = try await done(m)
        XCTAssertNil(why3)
        let presses = m.presses.filter { $0.strip != nil }
        XCTAssertEqual(presses.count, 5)
        XCTAssertEqual(FlexibleEdgeStrips.regionsInTwoEntries(m.settings), [], "no region in two entries")
        XCTAssertTrue(FlexibleEdgeStrips.sharedSurface(m.settings, regions: m.regions, mesh: mesh).isEmpty, "no two entries share surface")
        for pr in presses {
            let faces = pr.regions.flatMap { m.regions.faces(of: $0, mesh: mesh) }
            XCTAssertEqual(faces.count, Set(faces).count, "\(pr.strip!.label): never two sectors of one face")
        }
        // the Top's pieces, by pick
        func piece(_ c: Candidate) -> Int? {
            presses.first { $0.strip?.label == FlexibleRowCopy.candidateLabel(c) }.flatMap { pr in
                pr.regions.first { m.regions.faces(of: $0, mesh: mesh) == [top] }
            }
        }
        // who holds the square where X and Y meet on the Top: a point a little in from that corner
        func holder(_ x: Candidate, _ y: Candidate) -> String? {
            let ex = Rules.ends(x), ey = Rules.ends(y)
            guard let q = ex.first(where: { e in ey.contains { simd_distance(e, $0) < 1e-3 } }) else { return nil }
            let centre = SIMD3<Double>(50, 50, q.z)   // the Top's middle
            let pt = q + simd_normalize(centre - q) * 0.5
            for c in ordered + [corner] {
                guard let id = piece(c), FaceRegionGeometry.inside(pt, m.regions.cuts(of: id)) else { continue }
                return FlexibleRowCopy.candidateLabel(c)
            }
            return nil
        }
        let name = { (c: Candidate) in FlexibleRowCopy.candidateLabel(c) }
        let squares = [(a, b), (b, ordered[2]), (ordered[2], ordered[3]), (ordered[3], a)].map { ($0.0, $0.1, holder($0.0, $0.1)) }
        print("FLEX-I2-5 order: " + (ordered + [corner]).map(name).joined(separator: ", ") + " · squares on the Top: "
              + squares.map { "\(name($0.0))∩\(name($0.1)) → \($0.2 ?? "none")" }.joined(separator: " · "))
        XCTAssertEqual(squares[0].2, name(corner), "the corner takes its square out of A's and B's ends")
        XCTAssertEqual(squares[1].2, name(b), "B was picked before C: B keeps their square")
        XCTAssertEqual(squares[2].2, name(ordered[2]), "C before D")
        XCTAssertEqual(squares[3].2, name(a), "A before D")
        // pairwise: the Top's pieces never overlap
        let ids = (ordered + [corner]).compactMap(piece)
        let tris = FlexibleEdgeStrips.triangles(face: top, mesh: mesh)
        for i in 0..<ids.count { for j in (i + 1)..<ids.count {
            XCTAssertLessThan(FlexibleEdgeStrips.area(tris, m.regions.cuts(of: ids[i]) + m.regions.cuts(of: ids[j])), 1e-6,
                              "pieces \(ids[i]) and \(ids[j]) share no surface")
        } }
    }

    // MARK: - (6) a press at core's halfway, never sent

    /// ★ EACH PICK IS AN AP1 PRESS: over its strips (member order), aimed at AP3's default — core's halfway on ITS
    /// strips, bit for bit (FlexiblePressAimSet.defaultRelease), 45° from each face on a box edge — snap "halfway", in
    /// the new group (Group 4, edges, the pick's colour), at the force he typed. SAVED, NEVER SENT: not in sentPresses,
    /// not in the sends' jobs (no press_direction, no strip region), not in the lattice's key. RED (run here): a
    /// ViewerMesh-normal stand-in for the halfway has other bits.
    func testAPickedEdgeBecomesAPressAtCoresHalfwayInTheNewGroupAndIsNeverSent() async throws {
        let (r, m) = try await hisPad()
        let mesh = try XCTUnwrap(r.project.viewerMesh)
        let keyBefore = m.settings.designInputs
        let p = try await pickMode(m)
        let colour = p.colour
        let c = try XCTUnwrap(candidate(p, [1, 2]))
        m.toggleEdgePick(c.number)
        let why4 = try await done(m, kg: 6)
        XCTAssertNil(why4)
        let press = try XCTUnwrap(m.presses.first { $0.strip != nil })
        let aim = try await m.pressAim(press.regions)
        let rel = try XCTUnwrap(aim.defaultRelease, "core builds the halfway on the strips")
        XCTAssertEqual(Self.bits(press.direction), Self.bits(rel.direction), "★ the direction IS core's halfway on its strips, bit for bit")
        XCTAssertEqual(press.snap, "halfway")
        let deg = aim.memberLoads.map { FlexiblePressAim.degrees(press.direction, $0) }
        print("FLEX-I2-6 direction \(press.direction) · from each face \(deg) · kg \(press.settings.weightKg)")
        for d in deg { XCTAssertEqual(d, 45, accuracy: 1e-9, "a box edge: 45° from each face") }
        XCTAssertEqual(press.settings.weightKg, 6, "the force he typed")
        XCTAssertNil(press.settings.weightFrom, "never linked: the group's one force")
        let g = try XCTUnwrap(m.squeezeGroup(ofPress: press.id))
        XCTAssertEqual(g.number, 4)
        XCTAssertEqual(g.kind, .edges)
        XCTAssertTrue(g.regions.isEmpty)
        XCTAssertEqual(m.groupColour(g), colour.rgba, "the new group wears the pick's colour")
        XCTAssertEqual(m.rail, .group(g.id), "its tab opens")
        XCTAssertEqual(FlexibleSettingsRailView.tabs(model: m).first { $0.tab == .group(g.id) }?.detail, "1 edge")
        XCTAssertEqual(m.stripTitle(press.id), "Edge \(c.number) \u{00B7} Face 1 + Face 2", "its row names the pick and the faces")
        // never sent
        XCTAssertTrue(m.sentPresses.isEmpty)
        XCTAssertFalse(m.sentSqueezeGroups.contains { $0.id == g.id })
        XCTAssertNil(m.settings.designInputs.presses)
        let removed = keyBefore.faces.map(\.faceRegionID).filter { m.settings.face($0) == nil }
        print("FLEX-I2-6 the lattice's key moved for the faces that gave a strip only: \(removed)")
        XCTAssertEqual(removed.sorted(), [1, 2])
        for send in G.sends(m) {
            let job = try m.runJobJSON(resting: Set(send.resting))
            XCTAssertFalse(job.contains("press_direction"), "\(send.title): no press is written")
            let ids = try FlexibleCore.parseJobBlock(job).faces.map(\.faceRegionID)
            XCTAssertTrue(Set(ids).isDisjoint(with: press.regions), "\(send.title): no strip in the job")
        }
        // the viewer mesh's own normals (Float): on his axis-aligned pad they are exact — the same bits (printed)
        let n1 = try XCTUnwrap(mesh.faceNormal(1)), n2 = try XCTUnwrap(mesh.faceNormal(2))
        let padStandIn = try XCTUnwrap(FlexiblePressAim.halfway([-SIMD3<Double>(n1), -SIMD3<Double>(n2)]))
        print("FLEX-I2-6 his pad, ViewerMesh normals: \(padStandIn) — bits equal core's \(Self.bits(padStandIn) == Self.bits(press.direction)) (axis-aligned faces)")
        // ★ RED CONTROL, where it can bite: a wedge whose side is slanted — the edge between it and the top
        let wedge = try await wedgeModel()
        let wp = try await pickMode(wedge.m)
        let slanted = try XCTUnwrap(wp.candidates.first { c in
            c.kind == .edge && c.members.contains(wedge.top) && c.members.contains(wedge.slanted)
        }, "the top–slanted edge")
        wedge.m.toggleEdgePick(slanted.number)
        let why6b = try await done(wedge.m)
        XCTAssertNil(why6b)
        let wpress = try XCTUnwrap(wedge.m.presses.first { $0.strip != nil })
        let wset = try await wedge.m.pressAim(wpress.regions)
        let wrel = try XCTUnwrap(wset.defaultRelease)
        XCTAssertEqual(Self.bits(wpress.direction), Self.bits(wrel.direction), "the wedge: core's halfway on its strips, bit for bit")
        let wm = try XCTUnwrap(wedge.m.project.viewerMesh)
        var normals: [SIMD3<Double>] = []
        for f in slanted.members {
            let n = try XCTUnwrap(wm.faceNormal(Int32(f)))
            normals.append(-SIMD3<Double>(n))
        }
        let standIn = try XCTUnwrap(FlexiblePressAim.halfway(normals))
        print("FLEX-I2-6 control (wedge, ViewerMesh normals): \(standIn) vs core \(wpress.direction)")
        XCTAssertNotEqual(Self.bits(standIn), Self.bits(wpress.direction), "control: a ViewerMesh stand-in has other bits")
    }

    /// A wedge (an extruded trapezoid, 60 × 20…40 × 30 mm): its side from (60, 20) to (0, 40) is slanted in plan.
    func wedgeModel() async throws -> (m: FlexibleStageModel, top: Int, slanted: Int) {
        let outline: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(60, 0), SIMD2(60, 20), SIMD2(0, 40)]
        let path = try FlexiblePressFixtures.write("i2_wedge.stl",
                                                   FlexiblePressFixtures.asciiSTL("wedge", FlexiblePressFixtures.extrudedTriangles(outline, height: 30)))
        let pm = try FlexiblePressFixtures.project(path: path, name: "wedge")
        let m = try await G.openModel(self, pm, "the wedge")
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let top = FlexibleSquishFixture.face(mesh, axis: 2, value: 30)
        var slanted = -1
        for t in 0..<mesh.triangleCount {
            let f = Int(mesh.faceIDs[t])
            if let n = mesh.faceNormal(Int32(f)), abs(n.x) > 0.1, abs(n.y) > 0.1 { slanted = f; break }
        }
        XCTAssertGreaterThanOrEqual(top, 0); XCTAssertGreaterThanOrEqual(slanted, 0)
        return (m, top, slanted)
    }

    // MARK: - (7) the depth (was: the width)

    /// ★ RE-PINNED (round 7, R7-E1 — his 2026-10-18 words: "There shouldn't be a strip width. It should be a Flat prism that gets
    /// wider as it gets dragged further towards the centre of the model from the edge."): was testTheStripWidthReCutsOnChange-
    /// AsOneUndoStep. A DEPTH change of the flat prism RE-CUTS (the strip L × the implied reach h√2, the rest the face less it;
    /// the press stays on its whole faces' halfway — never re-aimed; the face's settings follow its rest) as ONE undo step; a
    /// typed depth past what the faces allow is held so each face keeps some of itself (his answer: the half-face rule dropped).
    func testTheFlatPrismDepthReCutsOnChangeAsOneUndoStep() async throws {
        let (r, m) = try await hisPad()
        let mesh = try XCTUnwrap(r.project.viewerMesh)
        let p = try await pickMode(m)
        m.toggleEdgePick(try XCTUnwrap(candidate(p, [1, 2])).number)
        let why5 = try await done(m)
        XCTAssertNil(why5)
        let press = try XCTUnwrap(m.presses.first { $0.strip != nil })
        let h0 = try XCTUnwrap(FlexibleFlatPrism.depth(of: press))
        let afterDone = r.project.faceRegions
        let settingsDone = m.settings
        let regionsDone = m.regions
        func groupOn(_ face: Int, _ s: FlexibleStageSettings, _ regs: FlexibleRegions) -> Int? {
            s.faces.first { regs.faces(of: $0.faceRegionID, mesh: mesh) == [face] }?.squeezeGroup
        }
        let h1 = 6.0
        let why6 = await m.setFlatCut(press.id, depthMM: h1, direction: press.direction, snap: press.snap)
        XCTAssertNil(why6)
        try await FlexibleHisProject.waitFor(240, "the part open again") { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        await m.waitForIdle()
        let re = try XCTUnwrap(m.press(press.id))
        XCTAssertEqual(re.settings.deepestMM, h1, accuracy: 1e-12)
        XCTAssertNil(re.strip?.widthMM, "no width")
        // ★ RE-PINNED (round 7, M2 — the reviewer's ruling 3): a strip is a Flexible sector keyed by its ROLE (its press and
        // member), so a re-cut keeps its ids and moves its cuts (I2's Surface cut made new sector ids)
        XCTAssertEqual(re.regions, press.regions, "re-cut: the same Flexible ids")
        XCTAssertNotEqual(re.regions.map { regionsDone.cuts(of: $0) }, re.regions.map { m.regions.cuts(of: $0) }, "re-cut: new cuts")
        for (k, reg) in re.regions.enumerated() {
            let face = re.strip!.members[k].face
            let reach = h1 * 2.0.squareRoot()
            XCTAssertEqual(Self.area(m, reg, face: face), 100 * reach, accuracy: 1e-3 * 100 * reach, "face \(face): L × h√2")
            let rest = m.settings.faces.filter { m.regions.faces(of: $0.faceRegionID, mesh: mesh) == [face] }
            XCTAssertEqual(rest.count, 1, "face \(face): its rest, re-keyed")
            XCTAssertEqual(rest.first?.squeezeGroup, groupOn(face, settingsDone, regionsDone), "face \(face): its group keeps the new rest")
        }
        XCTAssertEqual(Self.bits(re.direction), Self.bits(try XCTUnwrap(press.strip?.halfway)), "★ the whole faces' halfway — never re-aimed")
        XCTAssertEqual(FlexibleEdgeStrips.regionsInTwoEntries(m.settings), [])
        print("FLEX-I2-7 depth \(h0) → \(h1): regions \(press.regions) → \(re.regions)")
        r.project.performUndo()
        XCTAssertEqual(r.project.faceRegions, afterDone, "ONE undo step: the Surface regions untouched")
        XCTAssertEqual(m.settings, settingsDone, "ONE undo step: the cut at \(h0) back")
        r.project.performRedo()
        // past what the faces allow: held so each face keeps some of itself
        try await FlexibleHisProject.waitFor(240, "the part open again") { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        await m.waitForIdle()
        let why7 = await m.setFlatCut(press.id, depthMM: 999, direction: press.direction, snap: press.snap)
        try await FlexibleHisProject.waitFor(240, "the part open again") { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        await m.waitForIdle()
        let held = try XCTUnwrap(m.press(press.id))
        let cut = try XCTUnwrap(FlexibleFlatPrism.cut(of: held))
        print("FLEX-I2-7 999 mm typed: \(why7 ?? "stored") · depth \(cut.depthMM) · toast \(m.toast ?? "-")")
        XCTAssertLessThan(cut.depthMM, 999, "★ never 999 mm")
        for (k, mb) in held.strip!.members.enumerated() {
            XCTAssertTrue(FlexibleFlatPrism.keepsRest(FlexibleEdgeStrips.triangles(face: mb.face, mesh: mesh), member: mb, cut),
                          "★ member \(k): the face keeps some of itself")
        }
    }

    // MARK: - (8) what cannot be picked

    /// ★ GREY, WITH ONE LINE WHY: after an edges group exists, the candidates over its strips read "In Group 4"; a face
    /// taken out of the setup keeps AP2's line; the area's own refusal (a fillet) has its line; every line ≤ 44
    /// characters, and a grey row cannot be picked. Core's verdict was asked of every pickable candidate on his pad.
    func testWhatCannotBePickedIsGreyWithOneLine() async throws {
        let (_, m) = try await hisPad()
        let p0 = try await pickMode(m)
        let edge = try XCTUnwrap(candidate(p0, [1, 2]))
        XCTAssertEqual(p0.greyed, [:], "his pad as saved: every edge and corner can be pressed (core's verdict asked of each)")
        m.toggleEdgePick(edge.number)
        let why8 = try await done(m)
        XCTAssertNil(why8)
        m.edit({ s in s.removedRegions = [5] }, recompute: false)
        let p = try await pickMode(m)
        print("FLEX-I2-8 greyed: " + p.greyed.sorted { $0.key < $1.key }.map { "#\($0.key) \(p.candidate($0.key)?.members ?? []) '\($0.value)'" }.joined(separator: " | "))
        let inGroup = p.greyed.filter { $0.value == "In Group 4" }
        XCTAssertGreaterThan(inGroup.count, 0, "the candidates over the strips read 'In Group 4'")
        XCTAssertTrue(p.greyed.contains { $0.value.contains("taken out of the Flexible setup") }, "face 5 taken out: AP2's line")
        for (n, why) in p.greyed {
            XCTAssertLessThanOrEqual(why.count, 44, "#\(n): '\(why)' is one line")
            m.toggleEdgePick(n)
            XCTAssertFalse(m.edgePick?.picks.contains(n) ?? true, "#\(n): a grey row cannot be picked")
        }
        // the area's own refusal: a fillet
        let box = FlexibleLatticeFixtures.boxMesh(subdiv: 1).mesh
        let meet = FlexibleMeet(mesh: box, regions: FlexibleRegions(model: FaceRegionModel(), mesh: box))
        let fillet = Candidate(number: 9, kind: .blend, members: [0, 1, 2], point: .zero, polylines: [], offered: true, why: nil)
        switch FlexibleEdgeStrips.strip(for: fillet, label: "Fillet 9", order: 1, meet: meet, facts: FlexibleMeetFacts(),
                                        faceRegions: FaceRegionModel(), existing: [], name: { "Face \($0)" }) {
        case .success: XCTFail("a fillet has no straight strip")
        case .failure(let f): XCTAssertEqual(f.line, FlexibleRowCopy.stripFillet)
        }
    }

    // MARK: - (9) saved, and the other faces' job entries

    /// ★ SAVED WITH THE PROJECT: the press and its strip round-trip through the store's encoding; and every face entry
    /// of every send that gave no strip (faces 0, 3, 4, 5) is BYTE-identical before and after; the faces that gave one
    /// (1, 2) are their rests now (stated, printed).
    func testEdgesGroupsRoundTripAndOtherFacesKeepTheirJobEntries() async throws {
        let (r, m) = try await hisPad()
        try await G.settleAllowingRefusedStacks(m, "A1_0003")   // the sends as the Export step reads them, settled
        func entries() throws -> [String: [Int: String]] {
            var out: [String: [Int: String]] = [:]
            for send in G.sends(m) {
                let job = try m.runJobJSON(resting: Set(send.resting))
                let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(job.utf8)) as? [String: Any])
                let flex = try XCTUnwrap((doc["loads"] as? [String: Any])?["flexible"] as? [String: Any] ?? doc["flexible"] as? [String: Any],
                                         "the job's flexible block")
                let faces = try XCTUnwrap(flex["faces"] as? [[String: Any]])
                var byID: [Int: String] = [:]
                for f in faces {
                    let id = try XCTUnwrap(f["face_region_id"] as? Int)
                    byID[id] = String(decoding: try JSONSerialization.data(withJSONObject: f, options: [.sortedKeys]), as: UTF8.self)
                }
                out[send.title] = byID
            }
            return out
        }
        let before = try entries()
        let p = try await pickMode(m)
        m.toggleEdgePick(try XCTUnwrap(candidate(p, [1, 2])).number)
        let why9 = try await done(m)
        XCTAssertNil(why9)
        try await G.settleAllowingRefusedStacks(m, "A1_0003 after the cut")
        let after = try entries()
        XCTAssertEqual(Set(before.keys), Set(after.keys), "the same sends (the edges group sends nothing)")
        var same = 0
        for (send, ids) in before {
            for id in [0, 3, 4, 5] where ids[id] != nil {
                XCTAssertEqual(after[send]?[id], ids[id], "\(send): face \(id)'s entry byte-identical")
                same += 1
            }
            let moved = (after[send] ?? [:]).keys.filter { FlexibleRegions.isSector($0) }.sorted()
            print("FLEX-I2-9 \(send): faces 1, 2 → their rests \(moved) · " + moved.map { "\($0): \(after[send]![$0]!.prefix(160))…" }.joined(separator: " | "))
            XCTAssertNil(after[send]?[1]); XCTAssertNil(after[send]?[2])
        }
        XCTAssertGreaterThan(same, 0)
        // the store's encoding round-trips the press and its strip
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(r.project.lattice)
        let back = try JSONDecoder().decode(type(of: r.project.lattice), from: data)
        XCTAssertEqual(back.flexible?.presses, m.settings.presses, "the press and its strip round-trip")
        XCTAssertEqual(try enc.encode(back), data)
        XCTAssertNotNil(back.flexible?.presses?.first?.strip)
    }
}
