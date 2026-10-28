// FlexibleI3LinkSimTests — round 7 · U21 batch I, part I3: the LINKED WALLS HOLD THE LATTICE in the squish sim.
//   His answer of 2026-10-21 ~15:35: "I did a negative expansion. I expect the 4 walls around the lattice to hold the lattice up."
//   His picks ~15:45: "the linked walls HOLD that lattice. It squashes against them and they stay put; on his bracket the top pushes
//   in and the bottom bows out. Without links: Rests. Without Rests: the Topology page's fixed faces. With neither: the far side.
//   The card always says what holds it ('Held by 4 linked walls')." Links are not sent to core (CORE LIST item 10).
//   His decision of 2026-10-22 ~02:50: groups that HAVE Rests stay exactly as today when no link exists.
// On HIS live projects of 2026-10-21 (round7/batch_u21/his_live_1021_lbracket, his_live_1021_pad). Each RED control is asserted
// red inside its test.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleI3LinkSimTests: XCTestCase {

    override func tearDown() {
        FlexibleFERequest.controlIgnoreLinks = false
        FlexibleStageModel.controlGenerationOnlyGuard = false
        FlexibleStageModel.controlEveryLinkHoldsEveryGroup = false
        FlexibleStageSettings.controlLinksInDesignInputs = false
        FlexibleSettingsExit.controlLinksModifySettings = false
        super.tearDown()
    }

    static var face6: LatticeSelectableRef { .face(group: FlexibleI2AttachTests.groupB, face: 6) }

    func opened(_ dir: URL, _ what: String) async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(dir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let m = try await FlexibleHisProject.openedModel(r.project, test: self)
        try await FlexibleSquishFixture.settle(m, what)
        return (r, m)
    }

    /// His one-tap suggestion on Face 6 ("Attach to the 4 walls around it"): the 4 side → wall links, one step.
    func linkTheFourWalls(_ p: ProjectModel) throws -> [String] {
        let w = try XCTUnwrap(FlexibleLatticeWalls.walls(project: p, key: Self.face6.key), "Face 6's walls")
        let sides = try XCTUnwrap(w.suggestion(linked: []), "the suggestion row")
        XCTAssertEqual(sides, ["side:f1", "side:f7", "side:f3", "side:f0"], "premise: the 4 border walls (P0)")
        XCTAssertEqual(FlexibleFaceCommits.addSuggested(lattice: Self.face6.key, sides: sides, project: p), 4)
        return sides
    }

    static let face6Centre = SIMD3<Float>(75, 0, 87.5)     // his Face 6, pressed (x = 75)
    static let face2Centre = SIMD3<Float>(100, 0, 87.5)    // his Face 2: the far side's window behind the lattice (x = 100)

    /// What the raw solve does on his bracket: Face 6 / Face 2's window centre / the window's edge midpoints one FE spacing inside
    /// the walls (u_x), the largest |u| on the plate (z ≤ 20) and on the border beyond the walls' pinned layer.
    struct Look {
        var u6: Float, u2: Float, edges: [Float], plate: Float, frame: Float
        var edgeMean: Float { edges.reduce(0, +) / Float(max(1, edges.count)) }
    }
    func look(_ s: FlexSquishSolutionInfo) -> Look {
        let f = FlexibleFEField(solution: s, simID: "probe", generation: 0)
        let h = Float(s.spacing)
        let edges = [SIMD3<Float>(100, -47 + h, 87.5), SIMD3<Float>(100, 47 - h, 87.5),
                     SIMD3<Float>(100, 0, 28 + h), SIMD3<Float>(100, 0, 147 - h)].map { f.sample($0).x }
        var plate: Float = 0, frame: Float = 0
        for k in 0..<s.nz { for j in 0..<s.ny { for i in 0..<s.nx {
            let n = (k * s.ny + j) * s.nx + i
            guard s.solved[n] else { continue }
            let p = s.origin + SIMD3<Double>(Double(i), Double(j), Double(k)) * s.spacing
            let u = simd_length(SIMD3<Float>(s.u[3 * n], s.u[3 * n + 1], s.u[3 * n + 2]))
            if p.z <= 20 { plate = max(plate, u) }
            // the upright's solid beyond the walls: the 3 mm border (|y| ≥ 47, z ≥ 147, z ≤ 28) and the foot under it
            if p.x >= 75, abs(p.y) >= 47.5 || p.z >= 147.5 || p.z <= 27.5 { frame = max(frame, u) }
        } } }
        return Look(u6: f.sample(Self.face6Centre).x, u2: f.sample(Self.face2Centre).x, edges: edges, plate: plate, frame: frame)
    }
    func line(_ what: String, _ s: FlexSquishSolutionInfo, _ l: Look) -> String {
        String(format: "FLEX-I3 %@: bc %@ · walls held %@ (reach %@) · free modes %d · far anvils %d · exits held %@ · raw u_x Face 6 %.4f · Face 2 window %.4f (ratio %.3f) · window edges %@ (mean %.4f, centre/mean %.2f) · plate max|u| %.2e · frame max|u| %.2e · solve %.0f ms",
               what, s.bcMode, "\(s.wallNodes)", "\(s.wallReachMM.map { String(format: "%.3f", $0) })", s.freeModes, s.farAnvils,
               "\(s.exitsHeld)", l.u6, l.u2, l.u2 / l.u6, "\(l.edges.map { String(format: "%.4f", $0) })", l.edgeMean,
               l.u2 / max(1e-9, l.edgeMean), l.plate, l.frame, s.solveMS)
    }

    // MARK: 1 — his l-bracket with the 4 border walls linked: "the top pushes in and the bottom bows out"

    func testOnHisLBracketTheFourLinkedWallsHoldTheLatticeAndFace2BowsOut() async throws {
        let (r, m) = try await opened(FlexibleU21DeleteUndoTests.lbracketDir, "his l-bracket")
        let p = r.project
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let jobBefore = try m.runJobJSON()
        _ = try linkTheFourWalls(p)
        XCTAssertEqual(try m.runJobJSON(), jobBefore, "★ links never reach the job (CORE LIST item 10)")

        _ = try await FlexibleSquishFixture.build(m, "his l-bracket")
        try await FlexibleSquishFixture.solve(m, "his l-bracket")
        let g = try XCTUnwrap(m.squeezeGroups.first, "his one squeeze group (Face 6)")
        let id = FlexibleSim.groupID(g.number)
        let req = try XCTUnwrap(m.lastFERequest)
        XCTAssertEqual(req.walls[id]?.count, 4, "★ the 4 linked walls sent with group 1's sim")
        XCTAssertEqual(req.resting, [], "★ never as Rests")

        // the card's line, before the sim (decided) and from its receipt
        let i = m.holdInputs(g)
        let decided = FlexibleHold.decide(resting: [], anchors: m.topologyAnchors, pressed: i.pressed, forces: i.forces, farFaces: i.far,
                                          links: 4)
        XCTAssertEqual(FlexibleHold.line(decided), "Held by 4 linked walls")
        let f = try XCTUnwrap(m.squish[id]?.field, "group 1's sim landed")
        XCTAssertEqual(f.bcMode, "wall", "★ the linked walls hold it (no Topology anchor, no exit glue)")
        XCTAssertEqual(m.holdLine(g), "Held by 4 linked walls", "★ the receipt agrees with the decided line")
        XCTAssertEqual(FlexibleHold.spoken(m.holdKind(g)), "Held by 4 linked walls", "no 'set links' tail once links hold it")
        XCTAssertNotNil(f.referenceK, "★ k from the reference (exits held), the walls leave Face 2 free (R3)")

        // the raw solve
        let (s, _, sim) = try await FlexibleSquishFixture.resolve(m, id)
        let l = look(s)
        print(line("l-bracket 4 linked walls", s, l))
        XCTAssertEqual(s.bcMode, "wall")
        XCTAssertEqual(s.wallNodes.count, 4)
        XCTAssertTrue(s.wallNodes.allSatisfy { $0 > 0 }, "★ every linked wall pins nodes (\(s.wallNodes))")
        XCTAssertEqual(s.freeModes, 0, "bonded walls: no rigid mode left")
        XCTAssertEqual(s.farAnvils, 0)
        XCTAssertFalse(s.exitsHeld, "Face 2 (the anvil) is free")
        XCTAssertGreaterThan(l.u6, 0, "★ Face 6 pushed IN (+x)")
        XCTAssertGreaterThan(l.u2, 0, "★ Face 2's window bows OUT (+x, the sign asserted)")
        XCTAssertGreaterThanOrEqual(l.u2, 2 * l.edgeMean, "★ a BOW, not a swing: the window's centre moves ≥ 2× its held rim's mean")
        XCTAssertLessThanOrEqual(l.plate, 1e-6, "★ the plate beyond the walls stays put (\(l.plate))")
        XCTAssertLessThanOrEqual(l.frame, 1e-6, "★ the border beyond the walls stays put (\(l.frame))")
        // the ratio Face 2 / Face 6, pinned to what this probe measured (never §6.4's estimate)
        XCTAssertEqual(Double(l.u2 / l.u6), Self.measuredRatio, accuracy: 0.10 * Self.measuredRatio,
                       "★ Face 2 / Face 6 = the measured \(Self.measuredRatio) ±10 %")

        // the CORE LIST numbers: the deepest column's raw compression (Face 6's stack) and kRef
        let raw = FlexibleFEField(solution: s, simID: sim.id, generation: req.generation)
        func deepest(_ fld: FlexibleFEField) -> Double {
            sim.targets.flatMap { t in t.stack.columns.indices.map { fld.columnCompression(stack: t.stack, col: $0, pinched: false) } }.max() ?? 0
        }
        print(String(format: "FLEX-I3 l-bracket CORE LIST: deepest raw compression %.4f mm · shown k %.3f (kRef %@, asked %.3f) · gmaxPart (shown) %.3f · fold share %@ · shown max|u| %.3f mm",
                     deepest(raw), f.scale, f.referenceK.map { String(format: "%.3f", $0) } ?? "nil", f.coreRatio, f.gmaxPart,
                     f.foldShare.map { String(format: "%.3f", $0) } ?? "nil", f.maxDisplacement))

        // ★ RED CONTROL: the links ignored — the hold falls to Topology's fixed faces (I1): the upright swings, no bow
        FlexibleFERequest.controlIgnoreLinks = true
        let (sr, _, _) = try await FlexibleSquishFixture.resolve(m, id)
        FlexibleFERequest.controlIgnoreLinks = false
        let lr = look(sr)
        print(line("l-bracket RED links ignored", sr, lr))
        XCTAssertEqual(sr.bcMode, "anchor", "★ RED CONTROL: Topology's fixed faces hold it")
        XCTAssertEqual(sr.wallNodes, [], "★ RED CONTROL: no wall sent")
        XCTAssertLessThan(lr.u2, 2 * lr.edgeMean, "★ RED CONTROL: the window swings with the upright — the bow assertion fails")
        XCTAssertGreaterThan(lr.frame, 1e-6, "★ RED CONTROL: the border moves")
        print(String(format: "FLEX-I3 l-bracket RED CORE LIST: deepest raw compression %.4f mm", deepest(FlexibleFEField(solution: sr, simID: sim.id, generation: req.generation))))

        // nothing written but the links; no job byte moved
        XCTAssertFalse(m.settings.faces.contains { $0.role == "resting" }, "★ no Rest written")
        XCTAssertEqual(try m.runJobJSON(), jobBefore, "★ the job is byte-identical through the sims")
        _ = enc
    }

    /// His l-bracket's Face 2 / Face 6 centre ratio with the 4 walls linked, as the I3 probe MEASURED it (this test's first run).
    static let measuredRatio = 0.952   // run 1 (2026-10-22 13:09): u_x Face 2 window 4.7667 / Face 6 5.0085

    // MARK: 2 — a link re-solves the sims, never the lattice; a late answer of the old links is dropped; its Undo re-solves

    func testOnHisLBracketALinkReSolvesWithoutARebuildAndItsUndoToo() async throws {
        let (r, m) = try await opened(FlexibleU21DeleteUndoTests.lbracketDir, "his l-bracket")
        let p = r.project
        let l = try await FlexibleSquishFixture.build(m, "his l-bracket")
        try await FlexibleSquishFixture.solve(m, "his l-bracket")
        let g = try XCTUnwrap(m.squeezeGroups.first)
        let id = FlexibleSim.groupID(g.number)
        let before = try XCTUnwrap(m.squish[id]?.field)
        XCTAssertEqual(before.bcMode, "anchor", "premise: no link — Topology's fixed faces hold it (I1)")
        XCTAssertEqual(m.holdLine(g), "Held by Group A · fixed on Topology")
        let e0 = m.holdEpoch, key0 = m.latticeSettingsKey

        // the suggestion's one tap, then the change the stage hears (projectChanged → relinkIfNeeded)
        let opened = p.lattice.flexible
        _ = try linkTheFourWalls(p)
        // found by LOOKING (I3_02): a link is not a Squish-page change — never "Save & Exit builds the lattice"
        let now = try XCTUnwrap(p.lattice.flexible)
        XCTAssertFalse(FlexibleSettingsExit.modified(now, since: opened), "★ the Squish page reads 'nothing changed yet'")
        FlexibleSettingsExit.controlLinksModifySettings = true
        XCTAssertTrue(FlexibleSettingsExit.modified(now, since: opened), "★ RED CONTROL: links counted as a Squish change")
        FlexibleSettingsExit.controlLinksModifySettings = false
        XCTAssertEqual(m.latticeSettingsKey, key0, "★ a link never re-keys the lattice")
        XCTAssertFalse(m.latticeIsStale, "★ … nor puts it out of date")
        m.relinkIfNeeded()
        XCTAssertEqual(m.holdEpoch, e0 + 1, "★ a new hold epoch")
        XCTAssertEqual(m.shownWalls[id]?.count, 4)
        XCTAssertEqual(m.squish[id], .pending, "the sims run again (the lattice stays)")
        try await FlexibleSquishFixture.solve(m, "his l-bracket relinked")
        XCTAssertEqual(m.lattice?.generation, l.generation, "★ no rebuild: the same lattice")
        XCTAssertFalse(m.latticeBuilding)
        let linked = try XCTUnwrap(m.squish[id]?.field)
        XCTAssertEqual(linked.bcMode, "wall")
        XCTAssertEqual(linked.holdEpoch, e0 + 1, "★ the new field lands with holdEpoch + 1")
        XCTAssertEqual(m.holdLine(g), "Held by 4 linked walls")
        m.relinkIfNeeded()
        XCTAssertEqual(m.holdEpoch, e0 + 1, "nothing moved: no second solve")

        // a late answer of the links before (the old epoch) is discarded
        m.squishLanded(l.generation, id, .ready(before), epoch: e0)
        XCTAssertEqual(m.squish[id]?.field?.bcMode, "wall", "★ the stale hold's answer is dropped")
        // ★ RED CONTROL: a generation-only guard shows it
        FlexibleStageModel.controlGenerationOnlyGuard = true
        m.squishLanded(l.generation, id, .ready(before), epoch: e0)
        FlexibleStageModel.controlGenerationOnlyGuard = false
        XCTAssertEqual(m.squish[id]?.field?.bcMode, "anchor", "★ RED CONTROL: the old links' answer overwrote the shown one")
        m.squishLanded(l.generation, id, .ready(linked), epoch: e0 + 1)

        // ★ RED CONTROL: links in designInputs → the lattice goes out of date (a rebuild on every tap)
        FlexibleStageSettings.controlLinksInDesignInputs = true
        XCTAssertNotEqual(m.latticeSettingsKey, key0, "★ RED CONTROL: links in the key re-key the lattice")
        FlexibleStageSettings.controlLinksInDesignInputs = false

        // the toolbar Undo of the suggestion (one step) — ★ RED CONTROL first: no relink on history
        m.controlNoRelink = true
        p.performUndo()
        m.historyRestored()
        XCTAssertNil(p.lattice.flexible?.links, "the one Undo removes all 4")
        XCTAssertEqual(m.holdEpoch, e0 + 1, "★ RED CONTROL: the old hold epoch kept")
        XCTAssertEqual(m.shownWalls[id]?.count, 4, "★ RED CONTROL: the shown field keeps the 4 walls")
        m.controlNoRelink = false
        m.historyRestored()
        XCTAssertEqual(m.holdEpoch, e0 + 2, "★ the Undo re-solves")
        XCTAssertNil(m.shownWalls[id])
        try await FlexibleSquishFixture.solve(m, "his l-bracket undone")
        XCTAssertEqual(m.squish[id]?.field?.bcMode, "anchor", "★ back to Topology's fixed faces")
        XCTAssertEqual(m.lattice?.generation, l.generation, "still no rebuild")
        XCTAssertEqual(m.holdLine(g), "Held by Group A · fixed on Topology")
    }

    // MARK: 3 — a wall that pins nothing says so; links and Rests hold together; only this group's lattices count; the copy

    func testOnHisPadAFloorLinkHoldsBesideTheRestsOnlyForItsGroupAndAnEmptyWallIsDropped() async throws {
        let (r, m) = try await opened(FlexibleU21DeleteUndoTests.padDir, "his pad of 10-21")
        let p = r.project
        _ = try await FlexibleSquishFixture.build(m, "his pad")
        try await FlexibleSquishFixture.solve(m, "his pad")
        let req0 = try XCTUnwrap(m.lastFERequest)
        XCTAssertEqual(req0.walls, [:], "premise: no link on his pad")
        XCTAssertFalse(m.holdResting.isEmpty, "premise: his pad has Rests")

        // Face 5's lattice floor → the solid under it (P0: the 32 mm middle)
        let key5 = LatticeSelectableRef.face(group: FlexibleI2AttachTests.groupC, face: 5).key
        let w5 = try XCTUnwrap(FlexibleLatticeWalls.walls(project: p, key: key5))
        XCTAssertEqual(w5.floor?.target, "under", "premise: Face 5's lattice has a floor on solid")
        XCTAssertTrue(FlexibleFaceCommits.addLink(lattice: key5, wall: "floor", target: "under", project: p))
        let walls = m.linkWalls()
        var groupsWith: [Int] = [], groupsWithout: [Int] = []
        for g in m.squeezeGroups {
            let faces = Set(m.holdInputs(g).pressed.flatMap { m.regions.faces(of: $0, mesh: p.viewerMesh) })
            if faces.contains(5) {
                groupsWith.append(g.number)
                XCTAssertEqual(walls[FlexibleSim.groupID(g.number)]?.count, 1, "★ group \(g.number) presses Face 5: its floor holds it")
            } else {
                groupsWithout.append(g.number)
                XCTAssertNil(walls[FlexibleSim.groupID(g.number)], "★ group \(g.number) presses no linked lattice: no wall")
            }
        }
        print("FLEX-I3 pad: groups pressing Face 5 \(groupsWith) · others \(groupsWithout)")
        XCTAssertFalse(groupsWith.isEmpty, "premise: a group presses Face 5")
        XCTAssertFalse(groupsWithout.isEmpty, "premise: a group presses elsewhere")
        // ★ RED CONTROL: every link holds every group
        FlexibleStageModel.controlEveryLinkHoldsEveryGroup = true
        let every = m.linkWalls()
        FlexibleStageModel.controlEveryLinkHoldsEveryGroup = false
        for n in groupsWithout { XCTAssertEqual(every[FlexibleSim.groupID(n)]?.count, 1, "★ RED CONTROL: group \(n) sent Face 5's floor") }

        // the bridge: the floor holds beside the Rests (bc rest, the far anvil replaced), and a wall in the air holds nothing
        let ref = await m.squishWorker.sceneRef()
        let scene = try XCTUnwrap(ref)
        let sim = try XCTUnwrap(req0.sims.first { s in groupsWith.contains { FlexibleSim.groupID($0) == s.id } }, "a face group pressing Face 5")
        let gid = sim.id
        let today = try scene.squishSolve(req0.request(sim))
        let air = FlexHeldWallInfo(m: SIMD3(0, 0, 1), quads: [0, 0, 500, 10, 0, 500, 10, 10, 500, 0, 10, 500], tag: 9)
        let withWalls = req0.with(walls: [gid: (walls[gid] ?? []) + [air]], epoch: 1)
        let s = try scene.squishSolve(withWalls.request(sim))
        print(String(format: "FLEX-I3 pad %@ floor link + Rests: bc %@ · wall nodes %@ (reach %@) · far anvils %d (today %d) · free modes %d (today %d) · exits held %@ · max|u| raw %.4f (today %.4f)",
                     gid, s.bcMode, "\(s.wallNodes)", "\(s.wallReachMM)", s.farAnvils, today.farAnvils, s.freeModes, today.freeModes,
                     "\(s.exitsHeld)", s.u.map(abs).max() ?? 0, today.u.map(abs).max() ?? 0))
        XCTAssertEqual(s.bcMode, "rest", "★ the Rests still hold (links and Rests together)")
        XCTAssertEqual(s.wallNodes.count, 2)
        XCTAssertGreaterThan(s.wallNodes[0], 0, "★ the floor link pins the solid under it")
        XCTAssertEqual(s.wallNodes[1], 0, "★ the wall in the air pins nothing — reported, never silent")
        XCTAssertEqual(s.wallReachMM[1], 2 * s.spacing, accuracy: 1e-9, "it was tried again at 2 h")
        // ★ RE-PINNED (his answer of 2026-10-22 ~16:10, "All hold"): the link never drops the group's far anvil (here none today)
        XCTAssertEqual(s.farAnvils, today.farAnvils, "★ links and Rests both hold: today's far anvils kept")
        XCTAssertNotEqual(s.u, today.u, "the link changes the field")
        let wallsHeld = s.wallNodes.filter { $0 > 0 }.count
        let k = FlexibleHold.landed(.rests(m.holdResting.count), bcMode: s.bcMode, anchorsHeld: [], anchors: [], farFaces: [],
                                    wallsHeld: wallsHeld, resting: m.holdResting.count)
        XCTAssertEqual(FlexibleHold.line(k), "Held by 1 linked wall + \(m.holdResting.count) Rests",
                       "★ the line counts only the wall that held")
        // ★ RED CONTROL: counting every wall sent (the empty one too)
        let red = FlexibleHold.landed(.rests(2), bcMode: s.bcMode, anchorsHeld: [], anchors: [], farFaces: [],
                                      wallsHeld: s.wallNodes.count, resting: m.holdResting.count)
        XCTAssertNotEqual(FlexibleHold.line(red), FlexibleHold.line(k), "★ RED CONTROL: the empty wall counted")

        // no link: a rest group stays byte-identical to today (rule 0, no wall)
        let none = try scene.squishSolve(req0.with(walls: [:], epoch: 2).request(sim))
        XCTAssertEqual(none.u, today.u, "★ no link: today's field, byte for byte")
        XCTAssertEqual(none.pinnedDOFs, today.pinnedDOFs)
        XCTAssertEqual(none.farAnvils, today.farAnvils)

        // the copy (≤ 44, one line; "·" and "+" count as drawn)
        func fits(_ t: String) -> Bool { t.count <= FlexibleRowCopy.maxChars && !t.contains("\n") }
        for t in [FlexibleHold.line(.links(1, rests: 0)), FlexibleHold.line(.links(4, rests: 0)), FlexibleHold.line(.links(12, rests: 1)),
                  FlexibleHold.line(.links(123, rests: 123))] { XCTAssertTrue(fits(t), "≤ 44: '\(t)' (\(t.count))") }
        XCTAssertEqual(FlexibleHold.line(.links(1, rests: 0)), "Held by 1 linked wall")
        XCTAssertEqual(FlexibleHold.line(.links(4, rests: 1)), "Held by 4 linked walls + its Rest")
        XCTAssertEqual(FlexibleHold.line(.links(4, rests: 5)), "Held by 4 linked walls + 5 Rests")
        XCTAssertFalse(fits("Held by 1234567 linked walls + 1234567 Rests."), "★ RED CONTROL: 45 characters fail the checker")
    }

    // MARK: 4 — ★ LINKS AND RESTS BOTH HOLD (his answer of 2026-10-22 ~16:10, verbatim: "All hold. Links and far side wall that is
    // set to rest. If the user has set both up, they intended both to be implemented. So both should act on the model.")

    /// The bridge's RED control bit: I3's first rule — linked walls take a rest group's far anvil's place (FlexibleBridge.hpp).
    static let controlLinksReplaceFarAnvil = 262144

    func testOnHisPadALinkInARestGroupKeepsTheFarWallHeldBesideTheRests() async throws {
        let (r, m) = try await opened(FlexibleU21DeleteUndoTests.padDir, "his pad of 10-21")
        let p = r.project
        _ = try await FlexibleSquishFixture.build(m, "his pad")
        try await FlexibleSquishFixture.solve(m, "his pad")
        let req0 = try XCTUnwrap(m.lastFERequest)
        XCTAssertFalse(req0.resting.isEmpty, "premise: his pad has Rests (\(req0.resting))")
        // his link: Face 5's lattice floor → the solid under it (test 3's), on the group that presses Face 5
        let key5 = LatticeSelectableRef.face(group: FlexibleI2AttachTests.groupC, face: 5).key
        XCTAssertTrue(FlexibleFaceCommits.addLink(lattice: key5, wall: "floor", target: "under", project: p))
        let walls = m.linkWalls()
        let sim = try XCTUnwrap(req0.sims.first { walls[$0.id] != nil }, "a rest group with the link (\(walls.keys.sorted()))")
        let ref = await m.squishWorker.sceneRef()
        let scene = try XCTUnwrap(ref)
        // the far wall: an exit face of the group's stacks that nothing presses and nothing rests on — held today by batch G's far
        // anvil. FOUND BY THE FIRST RUN: on his pad as saved every exit of group 1 rests (with both Rests, and with either alone:
        // far anvils 0, exits held) — the far wall IS a Rest, held whether or not a link exists, so nothing there can drop. The
        // case his answer is about appears when the group presses ONE of its faces: Face 5 alone (his link's lattice first), his
        // Rests set — its far side (the face across the stack) is then the far wall the anvil holds (batch G's Group 2 case).
        let part = try XCTUnwrap(p.viewerMesh)
        let byFive = sim.pressed.sorted { a, b in
            let fa = m.regions.faces(of: a.face, mesh: part).contains(5), fb = m.regions.faces(of: b.face, mesh: part).contains(5)
            return fa && !fb
        }
        var pick: (pressed: [FlexSquishPressInfo], rests: [Int], today: FlexSquishSolutionInfo)?
        var tried: [String] = []
        search: for pressed in [sim.pressed] + byFive.map({ [$0] }) {
            for rests in [req0.resting] + req0.resting.map({ x in req0.resting.filter { $0 != x } }) where !rests.isEmpty {
                var q = req0.with(walls: [:], epoch: 0).request(sim)
                q.pressed = pressed
                q.restingIDs = rests
                let t = try scene.squishSolve(q)
                tried.append("pressed \(pressed.map(\.face)) rests \(rests): bc \(t.bcMode) · far anvils \(t.farAnvils) · exits held \(t.exitsHeld)")
                if t.bcMode == "rest", t.farAnvils > 0 { pick = (pressed, rests, t); break search }
            }
        }
        print("FLEX-LR \(sim.id) today: " + tried.joined(separator: " | "))
        let (pressed, rests, today) = try XCTUnwrap(pick, "premise: a rest group of his pad with a far wall (\(tried))")
        XCTAssertTrue(today.exitsHeld, "premise: today every exit is held (a Rest or the far anvil)")

        func solve(walls w: [FlexHeldWallInfo], control: Int = 0) throws -> FlexSquishSolutionInfo {
            var q = req0.with(walls: w.isEmpty ? [:] : [sim.id: w], epoch: 1).request(sim, control: control)
            q.pressed = pressed
            q.restingIDs = rests
            return try scene.squishSolve(q)
        }
        let link = try XCTUnwrap(walls[sim.id])
        let s = try solve(walls: link)
        let todayPins = Set(today.pinnedDOFs), pins = Set(s.pinnedDOFs)
        print(String(format: "FLEX-LR %@ pressed \(pressed.map(\.face)) rests %@ + 1 link: bc %@ · wall nodes %@ · far anvils %d (today %d) · exits held %@ · pinned %d (today %d, kept %d) · max|u| %.4f (today %.4f)",
                     sim.id, "\(rests)", s.bcMode, "\(s.wallNodes)", s.farAnvils, today.farAnvils, "\(s.exitsHeld)", pins.count,
                     todayPins.count, todayPins.intersection(pins).count, s.u.map(abs).max() ?? 0, today.u.map(abs).max() ?? 0))
        XCTAssertEqual(s.bcMode, "rest", "★ the Rests hold")
        XCTAssertTrue(s.wallNodes.allSatisfy { $0 > 0 }, "★ the linked wall holds (\(s.wallNodes))")
        XCTAssertEqual(s.farAnvils, today.farAnvils, "★ the far wall stays held beside the link (both act)")
        XCTAssertTrue(s.exitsHeld, "★ every exit still held")
        // (held nodes, not pinned DOFs: FOUND BY THE SECOND RUN — today's chain leaves a rigid mode its rests and anvil do not stop,
        // and the bridge pins ONE more DOF for it; with the bonded link no mode is left, so that anchor pin is not needed)
        let todayHeld = Set(today.heldNodes), held = Set(s.heldNodes)
        print("FLEX-LR held nodes: \(held.count) (today \(todayHeld.count), kept \(todayHeld.intersection(held).count)) · free modes \(s.freeModes) (today \(today.freeModes))")
        XCTAssertTrue(todayHeld.isSubset(of: held), "★ every hold of today's chain still acts (\(todayHeld.subtracting(held).count) dropped)")
        XCTAssertGreaterThan(held.count, todayHeld.count, "★ and the link adds its own")
        // the line counts the wall beside the Rests
        let k = FlexibleHold.landed(.rests(rests.count), bcMode: s.bcMode, anchorsHeld: [], anchors: [], farFaces: [],
                                    wallsHeld: s.wallNodes.filter { $0 > 0 }.count, resting: rests.count)
        XCTAssertEqual(FlexibleHold.line(k), FlexibleRowCopy.Hold.links(1, rests: rests.count))

        // ★ RED CONTROL: I3's first rule — the link takes the far anvil's place: the far wall is dropped
        let red = try solve(walls: link, control: Self.controlLinksReplaceFarAnvil)
        print("FLEX-LR RED (links replace the far anvil): far anvils \(red.farAnvils) · exits held \(red.exitsHeld) · today's held nodes kept \(Set(red.heldNodes).intersection(todayHeld).count)/\(todayHeld.count)")
        XCTAssertEqual(red.farAnvils, 0, "★ RED CONTROL: the far anvil dropped")
        XCTAssertFalse(red.exitsHeld, "★ RED CONTROL: the far wall reported free")
        XCTAssertFalse(todayHeld.isSubset(of: Set(red.heldNodes)), "★ RED CONTROL: today's far-wall holds are gone")

        // no link: byte for byte today (the control bit changes nothing without a wall)
        let none = try solve(walls: [])
        XCTAssertEqual(none.u, today.u, "★ a rest group with no link: today's field, byte for byte")
        XCTAssertEqual(none.pinnedDOFs, today.pinnedDOFs)
        let noneRed = try solve(walls: [], control: Self.controlLinksReplaceFarAnvil)
        XCTAssertEqual(noneRed.u, today.u, "no link: the control bit is inert")
    }
}
