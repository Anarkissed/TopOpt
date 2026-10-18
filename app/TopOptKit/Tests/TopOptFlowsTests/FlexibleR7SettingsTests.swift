// FlexibleR7SettingsTests — round 7 batch S, the Settings page (task 2026-09-29-flexible-screens; his UI breakdown of
// 2026-10-14, img3 and img4). Judged on HIS pad (A1_0003 as he saved it: his img1–4 pad). Written BEFORE the code; every
// RED CONTROL is run INSIDE its test, so a green run also shows each check can fail.
//   4f "After creating the first group, and in particular adding a corner modification, automatically brings me back to
//      Group 1. It does this after every change I make, please make it stay on the same group and never shift."
//      RED: today's syncRail (the tab follows the SELECTED face) — Group 1 after a Strip width change and after the re-open.
//   4g "What is this 3mm? I don't see anything listed in the group with that number? I should only be able to view numbers
//      associated to what I'm working on." RED: today's gate on the selection alone — Face 1's chip and curves over the
//      edges group's tab, exactly his img4.
//   4h "The "reset all" button does not clear out *all* groups, currently. It should absolutely do that. All that should be
//      viewed is the "model" folder tab and the "New" one." RED: today's freshSettings — [Model, Group 1, Rests, New], the
//      strip still cut.
//   4d "All groups should have a trash icon next to them and their names should be editable by tapping "group 1" or
//      whatever the default name is." RED: the × only with two groups; a name not carried through a renumber.
import XCTest
import CoreGraphics
import MetalKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleR7SettingsTests: XCTestCase {
    typealias G = FlexibleAngledGoldens

    // MARK: - fixtures

    /// HIS pad, A1_0003 as he saved it: Group 1 = the top (face 1, the main page's Top), Group 2 = faces 4 and 2, Group 3
    /// = faces 3 and 5, face 0 rests. Opened, every pressed stack built.
    func hisPad() async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let m = try await G.openModel(self, r.project, "A1_0003")
        try await FlexibleSquishFixture.settle(m, "A1_0003")
        XCTAssertEqual(m.squeezeGroups.map(\.regions), [[1], [4, 2], [3, 5]], "premise: his three groups")
        return (r, m)
    }

    /// The part open again on the regions as they are now, its designs settled.
    func reopened(_ m: FlexibleStageModel, _ what: String = "the part open again") async throws {
        try await FlexibleHisProject.waitFor(240, what) { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        await m.waitForIdle()
        try await FlexibleSquishFixture.settle(m, what)
    }

    /// [+ New] → [Edges/corners] → Edge 9 (Face 1 + Face 2) → [Done]: an edges group (I2), the part open on the strips.
    @discardableResult
    func withEdge9(_ m: FlexibleStageModel, kg: Double = 5) async throws -> UUID {
        m.rail = .newGroup
        m.startEdgePick()
        try await FlexibleHisProject.waitFor(240, "the edges and corners listed") { m.edgePick.map { !$0.loading && !$0.checking } ?? false }
        await m.waitForIdle()
        let p = try XCTUnwrap(m.edgePick, "pick mode")
        let c = try XCTUnwrap(p.candidates.first { $0.kind == .edge && Set($0.members) == [1, 2] }, "the Top–Face 2 edge")
        m.toggleEdgePick(c.number)
        m.setEdgePickWeight(kg)
        let why = await m.finishEdgePick()
        XCTAssertNil(why, "[Done] cut the strips")
        try await reopened(m, "the part open on the strips")
        return try XCTUnwrap(m.presses.first { $0.strip != nil }, "the edge's press").id
    }

    /// What a squeeze group IS, whatever its number or its rests' ids: the mesh faces its faces lie on; an edges group,
    /// its presses.
    func token(_ m: FlexibleStageModel, _ g: FlexibleSqueezeGroup) -> String {
        if g.kind == .edges { return "presses " + g.presses.map(\.uuidString).sorted().joined(separator: ",") }
        let faces = Set(g.regions.flatMap { m.regions.faces(of: $0, mesh: m.project.viewerMesh) })
        return "faces " + faces.sorted().map(String.init).joined(separator: ",")
    }

    func openToken(_ m: FlexibleStageModel) -> String? {
        guard case .group(let id) = m.rail, let g = m.railGroup(id) else { return "\(m.rail)" }
        return token(m, g)
    }

    /// ★ THE RULE, after every step: the open tab is the group that holds the same members, and the selected face is none
    /// or one of them.
    func check(_ m: FlexibleStageModel, _ want: String, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(openToken(m), want, "\(step): the open tab is still the group it was", file: file, line: line)
        if let r = m.selectedRegion, case .group(let id) = m.rail, let g = m.railGroup(id) {
            XCTAssertTrue(g.regions.contains(r), "\(step): the selected face \(r) is in the open group \(g.regions)", file: file, line: line)
        }
    }

    /// The region on mesh face `face` that `m`'s settings hold (a whole face, or its rest beside a strip).
    func faceOn(_ m: FlexibleStageModel, _ face: Int) -> Int? {
        m.settings.faces.first { m.regions.faces(of: $0.faceRegionID, mesh: m.project.viewerMesh) == [face] }?.faceRegionID
    }

    func titles(_ m: FlexibleStageModel) -> [String] { FlexibleSettingsRailView.tabs(model: m).map(\.title) }

    /// A projection of `project` at his img2 camera (the renderer's own clip-from-model).
    func projection(_ project: ProjectModel, size: CGFloat = 900) throws -> CameraProjection {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 1))
        mr.setMesh(try XCTUnwrap(project.viewerMesh))
        mr.beginSettle(to: project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0)), duration: 0)
        mr.camera.setOrientation(azimuth: .pi / 4, elevation: .pi / 6)
        return CameraProjection(viewProjection: mr.clipFromModel(aspect: 1), viewportSize: CGSize(width: size, height: size))
    }

    // MARK: - 4f the open group never shifts

    func testTheOpenGroupNeverShiftsAfterAnyChange() async throws {
        let (r, m) = try await hisPad()
        let pid = try await withEdge9(m)
        let edges = try XCTUnwrap(m.squeezeGroup(ofPress: pid))
        XCTAssertEqual(edges.kind, .edges)
        XCTAssertEqual(m.squeezeGroups.count, 4, "his three groups and the edges group")
        print("FLEX-R7-4f groups: " + m.squeezeGroups.map { "\($0.number) \(token(m, $0))" }.joined(separator: " | "))
        let popping0 = m.readiness.popping.map(\.id)
        print("FLEX-R7-4f standing pop-up issues: \(popping0)")

        var log: [String] = []
        for n in 1...m.squeezeGroups.count {
            // (each group read NOW: an earlier tab's re-cut re-ids the rests)
            let g = try XCTUnwrap(m.squeezeGroups.first { $0.number == n })
            let want = token(m, g)
            m.rail = .group(g.id)
            check(m, want, "open Group \(g.number)")
            if g.kind == .edges {
                XCTAssertNil(m.selectedRegion, "an edges tab selects no face (it has none)")
                XCTAssertEqual(m.selectedPress, g.presses.first, "…its first press instead")
            } else {
                XCTAssertEqual(m.selectedRegion, g.regions.first, "a faces tab selects its first face")
            }
            m.setGroupForce(g.id, kg: 3 + Double(g.number))
            check(m, want, "Group \(g.number): setGroupForce")
            m.setGroupColour(g.id, .yellow)
            check(m, want, "Group \(g.number): setGroupColour")
            // a curve edit on another group's face (Group 3's face 5) and on the open group's own
            for reg in [faceOn(m, 5)].compactMap({ $0 }) + (g.kind == .faces ? [m.railGroup(g.id)?.regions.first].compactMap { $0 } : []) {
                m.edit({ s in
                    guard var f = s.face(reg) else { return }
                    let i = f.curveX.y.count / 2
                    f.curveX.y[i] = f.curveX.y[i] > 0.5 ? f.curveX.y[i] - 0.05 : f.curveX.y[i] + 0.05
                    s.setFace(f)
                }, recompute: false)
                m.curveChanged(region: reg)
            }
            check(m, want, "Group \(g.number): a curve edit")
            // ★ HIS IMG4: a Strip width change, then the re-open after the cut
            var prompt = FlexibleFixPrompt(actionSerial: m.actionSerial)
            _ = prompt.next(m.readiness, actionSerial: m.actionSerial, settled: true)
            // ★ RE-PINNED (round 7, R7-E1 — his 2026-10-18 words: "There shouldn't be a strip width. It should be a Flat prism that gets wider as it gets dragged further towards the centre of the model from the edge."): the edit was a Strip width change (setStripWidth); the Strip width is gone, so the edit is the flat prism's depth (setFlatCut, 6 or 8 mm) — the same one re-cut and one undo step.
            let why = await FlexibleFlatPrismFixtures.reDepth(m, pid)
            XCTAssertNil(why)
            check(m, want, "Group \(g.number): setFlatCut (the depth)")
            try await reopened(m)
            check(m, want, "Group \(g.number): the re-open after the cut")
            // the pop-up's rule: a re-cut rest is not a NEW issue (ids by the face's root)
            let fresh = prompt.next(m.readiness, actionSerial: m.actionSerial, settled: true)
            XCTAssertNil(fresh.map(\.id).flatMap { id in popping0.contains(where: { $0.split(separator: "|").first == id.split(separator: "|").first }) ? id : nil },
                         "Group \(g.number): a standing issue re-keyed by the cut does not pop again")
            if n == 1 { try await issueKeysSurviveTheCut(m, pid) }
            // undo, then redo
            FlexibleStagePage.history(undo: true, project: r.project, model: m)
            try await reopened(m)
            check(m, want, "Group \(g.number): undo")
            FlexibleStagePage.history(undo: false, project: r.project, model: m)
            try await reopened(m)
            check(m, want, "Group \(g.number): redo")
            // the panels' onAppear rule
            let sel = m.selectedRegion
            m.selectedRegion = nil
            m.selectedRegion = FlexibleStageModel.appearSelection(m)
            check(m, want, "Group \(g.number): the panel's onAppear")
            if g.kind == .faces { XCTAssertNotNil(m.selectedRegion, "a faces tab's first face") } else { XCTAssertNil(m.selectedRegion) }
            if m.selectedRegion == nil, let s = sel, g.kind == .faces { m.selectedRegion = s }
            // the fix pop-up on every issue that pops now (a face in another group is pulsed, never opened)
            for i in m.readiness.popping {
                if let s = FlexibleStagePage.presentSelection(i, model: m) { m.selectedRegion = s }
                check(m, want, "Group \(g.number): the pop-up on \(i.id)")
            }
            log.append("Group \(g.number) [\(want)] → \(openToken(m) ?? "-") · selected \(m.selectedRegion.map(String.init) ?? "none")")
        }
        print("FLEX-R7-4f each tab after every step:\n  " + log.joined(separator: "\n  "))

        // ── the destructive steps, in one order: a face removed in another group, a lower group removed (renumber),
        // a face removed in the open group
        let g3 = try XCTUnwrap(m.squeezeGroups.first { token(m, $0) == "faces 3,5" })
        m.rail = .group(g3.id)
        let want3 = token(m, g3)
        m.removeFace(try XCTUnwrap(faceOn(m, 4)))
        check(m, want3, "Group 3 open: removeFace in another group (face 4)")
        let g2 = try XCTUnwrap(m.squeezeGroups.first { token(m, $0) == "faces 2" })
        m.removeGroup(g2.id)
        try await reopened(m)
        check(m, want3, "Group 3 open: a lower group removed (it renumbers)")
        XCTAssertEqual(m.railGroup({ if case .group(let id) = m.rail { return id }; return -1 }())?.number, g3.number - 1,
                       "Group 3 is shown as Group 2 now — and is still the open tab")
        m.removeFace(5)
        check(m, "faces 3", "Group 3 open: removeFace in the same group (face 5)")
        let e = try XCTUnwrap(m.squeezeGroup(ofPress: pid))
        m.rail = .group(e.id)
        m.removeFace(3)
        check(m, token(m, e), "the edges tab open: removeFace in another group (face 3)")

        // ★ RED CONTROL (today's syncRail): the edges tab open with Face 1's rest still selected — exactly the state
        // [Done] left (today's railChanged selects nothing on an edges tab) — a Strip width change opens Group 1
        FlexibleStageModel.controlRailFollowsSelection = true
        defer { FlexibleStageModel.controlRailFollowsSelection = false }
        let top = try XCTUnwrap(faceOn(m, 1))
        let e2 = try XCTUnwrap(m.squeezeGroup(ofPress: pid))
        m.selectedRegion = top
        m.rail = .group(e2.id)
        // ★ RE-PINNED (round 7, R7-E1 — his 2026-10-18 words: "There shouldn't be a strip width. It should be a Flat prism that gets wider as it gets dragged further towards the centre of the model from the edge."): the edit was a Strip width change (setStripWidth); the Strip width is gone, so the edit is the flat prism's depth (setFlatCut, 6 or 8 mm) — the same one re-cut and one undo step.
        _ = await FlexibleFlatPrismFixtures.reDepth(m, pid)
        XCTAssertEqual(m.rail, .group(1), "control: after the depth re-cut, Group 1 — his img4")
        try await reopened(m)
        XCTAssertEqual(m.rail, .group(1), "control: after the re-open, Group 1")
    }

    /// ★ 4f (f), "a readiness refresh with noLatticeUnder standing": on his pad as saved no face is short of lattice, so the
    /// issue is made to stand on Face 1's rest (its latticed share set to 10 % in the readiness inputs — core's count is
    /// the only thing changed) before and after a Strip width re-cut: its id is the face's, so the pop-up sees no NEW
    /// issue. RED CONTROL (ids by region, today's): the re-cut rest's new id pops it again.
    func issueKeysSurviveTheCut(_ m: FlexibleStageModel, _ pid: UUID) async throws {
        func standing() throws -> FlexibleReadiness {
            let rest = try XCTUnwrap(faceOn(m, 1))
            var i = m.readinessInputs
            i.pressed = i.pressed.map { f in var f = f; if f.region == rest { f.latticedShare = 0.1 }; return f }
            return FlexibleReadiness.evaluate(i)
        }
        func run() async throws -> (before: [String], after: [String], popped: FlexibleIssue?) {
            let r0 = try standing()
            var prompt = FlexibleFixPrompt(actionSerial: m.actionSerial)
            _ = prompt.next(r0, actionSerial: m.actionSerial, settled: true)
            // ★ RE-PINNED (round 7, R7-E1 — his 2026-10-18 words: "There shouldn't be a strip width. It should be a Flat prism that gets wider as it gets dragged further towards the centre of the model from the edge."): the edit was a Strip width change (setStripWidth); the Strip width is gone, so the edit is the flat prism's depth (setFlatCut, 6 or 8 mm) — the same one re-cut and one undo step.
            _ = await FlexibleFlatPrismFixtures.reDepth(m, pid)
            try await reopened(m)
            let r1 = try standing()
            let popped = prompt.next(r1, actionSerial: m.actionSerial, settled: true)
            return (r0.issues.filter { $0.kind == .noLatticeUnder }.map(\.id), r1.issues.filter { $0.kind == .noLatticeUnder }.map(\.id), popped)
        }
        let a = try await run()
        print("FLEX-R7-4f noLatticeUnder standing on Face 1's rest: \(a.before) → \(a.after) · popped \(a.popped?.id ?? "none")")
        XCTAssertEqual(a.before.count, 1, "premise: it stands")
        XCTAssertEqual(a.before, a.after, "its id is the face's: the re-cut rest is the same issue")
        XCTAssertNil(a.popped, "so the pop-up does not open on it again (it opened Group 1 in his img4)")
        // ★ RED CONTROL: ids by region (today's) — the re-cut rest is a NEW issue and pops
        FlexibleReadiness.controlIssueIdByRegion = true
        defer { FlexibleReadiness.controlIssueIdByRegion = false }
        let c = try await run()
        // ★ RE-PINNED (round 7, M2 — the reviewer's ruling 3): a strip's rest is a Flexible sector keyed by its ROLE
        // ("rest:<face>:1"), so a re-cut keeps its REGION id too — the failure this control showed (I2's Surface cut gave the
        // rest a new sector id, a new issue, a new pop-up) cannot happen any more; even ids by region stay the same
        print("FLEX-R7-4f control (ids by region, M2): \(c.before) → \(c.after) · popped \(c.popped?.id ?? "none")")
        XCTAssertEqual(c.before, c.after, "control (M2): by region too — the rest keeps its id through a re-cut")
        XCTAssertNil(c.popped, "control (M2): …so nothing pops")
    }

    /// The explicit picks still move the tab (testTheRailFollowsTheSelectedFaceAndThePlayingGroupIsTheTabs keeps its
    /// words): a face tapped on the part, a row, the player's picker; and the playing group IS the open tab.
    func testAnExplicitPickStillMovesTheTabAndTheTabIsWhatPlays() async throws {
        let (_, m) = try await hisPad()
        let pid = try await withEdge9(m)
        let edges = try XCTUnwrap(m.squeezeGroup(ofPress: pid))
        m.rail = .group(edges.id)
        XCTAssertEqual(m.playingGroup?.id, edges.id, "the open tab is the group that plays — never Group 1 behind it")
        m.tapFace(3)
        XCTAssertEqual(m.rail, .group(try XCTUnwrap(m.squeezeGroup(of: 3)).id), "a face tapped on the part opens its group")
        m.select(try XCTUnwrap(faceOn(m, 2)))
        XCTAssertEqual(m.rail, .group(try XCTUnwrap(m.squeezeGroup(of: try XCTUnwrap(faceOn(m, 2)))).id), "a row picked opens its group")
        m.selectedRegion = 3   // a selection made by the code is not a pick
        XCTAssertEqual(m.rail, .group(try XCTUnwrap(m.squeezeGroup(of: try XCTUnwrap(faceOn(m, 2)))).id), "…and moves no tab")
    }

    // MARK: - 4g only the open group's numbers

    func testOnlyTheOpenGroupsNumbersShow() async throws {
        let (r, m) = try await hisPad()
        // Face 1 as in his img3 / img4: Curves, deepest 3 mm
        m.setShape(1, "curves")
        m.edit { s in guard var f = s.face(1) else { return }; f.deepestMM = 3; s.setFace(f) }
        try await FlexibleSquishFixture.settle(m, "Face 1 curves 3 mm")
        let pid = try await withEdge9(m)
        let top = try XCTUnwrap(faceOn(m, 1), "Face 1's rest")
        let k = 3.0
        let edges = try XCTUnwrap(m.squeezeGroup(ofPress: pid))
        let g1 = try XCTUnwrap(m.squeezeGroup(of: top))
        // ★ HIS IMG4: the edges tab open, Face 1's rest selected (whatever put it there)
        m.rail = .group(g1.id)
        m.select(top)
        m.rail = .group(edges.id)
        m.selectedRegion = top
        XCTAssertNil(FlexibleStageOverlays.workingRegion(model: m), "the edges tab: no face is worked on")
        XCTAssertNil(FlexibleDepthChips.handle(model: m, k: k), "no '3.0 mm' chip over the edges tab")
        XCTAssertNil(FlexibleStageOverlays.curveEditors(model: m), "no Top curves over the edges tab")
        XCTAssertTrue(FlexibleFaceStampHandle.placements(m.settings, selected: FlexibleStageOverlays.workingRegion(model: m)).isEmpty,
                      "no stamp handle")
        // the Prisms view: the other groups' prisms stay, their mm tags go
        m.views = [.prisms]
        let g2 = try XCTUnwrap(m.squeezeGroups.first { token(m, $0) == "faces 2,4" })
        m.rail = .group(g2.id)
        let floors = FlexibleStageViewTags.floors(model: m, k: k)
        XCTAssertFalse(floors.isEmpty, "Group 2's other face has its tag")
        XCTAssertTrue(Set(floors.map(\.region)).isSubset(of: Set(g2.regions)), "only the open group's mm tags: \(floors.map(\.region)) ⊆ \(g2.regions)")
        let tags = FlexibleStageViewTags.tags(model: m, k: k, projection: try projection(r.project), keepOut: [])
        XCTAssertTrue(Set(tags.map(\.region)).isSubset(of: Set(g2.regions)), "on screen too: \(tags.map(\.region))")
        XCTAssertEqual(Set(FlexibleDepthPrism.renderItems(model: m, k: k, views: [.prisms]).map(\.volume.faceID)).count,
                       m.settings.loadedFaces.count, "every pressed face's prism is still drawn (faint)")
        m.views = []
        // Group 1 open: Face 1's chip, its number
        m.rail = .group(g1.id)
        XCTAssertEqual(m.selectedRegion, top)
        XCTAssertEqual(FlexibleStageOverlays.workingRegion(model: m), top)
        XCTAssertNotNil(FlexibleDepthChips.handle(model: m, k: k), "Group 1 open: Face 1's chip")
        XCTAssertEqual(String(format: "%.1f mm", try XCTUnwrap(m.settings.face(top)).deepestMM), "3.0 mm")
        XCTAssertEqual(FlexibleStageOverlays.curveEditors(model: m)?.axes, ["x", "y"], "its curves")
        print("FLEX-R7-4g Group 2 tags \(floors.map { "\($0.region) \($0.text)" }) · Group 1: chip on \(top)")

        // ★ RED CONTROL (today's gate on the selection alone): his img4 — the chip and the curves over the edges tab
        FlexibleStageOverlays.controlGateOnSelectionOnly = true
        defer { FlexibleStageOverlays.controlGateOnSelectionOnly = false }
        m.rail = .group(edges.id)
        m.selectedRegion = top
        XCTAssertEqual(FlexibleStageOverlays.workingRegion(model: m), top, "control: the selection alone")
        XCTAssertNotNil(FlexibleDepthChips.handle(model: m, k: k), "control: Face 1's '3.0 mm' chip over the edges tab")
        XCTAssertNotNil(FlexibleStageOverlays.curveEditors(model: m), "control: its curves too")
        m.views = [.prisms]
        m.rail = .group(g2.id)
        XCTAssertFalse(Set(FlexibleStageViewTags.floors(model: m, k: k).map(\.region)).isSubset(of: Set(g2.regions)),
                       "control: every group's tags")
        m.views = []
    }

    // MARK: - 4h Reset all leaves [Model] and [New]

    func testResetAllLeavesOnlyModelAndNew() async throws {
        let (r, m) = try await hisPad()
        let regionsBefore = r.project.faceRegions
        let wireBefore = m.regions.key
        let unit = m.settings.weightUnit
        try await withEdge9(m)
        // ★ RE-PINNED (round 7, M2 — the reviewer's ruling 3): the strip is a Flexible-only sector; the Surface stage's regions
        // are never cut (they were I2's premise here)
        XCTAssertEqual(r.project.faceRegions, regionsBefore, "★ M2: the Surface stage's regions untouched by the strip")
        XCTAssertFalse((m.regions.flexible?.pieces ?? []).filter { $0.kind == .strip }.isEmpty, "premise: the strip is cut (Flexible)")
        let settingsCut = m.settings, regionsCut = r.project.faceRegions, titlesCut = titles(m)
        print("FLEX-R7-4h before: \(titlesCut)")
        m.resetAll()
        XCTAssertEqual(titles(m), ["Model", "New"], "Reset all: only [Model] and [New]")
        XCTAssertTrue(m.settings.faces.isEmpty, "every face gone")
        XCTAssertNil(m.settings.presses, "every press gone")
        XCTAssertNil(m.settings.groupColours); XCTAssertNil(m.settings.groupNames)
        XCTAssertEqual(m.settings.weightUnit, unit, "the unit is how he reads — kept")
        XCTAssertEqual(r.project.faceRegions.regions, regionsBefore.regions, "every strip given back to its face")
        XCTAssertTrue((m.regions.flexible?.pieces ?? []).isEmpty, "★ M2: no Flexible strip left")
        XCTAssertEqual(m.regions.key, wireBefore, "the job's regions as before the strip")
        XCTAssertEqual(m.rail, .newGroup, "[New] open")
        XCTAssertNil(m.selectedRegion); XCTAssertNil(m.selectedPress)
        try await reopened(m, "the part open again on whole faces")
        XCTAssertEqual(titles(m), ["Model", "New"], "after the re-open: nothing read in again")
        XCTAssertTrue(m.settings.faces.isEmpty)
        XCTAssertNil(m.selectedRegion)
        // ONE undo: every tab and the strip back
        FlexibleStagePage.history(undo: true, project: r.project, model: m)
        try await reopened(m)
        XCTAssertEqual(m.settings, settingsCut, "undo: the setup as it was")
        XCTAssertEqual(r.project.faceRegions, regionsCut, "undo: the Surface stage's regions as they were (untouched)")
        XCTAssertFalse((m.regions.flexible?.pieces ?? []).filter { $0.kind == .strip }.isEmpty, "★ M2: undo — the strip back")
        XCTAssertEqual(titles(m), titlesCut, "undo: every tab back")
        FlexibleStagePage.history(undo: false, project: r.project, model: m)
        try await reopened(m)
        XCTAssertEqual(titles(m), ["Model", "New"], "redo")
        // [New] with nothing pressed: a tap on a face starts Group 1 — a typed weight where the main page gives none
        m.rail = .newGroup
        m.tapFace(3)
        XCTAssertEqual(m.newGroupAsk, 3, "face 3 (no main-page load): the keypad asks its weight")
        XCTAssertTrue(m.settings.loadedFaces.isEmpty, "nothing pressed before the weight")
        XCTAssertTrue(m.startFirstGroup(3, kg: 2), "the typed weight starts it")
        XCTAssertEqual(m.squeezeGroups.map(\.regions), [[3]], "Group 1 = face 3")
        XCTAssertEqual(m.settings.face(3)?.weightKg, 2)
        XCTAssertEqual(m.rail, .group(1), "its tab opens")
        XCTAssertNil(m.newGroupAsk)
        FlexibleStagePage.history(undo: true, project: r.project, model: m)
        XCTAssertTrue(m.settings.faces.isEmpty, "one undo step")
        // the top: the main page's Top gives its weight (no keypad)
        m.rail = .newGroup
        m.tapFace(1)
        XCTAssertEqual(m.squeezeGroups.map(\.regions), [[1]], "a tap on the top starts Group 1")
        XCTAssertEqual(m.settings.face(1)?.weightFrom, r.project.selection.groups.first { $0.name == "Top" }?.id, "linked to the main page's Top")
        XCTAssertEqual(m.rail, .group(1))

        // ★ RED CONTROL (today's freshSettings): the main page's loads read in again, the strip left cut
        FlexibleStagePage.history(undo: true, project: r.project, model: m)
        FlexibleStagePage.history(undo: true, project: r.project, model: m)
        try await reopened(m)
        XCTAssertEqual(m.settings, settingsCut, "back before the reset")
        FlexibleStageModel.controlResetAdopts = true
        defer { FlexibleStageModel.controlResetAdopts = false }
        m.resetAll()
        XCTAssertEqual(titles(m), ["Model", "Group 1", "Rests", "New"], "control: the main page's Top and Bottom read in again")
        // (★ M2: "the strip sectors stay cut" was I2's Surface regions — the strips now go with their presses in both resets)
    }

    // MARK: - 4d a trash and a name on every group

    func testEveryGroupHasATrashAndATapToRenameName() async throws {
        let (r, m) = try await hisPad()
        // an old project encodes byte-identical: no names, no key
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let saved = try XCTUnwrap(r.project.lattice.flexible)
        let data = try enc.encode(saved)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("groupNames"), "an old project carries no names key")
        XCTAssertEqual(try enc.encode(try JSONDecoder().decode(FlexibleStageSettings.self, from: data)), data, "round trip byte-identical")
        // rename Group 2
        let inputs = m.settings.designInputs
        let g2 = try XCTUnwrap(m.squeezeGroups.first { $0.number == 2 })
        m.setGroupName(g2.id, "Thumbs")
        XCTAssertEqual(m.groupName(try XCTUnwrap(m.railGroup(g2.id))), "Thumbs")
        XCTAssertEqual(titles(m)[2], "Thumbs", "the rail's tab")
        XCTAssertTrue(FlexibleSqueezeGroupRows.rows(model: m).contains { $0.line.hasPrefix("Thumbs") }, "the group's header")
        let sims = FlexibleSettingsSquish.playerSims(model: m)
        XCTAssertTrue(sims.contains { $0.short == "Thumbs" }, "the player's picker: \(sims.map(\.short))")
        XCTAssertEqual(m.settings.designInputs, inputs, "a name never makes the lattice stale")
        XCTAssertTrue(String(decoding: try enc.encode(m.settings), as: UTF8.self).contains("groupNames"), "a name is saved")
        // ★ VERIFY OF R7-S: 12 characters at most (16 were cut on the rail's tab and pushed the player's line: "Index
        // finger…", "no latti…"); cleared → its number again
        m.setGroupName(g2.id, "A name much longer than sixteen")
        XCTAssertLessThanOrEqual(m.groupName(try XCTUnwrap(m.railGroup(g2.id))).count, 12)
        XCTAssertEqual(FlexibleStageModel.groupNameMax, 12)
        m.setGroupName(g2.id, "")
        XCTAssertEqual(m.groupName(try XCTUnwrap(m.railGroup(g2.id))), "Group 2", "cleared: 'Group 2' again")
        m.setGroupName(g2.id, "Thumbs")
        // trash on Group 1: it is DELETED (its face leaves the setup); Group 2 is Group 1 now and keeps its name
        let rows = FlexibleSqueezeGroupRows.rows(model: m)
        XCTAssertTrue(rows.allSatisfy(\.removable), "every group has its trash")
        let before = m.settings
        m.removeGroup(try XCTUnwrap(m.squeezeGroups.first).id)
        XCTAssertNil(m.settings.face(1), "Group 1's face left the setup (the trash deletes; it no longer merges)")
        XCTAssertTrue(m.settings.removedRegions?.contains(1) == true, "the main page's Top still holds it: remembered as deleted")
        XCTAssertEqual(m.squeezeGroups.first?.regions, [4, 2])
        XCTAssertEqual(m.squeezeGroups.first.map { m.groupName($0) }, "Thumbs", "renumbered to 1, still 'Thumbs'")
        FlexibleStagePage.history(undo: true, project: r.project, model: m)
        XCTAssertEqual(m.settings, before, "one undo step")
        // ★ RED CONTROL: a name not carried through the renumber is lost
        FlexibleSqueezeGroups.controlNoNameRemap = true
        defer { FlexibleSqueezeGroups.controlNoNameRemap = false }   // (a throw below must not leave it on for later tests)
        m.removeGroup(try XCTUnwrap(m.squeezeGroups.first).id)
        XCTAssertNotEqual(m.squeezeGroups.first.map { m.groupName($0) }, "Thumbs", "control: the name lost on the renumber")
        FlexibleSqueezeGroups.controlNoNameRemap = false
        FlexibleStagePage.history(undo: true, project: r.project, model: m)
        XCTAssertEqual(m.settings, before)
        // the ONLY group has its trash too: Reset all, the top starts Group 1, its trash leaves [Model] [New]
        m.resetAll()
        try await reopened(m)
        m.rail = .newGroup
        m.tapFace(1)
        XCTAssertEqual(m.squeezeGroups.count, 1)
        XCTAssertEqual(FlexibleSqueezeGroupRows.rows(model: m).map(\.removable), [true], "the only group has its trash")
        let one = m.settings
        m.removeGroup(try XCTUnwrap(m.squeezeGroups.first).id)
        XCTAssertTrue(m.squeezeGroups.isEmpty, "trash: no group left")
        XCTAssertEqual(titles(m), ["Model", "New"])
        XCTAssertEqual(m.rail, .newGroup)
        FlexibleStagePage.history(undo: true, project: r.project, model: m)
        XCTAssertEqual(m.settings, one, "one undo step")
        // ★ RED CONTROL: today's rule — the × only with two or more groups
        FlexibleSqueezeGroupRows.controlRemovableOnlyWithTwo = true
        defer { FlexibleSqueezeGroupRows.controlRemovableOnlyWithTwo = false }
        XCTAssertEqual(FlexibleSqueezeGroupRows.rows(model: m).map(\.removable), [false], "control: the only group has no trash")
    }

    // MARK: - the verify of R7-S (2026-10-14): what the review found

    /// ★ VERIFY (finding: present()'s new rule had no test — "the fix pop-up on every issue that pops now" looped over an
    /// empty list on his pad): an issue standing on GROUP 1's face, with another tab open, is named and pulsed — the tab and
    /// the selection stay; with its own group open it selects its face. RED CONTROL: today's present() (it selected the face
    /// and the tab followed it to Group 1 — his img4).
    func testAPopUpAboutAnotherGroupsFaceLeavesTheTab() async throws {
        let (_, m) = try await hisPad()
        let pid = try await withEdge9(m)
        let rest = try XCTUnwrap(faceOn(m, 1), "Face 1's rest")
        let g1 = try XCTUnwrap(m.squeezeGroup(of: rest))
        let edges = try XCTUnwrap(m.squeezeGroup(ofPress: pid))
        let g2 = try XCTUnwrap(m.squeezeGroups.first { token(m, $0) == "faces 2,4" })
        // the issue made to stand on Face 1's rest (core's latticed share 10 %, as issueKeysSurviveTheCut does)
        var inputs = m.readinessInputs
        inputs.pressed = inputs.pressed.map { f in var f = f; if f.region == rest { f.latticedShare = 0.1 }; return f }
        let issue = try XCTUnwrap(FlexibleReadiness.evaluate(inputs).popping.first { $0.region == rest }, "an issue on Face 1's rest")
        print("FLEX-R7-VERIFY pop-up issue \(issue.id) on \(rest)")
        /// The page's present(): its face selected only when presentSelection gives it.
        func present() { if let s = FlexibleStagePage.presentSelection(issue, model: m) { m.selectedRegion = s } }
        for (what, g) in [("the edges tab", edges), ("Group 2's tab", g2)] {
            m.rail = .group(g.id)
            let sel = m.selectedRegion
            XCTAssertNil(FlexibleStagePage.presentSelection(issue, model: m), "\(what): the pop-up selects no face of another group")
            present()
            XCTAssertEqual(m.rail, .group(g.id), "\(what): the tab stays")
            XCTAssertEqual(m.selectedRegion, sel, "\(what): the selection stays")
            XCTAssertNotEqual(FlexibleStageOverlays.workingRegion(model: m), rest, "\(what): Face 1's numbers are not drawn")
        }
        m.rail = .group(g1.id)
        XCTAssertEqual(FlexibleStagePage.presentSelection(issue, model: m), rest, "its own group open: the pop-up selects its face")
        // ★ RED CONTROL: today's present() — it selects Face 1 behind the edges tab, and the tab follows it to Group 1
        FlexibleStageModel.controlRailFollowsSelection = true
        defer { FlexibleStageModel.controlRailFollowsSelection = false }
        m.selectedRegion = nil
        m.rail = .group(edges.id)
        XCTAssertEqual(FlexibleStagePage.presentSelection(issue, model: m), rest, "control: today's pop-up selects Face 1")
        present()
        XCTAssertEqual(m.rail, .group(g1.id), "control: …and the tab jumps to Group 1 (his img4)")
    }

    /// ★ VERIFY (finding: "On [+ New] (with faces pressed) and on [Model], tapping a face no group holds still opens Group 1"):
    /// [+ New]'s line says "Tap the face that starts it" — a tap on a face no group holds STARTS a new group from it (the
    /// keypad asks its weight where no main-page Load group gives one; ONE undo step; its tab opens); on [Model] it opens the
    /// group he was working on (its card offers [Press it] there). Never Group 1 by default. RED CONTROL: today's default.
    func testATapOnNewStartsAGroupFromAFaceNoGroupHolds() async throws {
        let (r, m) = try await hisPad()
        m.removeFace(3)
        XCTAssertNil(m.settings.face(3), "premise: face 3 is in no group")
        XCTAssertEqual(m.squeezeGroups.map(\.regions), [[1], [4, 2], [5]])
        let g3 = try XCTUnwrap(m.squeezeGroups.first { $0.regions == [5] })
        // [+ New]: the tap asks the weight — the tab stays [+ New]
        m.rail = .newGroup
        m.tapFace(3)
        XCTAssertEqual(m.rail, .newGroup, "the tab stays [+ New] — never Group 1")
        XCTAssertEqual(m.newGroupAsk, 3, "the keypad asks face 3's weight (no main-page load presses it)")
        XCTAssertNil(m.settings.face(3), "nothing pressed before the weight")
        XCTAssertTrue(m.startNewGroup(3, kg: 2), "the typed weight starts it")
        let g = try XCTUnwrap(m.squeezeGroup(of: 3))
        XCTAssertEqual(g.regions, [3], "a group of its own")
        XCTAssertEqual(g.number, 4, "the next number")
        XCTAssertEqual(m.settings.face(3)?.weightKg, 2)
        XCTAssertEqual(m.squeezeGroups.map(\.regions), [[1], [4, 2], [5], [3]], "the other groups untouched")
        XCTAssertEqual(m.rail, .group(g.id), "its tab opens")
        XCTAssertEqual(m.selectedRegion, 3)
        XCTAssertNil(m.newGroupAsk)
        FlexibleStagePage.history(undo: true, project: r.project, model: m)
        XCTAssertNil(m.settings.face(3), "one undo step")
        XCTAssertEqual(m.squeezeGroups.map(\.regions), [[1], [4, 2], [5]])
        // [Model]: the group he was working on opens (its card offers [Press it] there)
        m.rail = .group(g3.id)
        m.rail = .model
        m.tapFace(3)
        XCTAssertEqual(m.rail, .group(g3.id), "[Model]: the group he had open — never Group 1")
        XCTAssertEqual(m.selectedRegion, 3)
        // ★ RED CONTROL: today's default — Group 1 opens from [+ New] and from [Model]
        FlexibleStageModel.controlNewTabOpensGroupOne = true
        defer { FlexibleStageModel.controlNewTabOpensGroupOne = false }
        let first = try XCTUnwrap(m.squeezeGroups.first).id
        m.rail = .newGroup
        m.tapFace(3)
        XCTAssertEqual(m.rail, .group(first), "control: [+ New] → Group 1")
        m.rail = .group(g3.id)
        m.rail = .model
        m.tapFace(3)
        XCTAssertEqual(m.rail, .group(first), "control: [Model] → Group 1")
    }

    /// ★ VERIFY (findings: "Reset all at once pops a blocker" — the [Press Face 1] pop-up over [Model] [New], still up while
    /// the keypad asked Face 3's weight): the blocker "nothing pressed" his Reset caused does not POP while [+ New] is open
    /// (that tab asks for exactly that: "Tap the face that starts it"); it stays in the top line and Exit still names it
    /// ("Fix 1 thing" — whether an empty setup may leave is asked of him). Any other tab: blockers pop at once as before.
    /// RED CONTROL: today's — it pops.
    func testResetAllPopsNothingOverModelAndNew() async throws {
        let (_, m) = try await hisPad()
        var prompt = FlexibleFixPrompt(actionSerial: m.actionSerial)   // the page as it opened
        _ = prompt.next(m.readiness, actionSerial: m.actionSerial, settled: true)
        m.resetAll()
        try await reopened(m, "the part open on whole faces")
        let i = try XCTUnwrap(prompt.next(m.readiness, actionSerial: m.actionSerial, settled: true),
                              "premise: 'nothing pressed' stands, new, from his Reset")
        XCTAssertEqual(i.kind, .noPressedFace)
        XCTAssertEqual(m.rail, .newGroup)
        XCTAssertFalse(FlexibleStagePage.popsAtOnce(i, model: m), "no pop-up over [Model] [New]")
        XCTAssertEqual(FlexibleSettingsExit.title(m.readiness, modified: true), "Fix 1 thing", "Exit still names it (asked of him)")
        // the keypad's ask on face 3: nothing pops either
        m.tapFace(3)
        XCTAssertEqual(m.newGroupAsk, 3)
        XCTAssertFalse(prompt.next(m.readiness, actionSerial: m.actionSerial, settled: true).map { FlexibleStagePage.popsAtOnce($0, model: m) } ?? false)
        // another tab open — ★ RE-PINNED (round 7 batch F, his answers 3 "Allow an *empty* setup after reset all." and 9
        // "Do not." keep suggesting the Top): over the EMPTY setup nothing pops on any tab; R7-S's rule (it popped on [Model])
        // is `controlEmptyBlocks`
        m.rail = .model
        XCTAssertTrue(m.isEmptySetup, "premise: nothing set to squish")
        XCTAssertFalse(FlexibleStagePage.popsAtOnce(i, model: m), "★ F: [Model] open over the empty setup: nothing pops")
        FlexibleSettingsExit.controlEmptyBlocks = true
        XCTAssertTrue(FlexibleStagePage.popsAtOnce(i, model: m), "R7-S's rule: [Model] open, a blocker pops at once")
        FlexibleSettingsExit.controlEmptyBlocks = false
        // ★ RED CONTROL: today's — the [Press Face 1] pop-up over [Model] [New]
        FlexibleStagePage.controlPopOnNewTab = true
        defer { FlexibleStagePage.controlPopOnNewTab = false }
        m.rail = .newGroup
        XCTAssertTrue(FlexibleStagePage.popsAtOnce(i, model: m), "control: today's pop-up")
    }
}
