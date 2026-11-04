// FlexibleU21OneLatticeRuleTests — round 7 · U21, batch E "One lattice rule" (NOLAT + LBR-COVER; his notes of 2026-10-21).
//   His words: Img12/11 "I tapped a face that didn't have a lattice and I received this notification. However, I then tapped a
//   different face and received the notification in img 11. This isn't consistent. I think if we are going to say 'you need to
//   lattice this first' then it should do so for every face"; Img14 "I tapped a side wall and it shows that there IS lattice
//   behind it? That's definitely a bug."
//   ONE rule — the app's face-prism geometry (FlexibleSectorSet.latticed) — decides "latticed", never core's column count
//   (faces.cpp:312-325 counts another face-prism's lattice on the column: his Face 5 11.8 %, Face 1 36.5 %, Face 7 93.8 %).
// On HIS live l-bracket of 2026-10-21 (round7/batch_u21/his_live_1021_lbracket, as saved: Face 6's face-prism through the wall,
// Group 1 = "Face 6 · lattice" 2000008) and his pad A1_0003 as saved (no face-prism). Each RED control asserted red inside.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleU21OneLatticeRuleTests: XCTestCase {
    static var lbracketDir: URL { FlexibleU21DeleteUndoTests.fixtures.appendingPathComponent("his_live_1021_lbracket", isDirectory: true) }

    /// Points ON his l-bracket's faces (the probe's LBR-A list), and one on Face 2's 3 mm solid rim (not a centroid).
    static let face5 = SIMD3<Double>(10.1, -34.1, 0)        // the plate's underside
    static let face1 = SIMD3<Double>(25.0, -50.0, 8.3)      // the ONE L-shaped side face over both slabs
    static let face7 = SIMD3<Double>(91.7, 16.7, 150.0)     // the wall's top
    static let face6 = SIMD3<Double>(75.0, -16.7, 66.7)     // the wall's inner face: its face-prism's lattice section
    static let face2Rim = SIMD3<Double>(100.0, 48.8, 80.0)  // the wall's outer face, inside its 3 mm rim (the −3 mm inset)

    override func tearDown() {
        FlexibleRegions.controlPressAnyRoot = false
        FlexibleStageModel.controlCoreShare = false
        super.tearDown()
    }

    func openLBracket() async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(Self.lbracketDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his l-bracket")
        return (r, m)
    }

    struct Tap { let selected: Int?; let faces: [Int]; let notice: FlexibleIssue?; let toast: String? }

    func tap(_ m: FlexibleStageModel, _ face: Int, _ p: SIMD3<Double>) -> Tap {
        m.toast = nil
        m.tapFace(face, point: p)
        return Tap(selected: m.selectedRegion, faces: m.settings.faces.map(\.faceRegionID), notice: m.noLatticeTap, toast: m.toast)
    }

    // MARK: NOLAT — every tap on a face with no lattice of its own does the same thing

    func testEveryNoLatticeTapSaysTheSame() async throws {
        let (_, m) = try await openLBracket()
        let mesh = try XCTUnwrap(m.project.viewerMesh)
        XCTAssertEqual(m.selectedRegion, 2000008, "premise: Face 6 · lattice selected (his Img12)")
        XCTAssertNil(m.regions.flexibleAt(Self.face2Rim, face: 2, mesh: mesh), "premise: the rim point is outside Face 2's lattice section")
        XCTAssertNotNil(m.regions.flexible?.partialRoots[2], "premise: Face 2 is partly inside Face 6's face-prism")
        let before = m.settings.faces.map(\.faceRegionID)

        // RED CONTROL (today: two rules): Face 5 is selected (its card then reads core's "Only 12 %"); the rim gives the toast
        FlexibleRegions.controlPressAnyRoot = true
        let red5 = tap(m, 5, Self.face5)
        let redRim = tap(m, 2, Self.face2Rim)
        FlexibleRegions.controlPressAnyRoot = false
        print("FLEX-U21-E1 RED (today) Face 5 → selected \(red5.selected.map(String.init) ?? "nil") notice \(red5.notice?.oneLine ?? "-") · rim → toast '\(redRim.toast ?? "-")'")
        XCTAssertEqual(red5.selected, 5, "RED CONTROL: today a tap on Face 5 selects it")
        XCTAssertNil(red5.notice, "RED CONTROL: and says nothing")
        XCTAssertEqual(redRim.toast, FlexibleRowCopy.solidHere, "RED CONTROL: the rim's other sentence (the 3.5 s toast)")
        m.select(2000008)

        for (face, point, rests) in [(5, Self.face5, true), (1, Self.face1, true), (7, Self.face7, true), (2, Self.face2Rim, false)] {
            let t = tap(m, face, point)
            print("FLEX-U21-E1 tap Face \(face) → selected \(t.selected.map(String.init) ?? "nil") · notice '\(t.notice?.oneLine ?? "-")' fixes \(t.notice?.fixes.map { $0.title { m.displayName($0) } } ?? [])")
            XCTAssertEqual(t.selected, 2000008, "★ Face \(face): nothing new is selected")
            XCTAssertEqual(t.faces, before, "★ Face \(face): nothing is pressed")
            let n = try XCTUnwrap(t.notice, "★ Face \(face): the notice")
            XCTAssertEqual(n.oneLine, "No lattice under Face \(face) \u{00B7} set a face-prism", "★ the same sentence for every face")
            XCTAssertFalse(n.blocking)
            XCTAssertEqual(n.fixes, [.goToLattice] + (rests ? [.rest(face)] : []),
                           "★ [Go to Lattice]\(rests ? " [Face \(face) rests]" : " only (the solid part of a partial face cannot rest)")")
            XCTAssertEqual(FlexibleStagePage.popUpIssue(shown: nil, model: m), n, "★ shown in the fix pop-up's place")
            XCTAssertNil(t.toast, "★ never the 3.5 s toast")
        }
        // the next tap (a lattice one) drops it; [Go to Lattice] asks the page to leave (saved, never the bake)
        _ = tap(m, 5, Self.face5)
        let asks = m.leaveForLatticeAsks
        FlexibleFixPopup.apply(.goToLattice, to: m)
        XCTAssertEqual(m.leaveForLatticeAsks, asks + 1, "★ [Go to Lattice] asks the page to leave for the Lattice page")
        XCTAssertNil(m.noLatticeTap)
    }

    func testTheLatticePartStillPresses() async throws {
        let (_, m) = try await openLBracket()
        m.select(2000008)
        _ = tap(m, 5, Self.face5)
        XCTAssertNotNil(m.noLatticeTap, "premise: a notice is up")
        let t = tap(m, 6, Self.face6)
        XCTAssertEqual(t.selected, 2000008, "★ Face 6 · lattice selects as today")
        XCTAssertNil(t.notice, "★ no notice on the lattice part (and the next tap dropped the last one)")
        XCTAssertTrue(m.hasOwnLattice(2000008))
        XCTAssertEqual(m.readiness.issues.filter { $0.kind == .noLatticeUnder }.count, 0, "no no-lattice issue for Face 6 · lattice")
    }

    // MARK: the no-face-prism stage says the same

    func testNoFacePrismStageSaysTheSame() async throws {
        let (_, s, m) = try await FlexibleR7M1Fixtures.hisPad(self, live: false)
        _ = s
        let mesh = try XCTUnwrap(m.project.viewerMesh)
        XCTAssertFalse(m.facePrismsSet, "premise: his pad as saved sets no face-prism")
        // a point ON face 1 (the centroid of one of its triangles)
        let t = try XCTUnwrap((0..<mesh.triangleCount).first { mesh.faceIDs[$0] == 1 })
        let p = (0..<3).map { FlexibleMeet.position(mesh, mesh.indices[3 * t + $0]) }.reduce(.zero, +) / 3
        let root = m.regions.ownRegion(at: p, face: 1, mesh: mesh)
        m.selectedRegion = nil

        FlexibleRegions.controlPressAnyRoot = true
        let red = tap(m, 1, p)
        FlexibleRegions.controlPressAnyRoot = false
        print("FLEX-U21-E3 RED (today) no face-prism, tap face 1 → selected \(red.selected.map(String.init) ?? "nil") notice \(red.notice?.oneLine ?? "-")")
        XCTAssertEqual(red.selected, root, "RED CONTROL: today the tap selects the face (its card reads 'no lattice under it')")
        XCTAssertNil(red.notice)

        m.selectedRegion = nil
        let a = tap(m, 1, p)
        print("FLEX-U21-E3 no face-prism, tap face 1 (root \(root)) → selected \(a.selected.map(String.init) ?? "nil") · '\(a.notice?.oneLine ?? "-")'")
        XCTAssertNil(a.selected, "★ nothing selected")
        let n = try XCTUnwrap(a.notice, "★ the same notice")
        XCTAssertEqual(n.oneLine, FlexibleRowCopy.noLatticeUnder(m.displayName(root)))
        XCTAssertEqual(n.fixes.first, .goToLattice)
        // a pressed face on that stage: the same sentence, [Go to Lattice] for the old [Lattice under it]
        let issue = try XCTUnwrap(FlexibleLatticeUnder.first(m.readiness), "a pressed face of his says it")
        let r = try XCTUnwrap(issue.region)
        XCTAssertEqual(issue.oneLine, FlexibleRowCopy.noLatticeUnder(m.displayName(r)), "★ the same sentence on a pressed face")
        XCTAssertEqual(issue.fixes, [.goToLattice, .rest(r)], "★ [Go to Lattice] [\(m.displayName(r)) rests]")
    }

    // MARK: LBR-COVER — a face already pressed with no face-prism of its own

    func pressAndSettle(_ m: FlexibleStageModel, _ r: Int) async throws {
        XCTAssertTrue(m.press(r, kg: 4.5))
        try await FlexibleHisProject.waitFor(120, "Face \(r)'s stack") { m.stack(r) != nil && m.geometry[FlexFaceKey(region: r, rotation: 0)] != nil }
        try await FlexibleSquishFixture.settle(m, "Face \(r) pressed")
    }

    func testAPressedFaceWithNoFacePrismSaysTheSameSentence() async throws {
        let (_, m) = try await openLBracket()
        try await pressAndSettle(m, 5)
        // RED CONTROL (today): core's count speaks — "Only 12 %", the Deepest box capped at 118.8 mm, the chip and prism drawn
        FlexibleStageModel.controlCoreShare = true
        let redIssue = m.readiness.issues.first { $0.kind == .noLatticeUnder && $0.region == 5 }
        let redMax = m.latticeMaxMM(5)
        let redPrisms = FlexibleDepthPrism.renderItems(model: m, k: 1, views: [.prisms]).count
        FlexibleStageModel.controlCoreShare = false
        print("FLEX-U21-E4 RED (today) Face 5 pressed: '\(redIssue?.oneLine ?? "-")' fixes \(redIssue?.fixes ?? []) · deepest cap \(redMax ?? -1) mm · prisms \(redPrisms)")
        XCTAssertEqual(redIssue?.oneLine, "Only 12 % of Face 5 has lattice under it", "RED CONTROL: core's count (his Img11)")
        XCTAssertEqual(redMax ?? 0, 118.8, accuracy: 0.1, "RED CONTROL: core's 118.8 mm on the card and chip")

        let issue = try XCTUnwrap(m.readiness.issues.first { $0.kind == .noLatticeUnder && $0.region == 5 })
        let share = m.latticedShare(5)
        let prisms = FlexibleDepthPrism.renderItems(model: m, k: 1, views: [.prisms]).count
        print("FLEX-U21-E4 Face 5 pressed: '\(issue.oneLine)' pill '\(issue.pill)' fixes \(issue.fixes) · share \(share ?? -1) · deepest \(m.latticeMaxMM(5) ?? -1) · prisms \(prisms) (today \(redPrisms))")
        XCTAssertEqual(issue.oneLine, "No lattice under Face 5 \u{00B7} set a face-prism", "★ the tap's sentence")
        XCTAssertEqual(issue.pill, "No lattice under Face 5")
        XCTAssertEqual(issue.fixes, [.goToLattice, .rest(5)], "★ [Go to Lattice] [Face 5 rests]; no [Lattice under it]")
        XCTAssertFalse(issue.blocking, "never blocking")
        XCTAssertEqual(share, 0, "★ share 0, not core's 11.8 %")
        XCTAssertEqual(m.latticeMaxMM(5), 0, "★ the card's and the chip's lattice depth: 0")
        XCTAssertTrue(FlexibleLatticeUnder.nothingToSquish(latticeMaxMM: m.latticeMaxMM(5)),
                      "★ the card shows 'No lattice under it' instead of a Deepest box, and the 3D chip is not drawn")
        XCTAssertNil(m.latticeUnderPlan(5), "★ no one-tap [Lattice under it] on it")
        XCTAssertEqual(prisms, redPrisms - 1, "★ no face-prism bowl drawn under Face 5 (Face 6's stays)")
        XCTAssertTrue(m.readiness.isReady, "never a blocker: Exit still leaves")
    }

    func testRestStillPossible() async throws {
        let (_, m) = try await openLBracket()
        _ = tap(m, 5, Self.face5)
        let n = try XCTUnwrap(m.noLatticeTap)
        XCTAssertTrue(n.fixes.contains(.rest(5)))
        FlexibleFixPopup.apply(.rest(5), to: m)
        XCTAssertEqual(m.settings.face(5)?.role, "resting", "★ [Face 5 rests]: it rests (rests need no lattice)")
        XCTAssertFalse(m.settings.face(5)?.isLoaded ?? true)
        _ = tap(m, 5, Self.face5)
        XCTAssertEqual(m.noLatticeTap?.fixes, [.goToLattice], "★ a resting face is not offered [rests] again")
    }

    func testNotYetKeepsCoresShare() {
        var set = FlexibleSectorSet()
        set.wholeRoots = [3]
        set.notYet = [7: FlexibleRowCopy.curvedNotYet]
        set.partialRoots = [2: ["s:f2:x#0"]]
        XCTAssertTrue(set.latticed(3), "a root wholly inside a face-prism")
        XCTAssertTrue(set.latticed(7), "★ a curved face-prism's root keeps core's share (notYet)")
        XCTAssertFalse(set.latticed(2), "the solid part of a partial root (its sections are latticed)")
        XCTAssertFalse(set.latticed(5), "a root no face-prism meets")
        XCTAssertFalse(FlexibleSectorSet.empty.latticed(1), "no face-prism: nothing latticed")
    }

    func testFace1DrawsNoSquares() async throws {
        let (_, m) = try await openLBracket()
        try await pressAndSettle(m, 1)
        FlexibleStageModel.controlCoreShare = true
        let red = FlexibleSettingsSquish.columnDepths(model: m, regions: [1])
        FlexibleStageModel.controlCoreShare = false
        let redCols = red.values.first?.compactMap { $0 }.count ?? 0
        let now = FlexibleSettingsSquish.columnDepths(model: m, regions: [1])
        print("FLEX-U21-E7 Face 1 pressed: column squares today \(redCols) (keys \(red.count)) · now keys \(now.count)")
        XCTAssertGreaterThan(redCols, 0, "RED CONTROL: today Face 1's 28.5°-off squares are drawn (the sawtooth of his Img14)")
        XCTAssertTrue(now.isEmpty, "★ no column dent (no squares) for a face with no lattice of its own")
        XCTAssertEqual(m.latticeMaxMM(1), 0)
        XCTAssertFalse(m.hasOwnLattice(1))
    }

    func testCopyFits() {
        for name in ["Face 5", "Face 12", "Top B", "Face 12 · lattice A", "a very long sector name of his"] {
            let s = FlexibleRowCopy.noLatticeUnder(name)
            XCTAssertLessThanOrEqual(s.count, FlexibleRowCopy.maxChars, s)
            XCTAssertTrue(s.hasSuffix("\u{00B7} set a face-prism"), "the what-to-do is never cut: \(s)")
        }
        XCTAssertEqual(FlexibleRowCopy.noLatticeUnder("Face 5"), "No lattice under Face 5 \u{00B7} set a face-prism")
        XCTAssertEqual(FlexibleFix.goToLattice.title { "Face \($0)" }, "Go to Lattice")
    }
}
