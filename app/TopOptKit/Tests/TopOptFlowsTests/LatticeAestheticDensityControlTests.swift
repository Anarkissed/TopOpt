import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★ THE PER-FACE DENSITY CONTROL, AESTHETIC ONLY (his spec, 2026-08-24 evening):
/// "The low end should be the printable limit… The upper limit is making it a
/// solid." Structural keeps core's certifiable band — no certificate exists
/// outside it.
final class LatticeAestheticDensityControlTests: XCTestCase {

    @MainActor private func project(mode: LatticeStageMode) -> ProjectModel {
        let p = ProjectModel(id: UUID(), name: "t", material: "ABS",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.lattice.enabled = true
        p.lattice.stageMode = mode
        return p
    }

    @MainActor func testAestheticClampIsPrintableFloorToSolid() {
        let p = project(mode: .aesthetic)
        let ref = LatticeSelectableRef.face(group: UUID(), face: FaceID(1))
        let bead = p.printParams.strutLineWidthMM
        // A 2.0 mm cell has a REAL floor (~20% at a 0.45 bead) — a big cell's
        // floor is ~0 and would make this test vacuous.
        let floor = LatticeType.named(p.lattice.topologyID)
            .printabilityDensityFloor(lineWidthMM: bead, cellMM: 2.0)
        XCTAssertGreaterThan(floor, 0.05)
        // Below the printable floor clamps UP to it…
        p.writeLatticeDensity(ref, fraction: 0.001, cellMM: 2.0)
        XCTAssertEqual(p.lattice.selectableDensity[ref.key] ?? 0, floor,
                       accuracy: 1e-9)
        // …and SOLID is reachable — the certifiable rhoMax must not cap it.
        p.writeLatticeDensity(ref, fraction: 1.0, cellMM: 2.0)
        XCTAssertEqual(p.lattice.selectableDensity[ref.key] ?? 0, 1.0,
                       accuracy: 1e-9)
    }

    @MainActor func testStructuralKeepsTheCertifiableBand() {
        let p = project(mode: .structural)
        let ref = LatticeSelectableRef.face(group: UUID(), face: FaceID(1))
        let limits = TopOptKit.latticeLimits(topology: p.lattice.topologyID)
        p.writeLatticeDensity(ref, fraction: 1.0, cellMM: 2.0)
        XCTAssertEqual(p.lattice.selectableDensity[ref.key] ?? 0, limits.rhoMax,
                       accuracy: 1e-9, "structural must stay certifiable")
    }
}
