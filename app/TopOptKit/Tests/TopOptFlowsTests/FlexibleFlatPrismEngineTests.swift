// FlexibleFlatPrismEngineTests — round 7, batch R7-E1: the flat prism's SEAM to core (core's press stack through a synthetic
// key, the bridge being ours) and its COMMIT ENGINE (one drag = one edit, one undo step, one scene open; a refused release
// stores nothing; the depth stops where the lattice ends, from core's columns; the halfway is the whole faces' and is never
// re-aimed), the READ-THROUGH of strips saved with M2's width, and one store per number. On HIS pad (A1_0003) and the 60 mm cube.
// His words (2026-10-18): "There shouldn't be a strip width. It should be a Flat prism that gets wider as it gets dragged further
// towards the centre of the model from the edge." The reviewer's rulings: NOTHING app-side stands in as the bend limit — the
// depth is capped by the lattice/geometry from core's columns; no request to core without a face-prism. Written BEFORE the code,
// against stubs (red run: round7/batch_e1/e1b_red_run.txt). Each RED CONTROL runs inside its test.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleFlatPrismSeamTests: XCTestCase {
    typealias F = FlexibleFlatPrismFixtures

    /// Register Edge 16 (his pad) and a cube edge: a synthetic id ≤ −1000; core's press stack's load is core's press_unit(d), its
    /// footprint the press's regions, columns > 0; a re-cut takes a new id and the old one is "not declared" in the new scene;
    /// core's press API is 2; the bridge's stack_of hands ids ≤ −1000 to fx::build_press_stack. RED: today's stack_of throws
    /// "face region −1000 is not declared".
    func testCoreStacksThePressThroughASyntheticKey() async throws {
        XCTAssertEqual(FlexibleScene.pressApiVersion, 2, "★ core's kPressApiVersion")
        for which in ["cube", "his pad"] {
            let m: FlexibleStageModel
            let c: FlexibleEdgeCandidates.Candidate
            if which == "cube" {
                m = try await F.cube(self).1
                let pick = try await F.M2.pickMode(m)
                c = try XCTUnwrap(F.anyEdge(pick))
            } else {
                m = try await F.hisPad(self).1
                c = try await F.edge16(m).c
            }
            let press = try await F.commit(m, c)
            try await FlexibleHisProject.waitFor(120, "\(which): the press registered") { m.pressKey(press.id) != nil }
            let id = try XCTUnwrap(m.pressKey(press.id))
            let st = try XCTUnwrap(m.pressStack(press.id))
            print("FLEX-E1-S \(which): \(FlexibleRowCopy.candidateLabel(c)) id \(id) · columns \(st.columns.count) · load \(st.load) · footprint \(st.footprintRegionIDs)")
            XCTAssertLessThanOrEqual(id, -1000, "★ a synthetic key")
            XCTAssertEqual(F.bits(st.load), F.bits(try XCTUnwrap(FlexiblePressAim.unit(press.direction))), "★ core's load is press_unit(d)")
            XCTAssertEqual(st.footprintRegionIDs, press.regions, "★ the footprint is the press's regions")
            XCTAssertGreaterThan(st.columns.count, 0)
            // a re-cut: a new scene, a new id; the old id is not declared there
            let why = await m.setFlatCut(press.id, depthMM: 2, direction: press.direction, snap: press.snap)
            XCTAssertNil(why, "the re-cut")
            try await FlexibleHisProject.waitFor(120, "\(which): re-registered") { (m.pressKey(press.id) ?? id) != id }
            let id2 = try XCTUnwrap(m.pressKey(press.id))
            XCTAssertNotEqual(id2, id, "★ a new id for a new cut (never reused)")
            do {
                _ = try await m.frameWorker.withScene { try $0.stack(face: id, rotation: 0) }
                XCTFail("★ the old id is not declared in the new scene")
            } catch {
                XCTAssertTrue("\(error)".contains("not declared"), "★ the old id: \(error)")
            }
        }
        // ★ the bridge's own seam (source pin): stack_of sends synthetic ids to core's press stack
        let src = try String(contentsOf: FlexibleHisProject.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptBridge/flexible_bridge.cpp"), encoding: .utf8)
        let body = try XCTUnwrap(src.range(of: "const fx::Stack& stack_of(").map { String(src[$0.lowerBound...].prefix(1800)) })
        XCTAssertTrue(body.contains("kSyntheticPressMax") && body.contains("fx::build_press_stack("), "★ stack_of dispatches ids ≤ −1000 to build_press_stack")
    }

    /// His live pad (Face 3's face-prism at 25 mm): a release at 20 mm LANDS on "Stops at N mm · the lattice ends there", N from
    /// core's columns over the 20 mm footprint — 25/√2 within one column pitch (the flat prism's wedge reaches the 25 mm slab's far
    /// side at h = 25/√2 on Face 2's rim). The cap read from the press's CURRENT stack (3 mm deep) is an upper bound (deeper adds rim
    /// columns); the release's check is exact. N reads each column's latticed run from its entry (FlexStackInfo.latticeRunMM). RED:
    /// the members' own stacks (the width's old default source) would let it go to 25 mm; core's whole-column lattice_mm (Face 5's
    /// prism far down the diagonal too) much further.
    /// (Corrected after the green run, our own new test: it asserted the CURRENT stack's cap == 25/√2, which holds only on the
    /// footprint at that depth.) ★ RE-PINNED by the R7-E1 review (ours; the verifier: "the drag runs to 46.1 mm, then the release
    /// springs back to 3 mm under a different number"; his wish of 2026-10-17 for every limit: "hard stop"): the release no longer
    /// stores nothing with a [Set N mm] — it lands on N (one Undo step) and the card keeps the line; FlexibleR7E1ReviewTests R4.
    func testTheDepthStopsWhereTheLatticeEnds() async throws {
        let (r, m) = try await F.hisLivePad(self)
        let (_, c, _) = try await F.edge16(m)
        let press = try await F.commit(m, c)
        try await FlexibleHisProject.waitFor(120, "registered") { m.pressStack(press.id) != nil }
        let st = try XCTUnwrap(m.pressStack(press.id))
        let upper = try XCTUnwrap(m.flatLatticeCap(press.id), "the cap from core's columns under the current footprint")
        let past = r.project.undo.past.count
        let why = await m.setFlatCut(press.id, depthMM: 20, direction: press.direction, snap: press.snap)
        try await F.M2.reopen(m, "landed")
        let n = try XCTUnwrap(m.press(press.id)).settings.deepestMM
        let total = (st.columns.map { $0.latticeMM + $0.entryT }.min() ?? 0) - (m.pressRegistrations[press.id]?.apexT ?? 0)
        print("FLEX-E1-S his live pad, Edge 16: release at 20 mm → \(why ?? "stored") · N \(n) (25/√2 = \(25 / 2.0.squareRoot())) · pitch \(st.pitchMM) · the 3 mm stack's cap \(upper) · with core's whole-column lattice_mm \(total)")
        XCTAssertEqual(n, 25 / 2.0.squareRoot(), accuracy: st.pitchMM, "★ the lattice ends at 25/√2, within one pitch")
        XCTAssertNil(why, "★ landed on N")
        XCTAssertEqual(m.lastFlatStop?.line, FlexibleRowCopy.flatLatticeEnds(n), "★ one line from core's number")
        XCTAssertEqual(m.lastFlatStop.map { $0.line.count <= 44 }, true)
        XCTAssertEqual(r.project.undo.past.count, past + 1, "★ one undo step")
        XCTAssertGreaterThanOrEqual(upper, n - 1e-9, "the current stack's cap is an upper bound")
        // ★ RED CONTROLS: the members' own stacks (I2's width default) — Face 3's lattice is 25 mm deep; and core's whole-column
        // lattice_mm (another face-prism far down the column) is no stop at all here
        let groupC = try XCTUnwrap(r.project.selection.groups.first { $0.name == "Group C" })
        let member = r.project.latticeSlabDepthMM(.face(group: groupC.id, face: 3), in: groupC.id)
        XCTAssertGreaterThan(member, n + 1, "★ RED CONTROL: the lattice depth under a member (25 mm) lets the wedge leave the lattice")
        XCTAssertGreaterThan(total, n + 5, "★ RED CONTROL: the whole column's lattice_mm runs on into Face 5's prism")
    }
}

@MainActor
final class FlexibleFlatPrismEngineTests: XCTestCase {
    typealias F = FlexibleFlatPrismFixtures
    typealias A = FlexibleFlatPrismAngles

    override func tearDown() {
        FlexibleStageModel.controlRefuseFlatCut = nil
        FlexibleStageModel.controlLiveFlatWrites = false
        super.tearDown()
    }

    static func bytes(_ s: FlexibleStageSettings?) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(s)
    }

    /// 20 drag samples (the chip, then the knob) write the PREVIEW only: the settings' bytes, the undo stack and core's scenes
    /// do not move. The release: setFlatCut once, one undo step, one scene open. Undo restores d, h, the pieces and the rests'
    /// settings; redo re-applies. RED: live writes (3 samples → 3 undo steps, 3 opens).
    func testOneDragIsOneEditOneUndoStepOneSceneOpen() async throws {
        let (r, m) = try await F.hisPad(self)
        let (_, c, _) = try await F.edge16(m)
        let press = try await F.commit(m, c)
        let p = r.project
        let s0 = try Self.bytes(p.lattice.flexible), past0 = p.undo.past.count, opens0 = m.frameWorker.door.opened
        let st = try XCTUnwrap(press.strip)
        let f = try XCTUnwrap(A.frame(st, d0: try XCTUnwrap(st.halfway), up: try XCTUnwrap(m.sceneInfo?.buildDir)))
        for k in 0..<10 { m.previewFlatCut(press.id, depthMM: 3 + 0.2 * Double(k), direction: nil) }
        for k in 0..<10 { m.previewFlatCut(press.id, depthMM: nil, direction: A.compose(f, theta: 2 * Double(k + 1), phi: 0)) }
        XCTAssertEqual(try Self.bytes(p.lattice.flexible), s0, "★ a drag writes nothing")
        XCTAssertEqual(p.undo.past.count, past0, "★ no undo step while dragging")
        XCTAssertEqual(m.frameWorker.door.opened, opens0, "★ no scene opened while dragging")
        XCTAssertEqual(try XCTUnwrap(m.flatCut(press.id)).depthMM, 4.8, accuracy: 1e-12, "the preview shows the drag")
        let why = await m.commitFlatPreview(press.id)
        XCTAssertNil(why, "the release")
        try await F.M2.reopen(m, "after the release")
        XCTAssertEqual(p.undo.past.count, past0 + 1, "★ one undo step")
        XCTAssertEqual(m.frameWorker.door.opened, opens0 + 1, "★ one scene open (the re-cut's, installed for the page)")
        let after = try XCTUnwrap(m.press(press.id))
        XCTAssertEqual(after.settings.deepestMM, 4.8, accuracy: 1e-12)
        XCTAssertEqual(A.decompose(f, after.direction).theta, 20, accuracy: 1e-9, "the knob's last tilt")
        XCTAssertNil(m.flatPreview, "the preview ends with the release")
        p.performUndo()
        try await F.M2.reopen(m, "undone")
        XCTAssertEqual(try Self.bytes(p.lattice.flexible), s0, "★ undo: d, h, the pieces and the rests' settings as they were")
        p.performRedo()
        try await F.M2.reopen(m, "redone")
        XCTAssertEqual(try XCTUnwrap(m.press(press.id)).settings.deepestMM, 4.8, accuracy: 1e-12, "redo re-applies")
        // ★ RED CONTROL: live writes — each sample a stored edit and a scene open
        FlexibleStageModel.controlLiveFlatWrites = true
        let past1 = p.undo.past.count, opens1 = m.frameWorker.door.opened
        for k in 0..<3 { m.previewFlatCut(press.id, depthMM: 5 + Double(k), direction: nil); await m.waitForIdle() }
        try await F.M2.reopen(m, "control")
        XCTAssertEqual(p.undo.past.count, past1 + 3, "★ RED CONTROL: 3 samples, 3 undo steps")
        XCTAssertGreaterThanOrEqual(m.frameWorker.door.opened, opens1 + 3, "★ RED CONTROL: 3 scene opens")
    }

    /// A release core refuses (an injected refusing verdict): nothing stored, the handle springs back (the preview ends), one plain
    /// line ≤ 44, no undo step.
    func testARefusedReleaseStoresNothing() async throws {
        let (r, m) = try await F.hisPad(self)
        let press = try await F.commit(m, try await F.edge16(m).c)
        let s0 = try Self.bytes(r.project.lattice.flexible), past0 = r.project.undo.past.count
        FlexibleStageModel.controlRefuseFlatCut = "press_direction does not point into the part over face region 3"
        m.previewFlatCut(press.id, depthMM: 6, direction: nil)
        let why = await m.commitFlatPreview(press.id)
        print("FLEX-E1-E refused: \(why ?? "-")")
        let line = try XCTUnwrap(why, "★ one line why")
        XCTAssertLessThanOrEqual(line.count, 44)
        XCTAssertTrue(line.contains("Arrow doesn't push into"), "core's refusal in plain words: \(line)")
        XCTAssertEqual(try Self.bytes(r.project.lattice.flexible), s0, "★ nothing stored")
        XCTAssertEqual(r.project.undo.past.count, past0, "★ no undo step")
        XCTAssertNil(m.flatPreview, "★ the handle springs back")
    }

    /// After releases at h = 2 then 20 the arrow's bits are the halfway's — stored at pick time from the WHOLE member faces — and
    /// never re-aimed. RED: core's halfway over the STRIPS (today's re-aim) has other bits.
    func testTheHalfwayIsTheWholeFacesAndNeverReAimed() async throws {
        let (_, m) = try await F.hisPad(self)
        let press = try await F.commit(m, try await F.edge16(m).c)
        let halfway = try XCTUnwrap(press.strip?.halfway)
        XCTAssertEqual(F.bits(press.direction), F.bits(halfway), "a new pick sits at its halfway")
        for h in [2.0, 20] {
            let why = await m.setFlatCut(press.id, depthMM: h, direction: halfway, snap: "halfway")
            XCTAssertNil(why, "h \(h)")
            try await F.M2.reopen(m, "h \(h)")
            let p = try XCTUnwrap(m.press(press.id))
            XCTAssertEqual(F.bits(p.direction), F.bits(halfway), "★ h \(h): the arrow is the halfway, bit for bit")
            XCTAssertEqual(p.snap, "halfway")
            XCTAssertEqual(p.settings.deepestMM, h, accuracy: 1e-12)
        }
        // ★ the engine asks core for NO halfway of the pieces (it never re-aims): the Flexible route's source has no aimSet call.
        // (Corrected after the green run, our own new test: its first control — "core's halfway on the strips has other bits" —
        // does not hold on his box pad, where a strip of a flat face has the face's own normal bit for bit; printed below. The red
        // is the engine before R7-E1, whose changeFlexibleStrips re-aimed every re-cut press on its strips.)
        let onStrips = try await m.pressAim(try XCTUnwrap(m.press(press.id)).regions)
        print("FLEX-E1-E halfway whole faces \(halfway) · on the strips \(onStrips.halfway.map { "\($0)" } ?? "-") (bit-equal \(onStrips.halfway.map { F.bits($0) == F.bits(halfway) } ?? false))")
        let src = try FlexibleSource.code("FlexibleStageModel+EdgePick.swift")
        let route = try XCTUnwrap(src.range(of: "func changeFlexibleStrips(").map { String(src[$0.lowerBound...]) })
        XCTAssertFalse(route.contains("aimSet("), "★ the Flexible route never re-aims a press from its pieces")
    }

    /// HIS strips saved with M2's width (Edge 16 and Edge 18 at 15 mm — his img_edges_1018's Group 3, rebuilt in M2's saved form on
    /// his pad: his live project no longer holds them) READ THROUGH: h = 15·sin 45°, the reach 15.000 on both faces, the same
    /// pieces (20 × 15 mm² each), the same role keys and sector numbers; widthMM is written nil only with his next edit of that
    /// press; one toast. A project with no strips reads byte-identical. RED: no read-through (3 mm → 4.24 mm reach).
    func testHisStripsReadThroughWithTheSameReach() async throws {
        let (r, m) = try await F.hisPad(self)
        let pick = try await F.M2.pickMode(m)
        let e16 = try XCTUnwrap(F.M2.edge(m, pick, faces: [3, 2])), e18 = try XCTUnwrap(F.M2.edge(m, pick, faces: [3, 4]))
        m.toggleEdgePick(e16.number); m.toggleEdgePick(e18.number)
        let doneWhy = try await F.M2.done(m)
        XCTAssertNil(doneWhy)
        // M2's saved form: each strip with widthMM 15 and no halfway, the press at its halfway (snap "halfway")
        var flex = try XCTUnwrap(r.project.lattice.flexible)
        flex.presses = flex.presses?.map { p in
            var q = p
            q.strip?.widthMM = 15
            q.strip?.halfway = nil
            q.settings.deepestMM = 3
            return q
        }
        let r2 = try FlexiblePressFixtures.a1Project(3, self)
        r2.project.lattice.flexible = flex
        r2.project.seedUndoBaseline()
        let m2 = try await FlexibleAngledGoldens.openModel(self, r2.project, "M2 form")
        try await FlexibleSquishFixture.settle(m2, "M2 form")
        let mesh = try XCTUnwrap(r2.project.viewerMesh)
        XCTAssertEqual(m2.toast, FlexibleRowCopy.stripsAreFlatNow, "★ one toast: \"Edge strips are flat prisms now · same reach\"")
        for p in m2.presses where p.strip != nil {
            let st = try XCTUnwrap(p.strip)
            let h = try XCTUnwrap(FlexibleFlatPrism.depth(of: p))
            XCTAssertEqual(h, 15 * sin(Double.pi / 4), accuracy: 1e-9, "★ \(st.label): 15 mm reads as 15·sin 45° deep")
            let cut = try XCTUnwrap(FlexibleFlatPrism.cut(of: p))
            for k in 0..<2 {
                XCTAssertEqual(try XCTUnwrap(FlexibleFlatPrism.reach(st, member: k, cut)), 15, accuracy: 1e-9, "★ the same 15 mm reach")
                let face = st.members[k].face
                let a = FlexibleEdgeStrips.area(FlexibleEdgeStrips.triangles(face: face, mesh: mesh), m2.regions.cuts(of: p.regions[k]))
                XCTAssertEqual(a, 20 * 15, accuracy: 1e-9 * 300, "★ the same piece (20 × 15 mm²)")
            }
            XCTAssertEqual(r2.project.lattice.flexible?.presses?.first { $0.id == p.id }?.strip?.widthMM, 15, "★ the file keeps its width until his next edit")
            // ★ RED CONTROL: no read-through — the stored 3 mm → 4.24 mm reach
            let raw = FlexibleFlatPrism.cut(st, direction: p.direction, depthMM: p.settings.deepestMM)
            XCTAssertNotEqual(try XCTUnwrap(FlexibleFlatPrism.reach(st, member: 0, raw)), 15, accuracy: 0.1, "★ RED CONTROL: 3 mm deep is a 4.24 mm reach")
        }
        let keys = Set((m2.regions.flexible?.pieces ?? []).map(\.key))
        let stored = r2.project.lattice.flexible?.sectors?.ids ?? [:]
        for k in keys where k.hasPrefix("p:") { XCTAssertEqual(m2.sectorNumbers.byKey[k], stored[k], "★ \(k): its number unchanged") }
        // his next edit of that press writes the flat form
        let first = try XCTUnwrap(m2.presses.first { $0.strip != nil })
        let why = await m2.setFlatCut(first.id, depthMM: 8, direction: first.direction, snap: first.snap)
        XCTAssertNil(why)
        try await F.M2.reopen(m2, "after his edit")
        let written = try XCTUnwrap(r2.project.lattice.flexible?.presses?.first { $0.id == first.id })
        XCTAssertNil(written.strip?.widthMM, "★ his next edit writes widthMM nil")
        XCTAssertEqual(written.settings.deepestMM, 8, accuracy: 1e-12, "★ and the depth")
        XCTAssertNotNil(written.strip?.halfway, "★ and the halfway it reads from")
        // a project with no strips: byte-identical
        let r3 = try FlexiblePressFixtures.a1Project(3, self)
        let raw0 = try Self.bytes(r3.project.lattice.flexible)
        let m3 = try await FlexibleAngledGoldens.openModel(self, r3.project, "no strips")
        try await FlexibleSquishFixture.settle(m3, "no strips")
        XCTAssertEqual(try Self.bytes(m3.rawSettings).count > 0, true)
        XCTAssertEqual(try Self.bytes(r3.project.lattice.flexible), raw0, "★ no strips: the file's bytes unchanged")
    }

    /// After a drag, a typed value and an Undo: the card's depth box, the chip's text, press.settings.deepestMM and the wedge's depth
    /// are one number; the Tilt / Twist boxes are decompose(d).
    func testOneStorePerNumber() async throws {
        let (r, m) = try await F.hisPad(self)
        let press = try await F.commit(m, try await F.edge16(m).c)
        m.selectedPress = press.id
        let st = try XCTUnwrap(press.strip)
        let f = try XCTUnwrap(A.frame(st, d0: try XCTUnwrap(st.halfway), up: try XCTUnwrap(m.sceneInfo?.buildDir)))
        func check(_ what: String) throws {
            let p = try XCTUnwrap(m.press(press.id))
            let shown = try XCTUnwrap(FlexibleFlatPrismUI.shown(model: m, press: press.id))
            let h = m.flatPreview?.depthMM ?? p.settings.deepestMM
            XCTAssertEqual(shown.depthMM, h, accuracy: 1e-12, "★ \(what): the card's box is the depth")
            XCTAssertEqual(shown.chipText, "\u{2193} " + String(format: "%.1f mm", h), "★ \(what): the chip says it")
            let item = try XCTUnwrap(FlexibleFlatPrismRender.items(model: m, k: 3).first)
            guard case .shell(let sh) = item.volume.shape else { return XCTFail() }
            XCTAssertEqual(sh.reachedDepthMM, h, accuracy: 1e-4, "★ \(what): the wedge is that deep")
            let a = A.decompose(f, m.flatPreview?.direction ?? p.direction)
            XCTAssertEqual(shown.tilt, a.theta, accuracy: 1e-9, "★ \(what): the Tilt box"); XCTAssertEqual(shown.twist, a.phi, accuracy: 1e-9)
        }
        m.previewFlatCut(press.id, depthMM: 5.5, direction: A.compose(f, theta: 12, phi: 0))
        try check("mid-drag")
        let rel = await m.commitFlatPreview(press.id)
        XCTAssertNil(rel, "the release stored")
        try await F.M2.reopen(m, "released")
        try check("released")
        // (corrected after the green run, our own new test: 7.25 mm twisted 6° reaches past his 20 mm pad's Top at the deep end —
        // core's columns leave the lattice at 4.9 mm there, and the engine rightly refused it; the typed edit is untwisted)
        let typed = await m.setFlatCut(press.id, depthMM: 7.25, direction: A.compose(f, theta: 12, phi: 0), snap: nil)
        XCTAssertNil(typed, "the typed values stored")
        try await F.M2.reopen(m, "typed")
        try check("typed")
        r.project.performUndo()
        try await F.M2.reopen(m, "undone")
        try check("undone")
        XCTAssertEqual(try XCTUnwrap(m.press(press.id)).settings.deepestMM, 5.5, accuracy: 1e-12)
        // a TYPED 2° stays 2° (the snap is for drags only)
        let typed2 = await m.setFlatCut(press.id, depthMM: 5.5, direction: A.compose(f, theta: 2, phi: 0), snap: nil)
        XCTAssertNil(typed2, "the typed 2° stored")
        try await F.M2.reopen(m, "typed 2°")
        XCTAssertEqual(A.decompose(f, try XCTUnwrap(m.press(press.id)).direction).theta, 2, accuracy: 1e-9, "★ a typed 2° stays 2°")
    }
}
