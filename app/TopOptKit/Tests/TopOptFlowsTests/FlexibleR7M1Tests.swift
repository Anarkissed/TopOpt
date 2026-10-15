// FlexibleR7M1Tests — round 7 batch M1 (round 7 step 2a, 2026-10-14), written BEFORE the code (the stubs' red run:
// docs/handoffs/evidence/2026-09-29-flexible-screens/round7/batch_m1/r7m1_red_run.txt). Each test runs its RED control
// inside. His pad is A1_0003 as he saved it (frozen; NO face-prism set), and — where the subject is the face-prism — the
// same pad with HIS LIVE LATTICE (his simulator's copy of 2026-10-14, read only: Group C = Face 3 + Face 5, protected,
// Lattice at 25 mm each; the Top's face Off), applied through the main page's own setters (`hisLiveLattice`).
//   M1-H18  "Remove the "Protect 3mm" chip" / Minimize plastic (his answer: remove it): FlexibleMainChips.hidden, and hook
//           H18 as the first statement of the chips' filter. NOT .cadFaces (the reviewer's ruling). RED controlNothingHidden.
//   M1-H15' "The face-prism depth in the modal and on the face-prism are not equal? … they should *always* be equal" and
//           img2's "What is this 12mm?": the main page's prism IS the picked group's LATTICE face-prism (#354's own
//           LatticeDepthPlane, at its depth — the list's number), never a squish prism; [Prisms] = every face-prism of the
//           picked group. RED controlSquishPrismsOnMain (round 6's squish prism: 24.5 mm on Face 3, the Top's 12 mm).
//   M1-1a   "ONLY the face-prism creates the lattice structure in any area": no face-prism ⇒ no lattice (the stacks keep no
//           lattice, the build refuses, the main page draws the plain model, the pill says "Set a face to Lattice in
//           Selections first", the SEND gate refuses — ruling 4, red first). RED controlWholePartWithoutPrism.
//   M1-5    an edges group beside a face group: Export makes ONE group and SAYS so before anything is sent ("This export
//           makes Group 1 only. Edges and faces go in separate exports for now."). RED controlEdgesSilentlyDropped (today:
//           the face group sent, the edges group dropped without a word).
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
enum FlexibleR7M1Fixtures {

    /// HIS LIVE LATTICE on his pad (his simulator's A1_0003, 2026-10-14 — read only, never written): Group C holds Face 3
    /// and Face 5, protected, its role Lattice, each face 25 mm; the Top's group Lattice with its Face 1 Off (21 mm stored).
    /// Through the main page's own setters (the Selections row's). Returns Group C's id.
    @discardableResult
    static func hisLiveLattice(_ p: ProjectModel) throws -> UUID {
        let c = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" }, "his Group C")
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" }, "his Top")
        p.selection.addFaces([5], to: c.id)
        p.force.sync(groups: p.selection.groups)
        p.force.setProtected(c.id, true)
        p.lattice.enabled = true
        p.lattice.groupRoles[c.id] = .include
        p.lattice.groupRoles[top.id] = .include
        p.lattice.groupDepthMM[c.id] = 4
        p.lattice.groupDepthMM[top.id] = 4
        p.lattice.selectableRoles[LatticeSelectableRef.face(group: c.id, face: 3).key] = .include
        p.lattice.selectableRoles[LatticeSelectableRef.face(group: top.id, face: 1).key] = .off
        p.writeLatticeDepthMM(.face(group: c.id, face: 3), mm: 25)
        p.writeLatticeDepthMM(.face(group: c.id, face: 5), mm: 25)
        p.writeLatticeDepthMM(.face(group: top.id, face: 1), mm: 21)
        return c.id
    }

    /// His pad on a main stage (the shared model), settled; `live`: with his live lattice.
    /// `wholePartControl`: the RED CONTROL from the scene's first open (core's stacks kept as they come — the whole part).
    static func hisPad(_ test: XCTestCase, live: Bool, wholePartControl: Bool = false) async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexiblePressFixtures.a1Project(3, test, facePrism: false)   // as he saved it: no face-prism
        if live { try hisLiveLattice(r.project) }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        m.controlWholePartWithoutPrism = wholePartControl
        test.addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his pad")
        return (r, s, m)
    }

    /// The include face-prisms of group `g` (the Selections modal's rows: Lattice), #354's own planes.
    static func facePrisms(_ p: ProjectModel, group g: UUID) -> [ProjectModel.LatticeDepthPlane] {
        p.latticeDepthPlanes().filter { $0.groupID == g && $0.role == .include }
    }
}

@MainActor
final class FlexibleR7M1Tests: XCTestCase {
    typealias F = FlexibleR7M1Fixtures

    // MARK: - M1-H18: Topology's two chips are off the Flexible stage

    func testProtectAndMinimizePlasticAreOffTheFlexibleStageAndNothingElseIs() throws {
        let all = SettingsChipID.allCases
        let owned = FlexibleMainChips.visible(all, owned: true)
        XCTAssertFalse(owned.contains(.faceProtectDepth), "★ \"Protect 3 mm\" is off the Flexible stage (his img1)")
        XCTAssertFalse(owned.contains(.minimizePlastic), "★ \"Minimize plastic\" is off the Flexible stage (his answer)")
        for kept in [SettingsChipID.quality, .buildOrientation, .gravity] {
            XCTAssertTrue(owned.contains(kept), "\(kept) stays: a live Flexible input")
        }
        XCTAssertTrue(owned.contains(.cadFaces), "★ the reviewer's ruling: H18 does NOT hide CAD surfaces (the redesign's H24)")
        XCTAssertEqual(FlexibleMainChips.hidden, [.faceProtectDepth, .minimizePlastic], "exactly the two approved chips")
        XCTAssertEqual(FlexibleMainChips.visible(all, owned: false), all, "every other stage: every chip, as today")
        // ★ RED CONTROL: nothing hidden — his img1 column ("Protect 3 mm", "Minimize plastic")
        FlexibleMainChips.controlNothingHidden = true
        let control = FlexibleMainChips.visible(all, owned: true)
        FlexibleMainChips.controlNothingHidden = false
        XCTAssertTrue(control.contains(.faceProtectDepth) && control.contains(.minimizePlastic), "★ RED CONTROL: today's column")
        print("FLEX-R7M1-H18 owned \(owned) · control \(control)")
    }

    /// The two approved hooks, each a stage switch at its anchor in #354's WorkspacePlaceholder (and nothing else of the
    /// file moves): H15' edits H15's line; H18 is the first statement of the chips' filter.
    func testH15PrimeAndH18AreStageSwitchesAtTheirAnchors() throws {
        let ws = try FlexibleSource.text("WorkspacePlaceholder.swift")
        let code = try FlexibleSource.code("WorkspacePlaceholder.swift")
        // H15': on the Flexible stage ONLY the main page's face-prisms; #354's slabs everywhere else, as before
        let h15p = "? (flexibleMain.owns(project, stage) ? [] : stageVolumeItems) + flexibleMain.volumes(project, on: stage, drilledIn: legendDrilledIn) : flexibleMain.volumes(project, on: stage, drilledIn: legendDrilledIn),   // Flexible (PR #362) H15':"
        XCTAssertEqual(ws.components(separatedBy: h15p).count - 1, 1, "★ H15' is one line at H15's anchor")
        XCTAssertFalse(code.contains("? stageVolumeItems + flexibleMain.volumes("), "★ H15's old line is gone (+1 −1)")
        XCTAssertEqual(code.components(separatedBy: "flexibleMain.volumes(").count - 1, 2, "volumes( is asked only on H15's line")
        // H18: the first statement of the filter; #354's own cases untouched
        let h18 = "SettingsChipID.allCases.filter { id in\n            if flexibleMain.owns(project, stage), FlexibleMainChips.hidden.contains(id) { return false }   // Flexible (PR #362) H18:"
        XCTAssertEqual(ws.components(separatedBy: h18).count - 1, 1, "★ H18 is the first statement inside the chips' filter")
        XCTAssertTrue(code.contains("case .faceProtectDepth: return force.explicitProtectCount(in: selection.groups) > 0"), "#354's rule stays")
        XCTAssertTrue(code.contains("case .cadFaces: return isStepPart"), "CAD surfaces: #354's rule, untouched (not in H18)")
        XCTAssertEqual(code.components(separatedBy: "FlexibleMainChips").count - 1, 1, "H18 is the only line that reads FlexibleMainChips")
    }

    // MARK: - M1-H15': the main page's prism IS the lattice face-prism, at the list's depth

    func testThePrismIsThePickedGroupsLatticeFacePrismAtTheListsDepth() async throws {
        let (r, s, m) = try await F.hisPad(self, live: true)
        let p = r.project
        let c = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" })
        let planes = F.facePrisms(p, group: c.id)
        XCTAssertEqual(Set(planes.map(\.faceKey)), [3, 5], "premise: his Group C's two face-prisms (Face 3 + Face 5)")
        XCTAssertTrue(s.volumes(p, on: .lattice, drilledIn: false).isEmpty, "nothing before his pick (his fixed rule)")
        p.selection.setActive(c.id)
        XCTAssertTrue(s.sessionPicked, "premise: his pick of Group C")
        let items = s.volumes(p, on: .lattice, drilledIn: false)
        XCTAssertEqual(items.count, 2, "★ Group C's face-prisms, and nothing else")
        for plane in planes {
            let item = try XCTUnwrap(items.first { $0.volume.faceID == plane.faceKey }, "Face \(plane.faceKey)'s prism")
            XCTAssertEqual(item.volume, plane.volume, "★ the drawn volume IS #354's face-prism (one shape for the list and the page)")
            XCTAssertEqual(item.tint, FlexibleStageStyle.facePrismTint, "the face-prism violet")
            guard case .shell(let sh) = item.volume.shape else { return XCTFail("a face-prism is a shell") }
            XCTAssertEqual(sh.reachedDepthMM, plane.depthMM, accuracy: 1e-6, "★ drawn at the list's depth")
            let list = String(format: "%.1f mm", p.latticeSlabDepthMM(plane.ref, in: c.id))   // the modal's own formatter
            XCTAssertEqual(String(format: "%.1f mm", sh.reachedDepthMM), list)
            XCTAssertEqual(list, "25.0 mm")
        }
        // img1's state: Face 3's SQUISH depth (Settings) is 24.5 — the main page's prism still reads the list's 25
        XCTAssertEqual(m.settings.face(3)?.deepestMM, 24.5, "premise: img1's 24.5 mm is Face 3's squish depth")
        // a typed depth moves both (one store)
        p.writeLatticeDepthMM(.face(group: c.id, face: 3), mm: 17.26)
        let moved = try XCTUnwrap(s.volumes(p, on: .lattice, drilledIn: false).first { $0.volume.faceID == 3 })
        guard case .shell(let sh3) = moved.volume.shape else { return XCTFail("a shell") }
        XCTAssertEqual(String(format: "%.1f mm", sh3.reachedDepthMM), String(format: "%.1f mm", p.latticeSlabDepthMM(.face(group: c.id, face: 3), in: c.id)))
        XCTAssertEqual(String(format: "%.1f mm", sh3.reachedDepthMM), "17.3 mm", "★ the list's 17.3, on the model too")
        // ★ RED CONTROL: round 6's squish prisms (S1b) — under [Prisms] (as in his img1) Face 3 drawn at its SQUISH depth
        // (24.5 mm × k), not the list's 25.0 (a Protect-only group's own prisms were never drawn: batch V's Pending rule)
        p.writeLatticeDepthMM(.face(group: c.id, face: 3), mm: 25)
        s.controlSquishPrismsOnMain = true
        m.views.insert(.prisms)
        let control = s.volumes(p, on: .lattice, drilledIn: false)
        m.views.remove(.prisms)
        s.controlSquishPrismsOnMain = false
        let squish3 = control.first { $0.volume.faceID == 3 }.flatMap { FlexibleDepthPrism.handle($0.volume) }
        XCTAssertNotNil(squish3, "★ RED CONTROL: the squish prism on Face 3")
        XCTAssertNotEqual(control.map(\.volume), items.map(\.volume), "★ RED CONTROL: not the lattice face-prisms")
        print("FLEX-R7M1-H15' Group C picked: \(items.map { $0.volume.faceID }) at \(planes.map { $0.depthMM }) mm (list \(planes.map { p.latticeSlabDepthMM($0.ref, in: c.id) })) · control squish items \(control.map { $0.volume.faceID })")
    }

    /// His img2: "What is this 12mm? … please remove whatever it is" — it was the Top's SQUISH prism (its group owns the Top's
    /// weight). The Top is Off in Selections: no face-prism, so nothing is drawn after picking the Top.
    func testPickingTheTopDrawsNoPrismItsFaceIsOffInSelections() async throws {
        let (r, s, _) = try await F.hisPad(self, live: true)
        let p = r.project
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        XCTAssertTrue(F.facePrisms(p, group: top.id).isEmpty, "premise: the Top's face is Off in Selections")
        p.selection.setActive(top.id)
        XCTAssertTrue(s.sessionPicked)
        XCTAssertEqual(s.volumes(p, on: .lattice, drilledIn: false), [], "★ no prism after picking the Top (img2's 12 mm)")
        // ★ RED CONTROL: the squish prism of the Top (its group owns the Top's weight) — img2's prism
        s.controlSquishPrismsOnMain = true
        let control = s.volumes(p, on: .lattice, drilledIn: false).map(\.volume.faceID)
        s.controlSquishPrismsOnMain = false
        XCTAssertEqual(control, [1], "★ RED CONTROL: the Top's squish prism returns")
        print("FLEX-R7M1-img2 Top picked: [] · control \(control)")
    }

    /// [Prisms] = every face-prism of the picked group (brighter), its legend row the face-prism's; X-ray on with it.
    func testPrismsIsEveryFacePrismOfThePickedGroup() async throws {
        let (r, s, m) = try await F.hisPad(self, live: true)
        let p = r.project
        let c = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" })
        s.togglePrisms()
        XCTAssertTrue(s.prismsOn)
        // ★ RE-PINNED (M1 verify — the verify: "[Prisms] does nothing visible on the model"; his round-6 words for the view:
        // "ALL … prisms"): was "[Prisms] before a pick: nothing"; now every group's face-prisms (his live lattice: Group C's),
        // none brighter (FlexibleR7M1VerifyTests V3)
        XCTAssertEqual(Set(s.volumes(p, on: .lattice, drilledIn: false).map(\.volume.faceID)), [3, 5], "★ [Prisms] before a pick: every group's")
        p.selection.setActive(c.id)
        let on = s.volumes(p, on: .lattice, drilledIn: false)
        XCTAssertEqual(Set(on.map(\.volume.faceID)), [3, 5], "★ every face-prism of the picked group")
        XCTAssertTrue(on.allSatisfy { $0.selected && $0.faceAlpha == nil }, "#354's own look for the active group's face-prism")
        XCTAssertTrue(s.xrayOn, "[Prisms] turns X-ray on (a prism sits inside the part)")
        XCTAssertTrue(s.legendPrismsRow, "[Prisms] puts its row in the ONE legend card")
        XCTAssertEqual(FlexibleRowCopy.mainFacePrismsRow, "Face-prism = where the lattice goes")
        XCTAssertLessThanOrEqual(FlexibleRowCopy.mainFacePrismsRow.count, FlexibleRowCopy.maxChars)
        m.views.remove(.prisms)
        let off = s.volumes(p, on: .lattice, drilledIn: false)
        XCTAssertEqual(off, on, "the picked group's face-prisms without [Prisms] too — the same face-prisms (his fixed rule)")
        XCTAssertFalse(s.legendPrismsRow)
        XCTAssertTrue(s.volumes(p, on: .topology, drilledIn: false).isEmpty, "off the Flexible stage: nothing")
        XCTAssertTrue(s.volumes(p, on: .lattice, drilledIn: true).isEmpty, "while a legend reads: nothing")
    }

    // MARK: - M1-1a: no face-prism ⇒ no lattice

    func testNoFacePrismMeansNoLatticeAnywhere() async throws {
        let (r, s, m) = try await F.hisPad(self, live: false)
        let p = r.project
        XCTAssertFalse(LatticeJobIncludeGate.hasIncludeWall(p.latticeJobRegions().regions), "premise: his pad as saved sets no face-prism")
        XCTAssertFalse(m.facePrismsSet)
        XCTAssertFalse(m.facePrismsNow)
        // core itself lattices the whole part (its rule for no include region): the override is the app's
        let k1 = try XCTUnwrap(m.key(1))
        let coreTop = try await m.workerForTests.withScene { try $0.stack(face: k1.region, rotation: k1.rotation) }
        XCTAssertGreaterThan(coreTop.latticedColumns, 0, "premise: core's own stack of the Top is latticed (whole part)")
        // ★ every stack the stage keeps: no lattice on any column's path
        for k in m.loadedKeys {
            let st = try XCTUnwrap(m.stacks[k], "Face \(k.region)'s stack")
            XCTAssertEqual(st.latticedColumns, 0, "★ Face \(k.region): no latticed column")
            XCTAssertEqual(st.latticeMMMax, 0, "★ Face \(k.region): no lattice depth")
            XCTAssertTrue(st.columns.allSatisfy { $0.latticeMM == 0 })
        }
        // ★ the readiness says it of every pressed face, with the one-tap fix
        let under = m.readiness.issues.filter { $0.kind == .noLatticeUnder }
        XCTAssertEqual(Set(under.compactMap(\.region)), Set(m.settings.loadedFaces.map(\.faceRegionID)), "★ \"No lattice under\" every pressed face")
        XCTAssertTrue(under.allSatisfy { $0.pill.hasPrefix("No lattice under") })
        // ★ the build refuses — no lattice, no failure
        m.generateLattice()
        XCTAssertNil(m.lattice, "★ no lattice is built")
        XCTAssertFalse(m.latticeBuilding)
        XCTAssertNil(m.latticeFailure, "★ not a failure: nothing to build")
        XCTAssertFalse(FlexibleLatticeView.available(model: m), "★ the Lattice view has nothing to show")
        // ★ the main page: the plain model and the one line
        s.apply(p, owned: true, pageUp: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        await m.waitForIdle()
        s.refresh()
        XCTAssertNil(m.lattice)
        XCTAssertTrue(s.layer(p, stage: .lattice, pageUp: false)?.hidden ?? true, "★ no wall drawn")
        XCTAssertNil(s.dents(p, on: .lattice), "★ no dent: the plain model")
        // (looking at the first pictures: his None pad's X-ray default drew an empty dark ghost — with no face-prism the
        // default is the opaque model; his own X-ray tap still wins)
        XCTAssertFalse(s.xrayOn, "★ X-ray off by default with no face-prism (nothing inside to see)")
        XCTAssertEqual(s.bodyAlpha(p, on: .lattice), 1, "★ the plain, opaque model")
        XCTAssertFalse(s.legendKinds.contains(.dent), "no dent scale")
        let st = s.status
        XCTAssertEqual(st.line, FlexibleRowCopy.noFacePrism, "★ the pill says what to do")
        XCTAssertEqual(st.line, "Set a face to Lattice in Selections first")
        XCTAssertLessThanOrEqual(st.line.count, FlexibleRowCopy.maxChars)
        // ★ RE-PINNED (M1 verify — the verify: the words pointed to Selections, the tap opened the Squish page's [Lattice under
        // all N], three new groups and the whole pad latticed again; ruling 4: "Export disabled with a stated reason"): was
        // `.fix` / `.openSettings`; now disabled on the main page with its reason, to the Lattice stage from another stage
        XCTAssertEqual(st.tone, .blocked)
        XCTAssertEqual(st.tap, .toSelections, "never core, never the Squish page's fix (FlexibleR7M1VerifyTests V4)")
        // ★ RED CONTROL: today's path — core's whole part
        m.controlWholePartWithoutPrism = true
        m.discardLattice()
        m.generateLattice()
        try await FlexibleHisProject.waitFor(240, "the control's lattice") { (m.lattice != nil && !m.latticeBuilding) || m.latticeError != nil }
        let controlBuilt = m.lattice != nil
        m.controlWholePartWithoutPrism = false
        await m.waitForIdle()
        XCTAssertTrue(controlBuilt, "★ RED CONTROL: without the gate the whole part is latticed")
        print("FLEX-R7M1-1a his pad as saved: facePrisms \(m.facePrismsSet) · stacks latticed \(m.loadedKeys.map { m.stacks[$0]?.latticedColumns ?? -1 }) (core's Top \(coreTop.latticedColumns)) · issues \(under.map(\.pill)) · pill '\(st.line)' · control built \(controlBuilt)")
    }

    /// The positive control: one face-prism lattices only under it. His live lattice (Face 3 + Face 5 at 25 mm): a lattice
    /// builds, the faces under the prisms carry lattice, the Top's columns only near Face 3 / Face 5, and the scene's
    /// lattice voxels are a fraction of the whole part's.
    func testHisFacePrismsLatticeOnlyUnderThem() async throws {
        let (_, _, m) = try await F.hisPad(self, live: true)
        XCTAssertTrue(m.facePrismsSet, "his live lattice sets two face-prisms")
        let three = try XCTUnwrap(m.stack(3)), top = try XCTUnwrap(m.stack(1))
        XCTAssertGreaterThan(three.latticedColumns, 0, "Face 3 has lattice under it")
        // Face 3's columns cross the pad to Face 5 (100 mm): 25 mm of lattice under each of the two prisms, none between
        // (the red run's first expectation, 25, forgot Face 5's prism at the far end of the same columns)
        XCTAssertEqual(three.latticeMMMax, 50, accuracy: 3.5, "…25 mm under each face-prism of the pair (one voxel)")
        XCTAssertLessThan(three.latticeMMMax, three.stackMMMax - 20, "★ not the whole 100 mm column")
        XCTAssertLessThan(top.latticedColumns, top.columns.count, "★ the Top is latticed only where a face-prism reaches")
        let latticed = try XCTUnwrap(m.sceneInfo).latticeVoxels
        let lattice = try await FlexibleSquishFixture.build(m, "his live lattice")
        XCTAssertNotNil(lattice)
        // the whole part's count, from the same pad as saved (core's rule with no include region)
        let (_, _, whole) = try await F.hisPad(self, live: false)
        let all = try XCTUnwrap(whole.sceneInfo).latticeVoxels
        XCTAssertLessThan(Double(latticed), 0.8 * Double(all), "★ the prisms' lattice is a part of the whole")
        print("FLEX-R7M1-1a+ his live lattice: Face 3 latticed \(three.latticedColumns)/\(three.columns.count) max \(three.latticeMMMax) · Top \(top.latticedColumns)/\(top.columns.count) · voxels \(latticed) of the whole part's \(all)")
    }

    /// ★ Ruling 4, RED FIRST: "The Flexible job builder must NEVER send a job with no include region … Export disabled with a
    /// stated reason when no face-prism is set." Core's runner is a stand-in that counts.
    func testExportIsDisabledWithAStatedReasonWhenNoFacePrismIsSet() async throws {
        let (pm, stage, m, top) = try await padStage()
        XCTAssertTrue(m.press(top, kg: 10))
        try await FlexibleSquishFixture.settle(m, "the pad")
        XCTAssertFalse(m.facePrismsNow, "premise: the pad sets no face-prism")
        let run = stage.coreRun
        run.runner = { _, _, _, _ in FlexRunInfo(refusal: nil, receiptJSON: "{\"faces\":[{}],\"topology\":\"gyroid\"}", files: []) }
        stage.refresh()
        XCTAssertEqual(stage.status.line, FlexibleRowCopy.noFacePrism)
        XCTAssertNotEqual(stage.status.tap, .send, "★ the big button does not send")
        // the send gate itself (any route to it)
        run.send(m)
        XCTAssertTrue(run.shown)
        guard case .notSent(let line, let why) = run.phase else { return XCTFail("★ not sent: \(run.phase)") }
        XCTAssertEqual(line, "Set a face to Lattice in Selections first", "★ the stated reason")
        XCTAssertEqual(why, FlexibleJob.EncodeError.noFacePrism.description)
        XCTAssertEqual(run.runs, 0, "★ nothing reached core")
        run.send(m, fix: .send(resting: [], title: "Send", scope: "all"))
        XCTAssertEqual(run.runs, 0, "★ …by the step's buttons either")
        // the pure encoder is untouched (its bytes are the goldens')
        XCTAssertNoThrow(try m.runJobJSON())
        // ★ positive: a face-prism under the top — the same tap sends
        pm.flexibleLatticeUnder(.newGroup(face: FaceID(top), region: nil, name: "Top", depthMM: 20))
        XCTAssertTrue(m.facePrismsNow)
        run.send(m)
        try await FlexibleHisProject.waitFor(30, "the stand-in's answer") { !run.isSending }
        XCTAssertEqual(run.runs, 1, "with a face-prism the job is sent")
        // ★ RED CONTROL: today's path — the job with no include region goes to core (the whole part)
        let (_, stage2, m2, top2) = try await padStage()
        XCTAssertTrue(m2.press(top2, kg: 10))
        try await FlexibleSquishFixture.settle(m2, "the pad (control)")
        m2.controlWholePartWithoutPrism = true
        stage2.coreRun.runner = run.runner
        stage2.coreRun.send(m2)
        try await FlexibleHisProject.waitFor(30, "the control's answer") { !stage2.coreRun.isSending }
        m2.controlWholePartWithoutPrism = false
        XCTAssertEqual(stage2.coreRun.runs, 1, "★ RED CONTROL: without the gate the whole-part job is sent")
        print("FLEX-R7M1-ruling4 no face-prism: '\(line)' · runs \(run.runs) after the prism · control runs \(stage2.coreRun.runs)")
    }

    // MARK: - M1-5: an edges group beside a face group

    /// The reviewer's ruling 4: "Export offers ONE group at a time; the app must SAY so before export in plain words ("This
    /// export makes Group B only. Edges and faces go in separate exports for now."). Never silently drop a group."
    func testAnEdgesGroupBesideAFaceGroupExportsOneGroupAndSaysSoFirst() async throws {
        addTeardownBlock { @MainActor in FlexibleCoreHold.controlEdgesSilentlyDropped = false }
        let (pm, stage, m, top) = try await padStage()
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let px = FlexibleSquishFixture.face(mesh, axis: 0, value: 100), py = FlexibleSquishFixture.face(mesh, axis: 1, value: 100)
        XCTAssertTrue(px >= 0 && py >= 0, "premise: the pad's +X and +Y sides")
        XCTAssertTrue(m.press(top, kg: 10))
        pm.flexibleLatticeUnder(.newGroup(face: FaceID(top), region: nil, name: "Top", depthMM: 20))   // a face-prism (ruling 4)
        let press = try XCTUnwrap(m.addPress(regions: [px, py], direction: simd_normalize(SIMD3(-1, -1, 0)), snap: nil, group: 2, kg: 5))
        try await FlexibleHisProject.waitFor(60, "the scene") { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        try await FlexibleSquishFixture.settle(m, "the pad + an edge")
        let groups = m.squeezeGroups
        XCTAssertEqual(groups.map(\.kind), [.faces, .edges], "premise: Group 1 (the top) beside an edges group")
        XCTAssertTrue(m.squeezeGroups.last?.presses.contains(press) == true)
        XCTAssertEqual(m.sentSqueezeGroups.count, 1, "premise: core takes no edge press yet (sentPresses is empty until AP9)")
        let run = stage.coreRun
        run.runner = { _, _, _, _ in FlexRunInfo(refusal: nil, receiptJSON: "{\"faces\":[{}],\"topology\":\"gyroid\"}", files: []) }
        // ★ the pill: a preview, never the Ready green
        stage.refresh()
        XCTAssertEqual(m.coreHoldKind, .edgesBeside)
        XCTAssertEqual(stage.status.line, FlexibleRowCopy.edgesBesidePill)
        XCTAssertEqual(stage.status.tone, .preview)
        // ★ SAID BEFORE anything is sent
        let hold = try XCTUnwrap(m.coreHold)
        XCTAssertEqual(hold.line, "This export makes Group 1 only.")
        XCTAssertEqual(hold.note, "Edges and faces go in separate exports for now.")
        XCTAssertEqual(hold.fixes, [.send(resting: [], title: "Send Group 1 only", scope: "Group 1 only")])
        stage.pillTapped(stage.status, open: { XCTFail("a preview never opens Settings") })
        XCTAssertTrue(run.shown)
        guard case .notSent(let line, _) = run.phase else { return XCTFail("★ said, not sent: \(run.phase)") }
        XCTAssertEqual(line, "This export makes Group 1 only.")
        XCTAssertEqual(run.hold?.note, FlexibleRowCopy.edgesExportSeparately)
        XCTAssertEqual(run.runs, 0, "★ nothing is exported before his tap")
        // his tap on [Send Group 1 only]: the face group's job, said so in core's answer line
        stage.coreFix(hold.fixes[0])
        try await FlexibleHisProject.waitFor(30, "the stand-in's answer") { !run.isSending }
        XCTAssertEqual(run.runs, 1)
        guard case .ran(let rep) = run.phase else { return XCTFail("ran: \(run.phase)") }
        XCTAssertEqual(rep.scope, "Group 1 only", "★ core's line names the one group it made")
        XCTAssertEqual(run.sentJob, try m.runJobJSON(), "the job is the face group's (the edge press is not in it)")
        // ★ RE-PINNED (M1 verify — his answer: "Group names in squish are JUST squish groups. NOT lattice groups."): was his
        // Squish-page name ("This export makes Thumbs only."); now the squeeze group's number, as every [Send Group N only]
        // (FlexibleR7M1VerifyTests V6, its RED CONTROL the name)
        let g1 = try XCTUnwrap(m.squeezeGroups.first)
        m.setGroupName(g1.id, "Thumbs")
        XCTAssertEqual(m.coreHold?.line, "This export makes Group 1 only.")
        XCTAssertEqual(m.coreHold?.fixes.first?.title, "Send Group 1 only")
        // ★ RED CONTROL: today's rule — the edges group is not counted: no hold, sent at once, the edges dropped unsaid
        FlexibleCoreHold.controlEdgesSilentlyDropped = true
        let controlKind = m.coreHoldKind
        FlexibleCoreHold.controlEdgesSilentlyDropped = false
        XCTAssertNil(controlKind, "★ RED CONTROL: no hold — the face group would be sent and the edges group dropped without a word")
        print("FLEX-R7M1-5 hold '\(hold.line)' / '\(hold.note ?? "-")' · fixes \(hold.fixes.map(\.title)) · runs \(run.runs) · scope \(rep.scope ?? "-") · control kind \(String(describing: controlKind))")
    }

    // MARK: - fixtures

    private func padStage() async throws -> (ProjectModel, FlexibleMainStage, FlexibleStageModel, Int) {
        let pm = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"), facePrism: false)
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: pm, materialsPath: FlexibleHisProject.materialsPath, stampsPath: nil, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        stage.apply(pm, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(60, "the pad's scene") { m.sceneState == .ready }
        await m.waitForIdle()
        stage.refresh()
        let top = FlexibleHisProject.topFace(try XCTUnwrap(pm.viewerMesh))
        return (pm, stage, m, top)
    }
}
