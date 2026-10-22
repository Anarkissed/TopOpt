// FlexibleI2AttachTests — round 7 · U21 batch I, part I2: the Attach tool's pure half (the walls, the steps, the links, undo,
// staying out of the job), on HIS projects (round7/batch_u21/his_live_1021_lbracket, his_live_1021_pad) and two small meshes.
//   His answer of 2026-10-21 ~15:35: "I did a negative expansion. I expect the 4 walls around the lattice to hold the lattice up
//   … you can select any wall of the lattice and select any wall of the solid/non-latriced areas and link them together … you
//   should be able to do this multiple times per lattice object." His picks ~15:45: targets = only the solid a wall touches;
//   one-tap "Attach to the 4 walls around it" (nothing set until he taps); the link listed under the lattice with a trash that
//   asks first. Every RED control is asserted red inside its test.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleI2AttachTests: XCTestCase {
    nonisolated static let groupB = UUID(uuidString: "B91ED058-A180-4125-8E82-420B89D45B79")!
    static let groupC = UUID(uuidString: "91596E96-9198-4738-B730-F7B52E4666D7")!
    nonisolated static var face6: LatticeSelectableRef { .face(group: groupB, face: 6) }

    override func tearDown() {
        FlexibleLatticeWalls.controlWallsFromTheFaceOutline = false
        FlexibleLatticeWalls.controlBareFaceIsATarget = false
        FlexibleLatticeWalls.controlBoxDepth = false
        FlexibleLatticeWalls.controlAnyContact = false
        FlexibleLatticeWalls.controlIndexKeys = false
        FlexibleAttach.controlNamesByScreenOrder = false
        FlexibleAttach.controlPruneStale = false
        FlexibleFaceCommits.controlUnsealedLinkWrite = false
        FlexibleFaceCommits.controlAutoApplySuggestion = false
        FlexibleFaceCommits.controlLinksEmptyArray = false
        FlexibleFaceCommits.controlTrashPrunesLinks = false
        FlexibleStageSettings.controlLinksInDesignInputs = false
        super.tearDown()
    }

    func bracket() throws -> FlexibleHisProject.Restored {
        let r = try FlexibleHisProject.restore(FlexibleU21DeleteUndoTests.lbracketDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        return r
    }
    func walls(_ p: ProjectModel, _ key: String = face6.key) throws -> FlexibleLatticeWalls.Result {
        try XCTUnwrap(FlexibleLatticeWalls.walls(project: p, key: key), "the walls of \(key)")
    }
    func setBox(_ p: ProjectModel, depth: Double? = nil, expand: Double? = nil) {
        if let d = depth { p.writeLatticeDepthMM(Self.face6, mm: d) }
        if let e = expand {
            // (#354's setter snaps |e| < 0.5 to 0 — a thinner-than-a-bead border is written straight into the store)
            if e != 0, abs(e) < 0.5 { p.lattice.selectableExpandMM[Self.face6.key] = e } else { p.writeLatticeExpandMM(Self.face6, mm: e) }
        }
    }
    func targets(_ w: FlexibleLatticeWalls.Result) -> [String: String] {
        var o: [String: String] = [:]
        for x in w.walls where x.status == .target { o[x.key] = x.target }
        return o
    }

    // MARK: 1 — his Face 6

    func testFace6HasFourWallsAndNoFloor() throws {
        let p = try bracket().project
        let w = try walls(p)
        XCTAssertEqual(w.depthMM, 30.5, accuracy: 1e-9, "the WIRE depth (box 33.5 + expand −3), never the box")
        XCTAssertNil(w.floor, "30.5 mm through the 25 mm upright: no floor")
        XCTAssertEqual(w.sides.map(\.name), ["Side 1", "Side 2", "Side 3", "Side 4"])
        XCTAssertEqual(w.sides.map(\.key), ["side:f1", "side:f7", "side:f3", "side:f0"], "as P0 printed")
        for (s, a) in zip(w.sides, [2975.0, 2350, 2975, 2350]) {
            XCTAssertEqual(s.target, "wall", "\(s.name) touches the border")
            XCTAssertEqual(s.latticeAreaMM2, a, accuracy: 0.02 * a, "\(s.name)'s lattice area ±2 %")
            XCTAssertEqual(s.touchedShare, 1, accuracy: 0.01)
        }
        XCTAssertEqual(w.suggestion(linked: [])?.count, 4, "★ Attach to the 4 walls around it")
        // ★ RED CONTROL: the walls from the FACE's outline at the box depth — Sides 1/2/3 lie on Faces 1/7/3 (open), only Side 4
        // (the foot beyond) keeps a target, and no suggestion
        FlexibleLatticeWalls.controlWallsFromTheFaceOutline = true
        let red = try walls(p)
        XCTAssertEqual(targets(red), ["side:f0": "wall"], "★ RED: 1 target, not 4")
        XCTAssertNil(red.suggestion(linked: []), "★ RED: no suggestion")
    }

    // MARK: 2 — expand 0 and +3

    func testExpandZeroLeavesOnlyTheFootSide() throws {
        let p = try bracket().project
        setBox(p, expand: 0)
        let w = try walls(p)
        XCTAssertEqual(targets(w), ["side:f0": "wall"], "only Side 4 (the foot beyond it)")
        XCTAssertEqual(w.wall("side:f0")!.touchedAreaMM2, 2500, accuracy: 50)
        XCTAssertNil(w.suggestion(linked: []), "not inset: no suggestion")
        XCTAssertEqual(FlexibleAttach.reason(w.wall("side:f1")!), "Side 1 is open to the outside")
        // ★ RED CONTROL: a bare model face counts as solid — Sides 1/2/3 get Face targets
        FlexibleLatticeWalls.controlBareFaceIsATarget = true
        XCTAssertEqual(targets(try walls(p)), ["side:f0": "wall", "side:f1": "skin:f1", "side:f7": "skin:f7", "side:f3": "skin:f3"],
                       "★ RED: the sides lying on Faces 1/7/3 become targets")
    }

    func testExpandPlusThree() throws {
        let p = try bracket().project
        setBox(p, expand: 3)
        let w = try walls(p)
        XCTAssertEqual(targets(w), ["side:f0": "wall"], "only the z = 22 side (it runs into the foot)")
        let s = w.wall("side:f0")!
        XCTAssertEqual(s.touchedAreaMM2, 2500, accuracy: 50)
        XCTAssertEqual(s.centre!.z, 22, accuracy: 1e-6)
        XCTAssertNil(w.suggestion(linked: []))
    }

    // MARK: 3 — box depth 9: a floor

    func testDepth9GivesAFloor() throws {
        let p = try bracket().project
        setBox(p, depth: 9)
        let w = try walls(p)
        let f = try XCTUnwrap(w.floor, "D_wire 6: a floor")
        XCTAssertEqual(f.target, "under")
        XCTAssertEqual(f.latticeAreaMM2, 11186, accuracy: 0.02 * 11186)
        XCTAssertEqual(f.centre!.x, 81, accuracy: 1e-6, "the floor at x = 75 + 6")
        XCTAssertEqual(w.wall("side:f1")!.latticeAreaMM2, 714, accuracy: 15)
        XCTAssertEqual(w.wall("side:f7")!.latticeAreaMM2, 564, accuracy: 12)
        // ★ RED CONTROL: the box's 9 mm — the floor at x = 84, the sides 1 071 / 846
        FlexibleLatticeWalls.controlBoxDepth = true
        let red = try walls(p)
        XCTAssertEqual(red.floor!.centre!.x, 84, accuracy: 1e-6, "★ RED: the floor 3 mm too deep")
        XCTAssertEqual(red.wall("side:f1")!.latticeAreaMM2, 1071, accuracy: 22, "★ RED")
        XCTAssertEqual(red.wall("side:f7")!.latticeAreaMM2, 846, accuracy: 17, "★ RED")
    }

    // MARK: 4 — his pad

    func testPadHasAFloorAndNoSuggestion() throws {
        let r = try FlexibleHisProject.restore(FlexibleU21DeleteUndoTests.padDir, asSaved: true)
        defer { r.cleanup() }
        let key = LatticeSelectableRef.face(group: Self.groupC, face: 5).key
        let w = try walls(r.project, key)
        XCTAssertEqual(w.sides.count, 4)
        for s in w.sides {
            XCTAssertEqual(s.status, .open, "\(s.name) lies on the pad's outside")
            XCTAssertEqual(FlexibleAttach.reason(s), "\(s.name) is open to the outside")
        }
        XCTAssertEqual(w.floor?.target, "under", "the 32 mm middle solid under it")
        XCTAssertEqual(w.floor!.latticeAreaMM2, 2000, accuracy: 40)
        XCTAssertNil(w.suggestion(linked: []), "no inset: no suggestion")
        // ★ RED CONTROL: bare faces as solid — the 4 sides get targets
        FlexibleLatticeWalls.controlBareFaceIsATarget = true
        XCTAssertEqual(try walls(r.project, key).sides.filter { $0.status == .target }.count, 4, "★ RED")
    }

    // MARK: 5 — a border thinner than a bead, and the touch threshold

    func testThinBorderAndTheAreaThreshold() throws {
        let r = try bracket()
        let p = r.project
        setBox(p, expand: -0.3)
        let w = try walls(p)
        for k in ["side:f1", "side:f7", "side:f3"] {
            XCTAssertEqual(w.wall(k)!.status, .thin, "\(k): 0.3 mm of solid beyond it")
        }
        XCTAssertEqual(FlexibleAttach.reason(w.wall("side:f1")!), "Side 1's solid is thinner than a bead")
        // (corrects §4.5: beyond Side 4 lies the foot — still a wall; one side is not a suggestion)
        XCTAssertEqual(w.wall("side:f0")!.target, "wall")
        XCTAssertNil(w.suggestion(linked: []), "no suggestion")
        // the two-box mesh: an edge contact (0 mm²) and a 2 × 2 patch → no target; a 10 × 10 patch → a target
        let edge = try boxWalls(contact: [20, 30, 0, 20, 10, 20])
        let patch2 = try boxWalls(contact: [20, 30, 9, 11, 4, 6])
        let patch10 = try boxWalls(contact: [20, 30, 5, 15, 0, 10])
        XCTAssertNotEqual(edge.status, .target, "an edge: 0 mm²")
        XCTAssertEqual(edge.touchedAreaMM2, 0, accuracy: 1e-9)
        XCTAssertNotEqual(patch2.status, .target, "a 2 × 2 patch: 4 mm² < 16 mm²")
        XCTAssertEqual(patch2.touchedAreaMM2, 4, accuracy: 0.5)
        XCTAssertEqual(patch10.status, .target, "a 10 × 10 patch")
        XCTAssertEqual(patch10.touchedAreaMM2, 100, accuracy: 2)
        // positive: a Face 0 (plate top) lattice — its side by Face 6 runs DOWN into the plate under the upright: a full touch
        setBox(p, expand: -3)
        // (Face 6 Off first: with both latticed, their shared edge is a SEAM — the lattice continues, never a wall)
        _ = p.flexibleLatticeUnder(.newGroup(face: 0, region: nil, name: "Plate", depthMM: 10))
        let plateID = try XCTUnwrap(p.selection.groups.first { $0.name == "Plate" }).id
        let seamed = try walls(p, LatticeSelectableRef.face(group: plateID, face: 0).key)
        XCTAssertEqual(seamed.wall("side:f6")?.status, .seam, "with Face 6 latticed too: a seam")
        XCTAssertEqual(FlexibleAttach.reason(seamed.wall("side:f6")!), "Side 2 runs into another lattice")
        FlexibleFaceCommits.setState(.off, ref: Self.face6, group: Self.groupB, project: p)
        let plate = try XCTUnwrap(p.selection.groups.first { $0.name == "Plate" }, "the plate group")
        let pw = try walls(p, LatticeSelectableRef.face(group: plate.id, face: 0).key)
        print(FlexibleI2WallsProbe.line(pw, "l-bracket + a Face 0 lattice (10 mm)"))
        XCTAssertEqual(pw.wall("side:f6")?.target, "wall", "★ the side by Face 6 is a wall (positive case)")
        XCTAssertEqual(pw.wall("side:f6")!.touchedAreaMM2, 1000, accuracy: 30, "100 × 10 mm")
        // ★ RED CONTROL: any contact — the 0.3 mm border and the 2 × 2 patch become targets
        FlexibleLatticeWalls.controlAnyContact = true
        FlexibleFaceCommits.setState(.include, ref: Self.face6, group: Self.groupB, project: p)
        setBox(p, expand: -0.3)
        XCTAssertEqual(try walls(p).wall("side:f1")!.status, .target, "★ RED: the 0.3 mm border is a target")
        XCTAssertEqual(try boxWalls(contact: [20, 30, 9, 11, 4, 6]).status, .target, "★ RED: the 2 × 2 patch is a target")
    }

    // MARK: 6 — keys survive depth and expand

    func testKeysSurviveDepthAndExpand() throws {
        let p = try bracket().project
        let k0 = try walls(p).sides.map(\.key)
        setBox(p, depth: 20, expand: -1)
        XCTAssertEqual(try walls(p).sides.map(\.key), k0, "33.5 → 20 and −3 → −1: the same keys")
        // an edge eaten on purpose: a 1 mm chamfer gone at a 2 mm inset — the others keep their keys, the chamfer goes GONE
        let a = try chamferWalls(expand: -0.6), b = try chamferWalls(expand: -2)
        XCTAssertEqual(a.sides.count, 5)
        let chamfer = try XCTUnwrap(a.sides.first { $0.latticeAreaMM2 < 30 }, "the chamfer side")
        XCTAssertEqual(b.wall(chamfer.key)?.status, .gone, "the chamfer's key kept, the side gone")
        for s in a.sides where s.key != chamfer.key {
            XCTAssertEqual(b.wall(s.key)?.neighbour, s.neighbour, "\(s.name) keeps its key")
            XCTAssertEqual(b.wall(s.key)?.number, s.number, "\(s.name) keeps its number")
        }
        // ★ RED CONTROL: keys by the wire edge's index — a link to the chamfer re-points to another side
        FlexibleLatticeWalls.controlIndexKeys = true
        let ra = try chamferWalls(expand: -0.6), rb = try chamferWalls(expand: -2)
        let rk = try XCTUnwrap(ra.sides.first { $0.latticeAreaMM2 < 30 }).key
        let now = try XCTUnwrap(rb.wall(rk), "★ RED: the stored key finds a wall")
        XCTAssertNotEqual(now.neighbour, chamfer.neighbour, "★ RED: the link re-points to the wrong wall (\(rk))")
    }

    // MARK: 7 — names never depend on the camera

    func testNamesDoNotDependOnTheCamera() throws {
        let w = try walls(try bracket().project)
        func frame(_ s: Float) -> LatticeBandChipFrame {
            // a look along x: screen x follows ±y, screen y follows z
            let m = simd_float4x4(columns: (SIMD4(0, 0, 0, 0), SIMD4(s / 200, 0, 0, 0), SIMD4(0, 1 / 200, 0, 0), SIMD4(0, -0.4, 0.5, 1)))
            return LatticeBandChipFrame(clipFromModel: m, viewportSize: CGSize(width: 1000, height: 1000))
        }
        let a = frame(1), b = frame(-1)
        let na = FlexibleAttach.names(w, screen: { a.project(SIMD3<Float>($0)) })
        let nb = FlexibleAttach.names(w, screen: { b.project(SIMD3<Float>($0)) })
        XCTAssertEqual(na, nb, "★ the same names from two cameras")
        XCTAssertEqual(na["side:f1"], "Side 1")
        // ★ RED CONTROL: numbered left to right on screen — the two frames disagree
        FlexibleAttach.controlNamesByScreenOrder = true
        let ra = FlexibleAttach.names(w, screen: { a.project(SIMD3<Float>($0)) })
        let rb = FlexibleAttach.names(w, screen: { b.project(SIMD3<Float>($0)) })
        XCTAssertNotEqual(ra, rb, "★ RED: screen order renames the sides when the camera turns")
    }

    // MARK: 8 — the step machine, and every end of Attach

    func testStepMachine() throws {
        let r = try bracket()
        let p = r.project
        let w = try walls(p)
        var s = FlexibleAttach.start(lattice: Self.face6.key, group: Self.groupB, faceName: "Face 6")
        XCTAssertEqual(FlexibleAttach.stepLine(s, walls: w), "1 of 2 · Tap a wall of the lattice")
        var e: FlexibleAttachEffect
        (s, e) = FlexibleAttach.step(s, .miss, walls: w, linked: [])
        XCTAssertEqual(s.step, .pickWall); XCTAssertEqual(s.say, "1 of 2 · Tap a wall of the lattice"); XCTAssertEqual(e, .none)
        (s, e) = FlexibleAttach.step(s, .wall("side:f7"), walls: w, linked: [])
        XCTAssertEqual(s.step, .pickTarget(wall: "side:f7"))
        XCTAssertEqual(FlexibleAttach.stepLine(s, walls: w), "2 of 2 · Tap what Side 2 connects to")
        (s, e) = FlexibleAttach.step(s, .face(9), walls: w, linked: [])
        XCTAssertEqual(s.say, "Face 9 doesn't touch Side 2"); XCTAssertEqual(s.step, .pickTarget(wall: "side:f7"))
        (s, e) = FlexibleAttach.step(s, .back, walls: w, linked: [])
        XCTAssertEqual(s.step, .pickWall)
        (s, _) = FlexibleAttach.step(s, .wall("side:f7"), walls: w, linked: [])
        (s, e) = FlexibleAttach.step(s, .target("wall"), walls: w, linked: [])
        XCTAssertEqual(e, .link(wall: "side:f7", target: "wall"))
        XCTAssertEqual(s.step, .pickWall, "back to step 1 for the next wall")
        XCTAssertEqual(s.linkedHere, 1, "[Done] replaces [Cancel]")
        XCTAssertEqual(s.say, "Linked Side 2 → wall")
        (s, _) = FlexibleAttach.step(s, .wall("side:f7"), walls: w, linked: [])
        (s, e) = FlexibleAttach.step(s, .target("wall"), walls: w, linked: ["side:f7|wall"])
        XCTAssertEqual(e, .none); XCTAssertEqual(s.say, "Side 2 → wall is linked already")
        // a greyed wall answers in the say line, the step stays
        setBox(p, expand: 0)
        let w0 = try walls(p)
        var g = FlexibleAttach.start(lattice: Self.face6.key, group: Self.groupB, faceName: "Face 6")
        (g, e) = FlexibleAttach.step(g, .wall("side:f1"), walls: w0, linked: [])
        XCTAssertEqual(g.step, .pickWall); XCTAssertEqual(g.say, "Side 1 is open to the outside")
        (g, e) = FlexibleAttach.step(g, .cancel, walls: w0, linked: [])
        XCTAssertEqual(g, .off); XCTAssertEqual(e, .end)
        // a box edit under step 2 that takes the picked wall's solid: back to step 1, said
        var c = FlexibleAttach.start(lattice: Self.face6.key, group: Self.groupB, faceName: "Face 6")
        (c, _) = FlexibleAttach.step(c, .wall("side:f1"), walls: w, linked: [])
        c = FlexibleAttach.revalidated(c, walls: w0)
        XCTAssertEqual(c.step, .pickWall); XCTAssertEqual(c.say, "Side 1 changed · tap a wall again")
        setBox(p, expand: -3)

        // every end of Attach (the stage): another pick, Solid, gravity setup, leaving the stage — and a stray tap never
        let st = FlexibleMainStage()
        func open() {
            st.pickFace(Self.face6, group: Self.groupB, project: p)
            st.startAttach(p, group: Self.groupB, ref: Self.face6)
            XCTAssertTrue(st.attach.active, "Attach opens on Face 6")
        }
        open()
        st.missTap()
        XCTAssertTrue(st.attach.active, "★ a stray tap keeps the steps"); XCTAssertEqual(st.attach.say, "1 of 2 · Tap a wall of the lattice")
        let groupA = try XCTUnwrap(p.selection.groups.first { $0.name == "Group A" }).id
        st.pickGroup(groupA, project: p)
        XCTAssertFalse(st.attach.active, "another pick ends it")
        open()
        FlexibleFaceCommits.setState(.exclude, ref: Self.face6, group: Self.groupB, project: p)
        st.revalidatePick(p)
        XCTAssertFalse(st.attach.active, "Solid ends it")
        p.performUndo()
        open()
        st.gravitySetupStarts()
        XCTAssertFalse(st.attach.active, "gravity setup ends it")
        open()
        st.apply(p, owned: false, pageUp: false)
        XCTAssertFalse(st.attach.active, "leaving the stage ends it")
        open()
        st.apply(p, owned: true, pageUp: true)
        XCTAssertFalse(st.attach.active, "a full-screen page ends it")
    }

    // MARK: 9 — one link = one undo step

    func testOneLinkIsOneUndoStep() throws {
        let p = try bracket().project
        p.sealUndoStep()
        func keys() -> [String] { (p.lattice.flexible?.links ?? []).map(\.wall) }
        FlexibleFaceCommits.addLink(lattice: Self.face6.key, wall: "side:f1", target: "wall", project: p)
        FlexibleFaceCommits.addLink(lattice: Self.face6.key, wall: "side:f7", target: "wall", project: p)   // within 0.5 s
        XCTAssertEqual(keys(), ["side:f1", "side:f7"])
        p.performUndo()
        XCTAssertEqual(keys(), ["side:f1"], "★ one Undo removes only the second link")
        p.performUndo()
        XCTAssertNil(p.lattice.flexible?.links, "…the next the first (nil, never [])")
        // a link after an unsealed edit (a drag's depth) is still its own step
        p.writeLatticeDepthMM(Self.face6, mm: 30)
        FlexibleFaceCommits.addLink(lattice: Self.face6.key, wall: "side:f3", target: "wall", project: p)
        p.performUndo()
        XCTAssertNil(p.lattice.flexible?.links)
        XCTAssertEqual(p.latticeSlabDepthMM(Self.face6, in: Self.groupB), 30, accuracy: 1e-9, "★ the depth edit stays")
        p.performUndo()
        // ★ RED CONTROL: an unsealed write — the link folds into the depth edit before it
        FlexibleFaceCommits.controlUnsealedLinkWrite = true
        let before = p.latticeSlabDepthMM(Self.face6, in: Self.groupB)
        p.writeLatticeDepthMM(Self.face6, mm: 28)
        FlexibleFaceCommits.addLink(lattice: Self.face6.key, wall: "side:f3", target: "wall", project: p)
        p.performUndo()
        XCTAssertNil(p.lattice.flexible?.links)
        XCTAssertEqual(p.latticeSlabDepthMM(Self.face6, in: Self.groupB), before, accuracy: 1e-9,
                       "★ RED: one Undo also reverted the depth edit made before the link")
    }

    // MARK: 10 — the suggestion is shown, never applied by itself

    func testSuggestionShownNotApplied() throws {
        let p = try bracket().project
        p.sealUndoStep()
        let st = FlexibleMainStage()
        guard case let .button(right, sides?) = st.attachRow(p, group: Self.groupB, ref: Self.face6) else { return XCTFail("the row with its suggestion") }
        XCTAssertEqual(right, "Not attached")
        XCTAssertEqual(sides.count, 4)
        XCTAssertEqual(FlexibleSelectionsCopy.suggest(sides.count, other: false), "Attach to the 4 walls around it")
        XCTAssertNil(p.lattice.flexible?.links, "★ nothing set until he taps")
        st.applySuggestion(p, group: Self.groupB, ref: Self.face6)
        XCTAssertEqual(p.lattice.flexible?.links?.count, 4, "one tap → the 4 walls")
        XCTAssertEqual(st.faceUI.toast?.text, "Linked 4 walls")
        guard case let .button(r2, s2) = st.attachRow(p, group: Self.groupB, ref: Self.face6) else { return XCTFail() }
        XCTAssertEqual(r2, "4 linked"); XCTAssertNil(s2, "nothing left to suggest")
        p.performUndo()
        XCTAssertNil(p.lattice.flexible?.links, "★ one Undo removes all 4")
        setBox(p, expand: 0)
        guard case let .button(_, s0) = st.attachRow(p, group: Self.groupB, ref: Self.face6) else { return XCTFail() }
        XCTAssertNil(s0, "at expand 0 no suggestion row")
        // ★ RED CONTROL: the suggestion applied on open
        setBox(p, expand: -3)
        FlexibleFaceCommits.controlAutoApplySuggestion = true
        _ = st.attachRow(p, group: Self.groupB, ref: Self.face6)
        XCTAssertEqual(p.lattice.flexible?.links?.count, 4, "★ RED: links written on open, before any tap")
    }

    // MARK: 11 — links never reach the job or the lattice's key

    func testLinksNeverReachTheJobOrTheKey() throws {
        let p = try bracket().project
        let s0 = try XCTUnwrap(p.lattice.flexible)
        FlexibleFaceCommits.addLink(lattice: Self.face6.key, wall: "side:f1", target: "wall", project: p)
        let s1 = try XCTUnwrap(p.lattice.flexible)
        XCTAssertNotEqual(s0, s1)
        XCTAssertEqual(s0.designInputs, s1.designInputs, "★ the design inputs equal")
        XCTAssertEqual(s0.designInputs.hashValue, s1.designInputs.hashValue, "★ the lattice's key (designInputs' hash) equal")
        func job(_ s: FlexibleStageSettings) throws -> String {
            var t = s
            if t.materialID == nil { t.materialID = "tpu_95a" }
            if t.loadedFaces.isEmpty { t.faces = [FlexibleFaceSettings(faceRegionID: 6)] }
            let i = FlexibleJob.Inputs(modelPath: "/x.step", resolution: 64, beadWidthMM: 0.45, faceCount: 12, settings: t, regions: [], stampGrids: [:])
            return try FlexibleJob.runJobJSON(i) + "\n" + FlexibleJob.sceneJobJSON(i, fallbackMaterial: "ABS")
        }
        XCTAssertEqual(try job(s0), try job(s1), "★ the run and scene jobs byte-identical")
        // ★ RED CONTROL: links left in designInputs — the key differs (a link would rebuild the lattice)
        FlexibleStageSettings.controlLinksInDesignInputs = true
        XCTAssertNotEqual(s0.designInputs.hashValue, s1.designInputs.hashValue, "★ RED: the key moves with a link")
    }

    // MARK: 12 — old saves decode, re-encode byte-identical; the last link stores nil

    func testOldSavesDecodeAndReencodeByteIdentical() throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        for dir in [FlexibleU21DeleteUndoTests.lbracketDir, FlexibleU21DeleteUndoTests.padDir] {
            let raw = try Data(contentsOf: dir.appendingPathComponent("project.json"))
            XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("\"links\""), "premise: his save has no links key")
            let r = try FlexibleHisProject.restore(dir, asSaved: true)
            defer { r.cleanup() }
            let p = r.project
            XCTAssertNil(p.lattice.flexible?.links, "\(dir.lastPathComponent): no links → nil")
            let before = try enc.encode(XCTUnwrap(p.lattice.flexible))
            let key = (p.lattice.selectableRoles.first { $0.value == .include }?.key)!
            FlexibleFaceCommits.addLink(lattice: key, wall: "floor", target: "under", project: p)
            let id = try XCTUnwrap(p.lattice.flexible?.links?.first?.id)
            FlexibleFaceCommits.removeLink(id: id, project: p)
            let after = try enc.encode(XCTUnwrap(p.lattice.flexible))
            XCTAssertEqual(before, after, "★ \(dir.lastPathComponent): byte-identical after a link came and went")
            XCTAssertFalse(String(decoding: after, as: UTF8.self).contains("links"))
        }
    }

    func testLastLinkRemovedStoresNil() throws {
        let p = try bracket().project
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let before = try enc.encode(XCTUnwrap(p.lattice.flexible))
        FlexibleFaceCommits.addLink(lattice: Self.face6.key, wall: "side:f1", target: "wall", project: p)
        FlexibleFaceCommits.removeLink(id: try XCTUnwrap(p.lattice.flexible?.links?.first?.id), project: p)
        XCTAssertNil(p.lattice.flexible?.links, "★ nil, never []")
        // ★ RED CONTROL: [] stored — the re-encode carries "links":[] and the bytes differ
        FlexibleFaceCommits.controlLinksEmptyArray = true
        FlexibleFaceCommits.addLink(lattice: Self.face6.key, wall: "side:f1", target: "wall", project: p)
        FlexibleFaceCommits.removeLink(id: try XCTUnwrap(p.lattice.flexible?.links?.first?.id), project: p)
        let red = try enc.encode(XCTUnwrap(p.lattice.flexible))
        XCTAssertTrue(String(decoding: red, as: UTF8.self).contains("\"links\":[]"), "★ RED: \"links\":[]")
        XCTAssertNotEqual(before, red, "★ RED: the bytes differ")
    }

    // MARK: 13 — a stale link says why and is kept

    func testAStaleLinkSaysWhyAndIsKept() throws {
        let p = try bracket().project
        let st = FlexibleMainStage()
        FlexibleFaceCommits.addLink(lattice: Self.face6.key, wall: "side:f1", target: "wall", project: p)
        XCTAssertEqual(st.listedLinks(p, key: Self.face6.key).map(\.state), [.live])
        setBox(p, expand: 0)
        let rows = st.listedLinks(p, key: Self.face6.key)
        XCTAssertEqual(rows.count, 1, "★ still listed")
        let l = rows[0]
        XCTAssertEqual(l.state, .stale(" · no solid there now"))
        XCTAssertEqual(FlexibleAttach.rowText(l.link, wallName: st.wallName(p, lattice: Self.face6.key, wall: "side:f1"), state: l.state),
                       "Side 1 → wall · no solid there now")
        XCTAssertEqual(p.lattice.flexible?.links?.count, 1, "★ still saved")
        XCTAssertEqual(st.liveLinks(p, key: Self.face6.key), [], "the sim ignores it (I3 reads the live ones)")
        setBox(p, expand: -3)
        XCTAssertEqual(st.listedLinks(p, key: Self.face6.key).map(\.state), [.live], "undoing the edit brings it back to life")
        FlexibleFaceCommits.setState(.exclude, ref: Self.face6, group: Self.groupB, project: p)
        XCTAssertEqual(st.listedLinks(p, key: Self.face6.key).map(\.state), [.stale(" · lattice off")])
        p.performUndo()
        // ★ RED CONTROL: stale links pruned
        FlexibleAttach.controlPruneStale = true
        setBox(p, expand: 0)
        _ = st.listedLinks(p, key: Self.face6.key)
        XCTAssertNil(p.lattice.flexible?.links, "★ RED: the stale link was removed by itself")
    }

    // MARK: 14 — dormant links come back with the group's Undo

    func testDormantLinksComeBackWithTheGroupsUndo() throws {
        let p = try bracket().project
        let st = FlexibleMainStage()
        FlexibleFaceCommits.addLink(lattice: Self.face6.key, wall: "side:f1", target: "wall", project: p)
        let saved = p.lattice.flexible?.links
        var taken = try XCTUnwrap(FlexibleFaceCommits.delete(Self.groupB, project: p))
        XCTAssertEqual(st.listedLinks(p, key: Self.face6.key).count, 0, "group B's trash: no rows")
        XCTAssertEqual(p.lattice.flexible?.links, saved, "★ links untouched")
        FlexibleFaceCommits.restore(taken, project: p)
        XCTAssertEqual(st.listedLinks(p, key: Self.face6.key).map(\.state), [.live], "★ the toast's [Undo]: the row is back")
        _ = try XCTUnwrap(FlexibleFaceCommits.delete(Self.groupB, project: p))
        p.performUndo()
        XCTAssertEqual(st.listedLinks(p, key: Self.face6.key).map(\.state), [.live], "★ the toolbar Undo: the row is back")
        // ★ RED CONTROL: the trash prunes the links in the same write — the toast's [Undo] (it re-adds the group only) cannot
        FlexibleFaceCommits.controlTrashPrunesLinks = true
        taken = try XCTUnwrap(FlexibleFaceCommits.delete(Self.groupB, project: p))
        FlexibleFaceCommits.restore(taken, project: p)
        XCTAssertEqual(st.listedLinks(p, key: Self.face6.key).count, 0, "★ RED: no row came back")
    }

    // MARK: 15 — every string fits

    func testCopyFits() {
        for s in FlexibleSelectionsCopy.attachWorstCases { XCTAssertTrue(FlexibleSelectionsCopy.fits(s), "≤ 44: \(s) (\(s.count))") }
        XCTAssertEqual(FlexibleSelectionsCopy.attachWorstCases.map(\.count).max() ?? 0, 41, "the longest, as drawn")
        // ★ RED CONTROL: a 45-character sample (with → and ·, one character each) fails the same checker
        let sample = "Side 12 → wall · " + String(repeating: "x", count: 28)
        XCTAssertEqual(sample.count, 45)
        XCTAssertFalse(FlexibleSelectionsCopy.fits(sample), "★ RED: 45 characters do not fit")
    }

    // MARK: - small meshes

    typealias Tri = (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
    /// A prism over a counter-clockwise polygon (bottom faceBase, top faceBase + 1, side i faceBase + 2 + i).
    static func prism(_ poly: [SIMD2<Float>], z0: Float, z1: Float, faceBase: Int32) -> [(Tri, Int32)] {
        var out: [(Tri, Int32)] = []
        func p(_ q: SIMD2<Float>, _ z: Float) -> SIMD3<Float> { SIMD3(q.x, q.y, z) }
        for i in 1..<(poly.count - 1) {
            out.append(((p(poly[0], z1), p(poly[i], z1), p(poly[i + 1], z1)), faceBase + 1))
            out.append(((p(poly[0], z0), p(poly[i + 1], z0), p(poly[i], z0)), faceBase))
        }
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count], f = faceBase + 2 + Int32(i)
            out.append(((p(a, z0), p(b, z0), p(b, z1)), f))
            out.append(((p(a, z0), p(b, z1), p(a, z1)), f))
        }
        return out
    }
    static func mesh(_ tris: [(Tri, Int32)]) -> ViewerMesh {
        var v: [Float] = [], idx: [Int32] = [], ids: [Int32] = []
        for (t, f) in tris {
            for q in [t.0, t.1, t.2] { idx.append(Int32(v.count / 3)); v += [q.x, q.y, q.z] }
            ids.append(f)
        }
        return ViewerMesh(vertices: v, indices: idx, faceIDs: ids)
    }
    /// A face spec on face `top` (pointing −z into the part) as the emission writes it.
    static func spec(_ m: ViewerMesh, top: Int32, depth: Double, expand: Double) -> LatticeRegionSpec {
        var s = LatticeRegionSpec(role: .include, kind: .face)
        let o = SIMD3<Double>(m.faceCentroid(top)!)
        let n = SIMD3<Double>(0, 0, -1)
        let (uF, vF) = LatticeRegionMask.basis(-n), (uS, vS) = LatticeRegionMask.basis(n)
        s.origin = o; s.normal = n
        s.outlineLoops = LatticeFaceOutline.loops(face: FaceID(top), in: m, normal: -n, origin: o).map { l in
            l.map { q in let d = uF * q.x + vF * q.y; return SIMD2(simd_dot(d, uS), simd_dot(d, vS)) }
        }
        s.inPlaneOffsetMM = expand
        s.depthMM = depth + expand
        s.halfUMM = 10; s.halfWMM = 10
        s.rawFaceID = FaceID(top)
        s.selectableKey = "test"
        return s
    }
    /// Box A (20 × 20 × 10, lattice from its top through) with box B touching its x = 20 side over `contact` [x0 x1 y0 y1 z0 z1].
    func boxWalls(contact c: [Float]) throws -> FlexibleLatticeWalls.Wall {
        let a = Self.prism([SIMD2(0, 0), SIMD2(20, 0), SIMD2(20, 20), SIMD2(0, 20)], z0: 0, z1: 10, faceBase: 0)
        let b = Self.prism([SIMD2(c[0], c[2]), SIMD2(c[1], c[2]), SIMD2(c[1], c[3]), SIMD2(c[0], c[3])], z0: c[4], z1: c[5], faceBase: 10)
        let m = Self.mesh(a + b)
        let s = Self.spec(m, top: 1, depth: 10, expand: 0)
        let r = try XCTUnwrap(FlexibleLatticeWalls.walls(spec: s, includes: [s], excludes: [], mesh: m, finish: .none, beadMM: 0.45, cellMinMM: 4))
        // the x = 20 side: across face 3 (side 1 of box A runs (20,0) → (20,20))
        return try XCTUnwrap(r.walls.first { $0.neighbour == 3 }, "the x = 20 side")
    }
    /// A 20 × 20 × 10 block with a 1 mm chamfer at (20, 0) (mid-loop: an index key shifts past it), lattice from its top, 10 mm deep, inset `expand`.
    func chamferWalls(expand: Double) throws -> FlexibleLatticeWalls.Result {
        let a = Self.prism([SIMD2(0, 0), SIMD2(19, 0), SIMD2(20, 1), SIMD2(20, 20), SIMD2(0, 20)], z0: 0, z1: 10, faceBase: 0)
        let m = Self.mesh(a)
        let s = Self.spec(m, top: 1, depth: 10, expand: expand)
        return try XCTUnwrap(FlexibleLatticeWalls.walls(spec: s, includes: [s], excludes: [], mesh: m, finish: .none, beadMM: 0.45, cellMinMM: 4))
    }
}
