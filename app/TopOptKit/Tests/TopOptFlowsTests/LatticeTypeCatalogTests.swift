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
        // ★ the words are core's (#358 lattice_type_readiness_plain), for core's verdict on these sets
        XCTAssertEqual(entry("kelvin").reason, TopOptKit.latticeTypeReadinessPlain(.notCertifiable))
        XCTAssertEqual(entry("sc").reason, TopOptKit.latticeTypeReadinessPlain(.notGeneratable))
        XCTAssertEqual(entry("gyroid").reason, TopOptKit.latticeTypeReadinessPlain(.notEither),
                       "★ a listed type core has no id for gets core's 'neither' line, not 'Not a lattice type'")
        XCTAssertEqual(e.filter(\.offered).map(\.id), ["octet"])
        // a type core adds that the list does not know still shows (after the round's)
        let more = LatticeTypeCatalog.entries(generatable: ["octet", "lattice9"], certifiable: ["octet", "lattice9"], jobAccepts: { _ in true })
        XCTAssertEqual(more.last?.id, "lattice9"); XCTAssertEqual(more.last?.offered, true)
    }

    /// The linked core: the octet alone is offered. ★ RE-PINNED (release (2), K1 + E2): core builds, certifies and
    /// runs the six struts now, so they are greyed by the TYPE GATE (their app batch, B7.n, has not shipped); core
    /// builds and certifies the two sheets but its job parser refuses their ids (core's fact, said first); the
    /// tetragonal three are neither. When a batch ships its id joins `appBatches` and this test fails by name.
    func testTheLinkedCoreOffersTheOctetAlone() {
        let e = LatticeTypeCatalog.entriesFromCore()
        XCTAssertEqual(e.filter(\.offered).map(\.id), ["octet"], "★ a newly offered type: light it up (A2)")
        for id in ["sc", "bcc", "fcc", "diamond", "kelvin", "rhombic"] {
            XCTAssertEqual(e.first { $0.id == id }?.reason, LatticeTypeCatalog.appBatchPending, id)
            XCTAssertTrue(TopOptKit.jobSchemaAcceptsTopology(id), "★ core runs \(id)")
        }
        for id in ["gyroid", "schwarz_d"] {
            XCTAssertEqual(e.first { $0.id == id }?.reason, LatticeTypeCatalog.jobRefused, id)
        }
        for id in ["bccz", "fccz", "reentrant"] {
            XCTAssertEqual(e.first { $0.id == id }?.reason, "Not buildable or strength-checked yet", id)
        }
        XCTAssertTrue(TopOptKit.jobSchemaAcceptsTopology("octet"), "the control")
        XCTAssertEqual(LatticeTypeCatalog.appBatches, ["octet"])
        XCTAssertEqual(LatticeSetupWizard.offeredTypeIDs, ["octet"])
    }

    /// ★ Both pickers read the one catalog, and neither can write a type it does not offer.
    func testBothPickersReadTheCatalogAndNeverPickAGreyedType() throws {
        let wiz = try src("LatticeSetupWizard.swift"), page = try src("LatticePage.swift")
        // ★ RE-PINNED (B7 slice 2): the Lattice page draws the OFFERED types only (a label card, or big cards)
        XCTAssertTrue(wiz.contains("let entries = LatticeTypeCatalog.entriesFromCore()")
                      && wiz.contains("let offered = entries.filter(\\.offered)")
                      && wiz.contains("ForEach(offered) { e in typeCard(e, fixesStale: stale != nil) }"),
                      "the Lattice page's cards")
        XCTAssertTrue(page.contains("private var topologyEntries: [LatticeTypeEntry] { LatticeTypeCatalog.entriesFromCore() }"), "the page's pane")
        XCTAssertTrue(page.contains("guard e.offered else { return }\n            project.lattice.topologyID = e.id"),
                      "★ the page never writes a greyed type")
        XCTAssertFalse(wiz.contains("ForEach(entries) {"), "★ a greyed type is never drawn, so never picked")
        XCTAssertFalse(try src("LatticeTypeCatalog.swift").contains("topologyID ="), "the catalog writes nothing")
    }
}
