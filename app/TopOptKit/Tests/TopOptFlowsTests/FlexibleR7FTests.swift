// FlexibleR7FTests — round 7 batch F (the Squish page's follow-ups from his 2026-10-14 answers), written BEFORE the code
// (the stubs' red run: round7/batch_f/r7f_red_run.txt). His words (tasks.md, "His answers on the R7-S/R7-V handoff
// questions" and "on the remaining handoff questions", 2026-10-14):
//   2. "Group trash should confirm deletion."                          11. the face-row trash looks different: yes.
//   3. "Yes. Allow an *empty* setup after reset all."                   9. the top line after Reset all: "Do not."
//   7. "split across all faces evenly" — clarified: an EQUAL SHARE PER LATTICE PART, only on the latticed parts.
//  10. Face card group chips: show the group NAMES.
//   5. "If bend is on, all views move to the furthest bend. Always. Bend view and Play cannot be viewed simultaneously."
//  12. "The curve should be viewed as nothing but the curve without any view turned on. Turning heat map on shows colour.
//      Turning bend on, shows bend. Turning play on, plays the sim."
//  13. "Heat follows whatever group is selected, first group as default. Hold for 3 seconds to view all. No picker
//      needed." — clarified: on the main page, the squeeze group of the face he last tapped; the 3 s hold there too.
// Each test runs its RED control inside.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleR7FTests: XCTestCase {
    typealias G = FlexibleAngledGoldens
    typealias F = FlexibleM2Fixtures

    override func tearDown() {
        FlexibleStageModel.controlTrashDeletesAtOnce = false
        FlexibleSettingsExit.controlEmptyBlocks = false
        FlexibleFaceGroupRow.controlChipsByNumber = false
        FlexibleStageViews.controlBendWithPlay = false
        FlexibleStagePage.controlBendRestPose = false
        FlexibleStageModel.controlHeatOnByDefault = false
        FlexibleMainStage.controlPlayAllDefault = false
        super.tearDown()
    }

    /// HIS pad (A1_0003 as he saved it: Group 1 = the top, Group 2 = faces 4 and 2, Group 3 = faces 3 and 5, face 0 rests)
    /// on the main stage's shared model, opened and settled.
    func hisPad() async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath,
                        persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "A1_0003")
        XCTAssertEqual(m.squeezeGroups.map(\.regions), [[1], [4, 2], [3, 5]], "premise: his three groups")
        return (r, s, m)
    }

    /// A point inside face `face` (its first triangle's centroid).
    func inside(_ m: FlexibleStageModel, face: Int) throws -> SIMD3<Double> {
        let t = try XCTUnwrap(FlexibleEdgeStrips.triangles(face: face, mesh: try XCTUnwrap(m.project.viewerMesh)).first)
        return (t[0] + t[1] + t[2]) / 3
    }

    // MARK: - (1) the group trash asks first, in one line; the face row's take-out looks different

    func testTheGroupTrashAsksFirstAndTheFaceRowLooksDifferent() async throws {
        let (r, _, m) = try await hisPad()
        let g2 = try XCTUnwrap(m.squeezeGroups.first { $0.number == 2 })
        let before = m.settings
        m.askDeleteGroup(g2.id)
        XCTAssertEqual(m.groupDeleteAsk, g2.id, "★ the trash ASKS")
        XCTAssertEqual(m.squeezeGroups.count, 3, "★ …and deletes nothing yet")
        XCTAssertEqual(m.settings, before, "nothing changed")
        XCTAssertEqual(FlexibleRowCopy.deleteGroupAsk(m.groupName(g2)), "Delete Group 2?", "★ his one line")
        XCTAssertEqual(FlexibleRowCopy.deleteGroupConfirm, "Delete")
        XCTAssertEqual(FlexibleRowCopy.deleteGroupKeep, "Keep")
        m.setGroupName(g2.id, "Thumbs")
        XCTAssertEqual(FlexibleRowCopy.deleteGroupAsk(m.groupName(try XCTUnwrap(m.railGroup(g2.id)))), "Delete Thumbs?", "his name in it")
        // Keep: nothing goes
        m.keepGroup()
        XCTAssertNil(m.groupDeleteAsk, "Keep closes the line")
        XCTAssertEqual(m.squeezeGroups.count, 3, "Keep deletes nothing")
        // Delete: the group goes (one undo step brings it back)
        m.askDeleteGroup(g2.id)
        m.confirmDeleteGroup()
        XCTAssertNil(m.groupDeleteAsk)
        XCTAssertEqual(m.squeezeGroups.count, 2, "★ Delete deletes it")
        XCTAssertFalse(m.squeezeGroups.contains { Set($0.regions) == [4, 2] }, "Group 2's faces left the setup")
        await m.waitForIdle()
        FlexibleStagePage.history(undo: true, project: r.project, model: m)
        await m.waitForIdle()
        XCTAssertEqual(m.squeezeGroups.map(\.regions), [[1], [4, 2], [3, 5]], "one undo brings it back")
        // a confirm for a group that is gone deletes nothing
        m.askDeleteGroup(999)
        XCTAssertNil(m.groupDeleteAsk, "no such group: nothing asked")
        // the face row's take-out: another glyph, smaller
        XCTAssertNotEqual(FlexibleTrashGlyphs.face, FlexibleTrashGlyphs.group, "★ the face row's glyph is not the group's trash")
        XCTAssertLessThan(FlexibleTrashGlyphs.faceSize, FlexibleTrashGlyphs.groupSize, "★ …and smaller")

        // ★ RED CONTROL: today's trash — the group goes at once
        FlexibleStageModel.controlTrashDeletesAtOnce = true
        let g = try XCTUnwrap(m.squeezeGroups.first { $0.number == 2 })
        m.askDeleteGroup(g.id)
        XCTAssertEqual(m.squeezeGroups.count, 2, "control: the trash deleted at once")
        XCTAssertNil(m.groupDeleteAsk, "control: nothing asked")
    }

    // MARK: - (2) after Reset all: an empty setup may Exit, the top line names no face; the Top at an equal share per part

    func testAnEmptySetupMayExitAndATapOnTheTopStartsGroupOneAtItsShare() async throws {
        let (r, _, m) = try await F.pad(self)
        let p = r.project
        m.resetAll()
        try await F.reopen(m, "after Reset all")
        XCTAssertTrue(m.isEmptySetup, "premise: nothing set to squish")
        let rd = m.readiness
        XCTAssertTrue(rd.blocking.contains { $0.kind == .noPressedFace }, "premise: the readiness still says nothing is pressed")
        XCTAssertEqual(FlexibleSettingsExit.title(rd, modified: true, empty: true), FlexibleSettingsExit.saveAndExit,
                       "★ an EMPTY setup may leave (no \"Fix 1 thing\")")
        XCTAssertEqual(FlexibleSettingsExit.title(rd, modified: false, empty: true), FlexibleSettingsExit.exit)
        XCTAssertEqual(FlexibleSettingsExit.decide(rd, modified: true, empty: true), .exit, "★ Exit leaves")
        let line = FlexibleSettingsExit.topLine(rd, modified: true, empty: true)
        XCTAssertEqual(line, FlexibleSettingsExit.emptyLine, "★ the top line")
        XCTAssertFalse(line.isEmpty)
        for word in ["Top", "Face", "Press", "tap"] { XCTAssertFalse(line.contains(word), "★ it suggests no face: '\(line)'") }
        XCTAssertNil(FlexibleStagePage.noticeFix(rd, model: m), "★ no [Fix] on the empty setup's line")
        m.rail = .model
        let issue = try XCTUnwrap(rd.blocking.first { $0.kind == .noPressedFace })
        XCTAssertFalse(FlexibleStagePage.popsAtOnce(issue, model: m), "★ nothing pops over the empty setup, on any tab")
        m.rail = .newGroup
        // a setup that holds a face is not empty: its blocker still holds Exit
        XCTAssertEqual(FlexibleSettingsExit.title(rd, modified: true, empty: false), "Fix 1 thing", "not empty: the blocker holds Exit")

        // a tap on the Top: Group 1 at the Top's weight, an EQUAL SHARE per lattice part (2 parts: 5 of 10 kg), no keypad
        let topGroup = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        let topKg = p.force.kind(for: topGroup.id).weightKg ?? 0
        m.tapFace(1, point: F.onTop(p, x: 10))
        XCTAssertNil(m.newGroupAsk, "★ no keypad: the main page's Top weight")
        XCTAssertEqual(m.squeezeGroups.count, 1, "★ Group 1 started")
        let sec = try XCTUnwrap(m.squeezeGroups.first?.regions.first)
        XCTAssertTrue(FlexibleRegions.isFlexible(sec), "★ the lattice part under the tap (\(sec))")
        let f = try XCTUnwrap(m.settings.face(sec))
        print("FLEX-R7F-RESET Top \(topKg) kg · section \(sec) at \(f.weightKg) kg (from \(String(describing: f.weightFrom)))")
        XCTAssertEqual(f.weightKg, topKg / 2, accuracy: 1e-9, "★ an equal share per lattice part: half of the Top's \(topKg) kg")
        XCTAssertEqual(f.weightFrom, topGroup.id, "linked to the main page's Top")
        // the other part: a tap adds it at the other half (the same share, linked)
        try await F.reopen(m, "Group 1's stack")
        m.rail = .newGroup
        m.tapFace(1, point: F.onTop(p, x: F.box(p).hi.x - F.box(p).lo.x - 10))
        let other = m.settings.loadedFaces.map(\.faceRegionID).filter { $0 != sec && m.regions.faces(of: $0, mesh: p.viewerMesh) == [1] }
        for o in other { XCTAssertEqual(m.settings.face(o)?.weightKg ?? 0, topKg / 2, accuracy: 1e-9, "★ the other part: the other half") }
        XCTAssertNil(m.settings.face(1), "never the whole Top")

        // ★ RED CONTROL: today's rule — the blocker holds Exit and the line names a face to press
        FlexibleSettingsExit.controlEmptyBlocks = true
        XCTAssertEqual(FlexibleSettingsExit.title(rd, modified: true, empty: true), "Fix 1 thing", "control: today's \"Fix 1 thing\"")
        XCTAssertEqual(FlexibleSettingsExit.topLine(rd, modified: true, empty: true), rd.oneLine, "control: today's line")
    }

    // MARK: - (3) the face card's group chips show the squeeze groups' names

    func testTheFaceCardsGroupChipsShowTheNames() async throws {
        let (_, _, m) = try await hisPad()
        let g1 = try XCTUnwrap(m.squeezeGroups.first)
        m.setGroupName(g1.id, "Thumbs")
        let labels = FlexibleFaceGroupRow.options(model: m, region: 4).map(\.label)
        XCTAssertEqual(Array(labels.prefix(3)), ["Thumbs", "Group 2", "Group 3"], "★ the chips say the names: \(labels)")
        // the menu (when the chips do not fit) says the same
        let o = try XCTUnwrap(FlexibleFaceGroupRow.options(model: m, region: 4).first)
        XCTAssertEqual(FlexibleFaceGroupRow.menuTitle(o, model: m), "Thumbs")
        // ★ RED CONTROL: today's chips — numbers
        FlexibleFaceGroupRow.controlChipsByNumber = true
        XCTAssertEqual(Array(FlexibleFaceGroupRow.options(model: m, region: 4).map(\.label).prefix(3)), ["1", "2", "3"], "control: numbers")
    }

    // MARK: - (4) Bend and Play never together; with Bend on everything drawn on the part sits at the full bend

    func testBendAndPlayNeverShowTogether() {
        var v: FlexibleStageViews = [.play, .prisms]
        v.toggle(.bend)
        XCTAssertEqual(v, [.bend, .prisms], "★ Bend on turns Play off")
        v.toggle(.play)
        XCTAssertEqual(v, [.play, .prisms], "★ Play on turns Bend off")
        v.toggle(.play)
        XCTAssertEqual(v, [.prisms], "Play off")
        v.toggle(.bend); v.toggle(.heatOff)
        XCTAssertEqual(v, [.bend, .prisms, .heatOff], "the other views stay with Bend")
        // ★ RED CONTROL: R7-V's rule — Bend with Play
        FlexibleStageViews.controlBendWithPlay = true
        var c: FlexibleStageViews = [.play]
        c.toggle(.bend)
        XCTAssertEqual(c, [.play, .bend], "control: both")
    }

    func testTheBendPoseMovesWhatIsDrawnOnThePart() {
        // a 5 × 5 grid on z = 0, each vertex pushed down by x / 10 mm, k = 3
        var pos: [Float] = [], d: [Float] = []
        for y in 0..<5 { for x in 0..<5 { pos += [Float(x), Float(y), 0]; d += [0, 0, -Float(x) / 10] } }
        let pose = try? XCTUnwrap(FlexibleBendPose(positions: pos, dents: d, k: 3))
        XCTAssertNotNil(pose, "★ a pose")
        guard let pose else { return }
        let p = SIMD3<Float>(4, 2, 0)
        XCTAssertEqual(pose.apply(p).z, -1.2, accuracy: 1e-5, "★ a point on the part moves by its bend × k")
        XCTAssertEqual(pose.apply(SIMD3<Double>(2, 2, 0)).z, -0.6, accuracy: 1e-5)
        let deep = SIMD3<Float>(4, 2, -40)
        XCTAssertEqual(pose.apply(deep), deep, "a point deep inside (a prism's floor, its chip) stays: the bent face meets it")
        // a prism: its face (base) moves with the bend, its floor stays
        let shell = FaceOffsetShell(base: [SIMD3(4, 2, 0), SIMD3(3, 2, 0), SIMD3(4, 3, 0)],
                                    offset: [SIMD3(4, 2, -40), SIMD3(3, 2, -40), SIMD3(4, 3, -40)], indices: [0, 1, 2], reachedDepthMM: 40)
        let item = ClearanceRenderItem(volume: .shell(faceID: 7, shell: shell), selected: true, tint: SIMD3(1, 0, 1), faceAlpha: 0.2)
        let posed = pose.pose(item)
        guard case .shell(let s) = posed.volume.shape else { return XCTFail("a shell") }
        XCTAssertEqual(s.base[0].z, -1.2, accuracy: 1e-5, "★ the prism's face sits on the bent face")
        // ★ RE-PINNED (round 7 review, R — his answer of 2026-10-15: "With Bend on, the depth chip and depth labels MOVE with
        // the bend (everything goes to the full-bend pose)"): the floor moves with its face (was XCTAssertEqual(s.offset,
        // shell.offset, "its floor stays") — F's rule, now `FlexibleBendPose.controlInsideStays`)
        XCTAssertEqual(s.offset[0].z, -41.2, accuracy: 1e-5, "★ R: its floor moves with its face")
        FlexibleBendPose.controlInsideStays = true
        guard case .shell(let fs) = pose.pose(item).volume.shape else { return XCTFail("a shell") }
        FlexibleBendPose.controlInsideStays = false
        XCTAssertEqual(fs.offset, shell.offset, "F's rule (the red control): its floor stays")
        XCTAssertEqual(posed.volume.faceID, 7); XCTAssertEqual(posed.tint, item.tint); XCTAssertEqual(posed.faceAlpha, 0.2)
        XCTAssertTrue(posed.selected)
        // the page's gates: Bend poses the overlays and no longer hides them
        XCTAssertTrue(FlexibleStagePage.posesOverlays(views: [.bend, .heatOff]), "★ Bend: the overlays at the full bend")
        XCTAssertFalse(FlexibleStagePage.posesOverlays(views: []))
        XCTAssertFalse(FlexibleStagePage.posesOverlays(views: [.play]))
        XCTAssertFalse(FlexibleStagePage.overlaysHidden(views: [.bend, .heatOff], edgePick: false), "★ Bend alone keeps the curves")
        XCTAssertEqual(FlexibleStagePage.bodyAlpha(views: [.bend, .heatOff], edgePick: false, hasDent: true), 1,
                       "Bend alone: the bent part still drawn to read (opaque)")
        XCTAssertEqual(FlexibleStagePage.dentScale(views: [.bend], exaggeration: 4, amount: 0.3), 4, "Bend: the full depth")
        // ★ RED CONTROL: R7-V's rule — Bend alone hides the overlays, nothing posed
        FlexibleStagePage.controlBendRestPose = true
        XCTAssertTrue(FlexibleStagePage.overlaysHidden(views: [.bend, .heatOff], edgePick: false), "control: hidden")
        XCTAssertFalse(FlexibleStagePage.posesOverlays(views: [.bend, .heatOff]), "control: the rest pose")
    }

    func testOnHisPadTheFaceUnderTheBendMovesWithIt() async throws {
        let (_, _, m) = try await hisPad()
        let g2 = try XCTUnwrap(m.squeezeGroups.first { $0.regions == [4, 2] })
        m.rail = .group(g2.id)
        m.select(4)
        m.tab = .face
        let overlay = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        var cache: (key: String, dents: [Float])?
        let views: FlexibleStageViews = [.bend, .heatOff]
        let c = FlexibleStagePage.composeTints(model: m, overlay: overlay, views: views)
        let sq = FlexibleSettingsSquish.shown(model: m, overlay: overlay, channels: c, feCache: &cache)
        let d = try XCTUnwrap(sq.dents, "premise: his drawing dents Group 2")
        let pose = try XCTUnwrap(FlexibleStagePage.bendPose(views: views, overlay: overlay, dents: d, k: sq.exaggeration), "★ Bend: a pose")
        XCTAssertNil(FlexibleStagePage.bendPose(views: [.heatOff], overlay: overlay, dents: d, k: sq.exaggeration), "no Bend: none")
        let w = try XCTUnwrap(FlexibleStageOverlays.workingFace(model: m), "Face 4 is worked on")
        let moved = w.geometry.centres.map { simd_length(pose.apply($0) - $0) }.max() ?? 0
        print(String(format: "FLEX-R7F-BEND face 4: k %.2f · its centres move up to %.3f mm", sq.exaggeration, moved))
        XCTAssertGreaterThan(moved, 0.1, "★ face 4's middle is drawn where the bend puts it")
        // ★ RED CONTROL: the rest pose
        FlexibleStagePage.controlBendRestPose = true
        XCTAssertNil(FlexibleStagePage.bendPose(views: views, overlay: overlay, dents: d, k: sq.exaggeration), "control: no pose")
    }

    // MARK: - (5) the Squish views: no view on = the curve only

    func testNoViewOnIsTheCurveOnly() async throws {
        let (_, _, m) = try await hisPad()
        XCTAssertEqual(m.views.heatScope, .off, "★ the page opens with no colour (Heat off)")
        // his Face 1 (the top) on Curves, as in his img3 (this copy of his pad saves every face on Stamp)
        let g1 = try XCTUnwrap(m.squeezeGroups.first { $0.regions == [1] })
        m.rail = .group(g1.id)
        m.select(1)
        m.tab = .face
        m.setShape(1, "curves")
        XCTAssertTrue(FlexibleStageHeat.shown(model: m, views: m.views).isEmpty, "★ no heat drawn")
        XCTAssertNotNil(FlexibleStageOverlays.curveEditors(model: m), "★ the curve")
        XCTAssertFalse(FlexibleStagePage.overlaysHidden(views: m.views, edgePick: false))
        XCTAssertFalse(m.views.contains(.bend)); XCTAssertFalse(m.views.contains(.play))
        // Heat on: colour (the current group's)
        var v = m.views; v.heatTapped(); m.views = v
        XCTAssertEqual(m.views.heatScope, .group)
        XCTAssertEqual(FlexibleStageHeat.shown(model: m, views: m.views), [1], "★ Heat: Group 1's colour")
        // ★ RED CONTROL: R7-V's opening look — the current group's heat
        FlexibleStageModel.controlHeatOnByDefault = true
        let (_, _, m2) = try await hisPad()
        XCTAssertEqual(m2.views.heatScope, .group, "control: colour on open")
    }

    // MARK: - (6) heat follows the selected group on the main page too; no picker in the bar

    func testTheMainPagesHeatFollowsTheLastTappedFacesGroup() async throws {
        func sim(_ n: Int) -> FlexibleSim { FlexibleSim(id: FlexibleSim.groupID(n), kind: .group(n), title: "Group \(n)", short: "Group \(n)", keys: []) }
        let all = FlexibleSim(id: FlexibleSim.allID, kind: .playAll, title: "Play all", short: "All", keys: [])
        let sims = [sim(1), sim(2), all]
        XCTAssertEqual(FlexibleMainStage.heatSim(sims: sims, tappedGroup: nil, all: false), "group-1", "★ the first group by default")
        XCTAssertEqual(FlexibleMainStage.heatSim(sims: sims, tappedGroup: 2, all: false), "group-2", "★ the tapped face's group")
        XCTAssertEqual(FlexibleMainStage.heatSim(sims: sims, tappedGroup: 2, all: true), FlexibleSim.allID, "★ the 3 s hold: every group")
        XCTAssertEqual(FlexibleMainStage.heatSim(sims: sims, tappedGroup: 9, all: false), "group-1", "a group with no sim: the first")
        XCTAssertNil(FlexibleMainStage.heatSim(sims: [sim(1)], tappedGroup: nil, all: false), "one group: nothing to pick")
        XCTAssertEqual(FlexibleMainPlayerSlot.pickerSims(sims), [], "★ no group picker in the play bar")

        let (_, s, m) = try await hisPad()
        XCTAssertNil(s.tappedGroupNumber, "nothing tapped yet")
        s.noteMainTap(face: 4, point: SIMD3<Float>(try inside(m, face: 4)))
        XCTAssertEqual(s.tappedGroupNumber, 2, "★ a tap on Face 4: Group 2")
        s.noteMainTap(face: 1, point: SIMD3<Float>(try inside(m, face: 1)))
        XCTAssertEqual(s.tappedGroupNumber, 1, "★ a tap on the Top: Group 1")
        s.noteMainTap(face: 0, point: SIMD3<Float>(try inside(m, face: 0)))
        XCTAssertEqual(s.tappedGroupNumber, 1, "a tap on a face in no group keeps the last group")
        // the heat icon: a tap shows the selected group's, the 3 s hold every group's, a tap hides
        s.heat = false
        s.heatHeld()
        XCTAssertTrue(s.heat, "★ the hold shows the heat")
        XCTAssertTrue(s.heatAll, "★ …of every group")
        s.toggleHeat()
        XCTAssertFalse(s.heat, "a tap hides it")
        XCTAssertFalse(s.heatAll)
        s.toggleHeat()
        XCTAssertTrue(s.heat)
        XCTAssertFalse(s.heatAll, "★ a tap shows the selected group's again")
        // Play on the main page turns Bend off (the views are shared)
        m.views = [.bend]
        s.togglePlay()
        XCTAssertTrue(m.views.contains(.play))
        XCTAssertFalse(m.views.contains(.bend), "★ Play on turns Bend off on the main page too")

        // ★ RED CONTROL: today's main page — Play all by default and its picker in the bar
        FlexibleMainStage.controlPlayAllDefault = true
        XCTAssertNil(FlexibleMainStage.heatSim(sims: sims, tappedGroup: 2, all: false), "control: the lattice's default (Play all)")
        XCTAssertEqual(FlexibleMainPlayerSlot.pickerSims(sims), sims, "control: the picker in the bar")
    }
}
