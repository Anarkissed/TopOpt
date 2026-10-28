// FlexibleP5EditFacesTests — the redesign plan's P5 (point 1: "Edit faces…" on the Flexible stage), under the reviewer's
// rulings R9 (✂ grey but enabled; capsule ~320 pt keeping the 12 pt gizmo check; the Squish leave-check first; under Edit
// faces only the Edit faces screen's layers are on, Flexible's are off, and Done restores them) and the overnight release
// ruling (2026-10-26 07:42 UTC; the new gated hooks H60 / H61 approved there).
//
//   1  the ● Flexible menu's "Edit faces…" row and the ✂ share ONE closure, and the ✂ is enabled (RED: a disabled ✂)
//   2  under Edit faces no tap reaches flexibleMain.tapFace — every POSITIVE owns() site carries the mode term (RED: the term
//      dropped from H22)
//   3  under Edit faces on Flexible, H26, H28 and FlexibleExportMount stay hidden: owns() stays true and only Flexible's own
//      layers go off (RED: a gate through owns())
//   4  on the Squish page Edit faces runs leave(then:) — Save & Exit's own check — first (RED: called directly)
//   5  Done returns to the Flexible page it came from, main or Squish (RED: it lands on Topology)
// Written before the code (red: the API absent).
import XCTest
@testable import TopOptFlows

@MainActor
final class FlexibleP5EditFacesTests: XCTestCase {

    override func tearDown() {
        FlexibleStageCapsule.controlScissorsDisabled = false
        FlexibleStagePage.controlEditFacesSkipsLeave = false
        FlexibleEditFaces.controlLandsOnTopology = false
        super.tearDown()
    }

    func flexibleProject() -> ProjectModel {
        let p = ProjectModel(id: UUID(), name: "P", material: "ABS", process: .fdm, importedFile: nil, importedMesh: nil)
        p.lattice.flexible = FlexibleStageSettings()
        return p
    }

    // MARK: 1

    func testTheRowAndTheScissorsShareOneClosureAndTheScissorsIsEnabled() throws {
        let items = FlexibleStageCapsule.menuItems(anchors: 0, loads: 0)
        let row = try XCTUnwrap(items.first { $0.action == .editFaces }, "★ the ● Flexible menu has an Edit faces row")
        XCTAssertEqual(row.id, "flexible-menu-edit-faces")
        XCTAssertEqual(row.title, "Edit faces\u{2026}")
        XCTAssertEqual(row.detail, "cuts \u{00B7} unions \u{00B7} patterns")
        XCTAssertTrue(row.enabled)
        // ★ RE-PINNED (P4 adds "Change lattice type…" right after ● Flexible ✓; Edit faces… keeps its divider)
        XCTAssertEqual(items.map(\.id), ["flexible-menu-topology", "flexible-menu-flexible", "flexible-menu-change-type", "flexible-menu-edit-faces", "flexible-menu-about"],
                       "after ● Flexible ✓ (a divider before it), before About")
        XCTAssertTrue(FlexibleStageCapsule.dividerBefore("flexible-menu-edit-faces"), "★ after a divider")
        let chrome = FlexibleChromeState()
        chrome.show(.setup)
        var opened = 0
        FlexibleStageCapsule.perform(.editFaces, chrome: chrome, go: { _ in XCTFail("no stage change") }, about: { XCTFail("not About") },
                                     editFaces: { opened += 1 })
        XCTAssertEqual(opened, 1, "★ the row opens Edit faces")
        XCTAssertNil(chrome.open, "…folding every card first")
        chrome.show(.latticeCard)
        FlexibleStageCapsule.tapScissors(chrome: chrome, editFaces: { opened += 1 })
        XCTAssertEqual(opened, 2, "★ the ✂ runs the same closure")
        XCTAssertNil(chrome.open)
        let src = try FlexibleSource.code("FlexibleStageCapsule.swift")
        // ★ RE-PINNED (P4: the row's call hands `changeType` too)
        XCTAssertTrue(src.contains("Self.perform(item.action, chrome: chrome, go: go, about: about, editFaces: editFaces, changeType: changeType)"), "the row: `editFaces`")
        XCTAssertTrue(src.contains("Self.tapScissors(chrome: chrome, editFaces: action)"), "the ✂: the same `editFaces`")
        XCTAssertTrue(src.contains("if let editFaces { scissors(editFaces) }"))
        XCTAssertTrue(FlexibleStageCapsule.scissorsEnabled, "★ grey in look, but enabled (R9)")
        XCTAssertGreaterThanOrEqual(FlexibleChromeLayout.capsuleMaxWidth, 312, "the capsule with its ✂ (~312 pt) fits its frame")
        // ★ RED CONTROL: a disabled ✂
        FlexibleStageCapsule.controlScissorsDisabled = true
        XCTAssertFalse(FlexibleStageCapsule.scissorsEnabled, "★ RED CONTROL: the disabled ✂ is caught")
    }

    // MARK: 2

    /// Every POSITIVE owns() site in #354's page (Flexible draws or takes something there) carries `!editFaces.isEditing`;
    /// the ternaries that hide #354's own channel (`owns ? nil : …`) are negated sites and keep owns() alone.
    static func positiveSites(_ ws: String) -> [String] {
        ws.components(separatedBy: "\n").filter { l in
            l.contains("flexibleMain.owns(project, stage)") && !l.contains("!flexibleMain.owns(project, stage)")
                && !l.contains("flexibleMain.owns(project, stage) ?") && !l.contains("(flexibleMain.owns(project, stage) ?")
                && !l.contains("func owns")
        }
    }

    func testUnderEditFacesNoTapReachesFlexibleAndItsPositiveSitesAreGated() throws {
        let ws = try FlexibleSource.text("WorkspacePlaceholder.swift")
        let sites = Self.positiveSites(ws)
        XCTAssertGreaterThanOrEqual(sites.count, 9, "premise: H22, H23, H27, H29, H32, H33, H34, H25, H30")
        for l in sites { XCTAssertTrue(l.contains("!editFaces.isEditing"), "★ gated under Edit faces: \(l.prefix(140))") }
        let h22 = try XCTUnwrap(sites.first { $0.contains("flexibleMain.tapFace(project, face: fid, point: pt, mesh: m)") }, "H22")
        XCTAssertTrue(h22.contains("flexibleMain.owns(project, stage), !editFaces.isEditing, force.phase == .edit"),
                      "★ under Edit faces a tap goes to Edit faces, never to the face chip's router")
        // ★ RED CONTROL: H22 without the mode term
        let dropped = ws.replacingOccurrences(of: "flexibleMain.owns(project, stage), !editFaces.isEditing, force.phase == .edit",
                                              with: "flexibleMain.owns(project, stage), force.phase == .edit")
        XCTAssertFalse(Self.positiveSites(dropped).allSatisfy { $0.contains("!editFaces.isEditing") }, "★ RED CONTROL: the dropped term is caught")
    }

    // MARK: 3

    func testUnderEditFacesOwnsStaysAndOnlyFlexiblesLayersGoOff() throws {
        let p = flexibleProject()
        let s = FlexibleMainStage()
        XCTAssertTrue(s.owns(p, .lattice), "premise")
        s.editFacesOpens()
        XCTAssertTrue(s.faceEditing)
        XCTAssertTrue(s.owns(p, .lattice), "★ owns() stays: #354's handles, settings button, Regions panel and Export step stay hidden")
        XCTAssertNil(s.current(p, .lattice), "★ Flexible's own layers are off under Edit faces")
        XCTAssertNil(s.tints(p, on: .lattice, roles: [:], stress: nil), "…its tints among them")
        let ws = try FlexibleSource.text("WorkspacePlaceholder.swift")
        for (name, marker) in [("H26 (the Regions panel)", "!flexibleMain.owns(project, stage) { regionsPanelOverlay }"),
                               ("H28 (the Settings button)", "!flexibleMain.owns(project, stage) { latticeSettingsButtonOverlay }"),
                               ("the Export step", "!flexibleMain.owns(project, stage) { FlexibleExportMount(")] {
            let line = try XCTUnwrap(ws.components(separatedBy: "\n").first { $0.contains(marker) }, name)
            XCTAssertFalse(line.contains("isEditing"), "★ \(name) stays gated through owns() alone")
        }
        _ = s.editFacesReturns(FlexibleEditFaces.origin(.lattice))
        XCTAssertFalse(s.faceEditing, "Done restores them")
        // owns() reads no mode (its body is FlexibleRound7ScreenHookTests' pin, unchanged)
        let code = try FlexibleSource.code("FlexibleMainStage.swift")
        let body = "public func owns(_ project: ProjectModel, _ stage: WorkspaceStage) -> Bool {\n        stage == .lattice && project.lattice.flexible != nil\n    }"
        func gatedThroughOwns(_ c: String) -> Bool { !c.contains(body) }
        XCTAssertFalse(gatedThroughOwns(code), "★ owns() is not gated by Edit faces")
        // ★ RED CONTROL: a gate through owns() — Edit faces turning owns() off (#354's own chrome would show on Flexible) is caught
        XCTAssertTrue(gatedThroughOwns(code.replacingOccurrences(of: "        stage == .lattice && project.lattice.flexible != nil\n    }",
                                                                  with: "        !faceEditing && stage == .lattice && project.lattice.flexible != nil\n    }")),
                      "★ RED CONTROL: owns() gated by the mode is caught")
    }

    // MARK: 4

    func testOnTheSquishPageEditFacesRunsTheLeaveCheckFirst() throws {
        var log: [String] = []
        let open = { log.append("edit faces") }
        let hop = try XCTUnwrap(FlexibleStagePage.editFacesHop(onEditFaces: open, leave: { follow in
            log.append("leave")
            follow?()   // a clean page: the check lets it go, then the follow-up runs
        }))
        hop()
        XCTAssertEqual(log, ["leave", "edit faces"], "★ Save & Exit's own check first, then Edit faces")
        log = []
        let blocked = try XCTUnwrap(FlexibleStagePage.editFacesHop(onEditFaces: open, leave: { _ in log.append("leave: blocked, the fix opens") }))
        blocked()
        XCTAssertEqual(log, ["leave: blocked, the fix opens"], "★ a blocked page never opens Edit faces")
        XCTAssertNil(FlexibleStagePage.editFacesHop(onEditFaces: nil, leave: { _ in }), "no closure: no ✂")
        let src = try FlexibleSource.code("FlexibleStagePage.swift")
        XCTAssertTrue(src.contains("editFaces: Self.editFacesHop(onEditFaces: onEditFaces, leave: { leave(then: $0) })"), "the page's capsule takes the hop")
        // ★ RED CONTROL: called directly
        FlexibleStagePage.controlEditFacesSkipsLeave = true
        log = []
        try XCTUnwrap(FlexibleStagePage.editFacesHop(onEditFaces: open, leave: { _ in log.append("leave: blocked, the fix opens") }))()
        XCTAssertNotEqual(log, ["leave: blocked, the fix opens"], "★ RED CONTROL: Edit faces opened past the check")
    }

    // MARK: 5

    func testDoneReturnsToTheFlexiblePageItCameFrom() {
        let s = FlexibleMainStage()
        for page in [FlexibleStageCapsule.Page.lattice, .squish] {
            var session = EditFacesSession()
            s.editFacesOpens()
            XCTAssertTrue(session.enter(from: FlexibleEditFaces.origin(page)))
            XCTAssertNil(FlexibleEditFaces.origin(page).stage, "★ a host page: the stage under the mode stays the Flexible stage (never Topology)")
            let back = session.done()
            XCTAssertEqual(back.flatMap(FlexibleEditFaces.page), page, "★ Done goes back to the \(page) page")
            XCTAssertEqual(s.editFacesReturns(back!), page == .squish, "the Squish page re-opens; the main page is under the mode already")
        }
        // ★ RED CONTROL: it lands on Topology
        FlexibleEditFaces.controlLandsOnTopology = true
        XCTAssertEqual(FlexibleEditFaces.origin(.squish).stage, .topology, "★ RED CONTROL: the Topology landing is caught")
        XCTAssertNil(FlexibleEditFaces.page(FlexibleEditFaces.origin(.squish)))
    }
}
