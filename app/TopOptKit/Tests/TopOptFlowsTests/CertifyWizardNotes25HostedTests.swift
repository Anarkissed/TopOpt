// CertifyWizardNotes25HostedTests — ★ his iPad notes 11-23 (notes25 B1, B2/B5, B3, B6) on the real pages, at his two windows
// (13″ landscape and 11″ portrait):
//   * B1: the fix pop-up sits at the very left in the middle, a clear gap from every control the page publishes (the stage menu
//     riding over Results among them: it sat under it, touching it); a drag moves it and its line leaves its edge; let go over a
//     control it settles at the nearest clear spot; the spot is kept for the session.
//   * B2/B5: Skip closes the pop-up and Results stays (it left Results: Skip ran Next's end). RED CONTROL: the old wiring.
//   * B3: the Checks panel's Strengthened line, opened, sits inside its row with the row's padding on every side.
//   * B6: Solve opens the Lattice settings with the field lit, as near the middle of the rows as they scroll.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class CertifyWizardNotes25HostedTests: XCTestCase {
    static let portrait = CGSize(width: 820, height: 1180)
    static let sizes = [AppBuildHost.landscape13, portrait]

    override nonisolated func setUp() {
        super.setUp()
        FlexibleSaid.recording = true   // the lattice page publishes its ids
        MainActor.assumeIsolated { CertifyCardPlace.shared.reset(); OrganicCertifyFocus.shared.reset() }
    }
    override nonisolated func tearDown() {
        FlexibleSaid.recording = false
        MainActor.assumeIsolated {
            OrganicCertifyCard.controlSkipLeaves = false
            CertifyCardPlace.shared.reset(); OrganicCertifyFocus.shared.reset()
        }
        super.tearDown()
    }

    // MARK: fixtures (his stand's shape, made-up numbers; never his job inputs)

    /// A print file's report that does not certify: 3 struts short after 6 rounds of strengthening (7 checks), the strengthening
    /// line as long as his ("1,554 struts thickened · 19 struts braced · 34 struts past your thickest strut (up to 4.1 mm)").
    static func report() -> [String: Any] {
        var r = IPadNotes1121Tests.report()
        var s = r["strength"] as! [String: Any]
        s["accepted"] = false; s["verdict"] = "fail"; s["fail_reason"] = "strut_margin"
        s["struts"] = ["judged": 8181, "under_safety": 3, "smallest_margin": 1.3399]
        s["weakest"] = [["margin": 1.3399, "by": "bending", "width_mm": 2.25, "length_mm": 15.6, "at": [0.2, 0.2, 0.0]]]
        r["strength"] = s
        let widened = [751, 288, 171, 127, 112, 105]
        var rounds: [[String: Any]] = widened.enumerated().map { i, n in
            ["added": ["struts_widened": n, "struts_braced": i == 0 ? 16 : (i == 1 ? 3 : 0),
                       "limit": ["past_limit": ["struts": i == 2 ? 34 : 5, "widest_mm": i == 5 ? 4.06 : 3.0]]] as [String: Any]]
        }
        rounds.append(["struts": ["judged": 8181]])
        r[LatticeFileButton.strengthenKey] = ["code": "limit", "passing": false, "rounds_fixed": 6, "seconds": 600.0, "rounds": rounds]
            as [String: Any]
        return r
    }

    static func outcome() throws -> OptimizeOutcome {
        let v = OptimizeVariant(requestedVolumeFraction: 0.6, achievedVolumeFraction: 0.6, massGrams: 67, supportVolumeVoxels: 0,
                                meshTriangleCount: 1, worstCaseMargin: 1.34, accepted: true, v3Passes: false,
                                meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2])
        return OptimizeOutcome(variants: [v], stoppedOnMargin: false, cancelled: false, acceptedCount: 1,
                               gridNx: 2, gridNy: 2, gridNz: 2, gridOrigin: .zero, spacing: 1, computedRemotely: true,
                               reportJSON: try JSONSerialization.data(withJSONObject: report()))
    }

    static func card() throws -> OrganicCertifyCard {
        let w = try XCTUnwrap(OrganicCertify.walk(version: UUID(), reportJSON: try outcome().reportJSON, infillNow: 50))
        let issue = try XCTUnwrap(w.current)
        let advice = OrganicCertifyAdvice.advice(issue, .init(strut: .init(light: 1.35, heavy: 2.7, single: false, auto: false),
                                                               stepMM: 0.45, infillNow: 50))
        return OrganicCertifyCard(issue: issue, step: w.step, grid: nil, solvedLines: nil, advice: advice,
                                  next: {}, skip: {}, solve: {})
    }

    /// ONE page up at a time, as on the iPad: the card's place is the session's (one object), so a page left open in an earlier
    /// window would keep telling it its own frames.
    var lastHost: AppBuildHost?
    func closeLast() {
        if let h = lastHost { h.window.orderOut(nil); h.window.contentView = nil; h.pump(0.1) }
        lastHost = nil
    }
    func opened(_ h: AppBuildHost) -> AppBuildHost { lastHost = h; return h }

    /// Results as the workspace mounts it, the stage menu riding over it where the workspace draws it (a stand-in publishing
    /// "capsule" at the capsule's place and size).
    func results(_ size: CGSize, certify: OrganicCertifyCard?) throws -> AppBuildHost {
        closeLast()
        let o = try Self.outcome()
        let capsule = Color.clear.frame(width: 268, height: StageCapsuleLayout.capsuleHeight)
            .background(ResultsChrome.publish("capsule"))
            .padding(.leading, StageCapsuleLayout.capsuleLeft).padding(.top, StageCapsuleLayout.capsuleTop)
        let v = ResultsScreen(projectName: "Stand", outcome: o, undo: {}, redo: {}, topLeftBlock: AnyView(capsule),
                              resultsModel: ResultsModel(projectName: "Stand", outcome: o), certify: certify)
            .frame(width: size.width, height: size.height)
        let h = opened(AppBuildHost(v, size: size, test: self))
        h.pump(2)
        return h
    }

    /// Every control the page publishes (the card's own frames, and the rings on the part, are not controls).
    func controls(_ h: AppBuildHost) -> [String: CGRect] {
        h.frames.all.filter { k, r in !CertifyCardLayout.ignored(k) && r.width >= 1 && r.height >= 1
            && r.width * r.height < 0.5 * h.size.width * h.size.height }
    }

    func assertClear(_ card: CGRect, _ h: AppBuildHost, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        for (k, r) in controls(h) {
            XCTAssertFalse(card.intersects(r.insetBy(dx: -(CertifyCardLayout.gap - 1), dy: -(CertifyCardLayout.gap - 1))),
                           "\(what): ★ the pop-up \(card) is within \(CertifyCardLayout.gap) pt of '\(k)' \(r)", file: file, line: line)
        }
        XCTAssertTrue(CGRect(origin: .zero, size: h.size).contains(card), "\(what): on the screen: \(card)", file: file, line: line)
    }

    // MARK: B1

    /// ★ B1: left, middle, clear of everything — the stage menu above all (it was right under it, touching it).
    func testThePopUpRestsAtTheLeftInTheMiddleClearOfEveryControl() throws {
        for size in Self.sizes {
            closeLast(); CertifyCardPlace.shared.reset()
            let h = try results(size, certify: try Self.card())
            let what = "\(Int(size.width))×\(Int(size.height))"
            let card = try h.onScreen("certifyCard", "\(what): the fix pop-up")
            _ = try h.onScreen("capsule", "\(what): premise, the stage menu over Results")
            XCTAssertEqual(card.minX, CertifyCardLayout.edge, accuracy: 1, "\(what): ★ at the very left")
            XCTAssertEqual(card.midY, size.height / 2, accuracy: 2, "\(what): ★ in the middle")
            assertClear(card, h, what)
            XCTAssertNotNil(h.frames.all["certifyAdvice"], "\(what): ★ B4: the value to try is on the card")
            try h.picture("certify-rest-\(what).png")
        }
    }

    /// ★ B1: a drag moves it (its line from its edge, live); let go clear, it stays; over a control it settles at the nearest
    /// clear spot; the spot is his for the session (a new Results screen opens it there).
    func testADragMovesItAndADropOnAControlSettlesClear() throws {
        for size in Self.sizes {
            closeLast(); CertifyCardPlace.shared.reset()
            let place = CertifyCardPlace.shared
            var h = try results(size, certify: try Self.card())
            let what = "\(Int(size.width))×\(Int(size.height))"
            let start = try h.onScreen("certifyCard", "\(what): the fix pop-up")

            // the drag: the card follows the finger, and the frame its line leaves from is the card's own
            let t = CGSize(width: 180, height: -90)
            place.dragChanged(t)
            h.pump(0.3)
            let moved = try h.onScreen("certifyCard", "\(what): dragged")
            XCTAssertEqual(moved.minX, start.minX + t.width, accuracy: 1, "\(what): ★ the drag moves it")
            XCTAssertEqual(moved.minY, start.minY + t.height, accuracy: 1)
            XCTAssertEqual(place.frame.origin.x, moved.minX, accuracy: 1, "\(what): ★ the line leaves the card as drawn")
            XCTAssertEqual(place.frame.origin.y, moved.minY, accuracy: 1)
            for p in [CGPoint(x: size.width / 2, y: size.height / 2), CGPoint(x: size.width - 5, y: 5), CGPoint(x: 5, y: size.height - 5),
                      CGPoint(x: moved.midX, y: size.height - 5)] {
                guard let s = OrganicCertifyLeader.start(place.frame, toward: p) else { continue }
                let onEdge = abs(s.x - moved.minX) < 1 || abs(s.x - moved.maxX) < 1 || abs(s.y - moved.minY) < 1 || abs(s.y - moved.maxY) < 1
                XCTAssertTrue(onEdge && moved.insetBy(dx: -1, dy: -1).contains(s), "\(what): ★ the line starts on the card's edge: \(s) \(moved)")
            }
            place.dragEnded(t)
            h.pump(0.8)
            let let1 = try h.onScreen("certifyCard", "\(what): let go")
            let expect1 = CertifyCardLayout.settle(moved.origin, size: moved.size, viewport: size, assets: place.assets)
            XCTAssertEqual(let1.minX, expect1.x, accuracy: 1, "\(what): let go: where it is when clear, else the nearest clear spot")
            XCTAssertEqual(let1.minY, expect1.y, accuracy: 1)
            assertClear(let1, h, "\(what) after the first drop")

            // dropped over the Checks panel: it settles at the nearest clear spot, never on the panel
            let checks = try h.onScreen("resultsChecks", "\(what): premise, Checks")
            let t2 = CGSize(width: checks.midX - let1.midX, height: checks.midY - let1.midY)
            place.dragChanged(t2)
            h.pump(0.3)
            let over = try h.onScreen("certifyCard", "\(what): over Checks")
            XCTAssertTrue(over.intersects(checks), "\(what): premise: dragged onto Checks")
            place.dragEnded(t2)
            h.pump(0.8)
            let settled = try h.onScreen("certifyCard", "\(what): settled")
            assertClear(settled, h, "\(what) after a drop on Checks")
            let expect2 = CertifyCardLayout.settle(over.origin, size: over.size, viewport: size, assets: place.assets)
            XCTAssertEqual(settled.minX, expect2.x, accuracy: 1, "\(what): ★ the NEAREST clear spot")
            XCTAssertEqual(settled.minY, expect2.y, accuracy: 1)
            XCTAssertLessThan(hypot(settled.minX - over.minX, settled.minY - over.minY),
                              hypot(start.minX - over.minX, start.minY - over.minY) + 1, "\(what): nearer than going home")

            // ★ kept for the session: Results opened again shows it there
            h = try results(size, certify: try Self.card())
            let again = try h.onScreen("certifyCard", "\(what): Results again")
            XCTAssertEqual(again.minX, settled.minX, accuracy: 1, "\(what): ★ his spot, kept")
            XCTAssertEqual(again.minY, settled.minY, accuracy: 1)
        }
    }

    // MARK: B3

    /// ★ B3 (his Checks note, img 2): the Strengthened line, opened, fits its row with the row's padding round it.
    func testTheStrengthenedLineFitsItsRow() throws {
        for size in Self.sizes {
            let h = try results(size, certify: nil)
            let what = "\(Int(size.width))×\(Int(size.height))"
            let key = try XCTUnwrap(h.frames.all.keys.first { $0.hasPrefix("resultsCheck-Strengthened") },
                                    "\(what): the Strengthened line: \(h.frames.all.keys.filter { $0.hasPrefix("resultsCheck") }.sorted())")
            let title = String(key.dropFirst("resultsCheck-".count))
            let line = try h.onScreen(key, "\(what): Strengthened")
            h.click(CGPoint(x: line.midX, y: line.midY))
            let text = try h.onScreen("resultsCheckMoreText-" + title, "\(what): ★ its opened words")
            let row = try h.onScreen("resultsCheckRow-" + title, "\(what): its row")
            XCTAssertGreaterThanOrEqual(text.minX - row.minX, DS.Space.l - 0.5, "\(what): ★ room at the left \(text) in \(row)")
            XCTAssertGreaterThanOrEqual(row.maxX - text.maxX, DS.Space.l - 0.5, "\(what): ★ room at the right \(text) in \(row)")
            XCTAssertGreaterThanOrEqual(text.minY - row.minY, DS.Space.sm - 0.5, "\(what): ★ room above")
            XCTAssertGreaterThanOrEqual(row.maxY - text.maxY, DS.Space.sm - 0.5, "\(what): ★ room below")
            let inset: CGFloat = DS.Space.l + 26 + DS.Space.m + DS.Space.l + 1
            XCTAssertGreaterThanOrEqual(text.width, row.width - inset,
                                        "\(what): ★ the words take the row's width (Details › is under them, not beside)")
            try h.picture("checks-strengthened-\(what).png")
        }
    }

    // MARK: B2/B5 and B6, on the workspace

    /// His stand's lookalike: an Organic part with one lattice group, its print file's result that does not certify (struts).
    func organicPart() throws -> FlexibleHisProject.Restored {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        p.lattice.algorithm = "organic"
        XCTAssertTrue(LatticeLayoutPreview.organic(p.lattice), "premise: Organic")
        let f = try XCTUnwrap(p.selection.groups.first?.faces.first, "premise: a face")
        _ = p.latticeStageTap(face: f, loop: [f])
        let g = try XCTUnwrap(p.latticeList.activeGroupID)
        p.lattice.groupRoles[g] = .include
        p.latticeList.clearActive()
        p.run.restoreOutcome(try Self.outcome())
        return r
    }

    final class Probe { var all: [String: CGRect] = [:] }

    func workspaceOnResults(_ size: CGSize, _ what: String) throws -> (AppBuildHost, Probe, FlexibleHisProject.Restored) {
        closeLast()
        CertifyCardPlace.shared.reset()
        OrganicCertifyFocus.shared.reset()
        let r = try organicPart()
        let probe = Probe()
        let h = opened(AppBuildHost(WorkspacePlaceholder(model: r.app, project: r.project).onPreferenceChange(LatticeProbeKey.self) { probe.all = $0 },
                                    size: size, test: self))
        h.pump(3)
        try h.tap("capsuleResults", "\(what): the capsule's Results")
        h.pump(1.5)
        _ = try h.onScreen("resultsVersions", "\(what): Results is open")
        return (h, probe, r)
    }

    /// ★ B1 on the real page: the stage menu rides over Results and the pop-up keeps clear of it (it sat touching it).
    /// ★ B2/B5: Skip closes the pop-up and Results stays. RED CONTROL: Skip as it was (Next's end) leaves Results.
    func testSkipStaysOnResultsAndThePopUpClearsTheStageMenu() throws {
        for size in Self.sizes {
            let what = "\(Int(size.width))×\(Int(size.height))"
            let (h, _, _) = try workspaceOnResults(size, what)
            let pl = CertifyCardPlace.shared
            print("CERTIFY PLACE \(what): size \(pl.size) viewport \(pl.viewport) rest \(pl.rest) assets \(pl.assets.count) "
                  + "card \(String(describing: h.frames.all["certifyCard"])) results' own \(String(describing: pl.rawResults["certifyCard"])) "
                  + "skip \(String(describing: pl.rawResults["certifySkip"])) vs \(String(describing: h.frames.all["certifySkip"]))")
            h.pump(1)
            print("CERTIFY PLACE later \(what): card \(String(describing: h.frames.all["certifyCard"])) results' own "
                  + "\(String(describing: pl.rawResults["certifyCard"]))")
            let card = try h.onScreen("certifyCard", "\(what): ★ the fix pop-up on Results")
            let capsule = try h.onScreen("capsule", "\(what): the stage menu over Results")
            XCTAssertFalse(card.intersects(capsule.insetBy(dx: -(CertifyCardLayout.gap - 1), dy: -(CertifyCardLayout.gap - 1))),
                           "\(what): ★ never close to the stage menu: \(card) \(capsule)")
            XCTAssertEqual(card.minX, CertifyCardLayout.edge, accuracy: 1, "\(what): ★ at the left")
            try h.picture("certify-workspace-\(what).png")
            try h.tap("certifySkip", "\(what): Skip")
            h.pump(1)
            XCTAssertNil(h.frames.all["certifyCard"], "\(what): ★ Skip closes the pop-up (1 of 1: the wizard ends)")
            XCTAssertNotNil(h.frames.all["resultsVersions"], "\(what): ★ and Results stays")
        }
        // RED CONTROL
        OrganicCertifyCard.controlSkipLeaves = true
        let (h, _, _) = try workspaceOnResults(AppBuildHost.landscape13, "control")
        try h.tap("certifySkip", "control: Skip")
        h.pump(1.5)
        XCTAssertNil(h.frames.all["resultsVersions"], "RED CONTROL: Skip as it was leaves Results")
    }

    /// ★ B6: Solve opens the Lattice settings with Strut thickness lit, as near the middle of the rows as they scroll.
    func testSolveOpensTheFieldLitInTheMiddle() throws {
        for size in Self.sizes {
            let what = "\(Int(size.width))×\(Int(size.height))"
            let (h, probe, r) = try workspaceOnResults(size, what)
            _ = try h.onScreen("certifyAdvice", "\(what): ★ B4: the card names the value to try")
            try h.tap("certifySolve", "\(what): Solve")
            h.pump(2.5)
            _ = try h.onScreen("latticeSettingsPanel", "\(what): ★ the Lattice settings are open")
            XCTAssertNil(h.frames.all["resultsVersions"], "\(what): Results gave way")
            XCTAssertTrue(r.project.latticePageManual, "\(what): ★ Manual: the Organic fields live there")
            let ring = try XCTUnwrap(probe.all["certify-focus-Strut thickness"],
                                     "\(what): ★ Strut thickness is lit; ids: \(probe.all.keys.filter { $0.hasPrefix("certify") || $0.hasPrefix("organic") }.sorted())")
            let rows = try XCTUnwrap(probe.all["lattice-page-rows"], "\(what): the rows")
            let content = try XCTUnwrap(probe.all["lattice-page-rows-content"], "\(what): the rows' content")
            XCTAssertTrue(rows.insetBy(dx: -8, dy: -8).contains(CGPoint(x: ring.midX, y: ring.midY)), "\(what): ★ in view: \(ring) \(rows)")
            let off = ring.midY - rows.midY
            let atTop = content.minY >= rows.minY - 1, atBottom = content.maxY <= rows.maxY + 1
            XCTAssertTrue(abs(off) <= 24 || (off < 0 && atTop) || (off > 0 && atBottom),
                          "\(what): ★ the field's centre is the rows' middle (\(off) pt off), or the rows cannot scroll further "
                          + "(content \(content), rows \(rows))")
            try h.picture("certify-solve-\(what).png")
        }
    }
}
#endif
