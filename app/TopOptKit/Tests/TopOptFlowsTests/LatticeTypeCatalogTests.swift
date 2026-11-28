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
    /// ★ RE-PINNED (notes28, the maintainer's decision 2026-11-24: all the strut types): the type gate is open for every
    /// strut type, so the old run's catalog offers the seven core builds, certifies and runs; the sheets and the tetragonal
    /// three are still greyed by core's own facts. (The Lattice stage's picker reads the new engine's catalog,
    /// `layoutEntries` — LatticeCellTypesNotes28Tests.)
    /// ★ RE-PINNED (362, his 11-25 "Sure"): this catalog is the OLD run's (variant page, Optimize's lattice, STL parts),
    /// which keeps the octet only until it moves to the new engine; the six struts core runs read `oldRunPending` here.
    func testTheLinkedCoreOffersEveryStrutTypeItRuns() {
        let e = LatticeTypeCatalog.entriesFromCore()
        XCTAssertEqual(e.filter(\.offered).map(\.id), ["octet"], "★ the old run: the octet only")
        for id in ["sc", "bcc", "fcc", "diamond", "kelvin", "rhombic"] {
            XCTAssertEqual(e.first { $0.id == id }?.reason, LatticeTypeCatalog.oldRunPending, id)
            XCTAssertTrue(TopOptKit.jobSchemaAcceptsTopology(id), "★ core runs \(id)")
        }
        for id in ["gyroid", "schwarz_d"] {
            XCTAssertEqual(e.first { $0.id == id }?.reason, LatticeTypeCatalog.jobRefused, id)
        }
        for id in ["bccz", "fccz", "reentrant"] {
            XCTAssertEqual(e.first { $0.id == id }?.reason, "Not buildable or strength-checked yet", id)
        }
        XCTAssertTrue(TopOptKit.jobSchemaAcceptsTopology("octet"), "the control")
        // ★ RE-PINNED (notes28 sheets, builder C): the sheets' batch shipped on the NEW engine only; the old run's gate
        // (`oldRunBatches`, `batchShipped`) is the strut types, so this old-run catalog is as it was
        XCTAssertEqual(LatticeTypeCatalog.appBatches, ["octet", "sc", "bcc", "fcc", "diamond", "kelvin", "rhombic",
                                                       "bccz", "fccz", "reentrant", "gyroid", "schwarz_d"])
        // ★ notes30 M1 (the merge): the old run's own set is his 11-25 "Sure" (the octet only); a sheet is never on it
        XCTAssertEqual(LatticeTypeCatalog.oldRunBatches, ["octet"])
        XCTAssertEqual(LatticeSetupWizard.offeredTypeIDs, ["octet"])
        // RED CONTROL: the stand-in opening every gate offers the seven core builds, certifies and runs (a sheet: never)
        LatticeTypeCatalog.appBatchesForTests = LatticeTypeCatalog.appBatches
        defer { LatticeTypeCatalog.appBatchesForTests = nil }
        XCTAssertEqual(LatticeTypeCatalog.entriesFromCore().filter(\.offered).map(\.id),
                       ["octet", "sc", "bcc", "fcc", "diamond", "kelvin", "rhombic"])
    }

    /// ★ Both pickers read the one catalog, and neither can write a type it does not offer.
    func testBothPickersReadTheCatalogAndNeverPickAGreyedType() throws {
        let wiz = try src("LatticeSetupWizard.swift"), page = try src("LatticePage.swift")
        // ★ RE-PINNED (B7 slice 2): the Lattice page draws the OFFERED types only (a label card, or big cards)
        // ★ RE-PINNED (notes28): the Lattice stage reads its own catalog (the new engine's, `stageEntries`), and draws the
        // offered types plus the Aesthetic-only three greyed with their caption — a greyed card's tap says why, never picks
        XCTAssertTrue(wiz.contains("LatticeTypeCatalog.stageEntries(structural:")
                      && wiz.contains("let entries = typeEntries")
                      && wiz.contains("let shown = entries.filter { $0.offered || Self.typeShownGreyed($0) }")
                      && wiz.contains("ForEach(shown) { e in typeCard(e, fixesStale: stale != nil) }"),
                      "the Lattice page's cards")
        XCTAssertTrue(wiz.contains("guard e.offered else { typeReason = LatticeTypeCatalog.line(e); return }"),
                      "★ a greyed card says why and is never picked")
        XCTAssertTrue(page.contains("private var topologyEntries: [LatticeTypeEntry] {\n        LatticeTypeCatalog.stageEntries(structural: (project.lattice.stageMode ?? .structural) == .structural, newEngine: false)"),
                      "the page's pane (★ notes28: the old run's facts with the stage's Structural rules)")
        XCTAssertTrue(page.contains("guard e.offered else { return }\n            // ★ notes28")
                      && page.contains("project.lattice = LatticeTypeChange.applied(project.lattice, to: e.id,"),
                      "★ the page never writes a greyed type")
        XCTAssertFalse(wiz.contains("ForEach(entries) {"), "★ a type the stage can't use is drawn only greyed, so never picked")
        XCTAssertFalse(try src("LatticeTypeCatalog.swift").contains("topologyID ="), "the catalog writes nothing")
    }
}
