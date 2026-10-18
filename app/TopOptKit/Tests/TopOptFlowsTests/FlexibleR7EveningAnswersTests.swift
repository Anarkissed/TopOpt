// FlexibleR7EveningAnswersTests — round 7, batch R7-D2: his four answers of 2026-10-17 evening (r7/tasks.md, binding) and the
// reviewer's ruling 5 on M2's D4, written BEFORE the code (red run: round7/batch_d2/d2_red_run.txt):
//   1. "After Reset all + Exit with face-prisms set and nothing squished: the main page shows the PLAIN PART + one line
//      'Nothing to squish yet'."
//   2. "X-ray on the main page shows EVERY face-prism faint, the picked group's bright (even before a pick)."
//   3. "Squish page with [Prisms] on and X-ray off: the part stays SOLID until X-ray (no 30 % see-through)."
//   4. "The face-prism glass over open lattice: FAINTER GLASS (not outline-only)."
//   D4 (ruling 5): "D4 (curved prisms don't cut yet) must SAY so on screen when it applies."
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleR7EveningAnswersTests: XCTestCase {

    override func tearDown() {
        FlexibleMainStage.controlLatticeOverEmptySetup = false
        FlexibleMainStage.controlXrayPickedOnly = false
        FlexibleMainStage.controlPrismGlassOverLattice = false
        FlexibleStagePage.controlPrismsSeeThrough = false
        super.tearDown()
    }

    // MARK: 1 — face-prisms set, nothing squished: the plain part and one line

    func testAfterResetAllTheMainPageShowsThePlainPartAndOneLine() async throws {
        let (r, s, m) = try await FlexibleR7M1Fixtures.hisPad(self, live: true)
        let p = r.project
        s.apply(p, owned: true, pageUp: false)
        m.resetAll()
        try await FlexibleSquishFixture.settle(m, "after Reset all")
        s.refresh()
        XCTAssertTrue(m.facePrismsSet, "premise: his face-prisms are still set")
        XCTAssertTrue(m.isEmptySetup, "premise: nothing squished")
        XCTAssertFalse(s.latticeShown, "★ no lattice drawn: the plain part")
        XCTAssertEqual(s.bodyAlpha(p, on: .lattice), 1, "★ the solid, opaque part")
        XCTAssertEqual(s.status.line, FlexibleSettingsExit.emptyLine, "★ one line: 'Nothing to squish yet'")
        XCTAssertEqual(FlexibleSettingsExit.emptyLine, "Nothing to squish yet")
        // ★ RED CONTROL: the lattice over an empty setup (the face-prisms' lattice drawn although nothing squishes)
        FlexibleMainStage.controlLatticeOverEmptySetup = true
        s.refresh()
        XCTAssertTrue(FlexibleLatticeView.available(model: m), "★ RED CONTROL: a lattice to show over nothing to squish")
    }

    // MARK: 2 — X-ray shows every face-prism faint, the picked group's bright

    func testXrayShowsEveryFacePrismFaintAndThePickedGroupBright() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        let c = try FlexibleR7M1Fixtures.hisLiveLattice(p)
        let s = FlexibleMainStage()
        _ = s.model(for: p, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        XCTAssertEqual(s.volumes(p, on: .lattice, drilledIn: false), [], "premise: X-ray off, nothing picked — nothing")
        s.xrayOn = true
        let all = s.volumes(p, on: .lattice, drilledIn: false)
        XCTAssertEqual(Set(all.map(\.volume.faceID)), [3, 5], "★ X-ray: every face-prism, even before a pick")
        XCTAssertTrue(all.allSatisfy { !$0.selected && ($0.faceAlpha ?? 1) <= FlexibleMainStage.faintFaceAlpha + 1e-6 }, "★ faint")
        s.pickGroup(c, project: p)
        let picked = s.volumes(p, on: .lattice, drilledIn: false)
        XCTAssertTrue(picked.allSatisfy(\.selected), "★ the picked group's bright")
        // ★ RED CONTROL: X1's rule — X-ray shows a group's face-prisms only after a pick
        s.missTap()
        FlexibleMainStage.controlXrayPickedOnly = true
        XCTAssertEqual(s.volumes(p, on: .lattice, drilledIn: false), [], "★ RED CONTROL: nothing before a pick in X-ray")
    }

    // MARK: 3 — the Squish page: [Prisms] with X-ray off keeps the part solid

    func testSquishPrismsWithXrayOffKeepThePartSolid() {
        XCTAssertEqual(FlexibleStagePage.bodyAlpha(views: [.prisms], edgePick: false, hasDent: true), 1, "★ solid until X-ray")
        XCTAssertEqual(FlexibleStagePage.bodyAlpha(views: [.prisms, .xray], edgePick: false, hasDent: true), FlexibleStagePage.xrayBodyAlpha,
                       "X-ray: see through")
        // ★ RED CONTROL: X1's 30 % see-through with [Prisms]
        FlexibleStagePage.controlPrismsSeeThrough = true
        XCTAssertEqual(FlexibleStagePage.bodyAlpha(views: [.prisms], edgePick: false, hasDent: true), FlexibleStagePage.dentBodyAlpha)
    }

    // MARK: 4 — fainter glass over the open lattice (never outline-only)

    func testTheFacePrismGlassOverTheOpenLatticeIsFainterNotOutlineOnly() {
        let over = FlexibleMainStage.prismAlphas(bright: true, faint: false, overLattice: true)
        let free = FlexibleMainStage.prismAlphas(bright: true, faint: false, overLattice: false)
        XCTAssertNil(free.face, "off the lattice: #354's own glass (as M1 drew it)")
        let face = try? XCTUnwrap(over.face)
        XCTAssertNotNil(face)
        XCTAssertLessThan(face ?? 1, 0.60 / 3, "★ fainter than #354's 0.60 glass")
        XCTAssertGreaterThan(face ?? 0, 0, "★ glass, not outline-only")
        XCTAssertGreaterThanOrEqual(over.edge ?? 0, 0.6, "its edges still read")
        // ★ RED CONTROL: M1's glass over the lattice (the streaks he saw)
        FlexibleMainStage.controlPrismGlassOverLattice = true
        XCTAssertNil(FlexibleMainStage.prismAlphas(bright: true, faint: false, overLattice: true).face, "★ RED CONTROL: #354's 0.60")
    }

    // MARK: D4 — said on screen

    func testACurvedOrHandPlacedPrismThatCannotCutSaysSoOnTheFacesCard() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        let c = try FlexibleR7M1Fixtures.hisLiveLattice(p)
        let m = FlexibleMainStage().model(for: p, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        XCTAssertNil(FlexibleFaceRows.curvedLine(model: m, region: 1), "premise: his planar face-prisms cut the Top into sections")
        // a hand-placed face-prism over part of the Top (a slab is not one of the planar, convex face-prisms D4 can cut)
        _ = p.force.addManualPrimitive(ManualPrimitive(kind: .face, center: SIMD3(80, 50, 20), axis: SIMD3(0, 0, -1),
                                                       halfUMM: 10, halfWMM: 10), to: c)
        XCTAssertEqual(FlexibleFaceRows.curvedLine(model: m, region: 1), FlexibleRowCopy.curvedNotYet,
                       "★ the Top's card says 'Curved lattice here · not yet'")
        let src = try String(contentsOf: FlexibleRound7SelectionsHookTests.sources.appendingPathComponent("FlexibleFacePanel.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("if let line = Self.curvedLine(model: model, region: r) {"), "★ drawn on the card, always (never only a toast)")
        XCTAssertTrue(src.contains("accessibilityIdentifier(\"flexible-row-curved-not-yet\")"))
        // ★ RED CONTROL: M2's D4 — said only as a toast on a tap
        let model = try String(contentsOf: FlexibleRound7SelectionsHookTests.sources.appendingPathComponent("FlexibleStageModel.swift"), encoding: .utf8)
        XCTAssertTrue(model.contains("if let line = regs.flexible?.notYet[r] { toast = line }"), "★ RED CONTROL: the tap's toast (kept)")
    }
}
