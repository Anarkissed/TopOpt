import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★ REVIEW 2026-10-01 (lattice types, the one confirmed finding): a type saved BEFORE the catalog
/// — the variant page's old pane wrote any certifiable id with no guard — still rides a project.
/// Its run carries NO lattice block, so Optimize ran the part bare and said nothing, and "Lattice"
/// failed on core's generic "requires a lattice block". Now every start refuses on the button in
/// the picker's own sentence, the stage's Type row says it at once, and one tap reaches the fix.
/// The pick is never migrated, and no job's bytes change: the gate only stops a start.
@MainActor
final class LatticeStaleTypeTests: XCTestCase {

    private static var sources: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("Sources/TopOptFlows")
    }
    private func src(_ f: String) throws -> String {
        try String(contentsOf: Self.sources.appendingPathComponent(f), encoding: .utf8)
    }
    private func member(_ text: String, _ decl: String) throws -> String {
        let r = try XCTUnwrap(text.range(of: decl), "missing \(decl)")
        let rest = text[r.lowerBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    }\n"), "unterminated \(decl)")
        return String(rest[..<end.upperBound])
    }

    /// The defect's mechanism, on the linked core: with a type core can't build the run spec is
    /// nil — the job would carry no lattice. Octet, the control, has one. Organic too: its
    /// topology still rides the job.
    func testAStaleTypeLosesTheLatticeAndTheGateNamesIt() {
        for organic in [false, true] {
            let (p, _, _) = VariantFacePrismFixture.project(organic: organic)
            XCTAssertNotNil(p.latticeRunSpec(emission: p.latticeJobRegions()), "control: octet runs (organic \(organic))")
            XCTAssertNil(LatticeTypeCatalog.selectionRefusal(p.lattice.topologyID))
            p.lattice.topologyID = "sc"
            XCTAssertNil(p.latticeRunSpec(emission: p.latticeJobRegions()),
                         "★ the mechanism: a type core can't build drops the lattice block (organic \(organic))")
            XCTAssertEqual(LatticeTypeCatalog.selectionRefusal(p.lattice.topologyID),
                           "Simple cubic: Core can’t build this type yet.", "★ the picker's own sentence")
        }
    }

    /// ★ The gate is exactly the catalog: refused ⇔ not offered, for every id it shows — and an
    /// id core does not know at all is neither built nor certified, never silently octet.
    func testTheRefusalIsTheCatalogsReason() {
        let e = LatticeTypeCatalog.entries(generatable: ["octet", "fcc"], certifiable: ["octet", "fcc", "sc"],
                                           jobAccepts: { $0 != "fcc" })
        for x in e {
            XCTAssertEqual(LatticeTypeCatalog.selectionRefusal(x.id, in: e),
                           x.offered ? nil : "\(x.displayName): \(x.reason!)", x.id)
        }
        XCTAssertEqual(LatticeTypeCatalog.selectionRefusal("fcc", in: e), "FCC: Core’s run doesn’t accept this type yet.")
        XCTAssertEqual(LatticeTypeCatalog.selectionRefusal("lattice9", in: e),
                       "lattice9: Core can’t build or certify this type yet.")
        // the linked core: every greyed id refuses, the octet alone runs
        for x in LatticeTypeCatalog.entriesFromCore() {
            XCTAssertEqual(LatticeTypeCatalog.selectionRefusal(x.id) == nil, x.offered, x.id)
        }
    }

    /// The stage's "Lattice" greys for a stale type (organic too); the octet control stays open.
    func testTheStageRefusesAStaleType() {
        let m = AppModel(materialsPath: nil)
        for organic in [false, true] {
            let (p, _, _) = VariantFacePrismFixture.project(organic: organic)
            XCTAssertTrue(WorkspacePlaceholder(model: m, project: p).canLatticeThis, "control: octet (organic \(organic))")
            p.lattice.topologyID = "rhombic"
            XCTAssertFalse(WorkspacePlaceholder(model: m, project: p).canLatticeThis,
                           "★ a type core can't build is refused on the button (organic \(organic))")
            p.lattice.enabled = false
            XCTAssertNil(LatticeJobIncludeGate.optimizeRefusal(latticeEnabled: false, regions: p.latticeJobRegions().regions),
                         "lattice off asks nothing: the run is topology only")
        }
    }

    /// Optimize and Lattice say it, in the same sentence, and their tap opens Settings — the Type
    /// row, where the offered chip is the fix. Navigation only: no type is picked for him.
    func testBothButtonsRefuseAndTheTapOpensSettings() throws {
        let ws = try src("WorkspacePlaceholder.swift")
        XCTAssertTrue(try member(ws, "private var latticeTypeRefusal")
            .contains("project.lattice.enabled ? LatticeTypeCatalog.selectionRefusal(project.lattice.topologyID) : nil"))
        XCTAssertTrue(try member(ws, "private var latticeOptimizeRefusal").contains("?? latticeTypeRefusal"), "★ Optimize")
        XCTAssertTrue(try member(ws, "private var latticeStageRefusal").contains("?? latticeTypeRefusal"), "★ Lattice")
        // every start is behind those two (canOptimize / canLatticeThis), and the sub-line says it
        XCTAssertTrue(try member(ws, "private var canOptimize: Bool").contains("guard latticeOptimizeRefusal == nil else { return false }"))
        XCTAssertTrue(try member(ws, "private var optimizeSummary: String").contains("if let why = latticeOptimizeRefusal { return why }"))
        XCTAssertTrue(try member(ws, "var canLatticeThis").contains("latticeStageRefusal == nil"))
        XCTAssertTrue(try member(ws, "private var latticeThisSummary").contains("if let why = latticeStageRefusal { return why }"))
        // the tap
        XCTAssertEqual(ws.components(separatedBy: "let opensType = !ok && summary == latticeTypeRefusal").count - 1, 2)
        XCTAssertTrue(ws.contains("if ok { requestLatticeRun() } else if marks { goToWallMarking() } else if opensType { goToLatticeType() }"))
        XCTAssertTrue(ws.contains("if ok { requestRun() } else if marks { goToWallMarking() } else if opensType { goToLatticeType() }"))
        XCTAssertEqual(ws.components(separatedBy: ".disabled(!ok && !marks && !opensType)").count - 1, 2, "★ greyed, yet tappable")
        let go = try member(ws, "private func goToLatticeType()")
        XCTAssertTrue(go.contains("if stage != .lattice { goToStage(.lattice) }") && go.contains("showLatticeWizard = true"))
        for write in ["topologyID", "setTopology", "lattice.enabled", "persist"] {
            XCTAssertFalse(go.contains(write), "★ navigation only — no \(write)")
        }
    }

    /// The stage's Type row says it AT ONCE (not only when a greyed chip is tapped), in the same
    /// sentence; the offered chip stays live as the fix — under Organic too, where it puts back
    /// the octet without leaving Organic.
    func testTheTypeRowSaysItAtOnceAndTheOfferedChipFixesIt() throws {
        let wiz = try src("LatticeSetupWizard.swift")
        let row = try member(wiz, "private var typeRow: some View")
        XCTAssertTrue(row.contains("let stale = LatticeTypeCatalog.selectionRefusal(model.topologyID, in: entries)"))
        XCTAssertTrue(row.contains("if let why = typeReason ?? stale {"), "★ at once, not only on a tap")
        XCTAssertTrue(row.contains("typeChip(e, fixesStale: e.offered && stale != nil)"))
        let chip = try member(wiz, "private func typeChip(_ e: LatticeTypeEntry, fixesStale: Bool)")
        XCTAssertTrue(chip.contains("let inert = organicOn && !fixesStale"))
        XCTAssertTrue(chip.contains(".disabled(inert)"))
        XCTAssertTrue(chip.contains("guard offered else { typeReason = LatticeTypeCatalog.reasonLine(e); return }"),
                      "a greyed chip still never picks; one sentence home")
        XCTAssertTrue(chip.contains("if organicOn { model.topologyID = e.id } else { model.setTopology(e.id) }"))
        // the model's topology is the project's after Save & Exit — never migrated on open
        XCTAssertFalse(try src("LatticeWizardModel.swift").contains("selectionRefusal"), "★ never migrated")
        XCTAssertFalse(try src("LatticeSettings.swift").contains("selectionRefusal"), "★ never migrated on decode")
    }
}
