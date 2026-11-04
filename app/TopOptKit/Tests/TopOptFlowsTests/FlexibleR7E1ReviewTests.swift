// FlexibleR7E1ReviewTests — round 7, the review of R7-E1 (the edge/corner FLAT PRISM): what the two verifiers found, each fix
// written as a test FIRST, against stubs, with its RED CONTROL inside the test. His words (2026-10-18): "There shouldn't be a
// strip width. It should be a Flat prism that gets wider as it gets dragged further towards the centre of the model from the
// edge. We should be able to change the angle up/down and left/right of the prism." His answers: the twist stops when the shallow
// end reaches 0 mm; the half-face rule is dropped — "the flat prism goes as deep as the lattice allows, as long as each face
// keeps some of itself". His wish of 2026-10-17 for every limit: "impossible to set … farther than a lattice can bend … (hard stop
// and/or a pop-up after it is attempted)". The reviewer's rulings: nothing app-side stands in as the limit — the depth is capped
// by the lattice/geometry from core's columns.
//   R1 (blocker) at Balanced, core leaves the Top's surface voxel layer Empty: the lattice stop read every column entering through
//      the Top as 0 mm of lattice, so the Top + Face 2 edge and the Top corner were refused at [Done] ("Stops at 0.4 mm").
//   R2 a new pick the lattice stops below 3 mm starts AT the stop (said), instead of a [Done] that fails with no fix.
//   R3 (blocker) "each face keeps some of itself" held per press only: two flat prisms on one face could take it all, and its
//      rest fell back to the WHOLE face — overlapping both (core's shared_footprint).
//   R4 the lattice stop is a HARD stop: a release past it lands on it (one Undo step, said), and the next drag stops there.
//   R5 an ANGLE the lattice stops is said as an angle ("Twist stops at X°"), landed there — never a depth that drops the angle.
//   R6 the knob's drag is a pure function (the hosted page cannot drive it), its boxes named in his words, the pick list's and the
//      (i)'s plain words.
//   R7 a flat corner's rest is pressed in a TURNED frame (core's principal axis): its column quads stepped past the Top's outer
//      edges and left notches (the sawtooth) — now they stop at the face's edge and the edge is filled.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleR7E1ReviewTests: XCTestCase {
    typealias F = FlexibleFlatPrismFixtures
    typealias A = FlexibleFlatPrismAngles

    override func tearDown() {
        FlexibleScene.controlRunFromFirstSample = false
        FlexibleStageModel.controlNoStartHold = false
        FlexibleStageModel.controlPerPressRest = false
        FlexibleStageModel.controlNoLatticeLanding = false
        FlexibleOverlayMesh.controlNoEdgeFill = false
        super.tearDown()
    }

    /// His pad (A1_0003 + the Top's 20 mm face-prism: the whole pad latticed) at `q`, opened and settled.
    func pad(_ q: RunQuality) async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        r.project.quality = q
        let m = try await FlexibleAngledGoldens.openModel(self, r.project, "A1_0003 \(q.rawValue)")
        try await FlexibleSquishFixture.settle(m, "A1_0003 \(q.rawValue)")
        return (r, m)
    }

    /// His LIVE project (2026-10-18 15:06, Balanced: Group C = Face 3 + Face 5, Protect + Lattice), opened and settled;
    /// `prismMM`: Group C's face-prisms set to that depth first (the main page's own setter).
    func live(prismMM: Double? = nil) async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        try FlexibleTopLayerFixtures.assertHisFiles()
        let r = try FlexibleHisProject.restore(FlexibleTopLayerFixtures.liveDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        if let mm = prismMM {
            let c = try XCTUnwrap(r.project.selection.groups.first { $0.name == "Group C" }, "his Group C")
            for f in [FaceID(3), FaceID(5)] { r.project.writeLatticeDepthMM(.face(group: c.id, face: f), mm: mm) }
        }
        let m = try await FlexibleAngledGoldens.openModel(self, r.project, "his live")
        try await FlexibleSquishFixture.settle(m, "his live")
        return (r, m)
    }

    /// The candidate on exactly `faces` (an edge, or a corner with `corner`).
    func candidate(_ m: FlexibleStageModel, _ p: FlexibleEdgePick, _ faces: Set<Int>, corner: Bool = false) -> FlexibleEdgeCandidates.Candidate? {
        corner ? F.corner(m, p, faces: faces) : F.M2.edge(m, p, faces: faces)
    }

    /// Core's press stack's columns that core says are latticed but whose run from the entry the bridge reads as 0.
    func zeroRuns(_ st: FlexStackInfo) -> Int {
        st.columns.indices.filter { st.latticeRunMM.count == st.columns.count && st.latticeRunMM[$0] == 0 && st.columns[$0].latticeMM > 0 }.count
    }

    // MARK: - R1 + R2

    /// R1. His pad at BALANCED (his own quality): 19.2 of core's 1.04 mm voxels tall, so core leaves the Top's surface layer Empty
    /// (centres at z 20.31). [Done] on the Top + Face 2 edge and on the Top corner stores the flat prism 3 mm deep, with a cap from
    /// core's columns well past it, and no latticed column reads 0 mm of lattice. His live Edge (Face 3 + Face 2) still stores. RED
    /// CONTROL (E1's rule, the run counted from the first sample): "Stops at 0.4 mm · the lattice ends there", nothing stored.
    func testTheTopEdgeAndTheCornerStoreAtBalanced() async throws {
        for (faces, corner) in [(Set([1, 2]), false), (Set([1, 2, 3]), true)] {
            let (r, m) = try await pad(.balanced)
            // ★ RED CONTROL first: E1's run from the first sample
            FlexibleScene.controlRunFromFirstSample = true
            var pick = try await F.M2.pickMode(m)
            var c = try XCTUnwrap(candidate(m, pick, faces, corner: corner), "\(faces.sorted()) at Balanced")
            XCTAssertNil(pick.greyed[c.number], "\(FlexibleRowCopy.candidateLabel(c)) is offered")
            let before = r.project.lattice.flexible, past = r.project.undo.past.count
            m.toggleEdgePick(c.number)
            let red = try await F.M2.done(m)
            print("FLEX-E1R-R1 RED CONTROL \(faces.sorted()) Balanced: [Done] → \(red ?? "stored")")
            XCTAssertTrue(red?.hasPrefix("Stops at 0.") ?? false, "★ RED CONTROL: E1's run stops the Top's columns at core's Empty surface voxel: \(red ?? "stored")")
            XCTAssertEqual(r.project.lattice.flexible, before, "RED CONTROL: nothing stored")
            XCTAssertEqual(r.project.undo.past.count, past)
            m.cancelEdgePick()
            FlexibleScene.controlRunFromFirstSample = false
            // the fix
            pick = try await F.M2.pickMode(m)
            c = try XCTUnwrap(candidate(m, pick, faces, corner: corner))
            m.toggleEdgePick(c.number)
            let why = try await F.M2.done(m)
            XCTAssertNil(why, "★ \(FlexibleRowCopy.candidateLabel(c)) at Balanced: [Done] stores the flat prism")
            let press = try XCTUnwrap(m.presses.last { $0.strip?.label == FlexibleRowCopy.candidateLabel(c) })
            XCTAssertEqual(press.settings.deepestMM, FlexibleFlatPrism.defaultDepthMM, "★ 3 mm deep")
            try await FlexibleHisProject.waitFor(120, "registered") { m.pressStack(press.id) != nil }
            let st = try XCTUnwrap(m.pressStack(press.id))
            let cap = try XCTUnwrap(m.flatLatticeCap(press.id))
            print("FLEX-E1R-R1 \(FlexibleRowCopy.candidateLabel(c)) \(faces.sorted()) Balanced: columns \(st.columns.count) · zero runs \(zeroRuns(st)) · cap \(cap)")
            XCTAssertEqual(zeroRuns(st), 0, "★ no latticed column reads 0 mm of lattice")
            XCTAssertGreaterThan(cap, 10, "★ the cap from core's columns is well past 3 mm on a 20 mm pad latticed through")
        }
        // his live project (Balanced): the side edge stores as before
        let (_, m) = try await live()
        let pick = try await F.M2.pickMode(m)
        let c = try XCTUnwrap(candidate(m, pick, [3, 2]), "his Edge: Face 3 + Face 2")
        m.toggleEdgePick(c.number)
        let why = try await F.M2.done(m)
        XCTAssertNil(why, "★ his live side edge stores")
    }

    /// R2. His live project with Group C's face-prisms at 2 mm: core's columns stop the flat prism below a new pick's 3 mm (at
    /// halfway it reaches the 2 mm slab's far side at 2/√2 = 1.4 mm, within a column pitch). [Done] starts it AT the stop (≥ 0.5
    /// mm), says so in one line, one Undo step. RED CONTROL (E1): [Done] refused, nothing stored.
    /// (Written at 4 mm against the stubs; the red run showed core's columns allow 3.6 mm there — the case moved to 2 mm.)
    func testANewPickStartsAtTheLatticeStop() async throws {
        let (r, m) = try await live(prismMM: 2)
        // ★ RED CONTROL first
        FlexibleStageModel.controlNoStartHold = true
        var pick = try await F.M2.pickMode(m)
        var c = try XCTUnwrap(candidate(m, pick, [3, 2]), "his Edge: Face 3 + Face 2")
        XCTAssertNil(pick.greyed[c.number], "offered: \(pick.greyed[c.number] ?? "")")
        let before = r.project.lattice.flexible
        m.toggleEdgePick(c.number)
        let red = try await F.M2.done(m)
        print("FLEX-E1R-R2 RED CONTROL: [Done] → \(red ?? "stored")")
        XCTAssertTrue(red?.contains("the lattice ends there") ?? false, "★ RED CONTROL: E1 refuses the pick: \(red ?? "stored")")
        XCTAssertEqual(r.project.lattice.flexible, before)
        m.cancelEdgePick()
        FlexibleStageModel.controlNoStartHold = false
        // the fix
        let past = r.project.undo.past.count
        pick = try await F.M2.pickMode(m)
        c = try XCTUnwrap(candidate(m, pick, [3, 2]))
        m.toggleEdgePick(c.number)
        let why = try await F.M2.done(m)
        XCTAssertNil(why, "★ [Done] stores it at the stop")
        let press = try XCTUnwrap(m.presses.last { $0.strip?.label == FlexibleRowCopy.candidateLabel(c) })
        let h = press.settings.deepestMM
        print("FLEX-E1R-R2 started at \(h) mm (2/√2 = \(2 / 2.0.squareRoot())) · toast \(m.toast ?? "-")")
        XCTAssertLessThan(h, FlexibleFlatPrism.defaultDepthMM, "★ below the 3 mm default")
        XCTAssertGreaterThanOrEqual(h, FlexibleFlatPrism.minDepthMM)
        XCTAssertEqual(h, 2 / 2.0.squareRoot(), accuracy: 1.1, "★ at the slab's far side, within a column pitch")
        XCTAssertEqual(m.lastFlatStop?.line, FlexibleRowCopy.flatLatticeEnds(h), "★ the card says where it stopped")
        XCTAssertEqual(m.toast, FlexibleRowCopy.flatStartsAt(h), "★ said in one line")
        XCTAssertLessThanOrEqual(FlexibleRowCopy.flatStartsAt(h).count, 44)
        XCTAssertEqual(r.project.undo.past.count, past + 1, "★ one Undo step")
    }

    // MARK: - R3

    /// R3. His pad (Fast, the whole pad latticed): two flat prisms on Face 3 — its edges with Face 2 and with Face 4. The first goes
    /// to 40 mm (its wedge reaches 56.6 mm across Face 3); the second, typed 40 mm, is HELD where Face 3 still keeps 0.5 mm of itself
    /// ("Held at … · Face 3 keeps the rest"), its drag stops there too, and Face 3 keeps a rest piece — no surface in two entries,
    /// no shared footprint. RED CONTROL (E1's per-press check): stored at 40 mm, Face 3's rest the WHOLE face over both pieces.
    func testEachFaceKeepsSomeOfItselfUnderTwoPresses() async throws {
        for control in [true, false] {
            FlexibleStageModel.controlPerPressRest = control
            let (r, m) = try await F.hisPad(self)
            let mesh = try XCTUnwrap(r.project.viewerMesh)
            let pick = try await F.M2.pickMode(m)
            let e1 = try XCTUnwrap(candidate(m, pick, [3, 2])), e2 = try XCTUnwrap(candidate(m, pick, [3, 4]))
            m.toggleEdgePick(e1.number); m.toggleEdgePick(e2.number)
            let w0 = try await F.M2.done(m)
            XCTAssertNil(w0, "[Done] on both")
            let p1 = try XCTUnwrap(m.presses.last { $0.strip?.label == FlexibleRowCopy.candidateLabel(e1) })
            let p2 = try XCTUnwrap(m.presses.last { $0.strip?.label == FlexibleRowCopy.candidateLabel(e2) })
            let w1 = await m.setFlatCut(p1.id, depthMM: 40, direction: p1.direction, snap: p1.snap)
            XCTAssertNil(w1, "the first to 40 mm")
            try await F.M2.reopen(m, "first at 40")
            let q2 = try XCTUnwrap(m.press(p2.id))
            m.toast = nil
            let why = await m.setFlatCut(p2.id, depthMM: 40, direction: q2.direction, snap: q2.snap)
            try await F.M2.reopen(m, "second typed 40")
            let h2 = try XCTUnwrap(m.press(p2.id)).settings.deepestMM
            let face3 = FlexibleEdgeStrips.triangles(face: 3, mesh: mesh)
            let rests = m.settings.faces.filter { m.regions.faces(of: $0.faceRegionID, mesh: mesh) == [3] }
            let restArea = rests.map { FlexibleEdgeStrips.area(face3, m.regions.cuts(of: $0.faceRegionID)) }.reduce(0, +)
            let shared = FlexibleEdgeStrips.sharedSurface(m.settings, regions: m.regions, mesh: mesh)
            let twice = FlexibleEdgeStrips.regionsInTwoEntries(m.settings)
            print("FLEX-E1R-R3 control \(control): second → \(why ?? "stored") at \(h2) mm · toast \(m.toast ?? "-") · Face 3 rest \(restArea) mm² (\(rests.map(\.faceRegionID))) · shared \(shared) · twice \(twice)")
            if control {
                XCTAssertEqual(h2, 40, "RED CONTROL: stored at 40")
                XCTAssertFalse(shared.isEmpty && restArea < 1999, "★ RED CONTROL: Face 3's rest is the whole face over both pieces (shared \(shared), rest \(restArea))")
                continue
            }
            XCTAssertNil(why, "held, then stored")
            XCTAssertLessThan(h2, 40, "★ held short of 40 mm")
            XCTAssertTrue(m.toast?.hasPrefix("Held at ") ?? false, "★ the hold is said: \(m.toast ?? "-")")
            XCTAssertTrue(m.toast?.hasSuffix("Face 3 keeps the rest") ?? false, "★ his rule named: \(m.toast ?? "-")")
            XCTAssertGreaterThan(restArea, 0.5 * 20 - 1e-6, "★ Face 3 keeps at least 0.5 mm of itself across its 20 mm")
            XCTAssertLessThan(restArea, 2000 - 1, "Face 3's rest is not the whole face")
            XCTAssertTrue(shared.isEmpty, "★ no shared footprint")
            XCTAssertTrue(twice.isEmpty, "★ no surface in two entries")
            // its drag stops there too
            let q = try XCTUnwrap(m.press(p2.id)), st = try XCTUnwrap(q.strip)
            let range = A.depthRange(st, d: q.direction, limits: m.flatLimits(q.id, withLattice: false))
            XCTAssertEqual(range.max, h2, accuracy: 1e-6, "★ the drag stops where the hold did")
            if case .rest = range.maxStop {} else { XCTFail("★ the drag's stop is his rule: \(String(describing: range.maxStop))") }
        }
    }

    // MARK: - R4

    /// R4. His live form (Face 3's face-prism 25 mm): a release at 20 mm on the Face 3 + Face 2 edge LANDS on core's stop N (25/√2
    /// within a pitch): stored at N, one Undo step, "Stops at N mm · the lattice ends there" on the card, the hold said; the next drag
    /// stops at exactly N. RED CONTROL (E1): nothing stored, the depth back at 3 mm, and the drag's stop the current footprint's
    /// upper bound — past N.
    func testTheLatticeStopIsAHardStop() async throws {
        for control in [true, false] {
            FlexibleStageModel.controlNoLatticeLanding = control
            let (r, m) = try await F.hisLivePad(self)
            let (_, c, _) = try await F.edge16(m)
            let press = try await F.commit(m, c)
            try await FlexibleHisProject.waitFor(120, "registered") { m.pressStack(press.id) != nil }
            let upper = try XCTUnwrap(m.flatLatticeCap(press.id))
            let past = r.project.undo.past.count
            let why = await m.setFlatCut(press.id, depthMM: 20, direction: press.direction, snap: press.snap)
            try await F.M2.reopen(m, "after the release")
            let h = try XCTUnwrap(m.press(press.id)).settings.deepestMM
            print("FLEX-E1R-R4 control \(control): release at 20 → \(why ?? "stored") · depth \(h) · stop \(m.lastFlatStop.map { "\($0.line) [\($0.setMM ?? -1)]" } ?? "-") · toast \(m.toast ?? "-") · upper \(upper)")
            if control {
                XCTAssertEqual(h, FlexibleFlatPrism.defaultDepthMM, "RED CONTROL: back at 3 mm")
                XCTAssertGreaterThan(upper, (m.lastFlatStop?.setMM ?? 0) + 0.5, "★ RED CONTROL: the drag's stop is past core's N")
                continue
            }
            XCTAssertNil(why, "★ landed: stored")
            XCTAssertEqual(h, 25 / 2.0.squareRoot(), accuracy: try XCTUnwrap(m.pressStack(press.id)).pitchMM, "★ at core's stop, 25/√2 within a pitch")
            XCTAssertLessThan(h, 20)
            XCTAssertEqual(r.project.undo.past.count, past + 1, "★ one Undo step")
            XCTAssertEqual(m.lastFlatStop?.line, FlexibleRowCopy.flatLatticeEnds(h), "★ the card says where it stopped")
            XCTAssertNil(m.lastFlatStop?.setMM, "nothing to set: it is set")
            XCTAssertTrue(m.toast?.hasPrefix("Held at ") ?? false, "★ the hold is said: \(m.toast ?? "-")")
            // the next drag stops exactly there
            let q = try XCTUnwrap(m.press(press.id)), st = try XCTUnwrap(q.strip)
            let range = A.depthRange(st, d: q.direction, limits: m.flatLimits(q.id, withLattice: true))
            XCTAssertEqual(range.max, h, accuracy: 1e-9, "★ the drag's hard stop is core's N")
            XCTAssertEqual(range.maxStop, .lattice(h), "★ and its line is the card's")
        }
    }

    // MARK: - R5

    /// R5. His live project (Balanced), the Face 3 + Face 2 edge 10 mm deep: a typed twist of 5° leaves core's lattice (the deep
    /// end's columns reach core's Empty top voxel layer). It lands on the last twist the lattice allows, the depth KEPT, and the line
    /// names the angle: "Twist stops at X° · lattice ends". RED CONTROL (E1): a depth line ("Stops at 4.3 mm …") whose fix is the
    /// stored, untwisted arrow.
    /// (Written on the Fast live form at 3 mm and 8.5° against the stubs — the verifier's case on his simulator project; with the
    /// bridge's entry rule (R1) that twist fits, and on Fast 5° at 10 mm fits too — the case moved to his live project at 10 mm.)
    func testAnAngleTheLatticeStopsIsSaidAsAnAngle() async throws {
        for control in [true, false] {
            FlexibleStageModel.controlNoLatticeLanding = control
            let (_, m) = try await live()
            let pick = try await F.M2.pickMode(m)
            let c = try XCTUnwrap(candidate(m, pick, [3, 2]), "his Edge: Face 3 + Face 2")
            let p0 = try await F.commit(m, c)
            let w10 = await m.setFlatCut(p0.id, depthMM: 10, direction: p0.direction, snap: p0.snap)
            XCTAssertNil(w10, "10 mm deep")
            try await F.M2.reopen(m, "10 mm")
            let press = try XCTUnwrap(m.press(p0.id))
            try await FlexibleHisProject.waitFor(120, "registered") { m.pressStack(press.id) != nil }
            let why = await m.setFlatAngle(press.id, degrees: 5, tilt: false)
            try await F.M2.reopen(m, "after the typed twist")
            let q = try XCTUnwrap(m.press(press.id))
            let f = try XCTUnwrap(FlexibleFlatPrismUI.frame(m, press.id))
            let a = A.decompose(f, q.direction)
            print("FLEX-E1R-R5 control \(control): typed twist 5° at 10 mm → \(why ?? "stored") · now tilt \(a.theta) twist \(a.phi) depth \(q.settings.deepestMM) · stop \(m.lastFlatStop.map { "\($0.line) [\($0.setMM ?? -1)] dir \($0.direction.map { "\($0)" } ?? "the press's")" } ?? "-")")
            if control {
                XCTAssertTrue(why?.hasPrefix("Stops at ") ?? false, "★ RED CONTROL: E1 says a depth: \(why ?? "stored")")
                XCTAssertNil(m.lastFlatStop?.direction, "★ RED CONTROL: its fix is the stored (untwisted) arrow")
                continue
            }
            if why == nil, abs(a.phi - 5) < 0.05 {
                XCTFail("the lattice did not stop this twist on his live project — the case no longer reproduces")
                continue
            }
            XCTAssertNil(why, "★ landed on the angle the lattice allows")
            XCTAssertGreaterThan(a.phi, 0.1, "★ the twist is kept, short of 5°")
            XCTAssertLessThan(a.phi, 5)
            XCTAssertEqual(a.theta, 0, accuracy: 0.05, "the tilt untouched")
            XCTAssertEqual(q.settings.deepestMM, 10, accuracy: 1e-9, "★ the depth kept")
            let line = try XCTUnwrap(m.lastFlatStop?.line)
            XCTAssertEqual(line, FlexibleRowCopy.flatAngleStops(twist: true, corner: false, deg: a.phi, steep: true), "★ said as an angle")   // ★ re-pinned (R7-E1b, his 2026-10-19 note: Tilt = up/down — on his steep Edge 16 the along-edge angle is "Tilt")
            XCTAssertLessThanOrEqual(line.count, 44)
            XCTAssertFalse(line.contains(" mm"), "★ never a depth")
        }
    }

    // MARK: - R6

    /// R6. The knob's drag, pure: solved on the screen jacobian, each angle snapped to 0 within 3°; looking down the arrow, the
    /// trackball (0.5° per point). RED (the stub): the drag moves nothing.
    func testTheKnobDragIsPure() {
        let jac = (a: CGVector(dx: 0, dy: -8), b: CGVector(dx: 6, dy: 0))   // 8 pt up per degree of tilt, 6 pt right per degree of twist
        let k = FlexibleFlatPrismKnob.self
        var r = k.angles(start: (0, 0), translation: CGSize(width: 30, height: 0), jac: jac)
        XCTAssertEqual(r.theta, 0, accuracy: 1e-12); XCTAssertEqual(r.phi, 5, accuracy: 1e-12, "★ right = twist")
        r = k.angles(start: (0, 0), translation: CGSize(width: 0, height: -40), jac: jac)
        XCTAssertEqual(r.theta, 5, accuracy: 1e-12, "★ up = tilt"); XCTAssertEqual(r.phi, 0, accuracy: 1e-12)
        r = k.angles(start: (0, 0), translation: CGSize(width: 12, height: -16), jac: jac)
        XCTAssertEqual(r.theta, 0, "★ 2° snaps back to halfway"); XCTAssertEqual(r.phi, 0, "★ 2° snaps back to halfway")
        r = k.angles(start: (10, -4), translation: CGSize(width: 6, height: 8), jac: jac)
        XCTAssertEqual(r.theta, 9, accuracy: 1e-12); XCTAssertEqual(r.phi, -3, accuracy: 1e-12, "3° stays (the snap is under 3°)")
        r = k.angles(start: (0, 0), translation: CGSize(width: 20, height: -10), jac: nil)
        XCTAssertEqual(r.phi, 10, accuracy: 1e-12, "★ the trackball: 0.5° per point across"); XCTAssertEqual(r.theta, 5, accuracy: 1e-12, "★ and up")
        // the boxes name their angle in his row words (on a vertical edge a sideways drag tilts: an arrow glyph said the opposite)
        XCTAssertEqual(FlexibleFlatPrismUI.boxLabel(tilt: true, corner: false), "Tilt")
        XCTAssertEqual(FlexibleFlatPrismUI.boxLabel(tilt: false, corner: false), "Twist")
        XCTAssertEqual(FlexibleFlatPrismUI.boxLabel(tilt: true, corner: true), "Up/down")
        XCTAssertEqual(FlexibleFlatPrismUI.boxLabel(tilt: false, corner: true), "Left/right")
    }

    /// R6. Plain words: a removed member's reason fits one line whole (it was cut mid-word: "Face 1 · lattice A was taken out of the
    /// Fle…"); no "strip" on a curved edge; the (i) texts name no "core's columns" / "core's halfway". RED: the old words.
    func testPlainWords() {
        let removed = FlexibleRowCopy.outOfFlexible("Face 1 \u{00B7} lattice A")
        XCTAssertLessThanOrEqual(removed.count, 44, "★ one line: \(removed)")
        XCTAssertFalse(removed.contains("\u{2026}"), "★ whole, not cut: \(removed)")
        XCTAssertFalse(FlexibleRowCopy.stripCurvedEdge.lowercased().contains("strip"), "★ no strip: \(FlexibleRowCopy.stripCurvedEdge)")
        for t in [FlexibleRowCopy.Info.flatDepth, FlexibleRowCopy.Info.flatTilt, FlexibleRowCopy.Info.flatUpDown, FlexibleRowCopy.Info.flatLeftRight] {
            XCTAssertFalse(t.contains("core's"), "★ his plain words: \(t)")
        }
    }

    // MARK: - R7

    /// R7. His pad, Corner (Faces 1 + 2 + 3) [Done]: the Top's rest (his Group 1 press) is a pentagon, so core frames it on its
    /// principal axis — turned to the Top's edges. Its column quads now stop at the Top's outer edge and behind its own cut line
    /// (none past either by more than a micron), and the band along every outer edge and along the cut is covered (a point 0.2 mm
    /// inside each, every 0.5 mm, lies on a drawn triangle of the Top). RED CONTROL (the quads as they come): quads past the edge
    /// and notches along it — the sawtooth. (The cut line's checks were added after the red run, found by looking at the corner.)
    func testACornersTurnedRestHasNoSawtooth() async throws {
        let (r, m) = try await F.hisPad(self)
        let mesh = try XCTUnwrap(r.project.viewerMesh)
        let pick = try await F.M2.pickMode(m)
        let c = try XCTUnwrap(F.corner(m, pick, faces: [1, 2, 3]), "Corner: Faces 1 + 2 + 3")
        _ = try await F.commit(m, c)
        try await F.M2.reopen(m, "after the corner")
        let topKey = try XCTUnwrap(m.loadedKeys.first { m.regions.faces(of: $0.region, mesh: mesh) == [1] && !m.regions.cuts(of: $0.region).isEmpty },
                                   "the Top's rest is pressed (his Group 1)")
        let st = try XCTUnwrap(m.stacks[topKey])
        let top = FlexibleEdgeStrips.triangles(face: 1, mesh: mesh)
        let xs = top.flatMap { $0.map(\.x) }, ys = top.flatMap { $0.map(\.y) }
        let lo = SIMD2(xs.min()!, ys.min()!), hi = SIMD2(xs.max()!, ys.max()!)
        print("FLEX-E1R-R7 the Top's rest frame x \(st.xAxis) · pitch \(st.pitchMM) · columns \(st.columns.count) · Top \(lo)…\(hi)")
        XCTAssertGreaterThan(Swift.min(abs(st.xAxis.x), abs(st.xAxis.y)), 0.1, "the case: core's frame is turned to the Top's edges")
        // ★ found by looking at the corner's picture (after the red run): the rest's own cut line (the corner's diagonal) stepped
        // too — the quads behind it and the band along it are checked the same way
        let cutLines = m.regions.cuts(of: topKey.region).filter { abs($0.normal.z) < 1e-9 && simd_length($0.normal) > 1e-12 }
            .map { RegionCut(point: $0.point, normal: simd_normalize($0.normal)) }
        XCTAssertFalse(cutLines.isEmpty, "the Top's rest has its in-face cut (the corner's)")
        func measure() throws -> (past: Double, notches: Int, samples: Int) {
            let o = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
            let start = try XCTUnwrap(o.flatStart[topKey])
            let pos = o.mesh.flat.positions
            var past = 0.0
            for v in start..<(start + 6 * st.columns.count) {
                let x = Double(pos[3 * v]), y = Double(pos[3 * v + 1])
                past = Swift.max(past, lo.x - x, x - hi.x, lo.y - y, y - hi.y)
                for c in cutLines { past = Swift.max(past, -simd_dot(SIMD3(x, y, c.point.z) - c.point, c.normal)) }
            }
            // the Top's drawn triangles (its face id, near its plane), in plan
            var tris: [[SIMD2<Double>]] = []
            let n = o.mesh.flat.vertexCount / 3
            for t in 0..<n where t < o.mesh.faceIDs.count && Int(o.mesh.faceIDs[t]) == 1 {
                let p = (0..<3).map { j in SIMD2(Double(pos[3 * (3 * t + j)]), Double(pos[3 * (3 * t + j) + 1])) }
                tris.append(p)
            }
            func inside(_ q: SIMD2<Double>) -> Bool {
                tris.contains { t in
                    func s(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { (b.x - a.x) * (q.y - a.y) - (b.y - a.y) * (q.x - a.x) }
                    let d0 = s(t[0], t[1]), d1 = s(t[1], t[2]), d2 = s(t[2], t[0])
                    return (d0 >= -1e-9 && d1 >= -1e-9 && d2 >= -1e-9) || (d0 <= 1e-9 && d1 <= 1e-9 && d2 <= 1e-9)
                }
            }
            var samples: [SIMD2<Double>] = []
            var s = lo.x + 0.25
            while s < hi.x - 0.25 { samples += [SIMD2(s, lo.y + 0.2), SIMD2(s, hi.y - 0.2)]; s += 0.5 }
            s = lo.y + 0.25
            while s < hi.y - 0.25 { samples += [SIMD2(lo.x + 0.2, s), SIMD2(hi.x - 0.2, s)]; s += 0.5 }
            // along each cut line, 0.2 mm inside the rest, inside the Top
            for c in cutLines {
                let n2 = SIMD2(c.normal.x, c.normal.y), along = SIMD2(-c.normal.y, c.normal.x)
                let p0 = SIMD2(c.point.x, c.point.y) + n2 * 0.2
                var t = -150.0
                while t < 150 {
                    let q = p0 + along * t
                    if q.x > lo.x + 0.25, q.x < hi.x - 0.25, q.y > lo.y + 0.25, q.y < hi.y - 0.25 { samples.append(q) }
                    t += 0.5
                }
            }
            return (past, samples.filter { !inside($0) }.count, samples.count)
        }
        FlexibleOverlayMesh.controlNoEdgeFill = true
        let red = try measure()
        FlexibleOverlayMesh.controlNoEdgeFill = false
        let got = try measure()
        print("FLEX-E1R-R7 RED CONTROL: quads past the edge by \(red.past) mm · notches \(red.notches)/\(red.samples) · the fix: \(got.past) mm · \(got.notches)/\(got.samples)")
        XCTAssertGreaterThan(red.past, 0.05, "★ RED CONTROL: quads step past the Top's edge")
        XCTAssertGreaterThan(red.notches, 0, "★ RED CONTROL: notches along the edge")
        XCTAssertLessThan(got.past, 1e-3, "★ no quad past the Top's outer edge")
        XCTAssertEqual(got.notches, 0, "★ the band along every outer edge is covered")
    }
}
