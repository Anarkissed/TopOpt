// Notes29UIHostedTests — his iPad notes on release 20 (2026-11-25), builder N1, on the page itself (hosted: a test process
// builds no SwiftUI accessibility tree, so the ids come from `latticeID`'s probe and the chrome's published frames —
// FlexibleSaid). The pure parts: Notes29UITests.
//   (1) every type card one height, whether it carries "Not print-tested" or not;
//   (2) Skin turns off on Structural;
//   (3) every line the panel draws under a setting is at most five words;
//   (4) the (i)'s centred notification: any tap anywhere closes it; long words fit; few words, a small card;
//   (5) Save on Auto saves Allow quilt off; Cancel undoes a tap on it;
//   (7) the Settings sample follows the projection button.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes29UIHostedTests: XCTestCase {

    override nonisolated func setUp() { super.setUp(); FlexibleSaid.recording = true }
    override nonisolated func tearDown() {
        FlexibleSaid.recording = false
        LatticeTypeCatalog.appBatchesForTests = nil
        super.tearDown()
    }

    // MARK: the page

    final class Probe { var all: [String: CGRect] = [:] }

    @MainActor struct Page {
        let h: AppBuildHost
        let probe: Probe
        var ids: [String: CGRect] { probe.all.merging(h.frames.all) { a, _ in a } }
        /// Clicks `id` at its middle, scrolled into the panel's rows first; false when it is not on the page (or can't be
        /// brought into the rows).
        @discardableResult func click(_ id: String) -> Bool {
            let row = id.hasPrefix("wizard-") && !id.hasPrefix("wizard-stage-")   // a control in the panel's scrolling rows
            if row { reveal(id) }
            guard let f = ids[id], f.width > 1 else { return false }
            if row, let rows = ids["lattice-page-rows"],
               !rows.insetBy(dx: -2, dy: -2).contains(CGPoint(x: f.midX, y: f.midY)) { return false }   // scrolled out of reach
            h.click(CGPoint(x: f.midX, y: f.midY), settle: 0.6)
            return true
        }
        /// Scrolls the panel's rows until `id` is inside them (AppBuildHost.scrollIntoList's way).
        func reveal(_ id: String) {
            for _ in 0..<12 {
                guard let rows = ids["lattice-page-rows"], let f = ids[id], rows.minX <= f.midX, f.midX <= rows.maxX else { return }
                if rows.insetBy(dx: -1, dy: -1).contains(CGRect(x: f.midX, y: f.minY, width: 1, height: f.height)) { return }
                var v = h.view.hitTest(NSPoint(x: rows.midX, y: h.size.height - rows.midY))
                while let x = v, !(x is NSScrollView) { v = x.superview }
                guard let sv = v as? NSScrollView else { return }
                let clip = sv.contentView
                var o = clip.bounds.origin
                let dy = f.maxY > rows.maxY - 8 ? f.maxY - (rows.maxY - 8) : f.minY - (rows.minY + 8)
                o.y += clip.isFlipped ? dy : -dy
                clip.scroll(to: o); sv.reflectScrolledClipView(clip)
                h.pump(0.4)
            }
        }
    }

    /// His A1 part 3 with a lattice of `mode` (`set` adjusts it).
    func project(_ mode: LatticeStageMode, _ set: (ProjectModel) -> Void = { _ in }) throws -> ProjectModel {
        let p = try FlexiblePressFixtures.a1Project(3, self, facePrism: false).project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(mode)
        set(p)
        return p
    }

    /// One visit to the Lattice page, on the Part tab (or the area's).
    func visit(_ p: ProjectModel, area: Bool = false, size: CGSize = AppBuildHost.landscape13) -> Page {
        let pr = Probe()
        let v = LatticeSetupWizard(project: p, onExit: {}).cellsPage(regions: ["Group 1"], closeToken: 0)
            .onPreferenceChange(LatticeProbeKey.self) { pr.all = $0 }
        let h = AppBuildHost(v, size: size, test: self)
        h.pump(1.2)
        let page = Page(h: h, probe: pr)
        page.click("wizard-stage-\(LatticeWizardStage.allCases.last!.rawValue)")
        page.click(area ? "lattice-page-tab-area-0" : "lattice-page-tab-part")
        return page
    }

    // MARK: (1) type cards

    /// ★ (1) "They need to all be at the exact same height": every card one height, every column (card + the tag's row)
    /// one height, and the cards of a row share their top — the tagged and the untagged alike.
    func testEveryTypeCardIsTheSameHeight() throws {
        LatticeTypeCatalog.appBatchesForTests = LatticeTypeCatalog.appBatches   // every strut type's card (as on a STEP part)
        let p = try project(.structural) { $0.lattice.enabled = false }
        let page = visit(p)
        let ids = page.ids
        let cards = LatticeTypeCatalog.order.compactMap { id in ids["wizard-type-\(id)"].map { (id, $0) } }
        XCTAssertGreaterThanOrEqual(cards.count, 4, "premise: a grid of cards: \(ids.keys.filter { $0.hasPrefix("wizard-type") }.sorted())")
        let tagged = cards.filter { ids["wizard-type-untested-\($0.0)"] != nil }
        XCTAssertFalse(tagged.isEmpty, "premise: some cards carry Not print-tested")
        XCTAssertLessThan(tagged.count, cards.count, "premise: some don't (the octet)")
        let h0 = try XCTUnwrap(cards.first).1.height
        for (id, f) in cards {
            XCTAssertEqual(f.height, h0, accuracy: 0.5, "★ \(id)'s card is the same height as every other")
            let col = try XCTUnwrap(ids["wizard-type-column-\(id)"], "\(id)'s column")
            XCTAssertEqual(col.minY, f.minY, accuracy: 0.5, "★ \(id): its card at its column's top")
        }
        let rows = Dictionary(grouping: cards, by: { Int(($0.1.midY / 40).rounded()) })
        for (_, row) in rows where row.count > 1 {
            let top = row[0].1.minY
            for (id, f) in row { XCTAssertEqual(f.minY, top, accuracy: 0.5, "★ \(id): level with its row") }
        }
        let columns = cards.compactMap { ids["wizard-type-column-\($0.0)"] }
        XCTAssertEqual(Set(columns.map { Int(($0.height * 2).rounded()) }).count, 1, "★ every column one height: \(columns)")
    }

    // MARK: (2) Skin on Structural

    /// ★ (2) His project as release 20 left it: Structural, single-cell members still on from Aesthetic, Finish on Skin. Skin
    /// turns off — no "turn off single-cell members" pop-up — and Save writes None and single-cell members off.
    func testSkinTurnsOffOnStructural() throws {
        let p = try project(.structural) {
            $0.lattice.singleCellMembers = true; $0.lattice.boundary = .fullSkin; $0.latticePageManual = true
        }
        AppPopups.shared.current = nil
        let page = visit(p)
        XCTAssertNil(page.ids["wizard-finish-locked-note"], "★ no 'Single-cell members need Skin' on Structural")
        XCTAssertTrue(page.click("wizard-seg-none"), "premise: the Finish row: \(page.ids.keys.filter { $0.hasPrefix("wizard-seg") }.sorted())")
        XCTAssertNil(AppPopups.shared.current, "★ no 'To change the finish, turn off single-cell members'")
        XCTAssertTrue(page.click("lattice-cells-save"))
        XCTAssertEqual(p.lattice.boundary, LatticeBoundaryTreatment.none, "★ Skin is off")
        XCTAssertFalse(p.lattice.singleCellMembers, "★ saved off on Structural")

        // RED CONTROL: Aesthetic keeps his 09-18 rule — the finish stays Skin and the pop-up says how to unlock it
        let a = try project(.aesthetic) {
            $0.lattice.singleCellMembers = true; $0.lattice.boundary = .fullSkin; $0.latticePageManual = true
        }
        let pa = visit(a)
        XCTAssertNotNil(pa.ids["wizard-finish-locked-note"], "RED CONTROL: Aesthetic says Skin is required")
        pa.click("wizard-seg-none")
        XCTAssertEqual(AppPopups.shared.current?.title, LatticeSetupWizard.finishLockedTitle, "RED CONTROL: refused, said centred")
        AppPopups.shared.current = nil
        pa.click("lattice-cells-save")
        XCTAssertEqual(a.lattice.boundary, .fullSkin, "RED CONTROL: Aesthetic stays on Skin")
    }

    // MARK: (5) Allow quilt

    /// ★ (5) "It should *always* be off. Especially in 'Auto'": Save on Auto saves it off; a tap on it in Manual is undone by
    /// Cancel (it wrote the part at the tap); Manual's Save keeps his choice.
    func testAllowQuiltIsSavedOffOnAutoAndCancelUndoesIt() throws {
        let auto = try project(.aesthetic) { $0.lattice.allowQuilt = true; $0.latticePageManual = false }
        XCTAssertTrue(visit(auto).click("lattice-cells-save"))
        XCTAssertFalse(auto.lattice.allowQuilt, "★ Save on Auto: off")

        let manual = try project(.aesthetic) { $0.lattice.allowQuilt = true; $0.latticePageManual = true }
        XCTAssertTrue(visit(manual).click("lattice-cells-save"))
        XCTAssertTrue(manual.lattice.allowQuilt, "RED CONTROL: Manual keeps his choice")

        let cancel = try project(.aesthetic) { $0.latticePageManual = true }
        XCTAssertFalse(cancel.lattice.allowQuilt, "★ a new lattice: off")
        let page = visit(cancel, area: true)
        LatticeCaptions.recorded = []
        XCTAssertTrue(page.click("wizard-allow-quilt"), "premise: the switch, Manual's area tab: \(page.ids.keys.filter { $0.contains("quilt") })")
        XCTAssertTrue(LatticeCaptions.recorded.contains(LatticeSetupWizard.quiltOnLine), "premise: the page shows it on")
        XCTAssertFalse(cancel.lattice.allowQuilt, "★ the tap writes the page, not the part")
        XCTAssertTrue(page.click("lattice-page-cancel"))
        XCTAssertFalse(cancel.lattice.allowQuilt, "★ Cancel: still off")
    }

    // MARK: (3) five words, walked

    /// ★ (3) The panel walked in its states — Structural and Aesthetic, Auto and Manual, the Part tab and a group's, each
    /// grade, each finish, single-cell members on, Organic — and every line it drew under a setting is five words at most.
    func testEveryLineThePanelDrawsIsFiveWordsAtMost() throws {
        LatticeCaptions.recorded = []
        for mode in [LatticeStageMode.structural, .aesthetic] {
            for manual in [false, true] {
                for area in [false, true] {
                    let p = try project(mode) { $0.latticePageManual = manual }
                    let page = visit(p, area: area)
                    for seg in ["wizard-grade-type-fitShape", "wizard-grade-type-stressOnly", "wizard-grade-type-full",
                                "wizard-seg-rim", "wizard-seg-covered", "wizard-seg-skin", "wizard-seg-none",
                                "wizard-seg-uniform", "wizard-seg-per region", "wizard-single-cell-members",
                                "wizard-small-cells-thin-walls", "wizard-let-walls-cut-cells", "wizard-allow-quilt",
                                "wizard-grade-toggle", "wizard-grade-toggle", "wizard-simulate-stresses"] {
                        page.click(seg)
                    }
                    if manual, !area { page.click("wizard-type-organic"); page.click("lattice-page-tab-area-0") }
                }
            }
        }
        let seen = Set(LatticeCaptions.recorded)
        XCTAssertGreaterThan(seen.count, 15, "premise: the walk saw the panel's lines: \(seen.sorted())")
        XCTAssertTrue(seen.contains(LatticeSetupWizard.latticeAreaOwnBrief), "premise: a group's tab")
        XCTAssertTrue(seen.contains(LatticeSetupWizard.quiltOffLine) || seen.contains(LatticeSetupWizard.quiltOnLine),
                      "premise: Manual's rows")
        for line in seen.sorted() {
            XCTAssertLessThanOrEqual(LatticeCaptions.words(line), LatticeCaptions.maxWords, "★ under a setting: \"\(line)\"")
        }
        print("NOTES29 LINES SEEN (\(seen.count)): \(seen.sorted())")
    }

    // MARK: (4) the centred notification

    private func popupHost() -> AppBuildHost {
        let h = AppBuildHost(ZStack { Color.black; AppPopupLayer() }, size: AppBuildHost.landscape13, test: self)
        h.pump(0.4)
        return h
    }

    /// ★ (4) "a big bold line that says 'Tap anywhere to continue', allowing any tap anywhere on the screen to close out that
    /// notification": a tap on the card, or anywhere off it, closes it. RED CONTROL: an error keeps its OK.
    func testAnyTapAnywhereClosesTheNotification() throws {
        let h = popupHost()
        let p = AppPopups.shared
        p.help("Skin density", "Where a vine reaches the face, the skin joins it to its neighbours.")
        h.pump(0.6)
        let card = try h.onScreen("appPopup", "★ the notification, front and centre")
        XCTAssertEqual(card.midX, h.size.width / 2, accuracy: 2, "★ centred")
        XCTAssertEqual(card.midY, h.size.height / 2, accuracy: 2, "★ centred")
        h.click(CGPoint(x: card.midX, y: card.midY), settle: 0.6)
        XCTAssertNil(p.current, "★ a tap on the card closes it")
        p.help("Skin density", "Where a vine reaches the face, the skin joins it to its neighbours.")
        h.pump(0.6)
        h.click(CGPoint(x: 30, y: h.size.height - 30), settle: 0.6)
        XCTAssertNil(p.current, "★ a tap anywhere off it closes it")
        // RED CONTROL: an error card is closed by its OK only (a tap on its words leaves it)
        p.show("That number won’t work", "Use a number from 1 to 20.")
        h.pump(0.6)
        let err = try h.onScreen("appPopup", "the error")
        h.click(CGPoint(x: err.midX, y: err.minY + 50), settle: 0.6)
        XCTAssertNotNil(p.current, "RED CONTROL: an error stays until its OK")
        p.current = nil
        h.pump(0.3)
        // an action the notification offers ("Mark as tested") is its own button over the card: it runs, then closes
        var ran = 0
        p.help("Not print-tested", "Print the type's sample coupon, then mark it.", action: (title: "Mark as tested", run: { ran += 1 }))
        h.pump(0.6)
        let act = try h.onScreen("appPopupAction", "★ the action's button")
        let card2 = try h.onScreen("appPopup", "the card")
        XCTAssertTrue(card2.insetBy(dx: -0.5, dy: -0.5).contains(act), "★ inside the card")
        h.click(CGPoint(x: act.midX, y: act.midY), settle: 0.6)
        XCTAssertEqual(ran, 1, "★ the action ran (not the card's close)")
        XCTAssertNil(p.current)
        h.pump(0.3)
    }

    /// ★ (4) "ensure there is ample room for the text in the notification and that it expands/contracts with the text in it":
    /// a long explanation gets a wider, taller card whose words all show; a short one a small card.
    func testTheNotificationFitsLongWordsAndShrinksForFew() throws {
        let h = popupHost()
        let p = AppPopups.shared
        p.help("Allow single-cell members", "Two cells across a member.")
        h.pump(0.6)
        let small = try h.onScreen("appPopup", "the short card")
        p.current = nil
        h.pump(0.4)
        let long = String(repeating: "A member one cell wide has its struts cut at the face caps with no node to end on; "
                          + "the Skin finish re-ties them, so it is required and locked while this is on. ", count: 6)
        p.help("Allow single-cell members", long)
        h.pump(0.6)
        let big = try h.onScreen("appPopup", "the long card")
        let text = try h.onScreen("appPopupText", "its words")
        XCTAssertGreaterThan(big.width, small.width + 100, "★ a long text widens the card")
        XCTAssertGreaterThan(big.height, small.height + 100, "★ …and it grows to hold the words")
        XCTAssertTrue(CGRect(origin: .zero, size: h.size).contains(big), "★ on the screen")
        XCTAssertTrue(big.insetBy(dx: -0.5, dy: -0.5).contains(text), "★ the words inside the card")
        let font = NSFont.systemFont(ofSize: 14)
        let need = (long as NSString).boundingRect(with: CGSize(width: text.width, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin], attributes: [.font: font]).height
        XCTAssertGreaterThanOrEqual(text.height, need * 0.9, "★ every line shows (no word cut off): \(text.height) for \(need)")
        XCTAssertLessThanOrEqual(small.width, AppInfoCard.minWidth + 1, "★ a few words: the small card")
        p.current = nil
        h.pump(0.3)
    }

    // MARK: (7) projection

    /// ★ (7) "Choosing perspective/orthogonal view does nothing to the sample in the Settings tab": the sample follows it.
    func testTheSettingsSampleFollowsTheProjection() throws {
        let vp = ViewProjection.shared
        let was = vp.orthographic
        defer { vp.orthographic = was }
        vp.orthographic = false
        let page = visit(try project(.aesthetic))
        page.h.pump(0.4)
        XCTAssertEqual(LatticeSampleView.recordedOrthographic, false, "premise: perspective")
        vp.orthographic = true
        page.h.pump(0.6)
        XCTAssertEqual(LatticeSampleView.recordedOrthographic, true, "★ the sample draws orthographic")
        page.click("wizard-stage-\(LatticeWizardStage.allCases.first!.rawValue)")   // Cells
        page.h.pump(0.6)
        XCTAssertEqual(LatticeSampleView.recordedOrthographic, true, "★ the Cells sample too")
        vp.orthographic = false
        page.h.pump(0.6)
        XCTAssertEqual(LatticeSampleView.recordedOrthographic, false, "★ and back")
    }
}
#endif
