import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★ SYNTHETIC STRESSES ON UNLOADED WALLS (maintainer, 2026-09-05; Aesthetic only).
final class OrganicSyntheticStressTests: XCTestCase {

    // A 20 × 20 × 20 mm block on a 1 mm grid, one slab region on its −Y wall.
    private static let dims = (20, 20, 20)
    private static let origin = SIMD3<Double>(0, 0, 0)

    private func wall(faceY: Double, normalY: Double, depth: Double = 4,
                      foci: Int? = nil, key: String = "f:wall") -> LatticeRegionSpec {
        var s = LatticeRegionSpec(role: .include, kind: .face)
        s.origin = SIMD3<Double>(10, faceY, 10)
        s.normal = SIMD3<Double>(0, normalY, 0)
        s.halfUMM = 10; s.halfWMM = 10; s.depthMM = depth
        s.syntheticFoci = foci
        s.selectableKey = key
        return s
    }

    /// A field that is loaded everywhere EXCEPT the −Y slab (a uniform axial
    /// stress of 10 MPa), with rounding noise in the slab.
    private func loadedExceptWall() -> [Double] {
        let (nx, ny, nz) = Self.dims
        var t = [Double](repeating: 0, count: 6 * nx * ny * nz)
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx {
            let idx = (k * ny + j) * nx + i
            let y = Double(j) + 0.5
            if y < 4 { t[6 * idx] = 1e-4 * Double((i + k) % 3) }      // dead wall: noise
            else { t[6 * idx + 2] = 10 }                                // zz = 10 MPa
        } } }
        return t
    }

    func testADeadWallIsFilledAndALoadedOneIsLeftAlone() {
        let t = loadedExceptWall()
        let dead = wall(faceY: 0, normalY: 1, key: "f:dead")
        let live = wall(faceY: 20, normalY: -1, key: "f:live")
        let r = OrganicSyntheticStress.inject(tensor: t, dims: Self.dims, originMM: Self.origin,
                                              spacingMM: 1, regions: [dead, live], defaultFoci: 3)
        XCTAssertEqual(r.walls.count, 2)
        let d = r.walls.first { $0.key == "f:dead" }!
        let l = r.walls.first { $0.key == "f:live" }!
        XCTAssertTrue(d.dead, "median \(d.medianVM) of peak \(d.peakVM)")
        XCTAssertFalse(l.dead)
        XCTAssertEqual(d.foci, 3, "the default count when the wall states none")
        XCTAssertEqual(d.voxels, 20 * 20 * 4)
        XCTAssertEqual(d.injected, d.voxels, "a wall that is noise everywhere goes fully synthetic")
        XCTAssertEqual(l.injected, 0)
        // The live half of the field is byte-identical.
        let (nx, ny, nz) = Self.dims
        for k in 0..<nz { for j in 4..<ny { for i in 0..<nx {
            let b = 6 * ((k * ny + j) * nx + i)
            for c in 0..<6 { XCTAssertEqual(r.tensor[b + c], t[b + c]) }
        } } }
        // The dead wall carries a real tensor now: von Mises comparable to the peak,
        // and its principal directions are not all the same (a saddle, not a starburst).
        var vmMax = 0.0, dirs = Set<String>()
        for k in 0..<nz { for j in 0..<4 { for i in 0..<nx {
            let b = 6 * ((k * ny + j) * nx + i)
            let v = OrganicSyntheticStress.vonMises(r.tensor, b)
            vmMax = max(vmMax, v)
            let xx = r.tensor[b], zz = r.tensor[b + 2], zx = r.tensor[b + 5]
            dirs.insert(String(format: "%.0f/%.0f/%.0f", xx.sign == .minus ? -1 : 1,
                               zz.sign == .minus ? -1 : 1, zx.sign == .minus ? -1 : 1))
        } } }
        XCTAssertGreaterThan(vmMax, 0.1 * d.peakVM, "synthetic magnitude \(vmMax) vs peak \(d.peakVM)")
        XCTAssertGreaterThan(dirs.count, 1, "the injected field must vary across the wall")
    }

    func testTheWallsOwnCountWinsOverTheDefaultAndIsClamped() {
        let t = loadedExceptWall()
        let stated = wall(faceY: 0, normalY: 1, foci: 5, key: "f:five")
        let r = OrganicSyntheticStress.inject(tensor: t, dims: Self.dims, originMM: Self.origin,
                                              spacingMM: 1, regions: [stated], defaultFoci: 2)
        XCTAssertEqual(r.walls.first?.foci, 5)
        let over = wall(faceY: 0, normalY: 1, foci: 9, key: "f:nine")
        let r2 = OrganicSyntheticStress.inject(tensor: t, dims: Self.dims, originMM: Self.origin,
                                               spacingMM: 1, regions: [over], defaultFoci: 2)
        XCTAssertEqual(r2.walls.first?.foci, 5, "clamped to the 1…5 range")
        XCTAssertEqual(OrganicSyntheticStress.clampFoci(0), 1)
    }

    /// A LOADED wall is never injected, whatever count it states (his rule,
    /// 2026-09-05: "it should never be able to add foci to loaded walls").
    func testAStatedCountNeverInjectsALoadedWall() {
        let t = loadedExceptWall()
        let live = wall(faceY: 20, normalY: -1, foci: 3, key: "f:live-stated")
        let r = OrganicSyntheticStress.inject(tensor: t, dims: Self.dims, originMM: Self.origin,
                                              spacingMM: 1, regions: [live], defaultFoci: 2)
        let w = r.walls.first!
        XCTAssertFalse(w.dead, "it carries the full load")
        XCTAssertEqual(w.injected, 0)
        XCTAssertEqual(r.tensor, t, "byte-identical")
        XCTAssertTrue(w.statusText.hasPrefix("loaded"), w.statusText)
    }

    func testAnAllZeroFieldTreatsEveryWallAsDead() {
        let (nx, ny, nz) = Self.dims
        let t = [Double](repeating: 0, count: 6 * nx * ny * nz)
        let r = OrganicSyntheticStress.inject(tensor: t, dims: Self.dims, originMM: Self.origin,
                                              spacingMM: 1, regions: [wall(faceY: 0, normalY: 1)],
                                              defaultFoci: 1)
        XCTAssertTrue(r.walls.first?.dead ?? false)
        XCTAssertGreaterThan(r.injectedVoxels, 0)
        XCTAssertNotEqual(r.tensor, t)
    }

    func testExcludeRegionsAndBadInputsAreIgnored() {
        let t = loadedExceptWall()
        var ex = wall(faceY: 0, normalY: 1)
        ex = LatticeRegionSpec(role: .exclude, kind: .face).with(ex)
        let r = OrganicSyntheticStress.inject(tensor: t, dims: Self.dims, originMM: Self.origin,
                                              spacingMM: 1, regions: [ex], defaultFoci: 2)
        XCTAssertTrue(r.walls.isEmpty)
        XCTAssertEqual(r.tensor, t)
        let short = OrganicSyntheticStress.inject(tensor: [1, 2, 3], dims: Self.dims, originMM: Self.origin,
                                                  spacingMM: 1, regions: [wall(faceY: 0, normalY: 1)],
                                                  defaultFoci: 2)
        XCTAssertTrue(short.walls.isEmpty)
    }

    // MARK: settings, emission, drawer, job

    func testSettingsRoundTripAndDefaults() throws {
        var l = LatticeSettings()
        XCTAssertFalse(l.organicSyntheticStresses)
        XCTAssertEqual(l.organicSyntheticFoci, 4, "core's measured recipe")
        XCTAssertTrue(l.selectableSyntheticFoci.isEmpty)
        XCTAssertTrue(l.selectableWallStressFraction.isEmpty)
        l.organicSyntheticStresses = true
        l.organicSyntheticFoci = 3
        l.selectableSyntheticFoci["f:a:1"] = 5
        l.selectableWallStressFraction["f:a:1"] = 0.035
        let data = try JSONEncoder().encode(l)
        let back = try JSONDecoder().decode(LatticeSettings.self, from: data)
        XCTAssertTrue(back.organicSyntheticStresses)
        XCTAssertEqual(back.organicSyntheticFoci, 3)
        XCTAssertEqual(back.selectableSyntheticFoci["f:a:1"], 5)
        XCTAssertEqual(back.selectableWallStressFraction["f:a:1"], 0.035)
        // An older snapshot without the keys decodes to the defaults.
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
        // A wall the bake measured as LOADED refuses the write; unloaded accepts it.
        p.writeLatticeSyntheticFoci(ref, foci: nil)
        p.recordLatticeWallStress([ref.key: 0.26])
        XCTAssertEqual(p.latticeWallLoaded(ref), true)
        p.writeLatticeSyntheticFoci(ref, foci: 3)
        XCTAssertNil(p.latticeSelectableSyntheticFoci(ref), "never foci on a loaded wall")
        p.recordLatticeWallStress([ref.key: 0.035])
        XCTAssertEqual(p.latticeWallLoaded(ref), false)
        p.writeLatticeSyntheticFoci(ref, foci: 3)
        XCTAssertEqual(p.latticeSelectableSyntheticFoci(ref), 3)
        let unmeasured = LatticeSelectableRef.face(group: UUID(), face: 9)
        XCTAssertNil(p.latticeWallLoaded(unmeasured))
    }

    /// The job marks only walls the bake measured as unloaded, only under an organic
    /// Aesthetic lattice with the switch on.
    @MainActor func testTheJobMarksOnlyUnloadedWalls() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        let p = ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        let dead = LatticeSelectableRef.face(group: UUID(), face: 15)
        let live = LatticeSelectableRef.face(group: UUID(), face: 2)
        p.lattice.algorithm = "organic"
        p.lattice.stageMode = .aesthetic
        p.lattice.organicSyntheticStresses = true
        p.recordLatticeWallStress([dead.key: 0.035, live.key: 0.26])
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

    /// Core's contract is per REGION (`synthetic_stress` + `synthetic_foci`); no
    /// grading key exists, and the region keys travel only when the linked core's
    /// schema accepts them — a whole-job probe with a control.
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
        XCTAssertNil(g["organic_synthetic_foci"])
        var region = wall(faceY: 0, normalY: 1, foci: 4)
        region.faceID = 7
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
                                                syntheticFoci: "Auto · 2 · unloaded · 0.4% of peak")
        let i = withFoci.rows.firstIndex { $0.label == "Foci" }
        let d = withFoci.rows.firstIndex { $0.label == "Density" }
        XCTAssertNotNil(i)
        XCTAssertEqual(i, d.map { $0 + 1 }, "Foci sits directly below Density")
        XCTAssertEqual(withFoci.rows[i!].kind, .foci)
        XCTAssertTrue(withFoci.rows[i!].modifiable)
        XCTAssertEqual(withFoci.rows[i!].unit, "")
        XCTAssertNil(withFoci.rows.first { $0.label == "Stress on wall" }, "no bake yet ⇒ no verdict row")
        let measured = LatticeRegionDrawer.make(card: card, depthMM: 5, held: false,
                                                syntheticFoci: "3", wallStress: "unloaded · 3.5% of peak")
        let si = measured.rows.firstIndex { $0.label == "Stress on wall" }
        XCTAssertEqual(si, measured.rows.firstIndex { $0.label == "Foci" }.map { $0 + 1 })
        XCTAssertEqual(measured.rows[si!].kind, .fact)
        XCTAssertEqual(measured.rows[si!].value, "unloaded · 3.5% of peak")
        XCTAssertFalse(measured.rows.first { $0.label == "Foci" }!.disabled)
        let loaded = LatticeRegionDrawer.make(card: card, depthMM: 5, held: false,
                                              syntheticFoci: "—", fociDisabled: true,
                                              wallStress: "loaded · 26% of peak")
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
    /// Copy every geometric field of `other` onto a spec with THIS role/kind.
    func with(_ other: LatticeRegionSpec) -> LatticeRegionSpec {
        var s = self
        s.origin = other.origin; s.normal = other.normal
        s.halfUMM = other.halfUMM; s.halfWMM = other.halfWMM; s.depthMM = other.depthMM
        s.syntheticFoci = other.syntheticFoci; s.selectableKey = other.selectableKey
        s.syntheticStress = other.syntheticStress
        return s
    }
}
