import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★★ MAINTAINER, 2026-10-02, ITEM (a): "LatticeType.named() silently returning octet for an
/// unknown id: fix it now … It returns nil (or refuses), and each caller handles that. The two
/// WorkspacePlaceholder misroutes are exactly why." Every check below is on KELVIN — an id core
/// knows (it certifies it) and the Swift strut table does not carry — where the old fallback
/// gave octet's struts, strut law, aesthetic cap and core limits under Kelvin's name.
final class LatticeNamedNoOctetFallbackTests: XCTestCase {

    private func src(_ f: String) throws -> String {
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        return try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/\(f)"), encoding: .utf8)
    }

    /// The table resolves its own ids — octet included, so no octet result moves — and nothing else.
    func testTheLookupResolvesItsOwnIdsAndNothingElse() throws {
        XCTAssertEqual(LatticeType.named("octet"), .octet)
        for t in LatticeType.family { XCTAssertEqual(LatticeType.named(t.id), t, t.id) }
        for id in ["kelvin", "rhombic", "gyroid", "schwarz_d", "reentrant", "", "lattice9"] {
            XCTAssertNil(LatticeType.named(id), "★ \(id): never octet in disguise")
        }
    }

    /// A Kelvin graded job carries no octet cap (`max_relative_density` is octet's alone).
    /// ★ 2026-10-03 (the one guard): core gives Kelvin no numbers until it is live — its
    /// limits come back with core's readiness words, never octet's floor — so no Kelvin job
    /// is built at all, even when a caller claims it is generatable: nothing octet can ride.
    func testAKelvinJobCarriesNoOctetCap() throws {
        var lat = LatticeSettings(enabled: true, topologyID: "kelvin")
        lat.densityMode = .sim
        let limits = TopOptKit.latticeLimits(topology: "kelvin")
        XCTAssertFalse(limits.certifiable, "★ core gives a non-live type no numbers")
        XCTAssertEqual([limits.rhoMin, limits.rhoMax, limits.minCellsPerMember], [0, 0, 0],
                       "★ and never octet's band or floor")
        XCTAssertTrue(limits.reason?.contains("not buildable") ?? false, limits.reason ?? "nil")
        XCTAssertNil(lat.runSpec(limits: limits, generatable: true, lineWidthMM: 0.45),
                     "★ no Kelvin job, so no octet cap can ride one")
        // control: octet still carries its cap
        var oct = lat; oct.topologyID = "octet"
        let o = try XCTUnwrap(oct.runSpec(limits: TopOptKit.latticeLimits(topology: "octet"),
                                          generatable: true, lineWidthMM: 0.45))
        XCTAssertGreaterThan(o.densityCapRho, 0)
    }

    /// The bounds' reasons never quote octet's printability floor or strut width for Kelvin.
    func testKelvinBoundsQuoteNoOctetLaw() throws {
        var lat = LatticeSettings(enabled: true, topologyID: "kelvin")
        lat.cellMM = 2.0
        let b = LatticeBounds.compute(settings: lat, limits: TopOptKit.latticeLimits(topology: "kelvin"),
                                      lineWidthMM: 0.45)
        XCTAssertEqual(b.strutRadiusMM, 0, "★ no strut law: no strut width")
        XCTAssertNil(b.strutReason)
        XCTAssertFalse(b.densityLoReason?.contains("extrusion") ?? false, "★ no octet printability floor")
        // control: octet at 2 mm and a 0.45 mm bead does carry the floor
        var oct = lat; oct.topologyID = "octet"
        let o = LatticeBounds.compute(settings: oct, limits: TopOptKit.latticeLimits(topology: "octet"),
                                      lineWidthMM: 0.45)
        XCTAssertGreaterThan(o.strutRadiusMM, 0)
    }

    /// The preview draws no Kelvin-labelled octet struts; the proxy has no law; the wizard sample
    /// is empty.
    func testThePreviewDrawsNothingForATypeWithNoTable() throws {
        XCTAssertNil(LatticeSDFPreview(latticeID: "kelvin"))
        XCTAssertNotNil(LatticeSDFPreview(latticeID: "octet"))
        XCTAssertNil(LatticeProxyParams(latticeID: "kelvin").lattice)
        var m = LatticeWizardModel(settings: LatticeSettings(enabled: true, topologyID: "kelvin"))
        m.stage = .cell
        XCTAssertNil(m.lattice)
        XCTAssertEqual(m.stageTriangleCount, 0)
        XCTAssertEqual(m.stageMesh().indices.count, 0, "★ an empty sample, never an octet cell")
    }

    /// The face card asks core by the RAW id: Kelvin's card is core's answer for "kelvin",
    /// not octet's.
    func testTheFaceCardAsksCoreByTheRawID() throws {
        func card(_ id: String) -> LatticeFaceCard {
            LatticeFaceCardDerivation.card(faceID: 1, depthMM: 12, heldVoxels: 500, spacingMM: 1,
                                           densityGCM3: 1.24, topologyID: id, minExtrudableWidthMM: 0.45)
        }
        XCTAssertNotEqual(card("kelvin"), card("octet"), "★ Kelvin's card is not octet's")
    }

    /// The two workspace misroutes and the run report read the raw id.
    func testTheMisroutesAndTheReportReadTheRawID() throws {
        let ws = try src("WorkspacePlaceholder.swift")
        XCTAssertFalse(ws.contains(".lattice.lattice.id"), "★ misroute 1: limits by the resolved type")
        XCTAssertTrue(ws.contains("let limits = TopOptKit.latticeLimits(topology: project.lattice.topologyID)"))
        XCTAssertFalse(ws.contains("let topology = project.lattice.lattice\n"), "★ misroute 2: the card by the resolved type")
        XCTAssertTrue(ws.contains("densityGCM3: densityGCM3, topologyID: topologyID,"))
        XCTAssertTrue(try src("ResultsModel.swift").contains("let name = LatticeType.displayName(forID: r.topologyID)"))
        XCTAssertEqual(LatticeType.displayName(forID: "rhombic"), "Rhombic dodecahedron")
    }
}
