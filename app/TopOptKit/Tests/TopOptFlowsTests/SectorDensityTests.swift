// SectorDensityTests.swift — the per-region density override, app side (task
// 2026-08-16-per-sector-density-override, §3 / bars R1, R4, R5).
//
// The one behaviour under test is the one the whole task exists for: TWO REGIONS
// AT THE SAME DEPTH CAN CARRY DIFFERENT DENSITIES, and a project that dials
// nothing emits the byte-identical job it always did.

import XCTest
import simd
@testable import TopOptFlows
import TopOptKit

final class SectorDensityTests: XCTestCase {

    // A derivation stub standing in for core, so the model's own logic is tested
    // without a bridge call. The REAL derivation is exercised separately below.
    private func stub(cell: Double = 2.0, derived: Double = 0.14,
                      rhoMax: Double = 0.9, prints: Bool = true)
        -> (String, Double, Double, Double) -> TopOptKit.LatticeRegionDerivation {
        { _, extent, _, stated in
            let rho = stated > 0 ? stated : derived
            return .init(valid: extent > 0, feasible: extent > 0, cellMM: cell,
                         derivedRelativeDensity: derived, rhoMax: rhoMax,
                         relativeDensity: rho, strutMM: rho * cell,
                         cellsPerMember: extent / cell, outOfRegime: false,
                         prints: prints)
        }
    }

    private func group(_ name: String) -> SelectionGroup {
        SelectionGroup(id: UUID(), name: name, colorIndex: 0, faces: [])
    }

    private func faceRegion(depth: Double) -> LatticeRegionSpec {
        var s = LatticeRegionSpec(role: .include, kind: .face)
        s.origin = .zero; s.normal = SIMD3(0, 0, -1)
        s.halfUMM = 20; s.halfWMM = 20; s.depthMM = depth
        return s
    }

    // ── THE HEADLINE. Two regions, SAME depth, different densities. ───────────
    func testTwoSectorsAtTheSameDepthCarryDifferentDensities() {
        let a = group("Sector A"), b = group("Sector B")
        let densities = [a.id: 0.25, b.id: 0.40]
        let rows = LatticeSectorDensity.rows(
            groups: [a, b], roles: [a.id: .include, b.id: .include],
            densities: densities,
            regionsFor: { _ in [self.faceRegion(depth: 7.5)] },
            topology: "octet", minExtrudableWidthMM: 0.42, derive: stub())
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].extentMM, rows[1].extentMM,
                       "the two sectors are at the SAME depth — that is the point")
        XCTAssertEqual(rows[0].derivation.relativeDensity, 0.25, accuracy: 1e-12)
        XCTAssertEqual(rows[1].derivation.relativeDensity, 0.40, accuracy: 1e-12)
        XCTAssertNotEqual(rows[0].derivation.strutMM, rows[1].derivation.strutMM,
                          "different densities ⇒ different struts at the same cell")
        XCTAssertEqual(rows[0].derivation.cellMM, rows[1].derivation.cellMM,
                       "and the CELL is unchanged: this dials density, not cell")
    }

    // ── R1. AUTO IS ABSENCE, NOT A NUMBER. ───────────────────────────────────
    func testAutoWritesNothingAndEmitsNoKey() {
        let a = group("Sector A")
        let rows = LatticeSectorDensity.rows(
            groups: [a], roles: [a.id: .include], densities: [:],
            regionsFor: { _ in [self.faceRegion(depth: 7.5)] },
            topology: "octet", minExtrudableWidthMM: 0.42, derive: stub())
        XCTAssertTrue(rows[0].isAuto)
        XCTAssertNil(rows[0].stated)
        XCTAssertEqual(rows[0].derivation.relativeDensity, 0.14, accuracy: 1e-12,
                       "an auto row shows the density CORE will derive")

        // …and the wire carries no key at all.
        var spec = faceRegion(depth: 7.5)
        XCTAssertNil(spec.relativeDensity)
        XCTAssertNil(spec.wireDictionary["relative_density"],
                     "★ no override ⇒ no key ⇒ the job is byte-identical (bar R1)")
        spec.relativeDensity = 0.25
        XCTAssertEqual(spec.wireDictionary["relative_density"] as? Double, 0.25)
    }

    // A zero or non-finite stored value is "nothing stated", never a density —
    // core's sentinel for derive is exactly `<= 0`.
    func testZeroAndNonFiniteAreNotDensities() {
        let a = group("A"), b = group("B")
        let rows = LatticeSectorDensity.rows(
            groups: [a, b], roles: [a.id: .include, b.id: .include],
            densities: [a.id: 0, b.id: .nan],
            regionsFor: { _ in [self.faceRegion(depth: 7.5)] },
            topology: "octet", minExtrudableWidthMM: 0.42, derive: stub())
        XCTAssertTrue(rows.allSatisfy(\.isAuto))
        XCTAssertNil(LatticeRegionEmission.density(for: a.id, role: .include,
                                                   densities: [a.id: 0]))
        XCTAssertNil(LatticeRegionEmission.density(for: b.id, role: .include,
                                                   densities: [b.id: .nan]))
    }

    // ── THE GATE. Only an include region can carry a density. ────────────────
    func testExcludeRegionsCarryNoDensityAndGetNoRow() {
        let a = group("Frozen boss")
        XCTAssertNil(LatticeRegionEmission.density(for: a.id, role: .exclude,
                                                   densities: [a.id: 0.4]),
                     "an exclude region is frozen solid — there is no lattice to set")
        let rows = LatticeSectorDensity.rows(
            groups: [a], roles: [a.id: .exclude], densities: [a.id: 0.4],
            regionsFor: { _ in [self.faceRegion(depth: 7.5)] },
            topology: "octet", minExtrudableWidthMM: 0.42, derive: stub())
        XCTAssertTrue(rows.isEmpty, "no row either — the control never offers it")
    }

    // ── R4. A DENSITY CORE WILL REFUSE IS NAMED BEFORE THE RUN. ──────────────
    func testUnprintableAndOutOfBandDensitiesAreRefusedInTheUI() {
        let a = group("Sector A")
        let tooLight = LatticeSectorDensity.rows(
            groups: [a], roles: [a.id: .include], densities: [a.id: 0.06],
            regionsFor: { _ in [self.faceRegion(depth: 7.5)] },
            topology: "octet", minExtrudableWidthMM: 0.42,
            derive: stub(prints: false))
        XCTAssertNotNil(tooLight[0].refusal)
        XCTAssertTrue(tooLight[0].refusal!.contains("14"),
                      "★ the refusal NAMES the lightest that prints, so the user "
                      + "has a number to type: \(tooLight[0].refusal!)")
        XCTAssertEqual(LatticeSectorDensity.refusals(tooLight).count, 1)
        XCTAssertEqual(LatticeSectorDensity.refusals(tooLight)[0].name, "Sector A")

        let tooHeavy = LatticeSectorDensity.rows(
            groups: [a], roles: [a.id: .include], densities: [a.id: 0.98],
            regionsFor: { _ in [self.faceRegion(depth: 7.5)] },
            topology: "octet", minExtrudableWidthMM: 0.42, derive: stub())
        XCTAssertTrue(tooHeavy[0].refusal?.contains("band") ?? false)

        // A legal one is silent.
        let ok = LatticeSectorDensity.rows(
            groups: [a], roles: [a.id: .include], densities: [a.id: 0.25],
            regionsFor: { _ in [self.faceRegion(depth: 7.5)] },
            topology: "octet", minExtrudableWidthMM: 0.42, derive: stub())
        XCTAssertNil(ok[0].refusal)
        XCTAssertTrue(LatticeSectorDensity.refusals(ok).isEmpty)
    }

    // ── The extent mirrors core's own reader, line for line. ─────────────────
    func testThinnestExtentMirrorsCore() {
        // core: face  → min(depth, 2·half_u, 2·half_w)
        var f = LatticeRegionSpec(role: .include, kind: .face)
        f.depthMM = 7.5; f.halfUMM = 20; f.halfWMM = 1.5
        XCTAssertEqual(LatticeSectorDensity.thinnestExtentMM(f), 3.0,
                       "2·half_w binds here, not the depth")
        f.halfWMM = 20
        XCTAssertEqual(LatticeSectorDensity.thinnestExtentMM(f), 7.5)
        // core: bolt  → min(2·radius, 2·half_length)
        var b = LatticeRegionSpec(role: .include, kind: .bolt)
        b.radiusMM = 4; b.halfLengthMM = 10
        XCTAssertEqual(LatticeSectorDensity.thinnestExtentMM(b), 8.0)
    }

    // ── The summary says what the page says, in one line. ────────────────────
    func testSummaryDistinguishesAutoFromDialled() {
        let a = group("A"), b = group("B")
        let roles: [UUID: LatticeGroupRole] = [a.id: .include, b.id: .include]
        let regions: (UUID) -> [LatticeRegionSpec] = { _ in [self.faceRegion(depth: 7.5)] }
        let auto = LatticeSectorDensity.rows(groups: [a, b], roles: roles, densities: [:],
                                             regionsFor: regions, topology: "octet",
                                             minExtrudableWidthMM: 0.42, derive: stub())
        XCTAssertEqual(LatticeSectorDensity.summary(auto), "auto · 2 regions",
                       "an untouched project must read as normal, not as a gap")
        let mixed = LatticeSectorDensity.rows(groups: [a, b], roles: roles,
                                              densities: [a.id: 0.25],
                                              regionsFor: regions, topology: "octet",
                                              minExtrudableWidthMM: 0.42, derive: stub())
        XCTAssertEqual(LatticeSectorDensity.summary(mixed), "1 of 2 dialled")
        let both = LatticeSectorDensity.rows(groups: [a, b], roles: roles,
                                             densities: [a.id: 0.25, b.id: 0.40],
                                             regionsFor: regions, topology: "octet",
                                             minExtrudableWidthMM: 0.42, derive: stub())
        XCTAssertEqual(LatticeSectorDensity.summary(both), "25–40% across 2 regions")
        XCTAssertEqual(LatticeSectorDensity.summary([]), "no latticed regions")
    }

    // ── R5. THE VALID RANGE AND EVERY NUMBER BESIDE THE FIELD ARE CORE'S. ────
    // Not a stub: this calls the real bridge, and asserts it agrees with the
    // OTHER core-backed reading the page already trusts. An app-side octet law
    // was 1.4x off core's once; this is what stops a second one.
    func testDerivationComesFromCoreAndAgreesWithTheCellBounds() {
        let w = 0.42
        let d = TopOptKit.latticeRegionDerivation(
            topology: "octet", memberWidthMM: 13.6422, minExtrudableWidthMM: w)
        XCTAssertTrue(d.valid); XCTAssertTrue(d.feasible)
        let bounds = TopOptKit.latticeCellBounds(topology: "octet",
                                                 minExtrudableWidthMM: w)
        XCTAssertTrue(bounds.valid)
        // The derivation IS max(extent / N*, the finest printable cell).
        XCTAssertEqual(d.cellMM,
                       max(13.6422 / bounds.cellsPerMemberFloor,
                           bounds.printabilityFloorDensestMM),
                       accuracy: 1e-9,
                       "★ the field's cell is core's own law, not an app formula")
        XCTAssertEqual(d.cellsPerMember, 13.6422 / d.cellMM, accuracy: 1e-9)
        XCTAssertFalse(d.outOfRegime)
        // Auto ⇒ the density in force IS the derived one, and it prints.
        XCTAssertEqual(d.relativeDensity, d.derivedRelativeDensity, accuracy: 1e-12)
        XCTAssertTrue(d.prints)
        XCTAssertGreaterThan(d.strutMM, 0)
        XCTAssertGreaterThanOrEqual(d.strutMM, w - 1e-9,
                                    "the lightest printable density prints, by definition")

        // A STATED density moves the strut and nothing else.
        let heavy = TopOptKit.latticeRegionDerivation(
            topology: "octet", memberWidthMM: 13.6422, minExtrudableWidthMM: w,
            statedRelativeDensity: 0.60)
        XCTAssertEqual(heavy.cellMM, d.cellMM, accuracy: 1e-12)
        XCTAssertEqual(heavy.cellsPerMember, d.cellsPerMember, accuracy: 1e-12)
        XCTAssertEqual(heavy.relativeDensity, 0.60, accuracy: 1e-12)
        XCTAssertGreaterThan(heavy.strutMM, d.strutMM)
        XCTAssertTrue(heavy.prints)
        XCTAssertEqual(heavy.derivedRelativeDensity, d.derivedRelativeDensity,
                       accuracy: 1e-12,
                       "the DERIVED value is kept beside the stated one — it is "
                       + "the floor of the range the field offers")

        // An unprintable one is reported as such, NOT clamped.
        let light = TopOptKit.latticeRegionDerivation(
            topology: "octet", memberWidthMM: 13.6422, minExtrudableWidthMM: w,
            statedRelativeDensity: 0.06)
        XCTAssertEqual(light.relativeDensity, 0.06, accuracy: 1e-12,
                       "★ NOT clamped — the app reports what core will refuse")
        XCTAssertFalse(light.prints)
        XCTAssertLessThan(light.strutMM, w)

        // The valid range offered by the control is [derived, rho_max], both core's.
        let row = LatticeSectorDensity.Row(id: UUID(), name: "A", extentMM: 13.6422,
                                           stated: nil, derivation: d)
        XCTAssertEqual(row.validRange?.lowerBound, d.derivedRelativeDensity)
        XCTAssertEqual(row.validRange?.upperBound, d.rhoMax)
    }

    // A region too thin to carry a lattice at ANY density says so, and offers no
    // range to type into, rather than showing a number that cannot be honoured.
    func testAnInfeasibleRegionOffersNoRange() {
        let d = TopOptKit.latticeRegionDerivation(
            topology: "octet", memberWidthMM: 0.5, minExtrudableWidthMM: 0.42)
        XCTAssertTrue(d.valid)
        XCTAssertFalse(d.feasible, "0.5 mm cannot carry an octet strut network")
        let row = LatticeSectorDensity.Row(id: UUID(), name: "Sliver", extentMM: 0.5,
                                           stated: 0.3, derivation: d)
        XCTAssertNil(row.validRange)
        XCTAssertEqual(row.readout, "no lattice fits this region")
        XCTAssertEqual(row.refusal, "this region cannot carry a lattice at any density")
    }

    // ── THE RUN IS BLOCKED, NOT MERELY ANNOTATED. ────────────────────────────
    // The page's own design-box precedent: core refuses this job, so the button
    // that would submit it says so, rather than letting the user configure a
    // whole page and meet the refusal at the other end.
    func testARefusableDensityDisablesTheOptimizeButtonAndNamesTheRegion() {
        let ok = LatticeOptimizeSurface.compute(
            baseCanOptimize: true, baseSummary: "s", latticeEnabled: true,
            densityMode: .sim, topologyDisplayName: "Octet", cellMM: 2,
            bounds: nil, running: false, lineWidthMM: 0.42)
        XCTAssertTrue(ok.enabled, "no refusal ⇒ the button is exactly as before")

        let blocked = LatticeOptimizeSurface.compute(
            baseCanOptimize: true, baseSummary: "s", latticeEnabled: true,
            densityMode: .sim, topologyDisplayName: "Octet", cellMM: 2,
            bounds: nil, running: false, lineWidthMM: 0.42,
            densityRefusals: [("Sector A", "0.27 mm strut, under the profile's width")])
        XCTAssertFalse(blocked.enabled)
        XCTAssertTrue(blocked.sub.contains("Sector A"),
                      "★ the reason names the REGION, not a count: \(blocked.sub)")
        XCTAssertTrue(blocked.sub.contains("0.27 mm"), "and carries core's number")

        let two = LatticeOptimizeSurface.compute(
            baseCanOptimize: true, baseSummary: "s", latticeEnabled: true,
            densityMode: .sim, topologyDisplayName: "Octet", cellMM: 2,
            bounds: nil, running: false, lineWidthMM: 0.42,
            densityRefusals: [("A", "too light"), ("B", "too light")])
        XCTAssertTrue(two.sub.contains("and 1 more"),
                      "the rest are counted, never silently dropped: \(two.sub)")
    }

    // ── ONE WIRE ENCODER. The two job builders must not drift again. ─────────
    func testBothJobBuildersUseTheOneRegionEncoder() throws {
        for f in ["RemoteRunner.swift", "RelatticeRunner.swift"] {
            let src = try String(contentsOf: sourceURL(f), encoding: .utf8)
            XCTAssertTrue(src.contains("lat.regions.map { $0.wireDictionary }"),
                          "\(f) encodes regions through the ONE encoder")
            XCTAssertFalse(src.contains("\"half_length_mm\": r.halfLengthMM"),
                           "\(f) no longer carries its own hand-copied region dictionary")
        }
    }

    private func sourceURL(_ name: String) -> URL {
        var u = URL(fileURLWithPath: #filePath)
        u.deleteLastPathComponent(); u.deleteLastPathComponent()
        u.deleteLastPathComponent()
        return u.appendingPathComponent("Sources/TopOptFlows/\(name)")
    }
}
