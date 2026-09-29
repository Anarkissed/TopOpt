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

    /// ★★ CORE'S VERDICT DECIDES (maintainer, 2026-09-29, ruling 1): a wall core
    /// synthesised is barely loaded; one core left alone carries load — in plain words.
    /// (The app's own share rule that stood here, and its two-number row, are retired.)
    func testTheReportMapsBackToWalls() {
        let a = wall(faceY: 0, normalY: 1, key: "f:a", faceID: 2)
        let b = wall(faceY: 20, normalY: -1, key: "f:b", faceID: 15)
        let plan = OrganicSyntheticStress.plan(regions: [a, b], dims: Self.dims, originMM: Self.origin,
                                               spacingMM: 1, defaultFoci: 4, statedFoci: [:])
        let report = TopOptKit.OrganicSyntheticReport(
            regions: [
                .init(regionID: 1, faceID: 2, foci: 4, softMM: 5, voxels: 1600, fullySynthetic: 0, blended: 0),
                .init(regionID: 2, faceID: 15, foci: 4, softMM: 5, voxels: 1600, fullySynthetic: 1600, blended: 0),
            ],
            voxelsInRegions: 3200, fullySynthetic: 1600, blended: 0, deadThreshold: 0.005, peakVonMises: 31)
        let walls = OrganicSyntheticStress.wallReports(from: report, plan: plan)
        XCTAssertEqual(walls.count, 2)
        let loaded = walls["f:a"]!, dead = walls["f:b"]!
        XCTAssertFalse(loaded.dead, "core left it alone")
        XCTAssertEqual(loaded.statusText, "Carries load")
        XCTAssertTrue(dead.dead, "core synthesised it")
        XCTAssertEqual(dead.statusText, "Barely loaded — a made-up load can be added")
        XCTAssertEqual(dead.faceID, 15)
        XCTAssertTrue(OrganicSyntheticStress.wallReports(from: nil, plan: plan).isEmpty)
    }

    /// ★ A WALL IS ONE ROW however many regions it emits (a curved face's facets, a
    /// region's member faces): core synthesised ANY of them ⇒ barely loaded, whatever
    /// the order. The last region in plan order used to decide it.
    func testAWallCoreSynthesisedInPartIsBarelyLoaded() {
        let plan = OrganicSyntheticStress.Plan(regionIDs: [], regions: [], keyByID: [1: "f:c", 2: "f:c"])
        func rows(_ first: Int, _ second: Int) -> TopOptKit.OrganicSyntheticReport {
            .init(regions: [
                .init(regionID: 1, faceID: 7, foci: 4, softMM: 0, voxels: 100, fullySynthetic: first, blended: 0),
                .init(regionID: 2, faceID: 7, foci: 4, softMM: 0, voxels: 60, fullySynthetic: second, blended: 0)],
                  voxelsInRegions: 160, fullySynthetic: first + second, blended: 0,
                  deadThreshold: 0.005, peakVonMises: 1)
        }
        for (f, s) in [(100, 0), (0, 60)] {
            let w = OrganicSyntheticStress.wallReports(from: rows(f, s), plan: plan)["f:c"]!
            XCTAssertEqual(w.voxels, 160, "the wall's regions are summed")
            XCTAssertTrue(w.dead, "★ core synthesised part of it (\(f), \(s)) — whichever region came last")
        }
        XCTAssertFalse(OrganicSyntheticStress.wallReports(from: rows(0, 0), plan: plan)["f:c"]!.dead)
    }

    func testTheConstantsAreTheRuns() {
        XCTAssertEqual(OrganicSyntheticStress.deadFraction, 0.02, "run_job passes 0.02")
        XCTAssertEqual(OrganicSyntheticStress.clampFoci(0), 1)
        XCTAssertEqual(OrganicSyntheticStress.clampFoci(9), 5)
        XCTAssertEqual(OrganicSyntheticStress.wallWord(loaded: true), "Carries load")
        XCTAssertEqual(OrganicSyntheticStress.wallWord(loaded: false), "Barely loaded — a made-up load can be added")
    }

    // MARK: settings, project, drawer, job

    func testSettingsRoundTripAndDefaults() throws {
        var l = LatticeSettings()
        XCTAssertFalse(l.organicSyntheticStresses)
        XCTAssertEqual(l.organicSyntheticFoci, 4, "core's measured recipe")
        XCTAssertTrue(l.selectableSyntheticFoci.isEmpty)
        XCTAssertTrue(l.selectableWallCoreDead.isEmpty)
        l.organicSyntheticStresses = true
        l.organicSyntheticFoci = 3
        l.selectableSyntheticFoci["f:a:1"] = 5
        l.selectableWallCoreDead["f:a:1"] = true
        let data = try JSONEncoder().encode(l)
        let back = try JSONDecoder().decode(LatticeSettings.self, from: data)
        XCTAssertTrue(back.organicSyntheticStresses)
        XCTAssertEqual(back.organicSyntheticFoci, 3)
        XCTAssertEqual(back.selectableSyntheticFoci["f:a:1"], 5)
        XCTAssertEqual(back.selectableWallCoreDead["f:a:1"], true)
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "organicSyntheticStresses")
        obj.removeValue(forKey: "organicSyntheticFoci")
        obj.removeValue(forKey: "selectableSyntheticFoci")
        obj.removeValue(forKey: "selectableWallCoreDead")
        let old = try JSONDecoder().decode(LatticeSettings.self,
                                           from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertFalse(old.organicSyntheticStresses)
        XCTAssertEqual(old.organicSyntheticFoci, 4)
        XCTAssertTrue(old.selectableSyntheticFoci.isEmpty)
        XCTAssertTrue(old.selectableWallCoreDead.isEmpty)
    }

    /// ★★★ THE STORED VALUE CHANGED MEANING, SO OLD VALUES MUST NOT BE READ — twice now.
    /// 2026-09-07 core's synthesis share gave way to the app's stress share; 2026-09-29
    /// (ruling 1) that gave way to CORE'S VERDICT. An old 0 meant "the app called it
    /// unloaded" — his stand's 0.0203 MPa back wall among them, which core leaves alone —
    /// so neither old key is read: the wall reads unmeasured until a bake asks core.
    @MainActor func testAnOlderProjectsWallNumbersAreNotReadUnderTheNewRule() throws {
        var l = LatticeSettings(enabled: true)
        l.selectableWallCoreDead = ["f:a": false]
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(l)) as? [String: Any])
        XCTAssertNotNil(obj["selectableWallCoreDead"], "the new key is what is written")
        XCTAssertNil(obj["selectableWallStressShare"], "and neither old name is")
        XCTAssertNil(obj["selectableWallStressFraction"])
        // Older snapshots, under BOTH old keys.
        var older = obj
        older.removeValue(forKey: "selectableWallCoreDead")
        older["selectableWallStressShare"] = ["f:a": 0, "f:b": 0.87]
        older["selectableWallStressFraction"] = ["f:a": 0.87, "f:b": 0.83]
        let back = try JSONDecoder().decode(
            LatticeSettings.self, from: JSONSerialization.data(withJSONObject: older))
        XCTAssertTrue(back.selectableWallCoreDead.isEmpty,
                      "★ the old numbers are ignored — the wall reads unmeasured until a bake asks core")
        let p = ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        p.lattice = back
        XCTAssertNil(p.latticeWallLoaded(LatticeSelectableRef.face(group: UUID(), face: 2)),
                     "unmeasured, not loaded — so the foci are offered")
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
        // A wall core LEFT ALONE carries load and refuses the write.
        p.writeLatticeSyntheticFoci(ref, foci: nil)
        p.recordLatticeWallVerdicts([ref.key: false])
        XCTAssertEqual(p.latticeWallLoaded(ref), true)
        p.writeLatticeSyntheticFoci(ref, foci: 3)
        XCTAssertNil(p.latticeSelectableSyntheticFoci(ref), "never foci on a loaded wall")
        p.recordLatticeWallVerdicts([ref.key: true])
        XCTAssertEqual(p.latticeWallLoaded(ref), false)
        p.writeLatticeSyntheticFoci(ref, foci: 3)
        XCTAssertEqual(p.latticeSelectableSyntheticFoci(ref), 3)
        XCTAssertNil(p.latticeWallLoaded(LatticeSelectableRef.face(group: UUID(), face: 9)))
    }

    /// ★★ RULING 2 (2026-09-29): with the switch on, the job flags EVERY include wall —
    /// measured or not, loaded or not — and core decides on the run's own tensor.
    /// Core's default for a flagged wall with no count is 4 foci it places itself.
    @MainActor func testTheJobFlagsEveryIncludeWall() throws {
        let p = ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        let dead = LatticeSelectableRef.face(group: UUID(), face: 15)
        let live = LatticeSelectableRef.face(group: UUID(), face: 2)
        let unmeasured = LatticeSelectableRef.face(group: UUID(), face: 9)
        p.lattice.algorithm = "organic"
        p.lattice.stageMode = .aesthetic
        p.lattice.organicSyntheticStresses = true
        p.recordLatticeWallVerdicts([dead.key: true, live.key: false])
        p.writeLatticeSyntheticFoci(dead, foci: 2)
        let flags = try XCTUnwrap(p.latticeSyntheticFlags(), "switch on ⇒ flags")
        XCTAssertEqual(flags.foci(for: dead.key), 2, "its own count")
        XCTAssertEqual(flags.foci(for: live.key), 4, "★ a loaded wall is flagged too — core leaves it alone")
        XCTAssertEqual(flags.foci(for: unmeasured.key), 4, "★ and one never measured")
        XCTAssertEqual(flags.foci(for: nil), 4, "a wall with no selectable: the default")
        p.lattice.organicSyntheticFoci = 3
        XCTAssertEqual(p.latticeSyntheticFlags()?.foci(for: live.key), 3, "the lattice default")
        p.lattice.stageMode = .structural
        XCTAssertNil(p.latticeSyntheticFlags(), "never under Structural")
        p.lattice.stageMode = .aesthetic
        p.lattice.organicSyntheticStresses = false
        XCTAssertNil(p.latticeSyntheticFlags(), "switch off")
        p.lattice.organicSyntheticStresses = true
        p.lattice.algorithm = "octet"
        XCTAssertNil(p.latticeSyntheticFlags(), "organic only")
        // ★ the emission flags every INCLUDE wall with its count, never an exclude one, and
        // a legacy include primitive (no selectable) takes the default
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<3 { root.deleteLastPathComponent() }
        let em = try String(contentsOf: root.appendingPathComponent("Sources/TopOptFlows/LatticeRegionEmission.swift"),
                            encoding: .utf8)
        XCTAssertEqual(em.components(separatedBy: "if role == .include, let sf = synthetic { s.syntheticStress = true; s.syntheticFoci = sf.foci(for: ref.key) }").count - 1, 3,
                       "primitive, face and region-member walls")
        XCTAssertTrue(em.contains("if let sf = synthetic { s.syntheticStress = true; s.syntheticFoci = sf.foci(for: nil) }"))
        XCTAssertFalse(em.contains("syntheticWalls"), "no measurement gates the job any more")
    }

    /// A project with an include group and an exclude group, each holding one placed bolt,
    /// plus a legacy include primitive — organic, Aesthetic, simulation on, synthesis on.
    @MainActor private func variantProject() -> (ProjectModel, inc: UUID, exc: UUID) {
        let p = ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        var sel = SelectionModel(); let gi = sel.addGroup(); let ge = sel.addGroup(); p.selection = sel
        let inc = p.force.addManualPrimitive(.defaultBolt(at: SIMD3(0, 0, 5), radiusMM: 3, halfLengthMM: 5), to: gi)
        let exc = p.force.addManualPrimitive(.defaultBolt(at: SIMD3(20, 0, 5), radiusMM: 3, halfLengthMM: 5), to: ge)
        p.lattice.includePrimitives = [.defaultBolt(at: SIMD3(40, 0, 5), radiusMM: 3, halfLengthMM: 5)]
        p.lattice.enabled = true
        p.lattice.groupRoles = [gi: .include, ge: .exclude]
        p.lattice.algorithm = "organic"
        p.lattice.stageMode = .aesthetic
        p.lattice.simulateStresses = true
        p.lattice.organicSyntheticStresses = true
        return (p, inc, exc)
    }

    /// ★★ RULING 1 (2026-09-29): the RE-LATTICE job — Check sizes, the forecast and the
    /// re-lattice run all read `variantLatticeJobRegions()` — flags every include wall
    /// exactly as the main job does, with the wall's own count or the default; an
    /// exclude wall never.
    @MainActor func testTheReLatticeJobFlagsEveryIncludeWall() throws {
        let (p, inc, _) = variantProject()
        p.writeLatticeSyntheticFoci(.primitive(inc), foci: 2)
        let regions = p.variantLatticeJobRegions().regions
        let includes = regions.filter { $0.role == .include }, excludes = regions.filter { $0.role == .exclude }
        XCTAssertEqual(includes.count, 2, "the placed bolt and the legacy include")
        XCTAssertEqual(excludes.count, 1)
        XCTAssertTrue(includes.allSatisfy(\.syntheticStress), "★ every include wall is flagged")
        XCTAssertEqual(includes.compactMap(\.syntheticFoci).sorted(), [2, 4], "its own count, else the default")
        XCTAssertFalse(excludes[0].syntheticStress, "★ never an exclude wall")
        XCTAssertNil(excludes[0].syntheticFoci)
        if TopOptKit.organicSyntheticStressWired {
            XCTAssertTrue(includes.allSatisfy { $0.wireDictionary["synthetic_stress"] as? Bool == true })
            XCTAssertNil(excludes[0].wireDictionary["synthetic_stress"])
        }
        // the gates: nothing flagged under Structural, synthesis off, octet, simulation off
        for (label, change) in [("Structural", { (l: inout LatticeSettings) in l.stageMode = .structural }),
                                ("synthesis off", { (l: inout LatticeSettings) in l.organicSyntheticStresses = false }),
                                ("octet", { (l: inout LatticeSettings) in l.algorithm = "octet" }),
                                ("simulation off", { (l: inout LatticeSettings) in l.setSimulateStresses(false) })] {
            let (q, _, _) = variantProject()
            change(&q.lattice)
            XCTAssertFalse(q.variantLatticeJobRegions().regions.contains(where: \.syntheticStress), label)
        }
        // one builder for all three documents, and the variant path carries the flags
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<3 { root.deleteLastPathComponent() }
        func src(_ f: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("Sources/TopOptFlows/\(f)"), encoding: .utf8)
        }
        let pm = try src("ProjectModel.swift"), ws = try src("WorkspacePlaceholder.swift"), vs = try src("LatticeVariantSession.swift")
        XCTAssertTrue(pm.contains("synthetic: latticeSyntheticFlags())"), "variantLatticeJobRegions passes the flags")
        XCTAssertTrue(ws.contains("let emission = project.variantLatticeJobRegions()"), "relatticeJobJSON builds from it")
        XCTAssertGreaterThanOrEqual(ws.components(separatedBy: "relatticeJobJSON(").count - 1, 4,
                                    "the definition plus the forecast, the Check-sizes probe and the run")
        XCTAssertTrue(vs.contains("if role == .include, let sf = synthetic { s.syntheticStress = true; s.syntheticFoci = sf.foci(for: ref.key) }"))
        XCTAssertTrue(vs.contains("if let sf = synthetic { s.syntheticStress = true; s.syntheticFoci = sf.foci(for: nil) }"))
    }

    /// ★★ RULING 2 (2026-09-29): "A hidden setting must not act." The synthesis toggle is
    /// offered only with the simulation on, so it acts only then. A saved "on" with the
    /// simulation off flags nothing — main job, re-lattice job, preview, Selections row —
    /// and stays saved for when the switch comes back.
    @MainActor func testASavedOnWithTheSimulationOffFlagsNothing() throws {
        let (p, _, _) = variantProject()
        // control: switch on ⇒ it acts
        XCTAssertTrue(p.lattice.organicSyntheticStressesActive)
        XCTAssertNotNil(p.latticeSyntheticFlags())
        XCTAssertTrue(p.variantLatticeJobRegions().regions.contains(where: \.syntheticStress))
        XCTAssertTrue(p.latticeJobRegions().regions.contains(where: \.syntheticStress))
        // the real switch, off
        p.lattice.setSimulateStresses(false)
        XCTAssertTrue(p.lattice.organicSyntheticStresses, "★ the saved on stays saved")
        XCTAssertFalse(p.lattice.organicSyntheticStressesActive)
        XCTAssertNil(p.latticeSyntheticFlags(), "★ …and flags nothing")
        XCTAssertFalse(p.variantLatticeJobRegions().regions.contains(where: \.syntheticStress))
        XCTAssertFalse(p.latticeJobRegions().regions.contains(where: \.syntheticStress))
        XCTAssertFalse(p.latticeJobRegions().regions.contains { $0.wireDictionary["synthetic_stress"] != nil })
        // …and a project saved that way reads the same
        let back = try JSONDecoder().decode(LatticeSettings.self, from: try JSONEncoder().encode(p.lattice))
        XCTAssertTrue(back.organicSyntheticStresses); XCTAssertFalse(back.simulateStresses)
        XCTAssertFalse(back.organicSyntheticStressesActive)
        // the switch back on brings it back
        p.lattice.setSimulateStresses(true)
        XCTAssertNotNil(p.latticeSyntheticFlags())
        // every reader goes through the one gate
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<3 { root.deleteLastPathComponent() }
        func src(_ f: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("Sources/TopOptFlows/\(f)"), encoding: .utf8)
        }
        let ws = try src("WorkspacePlaceholder.swift"), pm = try src("ProjectModel.swift")
        XCTAssertTrue(ws.contains("let synthOn = project.lattice.organicSyntheticStressesActive && organicForBake != nil"),
                      "the preview's synthesis")
        XCTAssertTrue(ws.contains("guard lat.organicSyntheticStressesActive else { return nil }"), "the Selections row")
        XCTAssertTrue(pm.contains("guard lattice.organicSyntheticStressesActive else { return nil }"), "the job")
        XCTAssertFalse(ws.contains("lattice.organicSyntheticStresses\n") || ws.contains("lat.organicSyntheticStresses,"),
                       "no raw read of the toggle acts")
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
                                                syntheticFoci: "3", wallStress: "Barely loaded — a made-up load can be added")
        let si = measured.rows.firstIndex { $0.label == "Stress on wall" }
        XCTAssertEqual(si, measured.rows.firstIndex { $0.label == "Foci" }.map { $0 + 1 })
        XCTAssertEqual(measured.rows[si!].kind, .fact)
        XCTAssertFalse(measured.rows.first { $0.label == "Foci" }!.disabled)
        let loaded = LatticeRegionDrawer.make(card: card, depthMM: 5, held: false,
                                              syntheticFoci: "—", fociDisabled: true,
                                              wallStress: "Carries load")
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
