// LatticeSampleViewTests — his iPad notes 11-08 (4.1): "There is no 'One cell' or 'In the part' visuals whatsoever."
// The view switch outlived the sample stage B8 deleted (10-24), so Sample drew nothing. Design note 30 / R3.2 (plan B7):
// Sample is core's sample block beside the panel. These pin that the page mounts it and that the block is core's own.
import XCTest
import TopOptKit
@testable import TopOptFlows

final class LatticeSampleViewTests: XCTestCase {

    /// ★ The block is core's coupon for the type: triangles, and a receipt that says so.
    func testTheSampleIsCoresCouponForTheType() throws {
        let block = try TopOptKit.latticeSampleBlock(topology: "octet")
        XCTAssertGreaterThan(block.mesh.triangleCount, 1000, "★ the engine's block, not an empty stand-in")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(block.receiptJSON.utf8)) as? [String: Any])
        XCTAssertEqual(obj["shape"] as? String, "coupon")
        XCTAssertEqual(obj["topology"] as? String, "octet")
        XCTAssertEqual((obj["dimensions_mm"] as? [Double])?.count, 3)
        XCTAssertEqual(LatticeSampleView.caption(receiptJSON: block.receiptJSON, typeName: "Octet truss").hasPrefix("Sample part · "), true)
        // CONTROL: a type core cannot generate is refused in core's words, never drawn as octet
        XCTAssertThrowsError(try TopOptKit.latticeSampleBlock(topology: "no-such-type"))
    }

    /// ★ his 11-10: "go back to how it was, showing a chunk of a bunch of lattice cells together" — core's cube of whole
    /// cells at the page's cell and density (held to the band), production struts; a different cell, a different chunk.
    func testCellsIsCoresChunkOfCells() throws {
        let a = try TopOptKit.latticeSampleBlock(topology: "octet", cellMM: 8, rhoHi: 0.3, cube: true)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(a.receiptJSON.utf8)) as? [String: Any])
        XCTAssertNotEqual(obj["shape"] as? String, "coupon", "★ the chunk, not the sample part")
        XCTAssertEqual((obj["cells_per_side"] as? NSNumber)?.intValue, 5, "★ 40 mm of 8 mm cells")
        XCTAssertGreaterThan(a.mesh.triangleCount, 1000)
        // a cell that does not divide 40 mm still gives whole cells (core refuses a part cell)
        let b = try TopOptKit.latticeSampleBlock(topology: "octet", cellMM: 6.5, rhoHi: 0.3, cube: true)
        let ob = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(b.receiptJSON.utf8)) as? [String: Any])
        XCTAssertEqual((ob["cells_per_side"] as? NSNumber)?.intValue, 6)
        XCTAssertNotEqual(a.mesh.vertices, b.mesh.vertices, "★ the cell size changes the chunk")
        // a density outside the band is held, and said
        let held = try TopOptKit.latticeSampleBlock(topology: "octet", cellMM: 8, rhoHi: 1.0, cube: true)
        XCTAssertTrue(held.densityHeld)
        let cap = LatticeSampleView.cellsCaption(receiptJSON: held.receiptJSON, typeName: "Octet truss", densityHeld: true)
        XCTAssertTrue(cap.hasPrefix("5 × 5 × 5 cells of 8 mm · Octet truss · density "), cap)
        XCTAssertTrue(cap.contains("(held to Octet truss's band)"), cap)
    }

    /// ★ The page draws a sample in BOTH views — Cells the chunk, In a part the sample part — and the switch says so.
    @MainActor
    func testThePageDrawsTheSampleUnderTheSwitch() throws {
        let src = try FlexibleSource.code("LatticeSetupWizard.swift")
        let r = try XCTUnwrap(src.range(of: "private func latticePage(_ c: CellsPageContext, size: CGSize) -> AnyView {"))
        let page = String(src[r.upperBound...].prefix(1400))
        XCTAssertFalse(page.contains("if model.stage == .cell {"), "★ no longer only under the first view")
        XCTAssertTrue(page.contains("LatticeSampleView(inputs: latticeSampleInputs, notInSample: latticeNotInSample)"))
        XCTAssertTrue(src.contains("Text(s.title)"), "the switch says the views' own titles")
        XCTAssertEqual(LatticeWizardStage.cell.title, "Cells")
        XCTAssertEqual(LatticeWizardStage.lattice.title, "In a part")
        var m = LatticeWizardModel(settings: LatticeSettings(enabled: true))
        m.stage = .cell
        XCTAssertEqual(LatticeSetupWizard.sampleInputs(m, beadMM: 0.45).shape, .cells)
        m.stage = .lattice
        XCTAssertEqual(LatticeSetupWizard.sampleInputs(m, beadMM: 0.45).shape, .part, "★ a sample part, not his")
    }

    // MARK: his iPad notes 11-10 (img 6): "I am not seeing the details adjusting the sample on the right side at all"

    private func graded(_ block: TopOptKit.LatticeSampleBlock) throws -> [Double] {
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(block.receiptJSON.utf8)) as? [String: Any])
        return try XCTUnwrap(obj["relative_density_graded"] as? [Double])
    }

    /// ★ The Grade's ends reach core's block: a different grade, a different block; ends outside the type's band are held
    /// to it (and said), never refused. CONTROL: no ends = core's own band, as before.
    func testTheGradeReachesTheSample() throws {
        let base = try TopOptKit.latticeSampleBlock(topology: "octet")
        let band = try graded(base)
        XCTAssertFalse(base.densityHeld, "control: core's band, nothing moved")
        let mid = (band[0] + band[1]) / 2
        let narrow = try TopOptKit.latticeSampleBlock(topology: "octet", rhoLo: mid, rhoHi: mid)
        XCTAssertEqual(try graded(narrow)[0], mid, accuracy: 1e-9, "★ his grade is the block's")
        XCTAssertEqual(try graded(narrow)[1], mid, accuracy: 1e-9)
        XCTAssertFalse(narrow.densityHeld)
        XCTAssertNotEqual(narrow.mesh.vertices, base.mesh.vertices, "★ a different grade, a different block")
        // his img 05: Grade 100 % → 20 % — outside octet's band at the top: held, not refused
        let wide = try TopOptKit.latticeSampleBlock(topology: "octet", rhoLo: 0.2, rhoHi: 1.0)
        XCTAssertTrue(wide.densityHeld, "★ held to the band")
        XCTAssertEqual(try graded(wide)[1], band[1], accuracy: 1e-9, "★ the top is the band's top")
        let cap = LatticeSampleView.caption(receiptJSON: wide.receiptJSON, typeName: "Octet truss", densityHeld: true)
        XCTAssertTrue(cap.contains("density ") && cap.contains("(held to Octet truss's band)"), cap)
    }

    /// ★ The page's own model drives the inputs: graded = "to" → "from"; Grade off = one density. Changing either changes
    /// the inputs (the view rebuilds on `.task(id:)`).
    @MainActor
    func testThePageModelDrivesTheSampleInputs() {
        var m = LatticeWizardModel(settings: LatticeSettings(enabled: true))
        m.relativeDensity = 0.3
        m.minRelativeDensity = 0.15
        m.gradingMode = .full
        let a = LatticeSetupWizard.sampleInputs(m, beadMM: 0.45)
        XCTAssertEqual(a.rhoLo, 0.15); XCTAssertEqual(a.rhoHi, 0.3)
        m.gradingMode = LatticeGradingMode.none
        let b = LatticeSetupWizard.sampleInputs(m, beadMM: 0.45)
        XCTAssertEqual(b.rhoLo, 0.3, "★ not graded: one density"); XCTAssertEqual(b.rhoHi, 0.3)
        XCTAssertNotEqual(a, b, "★ the sample rebuilds when the grade changes")
    }

    /// ★ What the engine's block can't show is said, in one line, only for what he has on.
    func testTheSampleSaysWhatItCantShow() {
        XCTAssertNil(LatticeSampleView.notInSampleLine(
            LatticeSampleView.notInSample(organic: false, finish: .none, shapeBand: false, singleCell: false)), "nothing on, no line")
        let all = LatticeSampleView.notInSample(organic: true, finish: .fullSkin, shapeBand: true, singleCell: true)
        XCTAssertEqual(LatticeSampleView.notInSampleLine(all),
                       "Not in the sample yet: Organic, Skin, the shape band, single-cell members")
    }
}

/// ★ his iPad notes 11-10 (img 3): "The background of the model is completely visible and cut off. It looks horrendous.
/// This should not be visible at all." + (later) "It shouldn't be the actual part the user has": a sample is always up on the
/// Lattice page, so the workspace covers his part in both views.
final class LatticeSampleCoverTests: XCTestCase {
    func testThePageAlwaysCoversHisPart() throws {
        let wiz = try FlexibleSource.code("LatticeSetupWizard.swift")
        XCTAssertTrue(wiz.contains(".preference(key: LatticeSampleShowingKey.self, value: true)"),
                      "★ the page says a sample is up, in either view")
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains(".onPreferenceChange(LatticeSampleShowingKey.self) { latticeSampleUp = $0 }"))
        let cover = try XCTUnwrap(ws.range(of: "if showLatticeWizard, latticeSampleUp {"), "★ the cover")
        let chrome = try XCTUnwrap(ws.range(of: "if !fullScreenPageUp || cellsPageKeepsChrome { chrome }"))
        XCTAssertLessThan(cover.lowerBound, chrome.lowerBound, "★ under the top-left block, which stays")
        XCTAssertTrue(String(ws[cover.upperBound...].prefix(120)).contains("DS.Color.background.color.ignoresSafeArea()"),
                      "★ the whole viewport, edge to edge")
    }
}

#if canImport(AppKit) && canImport(MetalKit)
/// ★ his iPad notes 11-10 (img 3) + (later), IN THE REAL PAGE: on the Lattice page his part is covered edge to edge in both
/// views (the top-left block stays); Cells draws the chunk of cells, In a part the sample part; leaving the page shows his
/// part again.
@MainActor
final class LatticeSampleCoverHostedTests: XCTestCase {
    // `latticeID`'s probe (LatticeProbeKey), published while a test records
    override nonisolated func setUp() { super.setUp(); FlexibleSaid.recording = true }
    override nonisolated func tearDown() { FlexibleSaid.recording = false; super.tearDown() }
    final class Probe { var all: [String: CGRect] = [:] }

    func testSampleCoversThePartAndInThePartShowsIt() throws {
        // his A1 pad, a face latticed, Aesthetic (LatticeTypeExitHostedTests.page's set-up, on this test)
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: true)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.aesthetic)
        if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.makeAnchor(c.id) }
        let pr = Probe()
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p).onPreferenceChange(LatticeProbeKey.self) { pr.all = $0 },
                             size: AppBuildHost.landscape13, test: self)
        h.pump(3)
        func seen(_ id: String) -> CGRect? { (pr.all[id] ?? h.frames.all[id]).flatMap { $0.width > 1 ? $0 : nil } }
        func click(_ id: String, _ what: String) throws {
            let f = try XCTUnwrap(seen(id), "\(what) is on the page")
            h.click(CGPoint(x: f.midX, y: f.midY), settle: 1)
        }
        try h.pickFromMenu("capsuleMenu", "Aesthetic", what: "Topology's ● menu")
        try h.tap("capsuleLattice", "the Lattice page", settle: 1.5)
        try click("wizard-stage-\(LatticeWizardStage.cell.rawValue)", "Cells")
        XCTAssertNotNil(seen("lattice-sample-cells"), "★ Cells: the chunk of cells")
        let cover = try XCTUnwrap(seen("lattice-sample-cover"), "★ his part is covered")
        XCTAssertGreaterThanOrEqual(cover.width, AppBuildHost.landscape13.width - 1, "★ edge to edge")
        XCTAssertNotNil(h.frames.all["topLeftName"], "the top-left block stays")
        try click("wizard-stage-\(LatticeWizardStage.lattice.rawValue)", "In a part")
        XCTAssertNotNil(seen("lattice-sample-part"), "★ In a part: the sample part")
        XCTAssertNil(seen("lattice-sample-cells"))
        XCTAssertNotNil(seen("lattice-sample-cover"), "★ never his own part")
        // CONTROL: off the page, his part is back
        try h.tap("capsuleSetup", "Setup", settle: 1.5)
        XCTAssertNil(seen("lattice-sample-cover"), "control: Setup shows his part")
    }
}
#endif
