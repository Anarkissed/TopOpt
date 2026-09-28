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

    /// ★ THE WALL'S OWN STRESS DECIDES (his walk, 2026-09-07: "One literally has ZERO
    /// stress on it … Why are they saying the same stress MPa?"). Core's synthesis
    /// share answers a different question — how much core replaced, under a threshold
    /// that is 2 % of the PART's peak — and on a lightly loaded part it called a wall
    /// carrying a thousandth of the load "88 % real". The row now carries the wall's
    /// own p99 and its share of the part's peak, and that share is the gate.
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
        // Wall 1 carries the load (p99 = 24 of the part's 31, 77 %); wall 2 carries a
        // spill (0.4 of 31, 1.3 %) — his back wall. Core called BOTH mostly "real".
        let stress: [Int: (p99: Double, max: Double)] = [1: (24, 28), 2: (0.4, 0.9)]
        let walls = OrganicSyntheticStress.wallReports(from: report, plan: plan,
                                                       stressByRegion: stress)
        XCTAssertEqual(walls.count, 2)
        let loaded = walls["f:a"]!, dead = walls["f:b"]!
        XCTAssertFalse(loaded.dead)
        XCTAssertEqual(loaded.stressShare, 24.0 / 31, accuracy: 1e-9)
        XCTAssertTrue(loaded.statusText.hasPrefix("loaded"), loaded.statusText)
        XCTAssertTrue(loaded.statusText.contains("24 MPa"), loaded.statusText)
        // ★ THE ONE THAT WAS REFUSED: core says 96 % of it is real, its own stress says
        // 1.3 % of the part's peak. It is unloaded, and its row says its OWN number.
        XCTAssertEqual(dead.realShare, 1 - (1500 + 40) / 1600.0, accuracy: 1e-9)
        XCTAssertTrue(dead.dead, "1.3 % of the part's peak is spill, not load")
        XCTAssertEqual(dead.stressShare, 0.4 / 31, accuracy: 1e-9)
        XCTAssertTrue(dead.statusText.hasPrefix("unloaded"), dead.statusText)
        XCTAssertTrue(dead.statusText.contains("0.4 MPa"), dead.statusText)
        XCTAssertNotEqual(loaded.statusText, dead.statusText, "★ two walls, two numbers")
        XCTAssertEqual(dead.faceID, 15)
        XCTAssertTrue(OrganicSyntheticStress.wallReports(from: nil, plan: plan).isEmpty)
    }

    /// ★ The per-wall von Mises the row reports, measured from the tracer's own tensor.
    func testEachWallsStressIsMeasuredFromTheTensor() {
        // Two voxels in region 1 at 10/3/1 MPa (von Mises √67), two in region 2 at zero.
        var t = [Double](repeating: 0, count: 6 * 4)
        for i in 0..<2 { t[6 * i] = 10; t[6 * i + 1] = 3; t[6 * i + 2] = 1 }
        let stress = OrganicSyntheticStress.wallStress(tensor: t, regionIDs: [1, 1, 2, 2])
        XCTAssertEqual(stress[1]!.p99, (67.0).squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(stress[1]!.max, (67.0).squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(stress[2]!.p99, 0, accuracy: 1e-12, "a wall with no stress reads zero")
        XCTAssertTrue(OrganicSyntheticStress.wallStress(tensor: [], regionIDs: [1]).isEmpty)
    }

    func testTheConstantsAreTheRuns() {
        XCTAssertEqual(OrganicSyntheticStress.deadFraction, 0.02, "run_job passes 0.02")
        XCTAssertEqual(OrganicSyntheticStress.loadedRealShare, 0.5)
        XCTAssertEqual(OrganicSyntheticStress.loadedStressShare, 0.15,
                       "a wall under 15 % of the part's peak carries spill, not load")
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
        obj.removeValue(forKey: "selectableWallStressShare")
        let old = try JSONDecoder().decode(LatticeSettings.self,
                                           from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertFalse(old.organicSyntheticStresses)
        XCTAssertEqual(old.organicSyntheticFoci, 4)
        XCTAssertTrue(old.selectableSyntheticFoci.isEmpty)
        XCTAssertTrue(old.selectableWallStressFraction.isEmpty)
    }

    /// ★★★ THE STORED NUMBER CHANGED MEANING, SO OLD VALUES MUST NOT BE READ
    /// (2026-09-07). The key used to hold core's SYNTHESIS share (0.8–0.9 on a wall
    /// carrying nothing); it now holds the wall's STRESS share, and "loaded" is 0.15.
    /// Read as-is, every wall in every older project would refuse foci forever.
    @MainActor func testAnOlderProjectsWallNumbersAreNotReadUnderTheNewRule() throws {
        var l = LatticeSettings(enabled: true)
        l.selectableWallStressFraction = ["f:a": 0.87]
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(l)) as? [String: Any])
        XCTAssertNotNil(obj["selectableWallStressShare"], "the new key is what is written")
        XCTAssertNil(obj["selectableWallStressFraction"], "and the old name is not")
        // An older snapshot, carrying core's synthesis share under the OLD key.
        var older = obj
        older.removeValue(forKey: "selectableWallStressShare")
        older["selectableWallStressFraction"] = ["f:a": 0.87, "f:b": 0.83]
        let back = try JSONDecoder().decode(
            LatticeSettings.self, from: JSONSerialization.data(withJSONObject: older))
        XCTAssertTrue(back.selectableWallStressFraction.isEmpty,
                      "★ the old numbers are ignored — the wall reads unmeasured until a bake measures it")
        let p = ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        p.lattice = back
        XCTAssertNil(p.latticeWallLoaded(LatticeSelectableRef.face(group: UUID(), face: 2)),
                     "unmeasured, not loaded — so the foci are offered")
    }

    /// ★ A WALL ON AN IDLE PART IS NOT LOADED (his walk, 2026-09-07). His stand peaks
    /// at 0.024 MPa against 31 MPa allowable; the back wall at 0.004 MPa came back
    /// "loaded" for being 17 % of a very small number.
    func testNoWallIsLoadedWhenThePartItselfCarriesNothing() {
        var w = OrganicSyntheticStress.WallReport(key: "f:b", faceID: 15, voxels: 100,
                                                  fullySynthetic: 0, blended: 0, foci: 4)
        w.partPeakMPa = 0.024; w.wallP99MPa = 0.00411; w.allowableMPa = 31
        XCTAssertEqual(w.stressShare, 0.00411 / 0.024, accuracy: 1e-9)
        XCTAssertGreaterThan(w.stressShare, OrganicSyntheticStress.loadedStressShare,
                             "17 % of the peak — the ranking alone would call it loaded")
        XCTAssertFalse(w.partIsLoaded, "the part peaks at 0.08 % of allowable")
        XCTAssertTrue(w.dead, "★ so it is unloaded and may take foci")
        // ★ the row is two facts now (2026-09-07): the verdict and the wall's stress.
        XCTAssertEqual(w.statusText, "unloaded · 0.00411 MPa")
        // The wall that IS carrying the load on the same idle part: also unloaded.
        var hot = w; hot.wallP99MPa = 0.0203
        XCTAssertTrue(hot.dead, "nothing on an idle part is loaded")
        // …and on a part that IS working, the ranking decides again.
        var real = w
        real.partPeakMPa = 25; real.wallP99MPa = 21
        XCTAssertTrue(real.partIsLoaded)
        XCTAssertFalse(real.dead, "84 % of a real peak is a loaded wall")
        var spill = real; spill.wallP99MPa = 1.0
        XCTAssertTrue(spill.dead, "4 % of a real peak is spill")
        XCTAssertEqual(OrganicSyntheticStress.partLoadedAllowableShare, 0.02)
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
