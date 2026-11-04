import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★★ REVIEWER, 2026-10-05, Q3(i) (approved by the maintainer): "use core's floor. With Allow
/// quilt on, that's 1.173 mm at a 0.45 bead. The Sep 14 'about 1.8 mm' rule is retired. Read it
/// from core; don't copy the number."
///
/// The tile floor is core's printable floor at the cap the job writes — composed in the bridge
/// from core's band top and diameter law exactly as grade_lattice does (grading.cpp:184-187,
/// 258-260) — and the preview's tiles and the job's `stepped_min_tile_mm` read the same function.
final class LatticeTileFloorFromCoreTests: XCTestCase {

    private let bead = 0.45

    /// Allow quilt on (no cap): core's uncapped dense floor, the very number `lattice_cell_bounds`
    /// reports as its densest floor. Allow quilt off: the floor at the octet's aesthetic cap,
    /// w / φ(cap, 1) on core's own law — 2.25 mm.
    func testTheFloorIsCoresAtTheJobsCap() throws {
        let open = try XCTUnwrap(LatticeSettings.tileFloorMM(topologyID: "octet", beadMM: bead, allowQuilt: true))
        let densest = TopOptKit.latticeCellBounds(topology: "octet", minExtrudableWidthMM: bead)
            .printabilityFloorDensestMM
        XCTAssertEqual(open, densest, accuracy: 1e-12, "★ Allow quilt on: core's 1.173")
        XCTAssertEqual(open, 1.173, accuracy: 5e-4)

        let cap = try XCTUnwrap(TopOptKit.latticeAestheticDensityCeiling(topology: "octet"))
        let capped = try XCTUnwrap(LatticeSettings.tileFloorMM(topologyID: "octet", beadMM: bead, allowQuilt: false))
        XCTAssertEqual(capped, bead / TopOptKit.latticeStrutDiameterMM(topology: "octet", relativeDensity: cap, cellMM: 1),
                       accuracy: 1e-12, "★ Allow quilt off: w / φ(cap) on core's law")
        XCTAssertEqual(capped, 2.25, accuracy: 1e-6)
        // RED control: the retired rule is neither number
        XCTAssertGreaterThan(abs(4 * bead - open), 0.5)
        XCTAssertGreaterThan(abs(4 * bead - capped), 0.4)
        print("TILE-FLOOR octet bead \(bead): allowQuilt on \(open) off \(capped) (retired 4×bead \(4 * bead))")
    }

    /// A type core does not call live: no number, and core says why — nothing baked on a
    /// made-up floor.
    func testANonLiveTypeHasNoFloor() {
        XCTAssertNil(LatticeSettings.tileFloorMM(topologyID: "kelvin", beadMM: bead, allowQuilt: true))
        XCTAssertTrue(TopOptKit.lastCoreRefusal?.contains(TopOptKit.latticeTypeReadinessPlain(.notGeneratable)) ?? false,
                      TopOptKit.lastCoreRefusal ?? "nil")
        XCTAssertNil(TopOptKit.latticeMinPrintableCellMM(topology: "octet", minExtrudableWidthMM: 0, maxRelativeDensity: 0),
                     "no bead, no floor")
    }

    /// The job's `stepped_min_tile_mm` is the same function at the cap the job itself writes —
    /// with Allow quilt on there is no cap key and the floor is the uncapped one.
    func testTheStructuralSteppedJobSendsTheSameFloor() throws {
        guard TopOptKit.gradingSchemaAccepts(key: "stepped_min_tile_mm") else { throw XCTSkip("core takes no tile floor") }
        for allowQuilt in [false, true] {
            var lat = LatticeSettings(enabled: true)
            lat.densityMode = .sim
            lat.cellMM = 8
            lat.algorithm = "stepped"
            lat.stageMode = .structural
            lat.allowQuilt = allowQuilt
            let spec = try XCTUnwrap(lat.runSpec(limits: TopOptKit.latticeLimits(topology: "octet"),
                                                 generatable: true, lineWidthMM: bead))
            let g = try XCTUnwrap(spec.gradingDictionary())
            let sent = try XCTUnwrap(g["stepped_min_tile_mm"] as? Double, "allowQuilt \(allowQuilt)")
            let floor = try XCTUnwrap(LatticeSettings.tileFloorMM(topologyID: "octet", beadMM: bead, allowQuilt: allowQuilt))
            XCTAssertEqual(sent, floor, "★ one number, one source (allowQuilt \(allowQuilt))")
            XCTAssertEqual(g["max_relative_density"] != nil, !allowQuilt, "the cap key travels exactly when it binds")
        }
    }
}
