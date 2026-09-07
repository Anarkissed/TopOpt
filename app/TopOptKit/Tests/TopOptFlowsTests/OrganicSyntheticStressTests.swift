import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★ SYNTHETIC STRESSES ON UNLOADED WALLS (maintainer, 2026-09-05; Aesthetic only).
/// Since 2026-09-06 the preview calls CORE's `synthesize_focal_stress` through the
/// bridge; the app plans the call and reads the report back.
final class OrganicSyntheticStressTests: XCTestCase {

    private static let dims = (20, 20, 20)
    private static let origin = SIMD3<Double>(0, 0, 0)

    private func wall(faceY: Double, normalY: Double, depth: Double = 4,
                      foci: Int? = nil, key: String, faceID: Int? = nil) -> LatticeRegionSpec {
        var s = LatticeRegionSpec(role: .include, kind: .face)
        s.origin = SIMD3<Double>(10, faceY, 10)
        s.normal = SIMD3<Double>(0, normalY, 0)
        s.halfUMM = 10; s.halfWMM = 10; s.depthMM = depth
        // A real emitted face region carries its outline; the mask needs it when a
        // face id is set (a rectangle alone is the primitive's shape, not a face's).
        s.outlineLoops = [[SIMD2(-10, -10), SIMD2(10, -10), SIMD2(10, 10), SIMD2(-10, 10)]]
        s.syntheticFoci = foci
        s.selectableKey = key
        s.faceID = faceID
        return s
    }

    /// The plan numbers include regions 1-based in declaration order, tags each
    /// voxel with the first region holding its centre, and carries the count the
    /// wall states, else the lattice default.
    func testThePlanNumbersRegionsAndTagsVoxels() {
        let a = wall(faceY: 0, normalY: 1, key: "f:a", faceID: 2)
        let b = wall(faceY: 20, normalY: -1, foci: 5, key: "f:b", faceID: 15)
        let plan = OrganicSyntheticStress.plan(regions: [a, b], dims: Self.dims, originMM: Self.origin,
                                               spacingMM: 1, defaultFoci: 4, statedFoci: [:])
        XCTAssertEqual(plan.regionIDs.count, 8000)
        XCTAssertEqual(plan.regionIDs.filter { $0 == 1 }.count, 20 * 20 * 4, "the −Y slab")
        XCTAssertEqual(plan.regionIDs.filter { $0 == 2 }.count, 20 * 20 * 4, "the +Y slab")
        XCTAssertEqual(plan.regionIDs.filter { $0 == 0 }.count, 8000 - 3200)
        XCTAssertEqual(plan.regions.map(\.regionID), [1, 2])
        XCTAssertEqual(plan.regions.map(\.faceID), [2, 15])
        XCTAssertEqual(plan.regions.map(\.foci), [4, 5], "default, then the wall's own")
        XCTAssertEqual(plan.keyByID, [1: "f:a", 2: "f:b"])
        // A Selections-row count overrides the spec's.
        let stated = OrganicSyntheticStress.plan(regions: [a, b], dims: Self.dims, originMM: Self.origin,
                                                 spacingMM: 1, defaultFoci: 4, statedFoci: ["f:a": 2])
        XCTAssertEqual(stated.regions.map(\.foci), [2, 5])
        // Exclude regions and empty inputs plan nothing.
        var ex = a; ex = LatticeRegionSpec(role: .exclude, kind: .face).with(ex)
        XCTAssertTrue(OrganicSyntheticStress.plan(regions: [ex], dims: Self.dims, originMM: Self.origin,
                                                  spacingMM: 1, defaultFoci: 4, statedFoci: [:]).isEmpty)
    }

    /// Core's report comes back keyed to the rows; a wall whose real share is
    /// under a half is UNLOADED, the rest are loaded.
    func testTheReportMapsBackToWalls() {
        let a = wall(faceY: 0, normalY: 1, key: "f:a", faceID: 2)
        let b = wall(faceY: 20, normalY: -1, key: "f:b", faceID: 15)
        let plan = OrganicSyntheticStress.plan(regions: [a, b], dims: Self.dims, originMM: Self.origin,
                                               spacingMM: 1, defaultFoci: 4, statedFoci: [:])
        let report = TopOptKit.OrganicSyntheticReport(
            regions: [
                .init(regionID: 1, faceID: 2, foci: 4, softMM: 5, voxels: 1600, fullySynthetic: 0, blended: 40),
                .init(regionID: 2, faceID: 15, foci: 4, softMM: 5, voxels: 1600, fullySynthetic: 1500, blended: 80),
            ],
            voxelsInRegions: 3200, fullySynthetic: 1500, blended: 120, deadThreshold: 0.02, peakVonMises: 31)
        let walls = OrganicSyntheticStress.wallReports(from: report, plan: plan)
        XCTAssertEqual(walls.count, 2)
        let loaded = walls["f:a"]!, dead = walls["f:b"]!
        XCTAssertFalse(loaded.dead)
        XCTAssertEqual(loaded.realShare, 1 - 20.0 / 1600, accuracy: 1e-9)
        XCTAssertTrue(loaded.statusText.hasPrefix("loaded"), loaded.statusText)
        XCTAssertTrue(dead.dead)
        XCTAssertEqual(dead.syntheticFraction, (1500 + 40) / 1600.0, accuracy: 1e-9)
        XCTAssertTrue(dead.statusText.hasPrefix("unloaded"), dead.statusText)
        XCTAssertEqual(dead.faceID, 15)
        XCTAssertTrue(OrganicSyntheticStress.wallReports(from: nil, plan: plan).isEmpty)
    }

    func testTheConstantsAreTheRuns() {
        XCTAssertEqual(OrganicSyntheticStress.deadFraction, 0.02, "run_job passes 0.02")
        XCTAssertEqual(OrganicSyntheticStress.loadedRealShare, 0.5)
        XCTAssertEqual(OrganicSyntheticStress.clampFoci(0), 1)
        XCTAssertEqual(OrganicSyntheticStress.clampFoci(9), 5)
    }

    // MARK: settings, project, drawer, job

    func testSettingsRoundTripAndDefaults() throws {
        var l = LatticeSettings()
        XCTAssertFalse(l.organicSyntheticStresses)
        XCTAssertEqual(l.organicSyntheticFoci, 4, "core's measured recipe")
        XCTAssertTrue(l.selectableSyntheticFoci.isEmpty)
        XCTAssertTrue(l.selectableWallStressFraction.isEmpty)
        l.organicSyntheticStresses = true
        l.organicSyntheticFoci = 3
        l.selectableSyntheticFoci["f:a:1"] = 5
        l.selectableWallStressFraction["f:a:1"] = 0.1
        let data = try JSONEncoder().encode(l)
        let back = try JSONDecoder().decode(LatticeSettings.self, from: data)
        XCTAssertTrue(back.organicSyntheticStresses)
        XCTAssertEqual(back.organicSyntheticFoci, 3)
        XCTAssertEqual(back.selectableSyntheticFoci["f:a:1"], 5)
        XCTAssertEqual(back.selectableWallStressFraction["f:a:1"], 0.1)
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "organicSyntheticStresses")
        obj.removeValue(forKey: "organicSyntheticFoci")
        obj.removeValue(forKey: "selectableSyntheticFoci")
        obj.removeValue(forKey: "selectableWallStressFraction")
        let old = try JSONDecoder().decode(LatticeSettings.self,
                                           from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertFalse(old.organicSyntheticStresses)
        XCTAssertEqual(old.organicSyntheticFoci, 4)
        XCTAssertTrue(old.selectableSyntheticFoci.isEmpty)
        XCTAssertTrue(old.selectableWallStressFraction.isEmpty)
    }

    @MainActor func testProjectWriteClampsAndClears() {
        let p = ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        let ref = LatticeSelectableRef.face(group: UUID(), face: 3)
        p.writeLatticeSyntheticFoci(ref, foci: 4)
        XCTAssertEqual(p.latticeSelectableSyntheticFoci(ref), 4)
        p.writeLatticeSyntheticFoci(ref, foci: 0)
        XCTAssertNil(p.latticeSelectableSyntheticFoci(ref), "0 clears back to the default")
        p.writeLatticeSyntheticFoci(ref, foci: 7)
        XCTAssertNil(p.latticeSelectableSyntheticFoci(ref), "out of 1…5 is refused, not clamped")
        p.writeLatticeSyntheticFoci(ref, foci: 1)
        XCTAssertEqual(p.latticeSelectableSyntheticFoci(ref), 1)
        // A wall the bake measured as LOADED (real share ≥ ½) refuses the write.
        p.writeLatticeSyntheticFoci(ref, foci: nil)
        p.recordLatticeWallStress([ref.key: 0.9])
        XCTAssertEqual(p.latticeWallLoaded(ref), true)
        p.writeLatticeSyntheticFoci(ref, foci: 3)
        XCTAssertNil(p.latticeSelectableSyntheticFoci(ref), "never foci on a loaded wall")
        p.recordLatticeWallStress([ref.key: 0.1])
        XCTAssertEqual(p.latticeWallLoaded(ref), false)
        p.writeLatticeSyntheticFoci(ref, foci: 3)
        XCTAssertEqual(p.latticeSelectableSyntheticFoci(ref), 3)
        XCTAssertNil(p.latticeWallLoaded(LatticeSelectableRef.face(group: UUID(), face: 9)))
    }

    @MainActor func testTheJobMarksOnlyUnloadedWalls() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        let p = ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        let dead = LatticeSelectableRef.face(group: UUID(), face: 15)
        let live = LatticeSelectableRef.face(group: UUID(), face: 2)
        p.lattice.algorithm = "organic"
        p.lattice.stageMode = .aesthetic
        p.lattice.organicSyntheticStresses = true
        p.recordLatticeWallStress([dead.key: 0.1, live.key: 0.9])
        p.writeLatticeSyntheticFoci(dead, foci: 2)
        XCTAssertEqual(p.latticeSyntheticWalls(), [dead.key: 2])
        p.writeLatticeSyntheticFoci(dead, foci: nil)
        XCTAssertEqual(p.latticeSyntheticWalls(), [dead.key: 4], "the lattice default")
        p.lattice.stageMode = .structural
        XCTAssertTrue(p.latticeSyntheticWalls().isEmpty, "never under Structural")
        p.lattice.stageMode = .aesthetic
        p.lattice.organicSyntheticStresses = false
        XCTAssertTrue(p.latticeSyntheticWalls().isEmpty, "switch off")
    }

    /// Core's per-region keys travel only when the linked core's schema accepts them.
    func testJobKeysArePerRegionAndProbeGated() throws {
        var s = LatticeSpec(topologyID: "octet", cellMM: 6, strutRadiusMM: 0.6,
                            generateRelativeDensity: 0.2, minRelativeDensity: 0.05,
                            maxRelativeDensity: 0.9, graded: true)
        s.algorithm = "organic"
        s.organicSyntheticStresses = true
        s.organicSyntheticFoci = 3
        s.stageMode = .aesthetic
        let g = try XCTUnwrap(s.gradingDictionary())
        XCTAssertNil(g["organic_synthetic_stresses"], "no grading key in core's contract")
        var region = wall(faceY: 0, normalY: 1, foci: 4, key: "f:a", faceID: 7)
        XCTAssertNil(region.wireDictionary["synthetic_stress"], "not marked ⇒ nothing")
        region.syntheticStress = true
        let entry = region.wireDictionary
        XCTAssertEqual(entry["face_id"] as? Int, 7, "the receipt finds the row by face")
        if TopOptKit.organicSyntheticStressWired {
            XCTAssertEqual(entry["synthetic_stress"] as? Bool, true)
            XCTAssertEqual(entry["synthetic_foci"] as? Int, 4)
        } else {
            XCTAssertNil(entry["synthetic_stress"], "★ written to a core that would refuse it")
            XCTAssertNil(entry["synthetic_foci"])
        }
    }

    func testTheDrawerCarriesAFociRowOnlyWhenAsked() {
        let card = LatticeFaceCardDerivation.card(
            faceID: 1, depthMM: 30, heldVoxels: 10_000, spacingMM: 1.705279303, densityGCM3: 1.24,
            topology: LatticeType.octet, minExtrudableWidthMM: 0.45)
        let plain = LatticeRegionDrawer.make(card: card, depthMM: 5, held: false)
        XCTAssertNil(plain.rows.first { $0.label == "Foci" })
        let withFoci = LatticeRegionDrawer.make(card: card, depthMM: 5, held: false,
                                                syntheticFoci: "Auto · 4")
        let i = withFoci.rows.firstIndex { $0.label == "Foci" }
        let d = withFoci.rows.firstIndex { $0.label == "Density" }
        XCTAssertNotNil(i)
        XCTAssertEqual(i, d.map { $0 + 1 }, "Foci sits directly below Density")
        XCTAssertEqual(withFoci.rows[i!].kind, .foci)
        XCTAssertTrue(withFoci.rows[i!].modifiable)
        XCTAssertNil(withFoci.rows.first { $0.label == "Stress on wall" }, "no bake yet ⇒ no verdict row")
        let measured = LatticeRegionDrawer.make(card: card, depthMM: 5, held: false,
                                                syntheticFoci: "3", wallStress: "unloaded · 96% synthetic")
        let si = measured.rows.firstIndex { $0.label == "Stress on wall" }
        XCTAssertEqual(si, measured.rows.firstIndex { $0.label == "Foci" }.map { $0 + 1 })
        XCTAssertEqual(measured.rows[si!].kind, .fact)
        XCTAssertFalse(measured.rows.first { $0.label == "Foci" }!.disabled)
        let loaded = LatticeRegionDrawer.make(card: card, depthMM: 5, held: false,
                                              syntheticFoci: "—", fociDisabled: true,
                                              wallStress: "loaded · 99% real")
        XCTAssertTrue(loaded.rows.first { $0.label == "Foci" }!.disabled, "greyed on a loaded wall")
    }

    func testOrganicNeedsTheStageSolveWhateverTheDensityMode() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        var l = LatticeSettings(); l.enabled = true
        l.simulateStresses = true
        l.densityMode = .uniform
        l.algorithm = "organic"
        XCTAssertTrue(l.isOrganic)
        XCTAssertTrue(l.needsStressSolve, "the part preview traces the stage's tensor")
        l.algorithm = ""
        XCTAssertFalse(l.needsStressSolve)
    }
}

private extension LatticeRegionSpec {
    func with(_ other: LatticeRegionSpec) -> LatticeRegionSpec {
        var s = self
        s.origin = other.origin; s.normal = other.normal
        s.halfUMM = other.halfUMM; s.halfWMM = other.halfWMM; s.depthMM = other.depthMM
        s.syntheticFoci = other.syntheticFoci; s.selectableKey = other.selectableKey
        s.syntheticStress = other.syntheticStress; s.faceID = other.faceID
        return s
    }
}
