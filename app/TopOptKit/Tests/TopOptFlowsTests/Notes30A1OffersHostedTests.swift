// Notes30A1OffersHostedTests — ★ notes30 X2 (the maintainer's 11-26 answers) on the Lattice stage itself, his A1 pad frozen, the
// centred pop-up layer mounted as RootView mounts it. Hosted: a test process builds no SwiftUI accessibility tree, so the frames
// come from the pages' keep-out keys and the words from AppPopups (FlexibleSaid.recording).
//   1. Structural on his 20 mm pad lays nothing with Allow quilt off: the pop-up offers his three (Turn Allow quilt on, Switch
//      to Aesthetic, Leave it solid), each a 44 pt button, centred, with an (i) whose card opens over it and gives it back;
//      "Turn Allow quilt on" lays his pad. RED CONTROL: release 21's "use smaller cells".
//   2. The warning triangle opens the one centred card, its setting fixes as its buttons. RED CONTROL: release 21's wiring.
// The rule and the measurements: Notes30A1OffersTests.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes30A1OffersHostedTests: XCTestCase {

    override func tearDown() {
        SolidReason.controlSmallerCellsAlways = false
        SolidReason.controlThreeOffers = false
        WorkspacePlaceholder.controlDiagnosisNoCard = false
        FlexibleSaid.recording = false
        AppPopups.shared.current = nil
        SettingToChange.shared.ask = nil
        super.tearDown()
    }

    /// His pad under Structural on the Lattice stage (entered by the stage menu, as he does), his Top face as Lattice the whole
    /// 20 mm ("Solid + Lattice faces"), the settings saved.
    private func stage(_ size: CGSize = AppBuildHost.landscape13, depthMM: Double = 20) throws -> (AppBuildHost, ProjectModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.structural)
        try FlexiblePressFixtures.topFacePrism(p)
        if depthMM != 20, let top = p.selection.groups.first(where: { $0.name == "Top" }) {
            p.writeLatticeDepthMM(.face(group: top.id, face: 1), mm: depthMM)
        }
        p.lattice.enabled = true
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p).overlay { AppPopupLayer() }, size: size, test: self)
        h.pump(3)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "the stage menu")
        h.pump(1.5)
        if h.frames.all["latticeSettingsPanel"] != nil { try h.tap("capsuleLattice", "the page's Save", settle: 1.5) }
        return (h, p)
    }

    private func waitForPopUp(_ h: AppBuildHost, titled titles: [String], seconds: Double = 240) -> AppPopup? {
        let end = Date().addingTimeInterval(seconds)
        while !AppPopups.recorded.contains(where: { titles.contains($0.title) }), Date() < end { h.pump(1) }
        h.pump(1)
        return AppPopups.recorded.last { titles.contains($0.title) }
    }

    /// ★ 1. His pad, Structural, Allow quilt off: the centred pop-up says what the depth needs and offers, each a 44 pt button,
    /// ★ notes30 X2 (his yes, 11-26) Small cells in thin walls FIRST, then Allow quilt on and Switch to Aesthetic, and Leave it
    /// solid last; its (i) opens the card over it and a tap anywhere gives it back; "Small cells in thin walls" lays his pad with
    /// Allow quilt still off (the button is Lattice again). RED CONTROLS: release 21's pop-up (`controlSmallerCellsAlways`: "use
    /// smaller cells", no offer) and release 22's three offers (`controlThreeOffers`).
    func testHisPadOffersHisThreeAndAllowQuiltLaysIt() throws {
        FlexibleSaid.recording = true
        let offersTitle = "This needs 4 mm cells", oldTitle = "This lattice can't be laid"

        // RED CONTROL first: release 21's advice
        SolidReason.controlSmallerCellsAlways = true
        AppPopups.recorded = []
        let (rh, _) = try stage()
        let old = try XCTUnwrap(waitForPopUp(rh, titled: [offersTitle, oldTitle]), "RED CONTROL: the pop-up came")
        print("NOTES30-X2 HOSTED RED: \(old.title) — \(old.text.replacingOccurrences(of: "\n", with: " "))")
        XCTAssertEqual(old.title, oldTitle, "RED CONTROL: release 21's title")
        XCTAssertTrue(old.text.contains("use smaller cells"), "RED CONTROL: the advice that cannot help")
        XCTAssertNotEqual(AppPopups.shared.action?.title, SolidReason.Fix.allowQuilt.title, "RED CONTROL: no offer")
        AppPopups.shared.current = nil
        SolidReason.controlSmallerCellsAlways = false

        // RED CONTROL: release 22's three offers (no Small cells in thin walls)
        SolidReason.controlThreeOffers = true
        AppPopups.recorded = []
        let (r22, _) = try stage()
        _ = try XCTUnwrap(waitForPopUp(r22, titled: [offersTitle, oldTitle]), "RED CONTROL: the pop-up came")
        XCTAssertEqual([AppPopups.shared.action?.title, AppPopups.shared.second?.title, AppPopups.shared.third?.title],
                       ["Turn Allow quilt on", "Switch to Aesthetic", "Leave it solid"], "RED CONTROL: release 22's three")
        AppPopups.shared.current = nil
        SolidReason.controlThreeOffers = false

        AppPopups.recorded = []
        let (h, p) = try stage()
        let pop = try XCTUnwrap(waitForPopUp(h, titled: [offersTitle, oldTitle]), "★ the pop-up came")
        print("NOTES30-X2 HOSTED: \(pop.title) — \(pop.text.replacingOccurrences(of: "\n", with: " "))")
        XCTAssertEqual(pop.title, offersTitle, "★ what the depth needs")
        XCTAssertFalse(pop.text.contains("smaller cells"), "★ never the advice that cannot help")
        let popups = AppPopups.shared
        // ★ notes30 X2 (his yes, 11-26): Small cells in thin walls FIRST, then Allow quilt and Aesthetic; Leave it solid last
        XCTAssertEqual([popups.action?.title, popups.second?.title, popups.third?.title],
                       ["Small cells in thin walls", "Turn Allow quilt on", "Switch to Aesthetic"], "★ his four, Small cells first")
        XCTAssertTrue(popups.dismissShown)
        XCTAssertEqual(popups.dismissTitle, "Leave it solid", "★ Leave it solid last (it closes, changing nothing)")
        let card = try h.onScreen("appPopup", "★ the centred pop-up")
        XCTAssertEqual(card.midX, h.size.width / 2, accuracy: 2, "★ centred")
        XCTAssertEqual(card.midY, h.size.height / 2, accuracy: 2, "★ centred")
        for k in ["appPopupChoice1", "appPopupChoice2", "appPopupChoice3", "appPopupDismiss"] {
            let b = try h.probe(k, "★ \(k): a 44 pt button")
            XCTAssertTrue(card.contains(b), "\(k) inside the pop-up")
        }
        for k in ["new-engine-reason", "lane-new-engine-reason"] { XCTAssertNil(h.frames.all[k], "nothing at the bottom-centre") }

        // its (i): the card over it, then the pop-up back as it was
        let id = popups.current?.id
        try h.probe("appPopupWhy", "★ the pop-up's (i), a 44 pt target")
        try h.tap("appPopupWhy", "the (i)", settle: 1)
        XCTAssertEqual(popups.current?.info, true, "★ the (i)'s card")
        XCTAssertEqual(popups.current?.title, SolidPopUp.offersWhyTitle)
        XCTAssertTrue(popups.current?.text.hasPrefix("Small cells in thin walls:") ?? false, "★ its (i) says Small cells first")
        XCTAssertNotNil(h.frames.all["app-popup-tap-anywhere"] ?? h.frames.all["appPopup"], "the card is drawn")
        try h.tap("appPopupBackdrop", "a tap anywhere", settle: 1)
        XCTAssertEqual(popups.current?.id, id, "★ the pop-up is back")
        XCTAssertEqual(popups.action?.title, "Small cells in thin walls", "★ with its buttons")

        // "Small cells in thin walls": Manual with it on, Allow quilt still off, and his pad lays
        let raised = LatticeLayoutPreview.solidPopUpsRaised
        AppPopups.recorded = []
        try h.tap("appPopupChoice1", "★ Small cells in thin walls", settle: 1)
        XCTAssertTrue(p.latticePageManual && p.lattice.smallCellsInThinWalls, "★ the Lattice page's Manual, Small cells on")
        XCTAssertFalse(p.lattice.allowQuilt, "★ its own switch: Allow quilt stays off")
        let end = Date().addingTimeInterval(240)
        while h.frames.all["latticeCannot"] != nil, Date() < end { h.pump(1) }
        h.pump(3)
        XCTAssertNil(h.frames.all["latticeCannot"], "★ his pad lays: the button is Lattice again")
        XCTAssertFalse(AppPopups.recorded.contains { [offersTitle, oldTitle].contains($0.title) }, "★ nothing says it can't be laid")
        print("NOTES30-X2 HOSTED after Small cells: pop-ups \(AppPopups.recorded.map(\.title)), raised \(LatticeLayoutPreview.solidPopUpsRaised - raised)")
    }

    /// ★ 2. The warning triangle (his pad's Top face as Lattice 8 mm deep: too few of Structural's cells across it) opens the
    /// one centred card — "How to fix this", every failure with its fix, no OK — and its fixes are its 44 pt buttons.
    /// ★ notes30 X2 (cell advice): 8 mm holds 5 cells of 1.6 mm, under the 4.74 mm the lay may use, so the card never names a
    /// smaller cell: its fixes are the "This needs … cells" pop-up's that lay here — only Leave it solid at 8 mm (Allow quilt's
    /// 2.55 mm and Aesthetic's 2 cells of 4 mm do not fit) — and the depth that lays ("Make it deeper: 23.8 mm").
    /// RED CONTROLS: `controlDiagnosisNoCard` (release 21's tap raised no centred card) and `controlSmallerCellsAlways` (release
    /// 21's words: "Or use a smaller cell: 1.6 mm", its button the Cell size field).
    /// (At the whole 20 mm the card reads 5 cells of 4 mm across: the triangle has nothing to say.)
    func testTheTriangleOpensTheCentredCardWithItsFixes() throws {
        defer { SolidReason.controlSmallerCellsAlways = false }
        for red in [true, false] {
            SolidReason.controlSmallerCellsAlways = red
            let (h, p) = try stage(depthMM: 8)
            AppPopups.shared.current = nil
            SettingToChange.shared.ask = nil
            let g = try XCTUnwrap(p.latticeGroups.first, "his Top's lattice group")
            p.latticeList.setActive(g.id)
            let key = "lattice-diagnosis-\(g.id.uuidString)"
            let end = Date().addingTimeInterval(120)
            while h.frames.all[key] == nil, Date() < end { AppPopups.shared.current = nil; h.pump(1) }
            AppPopups.shared.current = nil
            h.pump(1)
            let glyph = try h.probe(key, "★ the warning triangle, a 44 pt target")
            if !red {   // RED CONTROL: release 21's wiring
                WorkspacePlaceholder.controlDiagnosisNoCard = true
                h.click(CGPoint(x: glyph.midX, y: glyph.midY), settle: 1)
                XCTAssertNil(AppPopups.shared.current, "RED CONTROL: release 21's tap raised no centred card")
                WorkspacePlaceholder.controlDiagnosisNoCard = false
                h.pump(0.5)
            }
            h.click(CGPoint(x: glyph.midX, y: glyph.midY), settle: 1)
            let pop = try XCTUnwrap(AppPopups.shared.current, "★ the triangle opens the centred card")
            let acts = AppPopups.shared.infoActions
            print("NOTES30-X2 TRIANGLE\(red ? " RED" : ""): \(pop.title) — \(pop.text.replacingOccurrences(of: "\n", with: " | ")) "
                  + "[\(acts.map(\.title))]")
            XCTAssertTrue(pop.info, "★ the (i)'s card, like every (i)")
            XCTAssertEqual(pop.title, LatticeDiagnosisCard.title)
            XCTAssertFalse(AppPopups.shared.dismissShown, "★ Tap anywhere to continue, no OK")
            let card = try h.onScreen("appPopup", "the card")
            XCTAssertEqual(card.midX, h.size.width / 2, accuracy: 2, "★ centred")
            XCTAssertFalse(acts.isEmpty, "★ its fixes are its buttons")
            let first = try h.probe("appPopupAction", "★ its first fix, a 44 pt button")
            XCTAssertTrue(card.contains(first))
            if red {
                XCTAssertTrue(pop.text.contains("Or use a smaller cell: 1.6 mm."), "RED CONTROL: release 21's cell under the smallest")
                XCTAssertEqual(acts.first?.title, "Change the cell size", "RED CONTROL: its button, the Cell size field")
            } else {
                XCTAssertFalse(pop.text.contains("smaller cell"), "★ never a cell under the 4.74 mm the lay may use")
                XCTAssertTrue(pop.text.contains("Make it deeper: 23.8 mm."), "★ the depth whose cells lay")
                XCTAssertTrue(pop.text.contains("Or leave it solid."), "★ the pop-up's own fix")
                XCTAssertEqual(acts.map(\.title), ["Leave it solid"], "★ only the fix that does something here")
            }
            let before = p.lattice
            h.click(CGPoint(x: first.midX, y: first.midY), settle: 2)
            XCTAssertNil(AppPopups.shared.current, "the card closed")
            if red {
                let ask = try XCTUnwrap(SettingToChange.shared.ask, "RED CONTROL: the button went to the Cell size field")
                XCTAssertEqual(ask.tryText, "Try 1.6 mm cells", "RED CONTROL: a cell the lay never lays")
            } else {
                XCTAssertNil(SettingToChange.shared.ask, "★ Leave it solid goes nowhere")
                XCTAssertEqual(p.lattice, before, "★ …and changes nothing")
            }
            SettingToChange.shared.ask = nil
        }
    }
}
#endif
