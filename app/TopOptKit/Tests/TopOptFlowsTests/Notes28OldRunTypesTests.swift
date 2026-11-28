// Notes28OldRunTypesTests — his "Sure" (2026-11-25, 362's question): the OLD run (a Topology result's lattice on the variant
// page, Optimize with a lattice grown inside, an STL part's Lattice button) keeps the OCTET only until it moves to the new
// engine; the other strut types are offered only where the new engine makes the lattice (the Lattice stage on a STEP part).
import XCTest
@testable import TopOptFlows

final class Notes28OldRunTypesTests: XCTestCase {

    override func tearDown() {
        LatticeTypeCatalog.appBatchesForTests = nil
        super.tearDown()
    }

    /// ★ The old run's gate: the octet only.
    func testTheOldRunKeepsTheOctetOnly() {
        LatticeTypeCatalog.appBatchesForTests = nil
        XCTAssertTrue(LatticeTypeCatalog.oldRunShipped("octet"))
        for id in ["sc", "bcc", "fcc", "diamond", "kelvin", "rhombic", "bccz", "fccz", "reentrant"] {
            XCTAssertTrue(LatticeTypeCatalog.batchShipped(id), "\(id): the new engine's gate is open (notes28)")
            XCTAssertFalse(LatticeTypeCatalog.oldRunShipped(id), "★ \(id): not on the old run")
        }
    }

    /// ★ The old run's catalog (the variant page, Optimize's lattice): a new-engine type is greyed with its own line, never
    /// the "later update" line (its batch HAS shipped, on the new engine).
    func testTheOldCatalogGreysTheNewTypesWithItsOwnLine() {
        LatticeTypeCatalog.appBatchesForTests = nil
        let old = LatticeTypeCatalog.entries(generatable: ["octet", "kelvin", "sc"], certifiable: ["octet", "kelvin", "sc"],
                                             jobAccepts: { _ in true },
                                             appReady: { LatticeTypeCatalog.batchShipped($0) && LatticeTypeCatalog.oldRunShipped($0) },
                                             pending: { LatticeTypeCatalog.batchShipped($0)
                                                 ? LatticeTypeCatalog.oldRunPending : LatticeTypeCatalog.appBatchPending })
        XCTAssertEqual(old.first { $0.id == "octet" }?.offered, true)
        let kelvin = old.first { $0.id == "kelvin" }
        XCTAssertEqual(kelvin?.offered, false, "★ kelvin is not offered where the old run makes the lattice")
        XCTAssertEqual(kelvin?.reason, LatticeTypeCatalog.oldRunPending)
        XCTAssertEqual(old.first { $0.id == "sc" }?.reason, LatticeTypeCatalog.oldRunPending)
    }

    /// RED CONTROL: with the test stand-in opening the gate, the old run offers what the stand-in names (so a test that
    /// opens or closes the gate still drives every picker).
    func testTheStandInStillDrivesTheOldRunGate() {
        LatticeTypeCatalog.appBatchesForTests = ["octet", "kelvin"]
        XCTAssertTrue(LatticeTypeCatalog.oldRunShipped("kelvin"), "RED CONTROL: the stand-in opens kelvin on the old run")
        XCTAssertFalse(LatticeTypeCatalog.oldRunShipped("sc"))
    }
}
