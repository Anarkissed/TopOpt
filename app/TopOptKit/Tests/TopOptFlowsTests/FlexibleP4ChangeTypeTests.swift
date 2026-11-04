// FlexibleP4ChangeTypeTests — the redesign plan's P4 (point 2: one lattice type per project) on the Flexible stage, under the
// reviewer's rulings (R8, R9: row details ≤ 22 characters, the Squish leave-check first; R12: the duplicate drops Topology's
// results) and the overnight release ruling of 2026-10-26 07:42 UTC (hook H62 approved there).
//
//   1  "Change lattice type…" is the ● Flexible menu's row right after ● Flexible ✓, its detail ≤ 22 characters, and it opens
//      #354's ChangeLatticeTypeCard (folding the cards first)
//   2  the card shows for a Flexible project, which #354's own mount never does (RED: #354's condition, `stageMode`)
//   3  Duplicate → the duplicate (once); Continue → today's delete (once); Cancel → nothing; the card closes each time
//   4  on the Squish page the row runs leave(then:) — Save & Exit's check, which saves the draft — first (RED: called directly)
//   5  choosing Structural on a copy makes owns() false (H54: Flexible's claim cleared with the type)
// The plan's P4 tests 1 and 3 (the duplicate's carry; the copy opens its selector once) are B4's API, tested on #354's side.
import XCTest
@testable import TopOptFlows

@MainActor
final class FlexibleP4ChangeTypeTests: XCTestCase {

    override func tearDown() {
        FlexibleStagePage.controlChangeTypeSkipsLeave = false
        super.tearDown()
    }

    func flexibleProject() -> ProjectModel {
        let p = ProjectModel(id: UUID(), name: "P", material: "ABS", process: .fdm, importedFile: nil, importedMesh: nil)
        p.lattice.flexible = FlexibleStageSettings()
        return p
    }

    func testTheRowIsAfterFlexibleAndAsksWithTheCard() throws {
        let items = FlexibleStageCapsule.menuItems(anchors: 0, loads: 0)
        XCTAssertEqual(items.map(\.id), ["flexible-menu-topology", "flexible-menu-flexible", "flexible-menu-change-type",
                                         "flexible-menu-edit-faces", "flexible-menu-about"], "★ right after ● Flexible ✓")
        let row = try XCTUnwrap(items.first { $0.action == .changeType })
        XCTAssertEqual(row.title, "Change lattice type\u{2026}")
        XCTAssertLessThanOrEqual(row.detail?.count ?? 0, 22, "★ R9: ≤ 22 characters (\(row.detail ?? ""))")
        XCTAssertTrue(row.enabled)
        let s = FlexibleMainStage()
        s.chrome.show(.latticeCard)
        FlexibleStageCapsule.perform(.changeType, chrome: s.chrome, go: { _ in XCTFail() }, about: { XCTFail() },
                                     changeType: { s.askChangeType() })
        XCTAssertTrue(s.changeTypeAsking, "★ the card asks")
        XCTAssertNil(s.chrome.open, "every card folded first")
    }

    func testTheCardShowsOnAFlexibleProjectWhereNumber354sMountNeverDoes() {
        let p = flexibleProject()
        XCTAssertTrue(FlexibleChangeType.shows(asking: true, project: p), "★ asked on a Flexible project: the card shows")
        XCTAssertFalse(FlexibleChangeType.shows(asking: false, project: p))
        let structural = ProjectModel(id: UUID(), name: "S", material: "ABS", process: .fdm, importedFile: nil, importedMesh: nil)
        structural.lattice.stageMode = .structural
        XCTAssertFalse(FlexibleChangeType.shows(asking: true, project: structural), "a Structural project: #354's own card")
        // ★ RED CONTROL: #354's mount — `if showChangeLatticeType, let mode = project.lattice.stageMode` — on his Flexible project
        XCTAssertNil(p.lattice.stageMode, "★ RED CONTROL: #354's mount needs a type, which a Flexible project never has")
    }

    func testEachChoiceDoesOneThingAndClosesTheCard() {
        let s = FlexibleMainStage()
        var dup = 0, lose = 0
        for (c, d, l) in [(ChangeLatticeTypeChoice.duplicate, 1, 0), (.loseAll, 1, 1), (.cancel, 1, 1)] {
            s.askChangeType()
            FlexibleChangeType.choose(c, main: s, duplicate: { dup += 1 }, loseAll: { lose += 1 })
            XCTAssertFalse(s.changeTypeAsking, "\(c): the card closes")
            XCTAssertEqual(dup, d, "\(c): the duplicate"); XCTAssertEqual(lose, l, "\(c): Continue (today's delete)")
        }
        XCTAssertEqual(FlexibleChangeType.detail.count <= 22, true)
    }

    func testOnTheSquishPageTheRowRunsTheLeaveCheckFirst() throws {
        var log: [String] = []
        let ask = { log.append("ask") }
        try XCTUnwrap(FlexibleStagePage.changeTypeHop(onChangeType: ask, leave: { f in log.append("leave (saves the draft)"); f?() }))()
        XCTAssertEqual(log, ["leave (saves the draft)", "ask"], "★ Save & Exit's check first: a duplicate then carries the draft")
        log = []
        try XCTUnwrap(FlexibleStagePage.changeTypeHop(onChangeType: ask, leave: { _ in log.append("blocked: the fix opens") }))()
        XCTAssertEqual(log, ["blocked: the fix opens"], "★ blocked: no card")
        let src = try FlexibleSource.code("FlexibleStagePage.swift")
        XCTAssertTrue(src.contains("changeType: Self.changeTypeHop(onChangeType: onChangeType, leave: { leave(then: $0) })"))
        // ★ RED CONTROL: called directly
        FlexibleStagePage.controlChangeTypeSkipsLeave = true
        log = []
        try XCTUnwrap(FlexibleStagePage.changeTypeHop(onChangeType: ask, leave: { _ in log.append("blocked: the fix opens") }))()
        XCTAssertNotEqual(log, ["blocked: the fix opens"], "★ RED CONTROL: the card asked past the check")
    }

    /// H62: the card is mounted right after #354's own (inside the same heap-boxed H58 chunk, so the page's body does not
    /// grow — WorkspaceBodySizeTests), and both pages hand the row its closure. RED CONTROL: the mount line taken out.
    func testTheCardIsMountedBesideNumber354sInsideItsChunk() throws {
        let ws = try FlexibleSource.text("WorkspacePlaceholder.swift")
        let mount = "if project.lattice.flexible != nil { FlexibleChangeTypeMount(main: flexibleMain, project: project, app: model, loseAll: { showFlexiblePage = false; deleteLatticeForMode() }).zIndex(49) }   // Flexible (PR #362) H62:"
        func mounted(_ text: String) -> Bool {
            guard let own = text.range(of: "ChangeLatticeTypeCard(type: mode.title, regions: latticeRegionTabNames.count) { chooseLatticeTypeChange($0) }") else { return false }
            return String(text[own.upperBound...].prefix(700)).contains(mount)
        }
        XCTAssertTrue(mounted(ws), "★ H62: Flexible's card mount sits right after #354's")
        XCTAssertEqual(ws.components(separatedBy: "Flexible (PR #362) H62:").count - 1, 3, "H62: the mount, the main page's row, the Squish page's row")
        XCTAssertTrue(ws.contains("changeType: { flexibleMain.askChangeType() }"), "the main page's capsule")
        XCTAssertTrue(ws.contains("onChangeType: { flexibleMain.askChangeType() }"), "the Squish page")
        XCTAssertFalse(mounted(ws.replacingOccurrences(of: mount, with: "")), "★ RED CONTROL: no mount is caught")
    }

    func testChoosingStructuralOnTheCopyEndsFlexiblesClaim() {
        let p = flexibleProject()
        let s = FlexibleMainStage()
        XCTAssertTrue(s.owns(p, .lattice))
        p.lattice.chooseLatticeType(.structural)
        XCTAssertNil(p.lattice.flexible, "H54: the type's pick clears Flexible")
        XCTAssertFalse(s.owns(p, .lattice), "★ Structural: Flexible no longer owns the lattice stage")
    }
}
