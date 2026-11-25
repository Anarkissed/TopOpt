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
        // ★ RE-PINNED (notes28, 2026-11-24): Kelvin, Rhombic and Re-entrant resolve to THEIR OWN types now — built from the engine's own
        // cell (core's lattice_strut_cell), with core's measured law — never the octet; a type core has no cell for is nil
        for id in ["kelvin", "rhombic", "reentrant"] {
            let t = LatticeType.named(id)
            XCTAssertEqual(t?.id, id, "★ \(id): its own type")
            XCTAssertNotEqual(t?.struts, LatticeType.octet.struts, "★ \(id): never octet in disguise")
        }
        for id in ["gyroid", "schwarz_d", "", "lattice9"] {
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
        // ★ RE-PINNED (release (2), E2): core makes Kelvin live with ITS OWN band (measured law), so a Kelvin spec
        // exists when a caller states it generatable — and still carries no octet cap and never octet's band.
        let octet = TopOptKit.latticeLimits(topology: "octet")
        XCTAssertTrue(limits.certifiable, "core certifies Kelvin now")
        XCTAssertNotEqual([limits.rhoMin, limits.rhoMax], [octet.rhoMin, octet.rhoMax], "★ never octet's band")
        let k = try XCTUnwrap(lat.runSpec(limits: limits, generatable: true, lineWidthMM: 0.45))
        // ★ RE-PINNED (notes28, 2026-11-24): Kelvin has its own strut law now (`LatticeType.named`), whose look cap is "none"
        // (1: only the octet carries one, his ruling), as every non-octet type with a law always had — so the cap the JOB
        // WRITES (`densityCapWritten`: 0 = none) is what is pinned. Kelvin's batch shipped too: the app runs Kelvin's own spec.
        XCTAssertEqual(k.densityCapWritten, 0, "★ no octet cap rides a Kelvin job")
        XCTAssertEqual(k.densityCapRho, 1, "Kelvin's own law: no cap")
        XCTAssertEqual(try XCTUnwrap(lat.runSpec(lineWidthMM: 0.45)).densityCapWritten, 0, "★ Kelvin's own run: no octet cap")
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
        // ★ RE-PINNED (notes28, 2026-11-24): Kelvin has its OWN strut law now (the engine's cell, core's measured table), so
        // its bounds carry Kelvin's strut — never the octet's; an id with no law (no type core knows) carries none
        var oct = lat; oct.topologyID = "octet"
        let o = LatticeBounds.compute(settings: oct, limits: TopOptKit.latticeLimits(topology: "octet"),
                                      lineWidthMM: 0.45)
        XCTAssertGreaterThan(o.strutRadiusMM, 0, "control: octet at 2 mm and a 0.45 mm bead carries its strut")
        XCTAssertGreaterThan(b.strutRadiusMM, 0, "★ Kelvin's own strut")
        XCTAssertNotEqual(b.strutRadiusMM, o.strutRadiusMM, accuracy: 1e-9, "★ never the octet's strut under Kelvin's name")
        var re = lat; re.topologyID = "lattice9"
        let r = LatticeBounds.compute(settings: re, limits: TopOptKit.latticeLimits(topology: "lattice9"), lineWidthMM: 0.45)
        XCTAssertEqual(r.strutRadiusMM, 0, "★ no strut law: no strut width")
        XCTAssertNil(r.strutReason)
        XCTAssertFalse(r.densityLoReason?.contains("extrusion") ?? false, "★ no octet printability floor")
    }

    /// The preview draws no Kelvin-labelled octet struts; the proxy has no law; the wizard sample
    /// is empty.
    func testThePreviewDrawsNothingForATypeWithNoTable() throws {
        // ★ RE-PINNED (notes28, 2026-11-24): Kelvin has a table now — the engine's own cell — so the type with none is
        // a sheet (Gyroid: no strut cell); Kelvin's preview draws Kelvin's struts, never the octet's
        XCTAssertNil(LatticeSDFPreview(latticeID: "gyroid"))
        XCTAssertNotNil(LatticeSDFPreview(latticeID: "octet"))
        XCTAssertEqual(LatticeSDFPreview(latticeID: "kelvin")?.lattice.id, "kelvin")
        XCTAssertNotEqual(LatticeSDFPreview(latticeID: "kelvin")?.segments, LatticeSDFPreview(latticeID: "octet")?.segments)
        XCTAssertNil(LatticeProxyParams(latticeID: "gyroid").lattice)
        let m = LatticeWizardModel(settings: LatticeSettings(enabled: true, topologyID: "gyroid"))
        XCTAssertNil(m.lattice, "★ no octet cell under another name (B8: the sample that drew it is deleted)")
        XCTAssertEqual(LatticeWizardModel(settings: LatticeSettings(enabled: true, topologyID: "kelvin")).lattice?.id, "kelvin")
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
