// FlexibleU21DeleteUndoTests — round 7 · U21, batch D (his notes of 2026-10-21, Img13; the reviewer's ruling E(2) of 18:09).
//   His words: "I accidentally deleted a face (which I shouldn't be able to do with a single click … is the 'cancel' button
//   where the delete button was and the OK button somewhere else so it requires a move to confirm?) Then I hit undo and now it
//   shows the bend on the model but it is not actually showing the face in the modal anymore? That's clearly a bug."
//   UNDO-GHOST — Undo puts the panel back: the tab a delete moved, the face it took out           — testTakeOut…, testGroupTrash…, testResetAll…
//   F12        — one toolbar Undo after a Lattice-page trash restores the group and its Squish entries — testOneToolbarUndo…
//   DEL-CONFIRM — every delete asks first; the take-out is its own undo step                     — testFaceTakeOutAsksFirst … testTakeOutIsItsOwnUndoStep
// On HIS live projects of 2026-10-21 (round7/batch_u21/his_live_1021_lbracket, his_live_1021_pad). Each RED control is asserted
// red inside its test.
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleU21DeleteUndoTests: XCTestCase {
    static var fixtures: URL {
        FlexibleHisProject.repoRoot.appendingPathComponent("docs/handoffs/evidence/2026-09-29-flexible-screens/round7/batch_u21", isDirectory: true)
    }
    static var lbracketDir: URL { fixtures.appendingPathComponent("his_live_1021_lbracket", isDirectory: true) }
    static var padDir: URL { fixtures.appendingPathComponent("his_live_1021_pad", isDirectory: true) }

    func open(_ dir: URL, _ what: String) async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(dir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, what)
        return (r, s, m)
    }

    func state(_ m: FlexibleStageModel) -> String {
        "rail \(m.rail) · selected \(m.selectedRegion.map(String.init) ?? "nil") · playing \(m.playingGroup.map { "Group \($0.number)" } ?? "nil")"
            + " · working \(FlexibleStageOverlays.workingRegion(model: m).map(String.init) ?? "nil") · faces \(m.settings.faces.map(\.faceRegionID))"
    }

    override func tearDown() {
        FlexibleStageModel.controlUndoKeepsMovedTab = false
        FlexibleStageModel.controlRemoveFaceNoSeal = false
        FlexibleStageModel.controlRemoveAtOnce = false
        FlexibleMainStage.controlDeferredCarry = false
        FlexibleStageModel.controlResetSealsAtOnce = false
        FlexibleStageModel.controlTakeOutFullName = false
        super.tearDown()
    }

    func undo(_ r: FlexibleHisProject.Restored, _ m: FlexibleStageModel, redo: Bool = false) async throws {
        FlexibleStagePage.history(undo: !redo, project: r.project, model: m)
        try await FlexibleHisProject.waitFor(120, "the history's scene") { m.sceneState == .ready }
        await m.waitForIdle()
    }

    func setDeepest(_ m: FlexibleStageModel, _ r: Int, _ mm: Double) {
        m.edit { s in guard var f = s.face(r) else { return }; f.deepestMM = mm; s.setFace(f) }
    }

    // MARK: UNDO-GHOST — the probe first (the plan): his 23.png with railKeep set by an earlier edit, and the fix

    struct Ghost { let afterRemove: String; let afterUndo: String; let rail: FlexibleRailTab; let selected: Int?; let working: Int?; let playing: Int? }

    func takeOutOnlyFaceThenUndo() async throws -> (Ghost, FlexibleHisProject.Restored, FlexibleStageModel) {
        let (r, _, m) = try await open(Self.lbracketDir, "his l-bracket")
        let face = 2000008
        XCTAssertEqual(m.selectedRegion, face, "premise: Face 6 selected (his Img12)")
        XCTAssertEqual(m.squeezeGroups.map(\.regions), [[face]], "premise: Group 1 = Face 6 alone")
        setDeepest(m, face, 7)   // his session: an edit before the ⊖ (Deepest 7)
        m.removeFace(face)
        let a = state(m)
        try await undo(r, m)
        let g = Ghost(afterRemove: a, afterUndo: state(m), rail: m.rail, selected: m.selectedRegion,
                      working: FlexibleStageOverlays.workingRegion(model: m), playing: m.playingGroup?.number)
        return (g, r, m)
    }

    func testTakeOutOnlyFaceThenUndoReopensItsGroup() async throws {
        // RED CONTROL first (= the plan's seeded probe): his 23.png — [+ New] open, Group 1's bend playing, no face card
        FlexibleStageModel.controlUndoKeepsMovedTab = true
        let (red, _, _) = try await takeOutOnlyFaceThenUndo()
        FlexibleStageModel.controlUndoKeepsMovedTab = false
        print("FLEX-U21-D1 RED (today) after ⊖: \(red.afterRemove)\n  after Undo: \(red.afterUndo)")
        XCTAssertEqual(red.rail, .newGroup, "RED CONTROL: the panel stays on [+ New] (his 23.png)")
        XCTAssertEqual(red.playing, 1, "RED CONTROL: Group 1's bend plays")
        XCTAssertNil(red.working, "RED CONTROL: no face card")

        let (g, r, m) = try await takeOutOnlyFaceThenUndo()
        print("FLEX-U21-D1 after ⊖: \(g.afterRemove)\n  after Undo: \(g.afterUndo)")
        XCTAssertEqual(g.rail, .group(1), "★ Undo opens Group 1 again")
        XCTAssertEqual(g.selected, 2000008, "★ with Face 6 selected")
        XCTAssertEqual(g.working, 2000008, "★ its card and numbers show")
        XCTAssertEqual(m.settings.face(2000008)?.deepestMM, 7, "the face as it was (Deepest 7)")

        // Redo: the take-out again — back on [+ New] (FlexibleR7SettingsTests' "Model and New stay put" unchanged); Undo again
        try await undo(r, m, redo: true)
        print("FLEX-U21-D1 after Redo: \(state(m))")
        XCTAssertEqual(m.rail, .newGroup, "★ Redo: the take-out again, [+ New] as before")
        XCTAssertNil(m.settings.face(2000008))
        XCTAssertNil(m.selectedRegion, "★ the face taken out is not left selected")
        try await undo(r, m)
        XCTAssertEqual(m.rail, .group(1), "★ Undo after Redo: Group 1 again")
        XCTAssertEqual(FlexibleStageOverlays.workingRegion(model: m), 2000008)
    }

    func padTakeOut(_ face: Int) async throws -> (selected: Int?, rail: FlexibleRailTab, line: String) {
        let (r, _, m) = try await open(Self.padDir, "his pad of 10-21")
        let g1 = try XCTUnwrap(m.squeezeGroups.first { $0.regions.contains(5) }, "premise: Faces 5 and 3 in one group")
        XCTAssertEqual(Set(g1.regions), [5, 3])
        m.select(face)
        setDeepest(m, face, 6)
        m.removeFace(face)
        let a = state(m)
        try await undo(r, m)
        return (m.selectedRegion, m.rail, "after take-out: \(a)\n  after Undo: \(state(m))")
    }

    func testTakeOutSelectedFaceThenUndoReselectsIt() async throws {
        FlexibleStageModel.controlUndoKeepsMovedTab = true
        let red = try await padTakeOut(5)
        FlexibleStageModel.controlUndoKeepsMovedTab = false
        print("FLEX-U21-D2 RED (today) \(red.line)")
        XCTAssertEqual(red.selected, 3, "RED CONTROL: Face 3 selected after Undo (probe C3)")
        let a = try await padTakeOut(5)
        print("FLEX-U21-D2 \(a.line)")
        XCTAssertEqual(a.selected, 5, "★ Undo re-selects Face 5, the face taken out")
        XCTAssertEqual(a.rail, .group(1))
    }

    func padGroupTrash() async throws -> (kind: FlexibleGroupKind?, regions: [Int], selected: Int?, line: String) {
        let (r, _, m) = try await open(Self.padDir, "his pad of 10-21")
        let g1 = try XCTUnwrap(m.squeezeGroups.first { $0.regions.contains(5) })
        m.rail = .group(g1.id)
        m.select(5)
        m.askDeleteGroup(g1.id)
        m.confirmDeleteGroup()
        let a = state(m)
        XCTAssertEqual(m.playingGroup?.kind, .edges, "premise: the edges group's tab opens (probe C4)")
        try await undo(r, m)
        try await FlexibleSquishFixture.settle(m, "after Undo (the scene re-open)")
        let g = m.playingGroup
        return (g?.kind, g?.regions ?? [], m.selectedRegion, "after trash: \(a)\n  after Undo + re-open: \(state(m))")
    }

    func testGroupTrashThenUndoReopensTheGroup() async throws {
        FlexibleStageModel.controlUndoKeepsMovedTab = true
        let red = try await padGroupTrash()
        FlexibleStageModel.controlUndoKeepsMovedTab = false
        print("FLEX-U21-D3 RED (today) \(red.line)")
        XCTAssertEqual(red.kind, .edges, "RED CONTROL: the tab stays on the edges group (probe C5)")
        let a = try await padGroupTrash()
        print("FLEX-U21-D3 \(a.line)")
        XCTAssertEqual(a.kind, .faces, "★ Undo opens the faces group again")
        XCTAssertEqual(Set(a.regions), [5, 3])
        XCTAssertEqual(a.selected, 5, "★ Face 5 selected again")
    }

    func padResetAll() async throws -> (rail: FlexibleRailTab, selected: Int?, line: String) {
        let (r, _, m) = try await open(Self.padDir, "his pad of 10-21")
        m.select(5)
        m.askResetAll()
        m.confirmResetAll()
        try await FlexibleHisProject.waitFor(120, "the reset's scene") { m.sceneState == .ready }
        await m.waitForIdle()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let a = state(m) + " · undo steps \(r.project.undo.past.count)"
        XCTAssertEqual(m.rail, .newGroup, "premise: Reset all opens [+ New]")
        try await undo(r, m)
        try await FlexibleSquishFixture.settle(m, "after Undo")
        return (m.rail, m.selectedRegion, "after Reset all: \(a)\n  after Undo: \(state(m))")
    }

    func testResetAllThenUndoReopensTheGroup() async throws {
        FlexibleStageModel.controlUndoKeepsMovedTab = true
        FlexibleStageModel.controlResetSealsAtOnce = true
        let red = try await padResetAll()
        FlexibleStageModel.controlUndoKeepsMovedTab = false
        FlexibleStageModel.controlResetSealsAtOnce = false
        print("FLEX-U21-D4 RED (today) \(red.line)")
        XCTAssertEqual(red.rail, .newGroup, "RED CONTROL: Undo leaves [+ New] open")
        let a = try await padResetAll()
        print("FLEX-U21-D4 \(a.line)")
        XCTAssertEqual(a.rail, .group(1), "★ Undo opens Group 1 again")
        XCTAssertEqual(a.selected, 5, "★ with Face 5 selected")
    }

    // MARK: F12 — one toolbar Undo after a Lattice-page trash

    struct Trash { let name: String; let facesBefore: [Int]; let facesAfterTrash: [Int]; let facesAfterUndo: [Int]; let back: Bool; let stepsBefore: Int; let stepsAfter: Int }

    func latticeTrash(_ groupName: String) async throws -> Trash {
        let (r, s, m) = try await open(Self.padDir, "his pad of 10-21")
        let p = r.project
        p.sealUndoStep()
        let stepsBefore = p.undo.past.count
        let facesBefore = m.settings.faces.map(\.faceRegionID)
        let gid = try XCTUnwrap(p.selection.groups.first { $0.name == groupName }?.id, "his \(groupName)")
        s.askDelete(gid)
        s.confirmDelete(project: p, cardsChanged: {})
        XCTAssertNil(p.selection.groups.first { $0.id == gid }, "premise: \(groupName) deleted")
        m.openScene()   // the main page's own reaction to the edit (FlexibleMainStage.projectChanged)
        try await Task.sleep(nanoseconds: 1_000_000_000)   // "wait 1 s"
        try await FlexibleHisProject.waitFor(120, "the re-opened scene") { m.sceneState == .ready }
        await m.waitForIdle()
        try await Task.sleep(nanoseconds: 600_000_000)
        let facesAfterTrash = m.settings.faces.map(\.faceRegionID)
        p.performUndo()   // ONE toolbar Undo
        let back = p.selection.groups.contains { $0.id == gid }
        return Trash(name: groupName, facesBefore: facesBefore, facesAfterTrash: facesAfterTrash, facesAfterUndo: m.settings.faces.map(\.faceRegionID),
                     back: back, stepsBefore: stepsBefore, stepsAfter: p.undo.past.count)
    }

    func testOneToolbarUndoRestoresTheTrashedGroup() async throws {
        FlexibleMainStage.controlDeferredCarry = true
        let red = try await latticeTrash("Group C")
        FlexibleMainStage.controlDeferredCarry = false
        print("FLEX-U21-F12 RED (today) \(red)")
        XCTAssertFalse(red.back && red.facesAfterUndo == red.facesBefore && red.stepsAfter == red.stepsBefore,
                       "RED CONTROL: one Undo does not restore Group C with its Squish entries")
        let a = try await latticeTrash("Group C")
        print("FLEX-U21-F12 \(a)")
        XCTAssertNotEqual(a.facesAfterTrash, a.facesBefore, "premise: the trash re-filed the Squish entries (the carry)")
        XCTAssertTrue(a.back, "★ one Undo: Group C is back")
        XCTAssertEqual(a.facesAfterUndo, a.facesBefore, "★ with its Squish entries")
        XCTAssertEqual(a.stepsAfter, a.stepsBefore, "★ the undo list as before the trash")
    }

    // MARK: DEL-CONFIRM — every delete asks first

    func testFaceTakeOutAsksFirst() async throws {
        let (_, _, m) = try await open(Self.padDir, "his pad of 10-21")
        m.askRemoveFace(5)
        XCTAssertEqual(m.faceRemoveAsk, 5, "★ the ⊖ asks")
        XCTAssertNotNil(m.settings.face(5), "★ nothing removed before [Take out]")
        m.keepFace()
        XCTAssertNil(m.faceRemoveAsk); XCTAssertNotNil(m.settings.face(5), "[Keep]: nothing changes")
        m.askRemoveFace(5)
        m.tapFace(0)   // a tap elsewhere drops the ask
        XCTAssertNil(m.faceRemoveAsk, "★ a tap elsewhere drops the ask")
        m.askRemoveFace(5)
        m.rail = .model   // a tab change drops it
        XCTAssertNil(m.faceRemoveAsk, "★ a tab change drops the ask")
        m.rail = .group(1)
        m.askRemoveFace(5)
        m.confirmRemoveFace()
        XCTAssertNil(m.settings.face(5), "★ [Take out]: Face 5 leaves the squish")
        XCTAssertLessThanOrEqual(FlexibleConfirmCopy.takeOutAsk("Face 6 · lattice A").count, 44)
        // RED CONTROL: today's one tap
        FlexibleStageModel.controlRemoveAtOnce = true
        m.askRemoveFace(3)
        XCTAssertNil(m.settings.face(3), "RED CONTROL: removed at once")
    }

    func testPressTrashAsksFirst() async throws {
        let (_, _, m) = try await open(Self.padDir, "his pad of 10-21")
        let p = try XCTUnwrap(m.presses.first { $0.strip?.label == "Edge 12" }, "premise: his Edge 12")
        m.askRemovePress(p.id)
        XCTAssertEqual(m.pressRemoveAsk, p.id, "★ the trash asks")
        XCTAssertNotNil(m.settings.press(p.id), "★ nothing removed before [Remove]")
        m.askRemoveFace(5)
        XCTAssertNil(m.pressRemoveAsk, "★ one ask at a time")
        m.keepFace()
        m.askRemovePress(p.id)
        m.confirmRemovePress()
        XCTAssertNil(m.pressRemoveAsk, "the ask goes before the strip removal's task")
        try await FlexibleHisProject.waitFor(60, "Edge 12 removed") { m.settings.press(p.id) == nil }
        XCTAssertNil(m.settings.press(p.id), "★ [Remove]: Edge 12 goes")
        m.pressRemoveAsk = p.id   // an ask on a press already gone
        m.confirmRemovePress()
        XCTAssertNil(m.pressRemoveAsk)
        // (fix round 1, the check's flake: Edge 12's strip removal re-opens the scene — wait for it before the red branch)
        try await FlexibleSquishFixture.settle(m, "after Edge 12's removal (the scene re-open)")
        // RED CONTROL: today's one tap
        let q = try XCTUnwrap(m.presses.first { $0.strip?.label == "Edge 9" })
        FlexibleStageModel.controlRemoveAtOnce = true
        m.askRemovePress(q.id)
        FlexibleStageModel.controlRemoveAtOnce = false
        try await FlexibleHisProject.waitFor(60, "Edge 9 removed at once") { m.settings.press(q.id) == nil }
        XCTAssertNil(m.settings.press(q.id), "RED CONTROL: removed at once")
    }

    func testPopupRemoveAsksFirst() async throws {
        let (_, _, m) = try await open(Self.padDir, "his pad of 10-21")
        var closed = 0
        let fix = FlexibleFix.remove(5)
        XCTAssertTrue(FlexibleFixPopup.removes(fix))
        XCTAssertTrue(FlexibleFixPopup.removes(.pressFix(.remove(UUID(), label: "Edge 12"))))
        XCTAssertFalse(FlexibleFixPopup.removes(.rest(5)))
        FlexibleFixPopup.tap(fix, model: m, onDone: { closed += 1 })
        XCTAssertEqual(m.fixRemoveAsk, FlexibleFixAsk.key(FlexibleFixPopup.scope, FlexibleFixPopup.id(fix)), "★ [Remove Face 5] asks in place")
        XCTAssertNotNil(m.settings.face(5), "★ nothing removed yet"); XCTAssertEqual(closed, 0, "the pop-up stays")
        // a non-deleting fix applies at once
        FlexibleFixPopup.tap(.rest(3), model: m, onDone: { closed += 1 })
        XCTAssertEqual(m.settings.face(3)?.isLoaded, false, "[Face 3 rests]: one tap, as before"); XCTAssertEqual(closed, 1)
        // RED CONTROL: today's one tap
        FlexibleStageModel.controlRemoveAtOnce = true
        FlexibleFixPopup.tap(fix, model: m, onDone: { closed += 1 })
        XCTAssertNil(m.settings.face(5), "RED CONTROL: removed at once")
    }

    // MARK: ★ U21 FIX ROUND 1 — the check's two one-tap deletes left: the Lattice page's callout / card Core row and the edges
    // card's warning row (his Img13 note: "I shouldn't be able to do with a single click"; ruling E(2))

    func testLatticeCalloutAndPressRowRemoveAskFirst() async throws {
        let (_, _, m) = try await open(Self.padDir, "his pad of 10-21")
        let e12 = try XCTUnwrap(m.presses.first { $0.strip?.label == "Edge 12" }, "premise: his Edge 12")
        var closed = 0
        // the callout / the card's Core row: [Face 5 rests] [Remove Face 5] (FlexibleReadiness.restOrRemove's pair)
        let issue = FlexibleIssue(id: "u21-test", kind: .refused, region: 5, oneLine: "Face 5 can't be squished here", blocking: true,
                                  fixes: [.rest(5), .remove(5)])
        let buttons = FlexibleBlockerCallout.buttons(issue, pressNeedsWeight: { _ in false })
        XCTAssertEqual(buttons, [.apply(.rest(5)), .apply(.remove(5))])
        for scope in ["callout", "card"] {
            FlexibleCalloutButtons.tap(.apply(.remove(5)), model: m, scope: scope, close: { closed += 1 })
            XCTAssertEqual(m.fixRemoveAsk, FlexibleFixAsk.key(scope, "remove-5"), "★ \(scope): [Remove Face 5] asks in place")
            XCTAssertNotNil(m.settings.face(5), "★ \(scope): nothing removed before [Remove]"); XCTAssertEqual(closed, 0, "\(scope) stays open")
            m.rail = .model; m.rail = .group(1)   // a tab change drops it
            XCTAssertNil(m.fixRemoveAsk, "★ \(scope): the ask drops")
        }
        // a kept-out press's [Remove Edge 12] in the callout (FlexibleReadiness :407) and in the edges card's warning row
        let pf = FlexiblePressFix.remove(e12.id, label: "Edge 12")
        FlexibleCalloutButtons.tap(.apply(.pressFix(pf)), model: m, scope: "callout", close: { closed += 1 })
        XCTAssertEqual(m.fixRemoveAsk, FlexibleFixAsk.key("callout", "press-fix-" + pf.id), "★ the kept-out press's [Remove] asks")
        m.tapPressFix(pf)
        XCTAssertEqual(m.fixRemoveAsk, FlexibleFixAsk.key("pressFix", pf.id), "★ the warning row's [Remove Edge 12] asks (one ask at a time)")
        await m.waitForIdle()
        XCTAssertNotNil(m.settings.press(e12.id), "★ nothing removed before [Remove]")
        XCTAssertEqual(closed, 0)
        // the other fixes still apply on one tap
        FlexibleCalloutButtons.tap(.apply(.rest(3)), model: m, scope: "callout", close: { closed += 1 })
        XCTAssertEqual(m.settings.face(3)?.isLoaded, false, "[Face 3 rests]: one tap, as before"); XCTAssertEqual(closed, 1)
        // RED CONTROL: the code before this fix round (both paths applied at once)
        FlexibleStageModel.controlRemoveAtOnce = true
        FlexibleCalloutButtons.tap(.apply(.remove(5)), model: m, scope: "callout", close: { closed += 1 })
        XCTAssertNil(m.settings.face(5), "RED CONTROL: the callout's [Remove Face 5] removed at once")
        m.tapPressFix(pf)
        FlexibleStageModel.controlRemoveAtOnce = false
        try await FlexibleHisProject.waitFor(60, "Edge 12 removed at once") { m.settings.press(e12.id) == nil }
        XCTAssertNil(m.settings.press(e12.id), "RED CONTROL: the warning row's [Remove Edge 12] removed at once")
    }

    func testTakeOutQuestionNamesTheFaceOnly() {
        XCTAssertEqual(FlexibleConfirmCopy.takeOutAsk("Face 6 \u{00B7} lattice"), "Take Face 6 out?", "★ his l-bracket's section suffix dropped")
        XCTAssertEqual(FlexibleConfirmCopy.takeOutAsk("Face 5"), "Take Face 5 out?")
        XCTAssertEqual(FlexibleConfirmCopy.takeOutAsk("Top A"), "Take Top A out?")
        FlexibleStageModel.controlTakeOutFullName = true
        XCTAssertEqual(FlexibleConfirmCopy.takeOutAsk("Face 6 \u{00B7} lattice"), "Take Face 6 \u{00B7} lattice out?", "RED CONTROL: the whole name")
        FlexibleStageModel.controlTakeOutFullName = false
    }

    func testTakeOutIsItsOwnUndoStep() async throws {
        func run() async throws -> (afterOne: [Int: Double], afterTwo: [Int: Double], line: String) {
            let (r, _, m) = try await open(Self.padDir, "his pad of 10-21")
            let p = r.project
            p.sealUndoStep()
            func deepest() -> [Int: Double] { Dictionary(uniqueKeysWithValues: m.settings.faces.filter(\.isLoaded).map { ($0.faceRegionID, $0.deepestMM) }) }
            let d3 = m.settings.face(3)?.deepestMM ?? 0
            setDeepest(m, 5, 9)            // an edit
            m.removeFace(5)                // the take-out
            setDeepest(m, 3, d3 + 1)       // an edit within 0.5 s
            FlexibleStagePage.history(undo: true, project: p, model: m)
            let one = deepest()
            FlexibleStagePage.history(undo: true, project: p, model: m)
            let two = deepest()
            return (one, two, "after one Undo \(one) · after two \(two)")
        }
        FlexibleStageModel.controlRemoveFaceNoSeal = true
        let red = try await run()
        FlexibleStageModel.controlRemoveFaceNoSeal = false
        print("FLEX-U21-D5 RED (today) \(red.line)")
        XCTAssertFalse(red.afterOne[5] == nil && red.afterTwo[5] == 9, "RED CONTROL: the take-out folds into the edits around it")
        let a = try await run()
        print("FLEX-U21-D5 \(a.line)")
        XCTAssertNil(a.afterOne[5], "★ one Undo: only the later edit is undone (Face 5 still out)")
        XCTAssertEqual(a.afterTwo[5], 9, "★ two: Face 5 back with Deepest 9 (its own step)")
    }
}
