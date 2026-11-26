// Notes30FollowUpsHostedTests — release 21's two follow-ups (builder F1, notes30), on the pages themselves. Hosted: a test
// process builds no SwiftUI accessibility tree, so the frames come from the pages' keep-out keys and the words from FlexibleSaid.
// The source parts: Notes30FollowUpsTests.
//   (1) His rule (notes29, builder N1): ONE (i) app-wide, opening the centred card — its title, its words, a big bold "Tap
//       anywhere to continue", and any tap closes it. The Flexible page's per-face (i) (the Selections list's line and the face
//       chip) still opened a card of its own beside it; each now opens the centred card, with the face's name and his numbers.
//   (2) Save copied Group 1's grade onto the part (B7's "the first area leads"), over the default Stress + shape (N1, notes29).
//       Save now keeps the Part tab's grade and each group its own: on a new part, a saved and reopened part, and a version.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class F1HostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class Notes30FollowUpsHostedTests: XCTestCase {

    override nonisolated func setUp() { super.setUp(); FlexibleSaid.recording = true }
    override nonisolated func tearDown() { FlexibleSaid.recording = false; super.tearDown() }

    // MARK: a page with the root's centred-card layer over it (RootView mounts AppPopupLayer the same way)

    final class Seen { var keepOut: [String: CGRect] = [:]; var chrome: [String: CGRect] = [:]; var said: [String] = [] }
    struct Host { let window: NSWindow; let size: CGSize; let seen: Seen }

    func pump(_ s: Double) {
        let end = Date().addingTimeInterval(s)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    func host<V: View>(_ v: V, size: CGSize) -> Host {
        let seen = Seen()
        let root = AnyView(ZStack { v; AppPopupLayer() }
            .onPreferenceChange(FlexibleKeepOutKey.self) { seen.keepOut = $0 }
            .onPreferenceChange(ChromeKeepOutKey.self) { seen.chrome = $0 }
            .onPreferenceChange(FlexibleSaidKey.self) { seen.said = $0 }
            .environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.sizingOptions = []
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = F1HostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = hv
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderFrontRegardless()
        w.makeKey()
        hv.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in w.orderOut(nil); w.contentView = nil }
        return Host(window: w, size: size, seen: seen)
    }

    func click(_ h: Host, _ p: CGPoint) {
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: NSPoint(x: p.x, y: h.size.height - p.y), modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            h.window.sendEvent(e)
            pump(0.06)
        }
        pump(0.8)
    }

    // MARK: (1) the face's (i) on the Flexible page

    /// His pad on the Flexible stage (A1_0003 + his live lattice: Group C = Face 3 + Face 5 at 25 mm).
    func flexibleStage(_ size: CGSize) throws -> (ProjectModel, Host, FlexibleMainStage, UUID) {
        Bundle.r7m1vSwap
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let c = try FlexibleR7M1Fixtures.hisLiveLattice(r.project)
        let h = host(WorkspacePlaceholder(model: r.app, project: r.project), size: size)
        pump(4)
        try FlexiblePressFixtures.enterLatticeStage(r.project, click: { click(h, $0) })
        pump(3)
        let s = try XCTUnwrap(FlexibleMainStage.lastMade, "the page's stage")
        addTeardownBlock { @MainActor in await s.model?.waitForIdle() }
        XCTAssertNotNil(h.seen.keepOut["capsule"], "premise: the Flexible stage")
        return (r.project, h, s, c)
    }

    final class Count { var n = 0 }

    /// ★ (1) Each face's (i) on the Flexible page — the Selections list's line ("info-l-") and the face chip ("info-c-") — opens
    /// the centred card: the face's name, the caption, his four numbers (or "No numbers yet for this face"), no OK, front and
    /// centre; a tap anywhere closes it; no card of its own is drawn beside it. RED CONTROL: release 21's wiring — the (i)'s
    /// glyph with a tap of its own, which opened the card beside it — raises no centred card.
    func testEachFacesInfoOpensTheCentredCard() throws {
        let (p, h, s, c) = try flexibleStage(CGSize(width: 1032, height: 1376))
        let r3 = LatticeSelectableRef.face(group: c, face: 3)
        AppPopups.shared.current = nil
        s.tapFace(p, face: 3, point: nil, mesh: try XCTUnwrap(p.viewerMesh))
        pump(1.5)
        let title = FlexibleFaceStatsRows.title(p.flexibleName(r3))
        for (key, what) in [("info-l-" + r3.key, "the Selections list's (i)"), ("info-c-" + r3.key, "the face chip's (i)")] {
            let f = try XCTUnwrap(h.seen.keepOut[key],
                                  "premise: \(what) is drawn: \(h.seen.keepOut.keys.filter { $0.hasPrefix("info-") }.sorted())")
            XCTAssertGreaterThanOrEqual(min(f.width, f.height), 43.5, "\(what): his 44 pt target")
            click(h, CGPoint(x: f.midX, y: f.midY))
            pump(0.6)
            let popup = try XCTUnwrap(AppPopups.shared.current, "★ \(what) opens the centred card")
            XCTAssertTrue(popup.info, "★ \(what): an (i)'s card, not an error")
            XCTAssertEqual(popup.title, title, "★ \(what): the face's name")
            XCTAssertEqual(popup.text, FlexibleSelectionsCopy.statsCaption, "\(what): the caption")
            XCTAssertFalse(AppPopups.shared.dismissShown, "★ \(what): no OK — Tap anywhere to continue")
            let card = try XCTUnwrap(h.seen.chrome["appPopup"], "★ \(what): the card is drawn")
            XCTAssertEqual(card.midX, h.size.width / 2, accuracy: 2, "★ \(what): centred")
            XCTAssertEqual(card.midY, h.size.height / 2, accuracy: 2, "★ \(what): centred")
            if let rows = s.faceStats(r3, group: c, project: p) {
                for row in rows.rows {
                    XCTAssertTrue(h.seen.said.contains(row.label + " " + row.value), "★ \(what): \(row.label) \(row.value) under its words")
                }
                print("NOTES30-F1 \(what): \(rows.rows.map { "\($0.label) \($0.value)" })")
            } else {
                XCTAssertTrue(h.seen.said.contains(FlexibleSelectionsCopy.noNumbers), "★ \(what): no lattice drawn yet, said so")
                print("NOTES30-F1 \(what): no numbers yet")
            }
            XCTAssertNil(h.seen.keepOut["statsCard"], "★ \(what): no card of its own beside it")
            click(h, CGPoint(x: 30, y: h.size.height - 30))
            XCTAssertNil(AppPopups.shared.current, "★ \(what): a tap anywhere closes it")
        }

        // RED CONTROL: release 21's wiring raised no centred card (so the checks above tell the two apart)
        let ran = Count()
        let red = host(AppInfoButton(title: "Its lattice numbers", text: "", tap: { ran.n += 1 })
            .background(GeometryReader { g in Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["redInfo": g.frame(in: .global)]) }),
                       size: CGSize(width: 400, height: 300))
        pump(0.5)
        let rf = try XCTUnwrap(red.seen.keepOut["redInfo"], "the old (i)")
        click(red, CGPoint(x: rf.midX, y: rf.midY))
        XCTAssertEqual(ran.n, 1, "premise: the old (i)'s own tap ran")
        XCTAssertNil(AppPopups.shared.current, "RED CONTROL: the old wiring raised no centred card")
    }

    // MARK: (2) Save keeps Stress + shape on the part

    /// His Lattice stage on a new part: Structural, Group 1 (a face, Lattice) and Zone 1 (a 30 × 20 × 12 mm box, Lattice), graded
    /// by stress (LatticeAreaGradingHostedTests' two areas).
    private func twoGroups() throws -> (ProjectModel, g1: UUID, g2: UUID) {
        let (h, p, _) = try ParityTopologyShots.pad(AppBuildHost.landscape13, test: self)
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.structural)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "the stage menu")
        h.pump(1)
        let f = try XCTUnwrap(p.selection.groups.first?.faces.first)
        _ = p.latticeStageTap(face: f, loop: [f])
        let g = try XCTUnwrap(p.latticeList.activeGroupID)
        p.lattice.groupRoles[g] = .include
        p.latticeList.clearActive()
        let z = try XCTUnwrap(p.addLatticeZone())
        p.setLatticeZoneSize(z, width: 30, depth: 20, height: 12)
        p.lattice.enabled = true
        p.lattice.simulateStresses = true
        p.lattice.densityMode = .sim
        h.pump(1)
        XCTAssertEqual(p.latticeAreaGroups.map(\.id), [g, z], "premise: two groups, Group 1's tab then Zone 1's")
        return (p, g, z)
    }

    /// One visit to the Lattice page, its tabs the project's lattice groups (as WorkspacePlaceholder passes them).
    private func visit(_ p: ProjectModel) -> Notes29UIHostedTests.Page {
        let pr = Notes29UIHostedTests.Probe()
        let v = LatticeSetupWizard(project: p, onExit: {}).cellsPage(regions: p.latticeAreaGroups.map(\.name), closeToken: 0)
            .onPreferenceChange(LatticeProbeKey.self) { pr.all = $0 }
        let h = AppBuildHost(v, size: AppBuildHost.landscape13, test: self)
        h.pump(1.2)
        let page = Notes29UIHostedTests.Page(h: h, probe: pr)
        page.click("wizard-stage-\(LatticeWizardStage.allCases.last!.rawValue)")
        return page
    }

    private func gradeIDs(_ page: Notes29UIHostedTests.Page) -> [String] {
        page.ids.keys.filter { $0.hasPrefix("wizard-grade") || $0.hasPrefix("lattice-page-tab") }.sorted()
    }

    /// ★ (2) A new part grades Stress + shape. On Group 1's tab he picks Shape and saves: the part stays on Stress + shape (so
    /// Zone 1 — and any group added later — grades Stress + shape) and Group 1 keeps its own Shape; the same after the part is
    /// saved and reopened, after a second visit's Save, and in a version of it. RED CONTROL: the old Save (B7's first area
    /// leads) on the same picks turned the part to Shape.
    func testSaveKeepsStressAndShapeOnThePart() throws {
        let (p, g1, g2) = try twoGroups()
        XCTAssertEqual(p.lattice.gradingMode, .full, "★ a new part: Stress + shape")
        XCTAssertTrue(p.lattice.areaGrading.isEmpty, "premise: no group has a grade of its own")
        let before = p.lattice
        let page = visit(p)
        XCTAssertTrue(page.click("lattice-page-tab-area-0"), "premise: Group 1's tab: \(gradeIDs(page))")
        XCTAssertTrue(page.click("wizard-grade-type-fitShape"), "premise: Shape on Group 1's tab: \(gradeIDs(page))")
        XCTAssertTrue(page.click("lattice-cells-save"), "Save")
        XCTAssertEqual(p.lattice.gradingMode, .full, "★ Save keeps the part on Stress + shape")
        XCTAssertEqual(p.lattice.areaGrading[g1]?.gradingMode, .fitShape, "★ Group 1 keeps its own Shape")
        XCTAssertNil(p.lattice.areaGrading[g2]?.gradingMode, "★ Zone 1 grades as the part: Stress + shape")
        XCTAssertEqual(p.lattice.resolvedAreaGrading[g1]?.gradingMode, .fitShape, "★ the run grades Group 1 by shape")
        XCTAssertNil(p.lattice.resolvedAreaGrading[g2]?.gradingMode, "★ and Zone 1 as the part")

        // RED CONTROL: the old Save on the same picks moved Group 1's Shape onto the part
        var old = before
        old.saveAreaGrading(p.lattice.areaGrading, areas: p.latticeAreaGroups.map(\.id), firstAreaLeads: true)
        XCTAssertEqual(old.gradingMode, .fitShape, "RED CONTROL: the old Save turned the part to Group 1's Shape")

        // saved and reopened
        let snap = try XCTUnwrap(p.snapshot(savedAt: Date()), "his part saved")
        let back = try JSONDecoder().decode(ProjectSnapshot.self, from: JSONEncoder().encode(snap))
        let reopened = ProjectModel(restoring: back, importedFile: try XCTUnwrap(p.importedFile),
                                    importedMesh: try XCTUnwrap(p.importedMesh))
        XCTAssertEqual(reopened.lattice.gradingMode, .full, "★ reopened: the part on Stress + shape")
        XCTAssertEqual(reopened.lattice.areaGrading[g1]?.gradingMode, .fitShape, "★ reopened: Group 1's own Shape")
        XCTAssertEqual(reopened.latticeAreaGroups.map(\.id), [g1, g2], "premise: the same two groups")
        // a second visit: Zone 1's tab opened, nothing picked, Save — nothing moves
        let again = visit(reopened)
        XCTAssertTrue(again.click("lattice-page-tab-area-1"), "premise: Zone 1's tab: \(gradeIDs(again))")
        XCTAssertTrue(again.click("lattice-cells-save"), "Save")
        XCTAssertEqual(reopened.lattice.gradingMode, .full, "★ a second Save: the part still on Stress + shape")
        XCTAssertEqual(reopened.lattice.areaGrading[g1]?.gradingMode, .fitShape, "★ and Group 1 on its own Shape")
        XCTAssertNil(reopened.lattice.areaGrading[g2]?.gradingMode, "★ and Zone 1 as the part")
        // a version (the Library keeps each version as its snapshot)
        let version = try JSONDecoder().decode(ProjectSnapshot.self,
                                               from: JSONEncoder().encode(try XCTUnwrap(reopened.snapshot(savedAt: Date()))))
        XCTAssertEqual(version.lattice?.gradingMode, .full, "★ a version: Stress + shape")
        XCTAssertEqual(version.lattice?.areaGrading[g1]?.gradingMode, .fitShape, "★ a version: Group 1's own Shape")
    }

    /// ★ (2) "unless he picked another grade there himself": with no group yet the Part tab carries the Grade row, and his pick
    /// there is what Save keeps. (The control of the test above: the part's grade does change when he sets it himself.)
    func testHisOwnPickOnThePartTabIsSaved() throws {
        let p = try FlexiblePressFixtures.a1Project(3, self, facePrism: false).project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        XCTAssertTrue(p.latticeAreaGroups.isEmpty, "premise: no lattice group, so the Part tab carries the Grade row")
        XCTAssertEqual(p.lattice.gradingMode, .full, "★ a new lattice: Stress + shape")
        let page = visit(p)
        XCTAssertTrue(page.click("wizard-grade-type-stressOnly"), "premise: the Part tab's Grade row: \(gradeIDs(page))")
        XCTAssertTrue(page.click("lattice-cells-save"), "Save")
        XCTAssertEqual(p.lattice.gradingMode, .stressOnly, "★ his own pick on the Part tab is saved")
    }
}
#endif
