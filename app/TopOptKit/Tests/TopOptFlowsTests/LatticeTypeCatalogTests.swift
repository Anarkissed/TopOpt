import XCTest
@testable import TopOptKit
@testable import TopOptFlows

/// ★★ LATTICE TYPES ROUND 1 — U1 + U2 (TASK 2026-09-28-lattice-types-app, 03-app-spec §2): the
/// offered set comes from core; every other type stays visible and greyed with core's reason; the
/// round's order and Q5's names; one catalog for both pickers; and nothing here writes a job.
final class LatticeTypeCatalogTests: XCTestCase {

    private func src(_ f: String) throws -> String {
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        return try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/\(f)"), encoding: .utf8)
    }

    /// The order (M4: octet first) and Q5's default names, every type visible — M1's three included.
    func testTheOrderAndTheNames() {
        let e = LatticeTypeCatalog.entriesFromCore()
        XCTAssertEqual(e.map(\.id), ["octet", "sc", "bcc", "fcc", "diamond", "kelvin", "rhombic",
                                     "gyroid", "schwarz_d", "bccz", "fccz", "reentrant"])
        XCTAssertEqual(e.map(\.displayName), ["Octet truss", "Simple cubic", "BCC", "FCC", "Diamond", "Kelvin",
                                              "Rhombic dodecahedron", "Gyroid", "Schwarz-D", "BCC + Z", "FCC + Z", "Re-entrant"])
        for fake in ["schwarz_p", "honeycomb", "voronoi"] { XCTAssertFalse(e.map(\.id).contains(fake), "\(fake) is not a type") }
    }

    /// ★ The offered set is build ∩ certify ∩ the job parser — each fact core's; the reason says
    /// which is missing. Driven with explicit facts, so it holds whatever core ships.
    func testOfferedIsBuildCertifyAndRun() {
        let e = LatticeTypeCatalog.entries(generatable: ["octet", "fcc", "kelvin"], certifiable: ["octet", "fcc", "sc"],
                                           jobAccepts: { $0 != "fcc" })
        func entry(_ id: String) -> LatticeTypeEntry { e.first { $0.id == id }! }
        XCTAssertTrue(entry("octet").offered); XCTAssertNil(entry("octet").reason)
        XCTAssertFalse(entry("fcc").offered, "★ built and certified, but its job would be refused")
        XCTAssertEqual(entry("fcc").reason, LatticeTypeCatalog.jobRefused)
        XCTAssertEqual(entry("kelvin").reason, LatticeTypeCatalog.notCertified)
        XCTAssertEqual(entry("sc").reason, LatticeTypeCatalog.notBuilt)
        XCTAssertEqual(entry("gyroid").reason, LatticeTypeCatalog.notBuiltOrCertified)
        XCTAssertEqual(e.filter(\.offered).map(\.id), ["octet"])
        // a type core adds that the list does not know still shows (after the round's)
        let more = LatticeTypeCatalog.entries(generatable: ["octet", "lattice9"], certifiable: ["octet", "lattice9"], jobAccepts: { _ in true })
        XCTAssertEqual(more.last?.id, "lattice9"); XCTAssertEqual(more.last?.offered, true)
    }

    /// The linked core (19a1443bee65): the octet alone is offered; the six struts are certifiable but
    /// not built; the sheets and the tetragonal three are neither. The job parser accepts octet only.
    /// When core lights a type this test fails by name — light it up (A2).
    func testTheLinkedCoreOffersTheOctetAlone() {
        let e = LatticeTypeCatalog.entriesFromCore()
        XCTAssertEqual(e.filter(\.offered).map(\.id), ["octet"], "★ a newly offered type: light it up (A2)")
        for id in ["sc", "bcc", "fcc", "diamond", "kelvin", "rhombic"] {
            XCTAssertEqual(e.first { $0.id == id }?.reason, LatticeTypeCatalog.notBuilt, id)
        }
        for id in ["gyroid", "schwarz_d", "bccz", "fccz", "reentrant"] {
            XCTAssertEqual(e.first { $0.id == id }?.reason, LatticeTypeCatalog.notBuiltOrCertified, id)
        }
        XCTAssertTrue(TopOptKit.jobSchemaAcceptsTopology("octet"), "the control")
        XCTAssertFalse(TopOptKit.jobSchemaAcceptsTopology("fcc"), "★ core's parser refuses a non-octet id today")
        XCTAssertEqual(LatticeSetupWizard.offeredTypeIDs, ["octet"])
    }

    /// ★ Both pickers read the one catalog, and neither can write a type it does not offer.
    func testBothPickersReadTheCatalogAndNeverPickAGreyedType() throws {
        let wiz = try src("LatticeSetupWizard.swift"), page = try src("LatticePage.swift")
        XCTAssertTrue(wiz.contains("ForEach(LatticeTypeCatalog.entriesFromCore()) { e in typeChip(e) }"), "the Lattice stage's chips")
        XCTAssertTrue(page.contains("private var topologyEntries: [LatticeTypeEntry] { LatticeTypeCatalog.entriesFromCore() }"), "the page's pane")
        XCTAssertTrue(page.contains("guard e.offered else { return }\n            project.lattice.topologyID = e.id"),
                      "★ the page never writes a greyed type")
        XCTAssertTrue(wiz.contains("guard offered else { typeReason"), "★ the chip never picks a greyed type")
        XCTAssertFalse(try src("LatticeTypeCatalog.swift").contains("topologyID ="), "the catalog writes nothing")
    }
}
