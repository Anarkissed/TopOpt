// LatticeVariantTests.swift — task 2026-08-02-lattice-a-variant, the app bars.
//
//   Z7  THE APP ROUTE IS HONEST. From a variant the page names WHICH variant and
//       offers TWO clearly-labelled actions — "Lattice this variant" (this job)
//       and "Optimize from scratch" (the ladder) — never one button that
//       silently does the surprising one. From the workspace there is still one.
//   Z9  THE PAGE OPERATES ON THE VARIANT. The context carries the VARIANT's own
//       mesh, and a region authored here lands on variant geometry in the
//       emitted job.
//  Z10  LATTICE ROLES MUST NOT STICK IN "PENDING". Optimize is reachable with
//       only lattice-role groups present.
//  Z11  AUTHORING ON A VARIANT IS NOT FACE-ID BASED. The variant emission emits
//       only explicit geometry predicates and COUNTS the face selections it
//       refused to synthesise.
//   Z2  (app side) THE LOAD CASE IS THE SAME ONE. The submitted document is the
//       retained one with only the lattice question changed — asserted key by
//       key, including a key this build has never heard of.

import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LatticeVariantTests: XCTestCase {

    /// One selection group per face, the same helper the other flow tests use.
    private func groups(_ faces: [FaceID]) -> (SelectionModel, [UUID]) {
        var m = SelectionModel()
        for f in faces { m.addGroup(); m.pickFaces([f]) }
        return (m, m.groups.map { $0.id })
    }

    // MARK: fixtures

    private func field() -> LatticeDemandField {
        LatticeDemandField(vonMises: [1, 2, 3, 4, 5, 6, 7, 8],
                           nx: 2, ny: 2, nz: 2, origin: .zero, spacingMM: 1,
                           provenance: .variant(runName: "Bracket", variantIndex: 1,
                                                date: nil))
    }

    private func context(artifacts: RelatticeArtifacts? = RelatticeArtifacts(
                            jobJSON: Data("{}".utf8), designBin: Data([1, 2, 3])),
                         unavailable: RelatticeUnavailable? = nil)
        -> LatticeVariantContext {
        LatticeVariantContext(
            runName: "Bracket", variantIndex: 1, requestedVolumeFraction: 0.6,
            massGrams: 41.2, worstCaseMargin: 2.31, accepted: true,
            meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2],
            field: field(), artifacts: artifacts, unavailable: unavailable)
    }

    private func surface(enabled: Bool = true) -> LatticeOptimizeSurface {
        LatticeOptimizeSurface(enabled: enabled, label: "Optimize",
                               sub: "1 anchor · 1 load")
    }

    // MARK: Z7 — two clearly-labelled actions, never one surprising one

    func testWorkspaceEntryKeepsTheSingleOptimizeButton() {
        let a = LatticePageActions.compute(variant: nil,
                                           optimizeSurface: surface(),
                                           running: false)
        XCTAssertNil(a.relattice,
                     "Z7: with no variant there is nothing to re-lattice, so no second button")
        XCTAssertEqual(a.optimize.label, "Optimize")
        XCTAssertEqual(a.optimize.sub, "1 anchor · 1 load",
                       "Z7: the workspace entry's button is unchanged")
        XCTAssertTrue(a.optimize.enabled)
        XCTAssertTrue(a.optimize.primary)
    }

    func testVariantEntryOffersTwoDistinctlyLabelledActions() {
        let a = LatticePageActions.compute(variant: context(),
                                           optimizeSurface: surface(),
                                           running: false)
        let re = try! XCTUnwrap(a.relattice)
        XCTAssertEqual(re.label, "Lattice this variant")
        XCTAssertTrue(re.enabled)
        XCTAssertTrue(re.primary, "Z7: latticing THIS variant is the primary action here")
        XCTAssertTrue(re.sub.contains("variant 2"),
                      "Z7: the action names the variant it will act on — got \(re.sub)")
        XCTAssertTrue(re.sub.contains("no ladder"),
                      "Z7: and says what it will NOT do — got \(re.sub)")

        XCTAssertEqual(a.optimize.label, "Optimize from scratch",
                       "Z7: the ladder action is labelled as the ladder, not as 'Optimize'")
        XCTAssertTrue(a.optimize.sub.contains("re-runs the whole ladder"),
                      "Z7: and says so in its sub-line — got \(a.optimize.sub)")
        XCTAssertFalse(a.optimize.primary)
        XCTAssertNotEqual(re.label, a.optimize.label,
                          "Z7: the two actions can never be mistaken for each other")
    }

    func testRelatticeIsRefusedWithAReasonWhenTheRunKeptNoDesign() {
        for why in [RelatticeUnavailable.computedOnDevice,
                    .runPredatesDesignStore, .designNotTransferred] {
            let a = LatticePageActions.compute(
                variant: context(artifacts: nil, unavailable: why),
                optimizeSurface: surface(), running: false)
            let re = try! XCTUnwrap(a.relattice)
            XCTAssertFalse(re.enabled,
                           "Z7: cannot lattice a variant whose design was not kept")
            XCTAssertEqual(re.sub, why.reason,
                           "Z7: and the button carries the REASON, not a blank disable")
            XCTAssertFalse(re.sub.isEmpty)
        }
    }

    func testRunningDisablesBothActions() {
        let a = LatticePageActions.compute(variant: context(),
                                           optimizeSurface: surface(),
                                           running: true)
        XCTAssertFalse(try! XCTUnwrap(a.relattice).enabled)
        XCTAssertFalse(a.optimize.enabled)
    }

    func testTheVariantIsNamedUnambiguously() {
        let v = context()
        XCTAssertEqual(v.title, "Variant 2 · 60% · 41.2 g")
        XCTAssertTrue(v.subtitle.contains("Bracket"))
        XCTAssertTrue(v.subtitle.contains("2.31"))
    }

    // MARK: Z9 — the page carries the VARIANT's geometry, not the original's

    func testContextCarriesTheVariantsOwnMesh() {
        let v = context()
        XCTAssertEqual(v.meshVertices.count, 9)
        XCTAssertEqual(v.meshIndices, [0, 1, 2],
                       "Z9: the variant's own geometry travels WITH its identity, so a "
                       + "page cannot name one object and render another")
        XCTAssertEqual(v.field.provenance,
                       .variant(runName: "Bracket", variantIndex: 1, date: nil),
                       "Z9/Z4: and the demand field is that variant's own")
    }

    // MARK: Z11 — authoring on a variant uses geometry predicates, not face ids

    func testVariantEmissionEmitsPrimitivesAndRefusesFaces() {
        let gid = UUID()
        // Faces authored against the ORIGINAL part — geometry this design no
        // longer has.
        let group = SelectionGroup(id: gid, name: "g", colorIndex: 0, faces: [7, 9])
        let bolt = ManualPrimitive(kind: .bolt, center: SIMD3<Double>(1, 2, 3),
                                   axis: SIMD3<Double>(0, 0, 1),
                                   radiusMM: 2, halfLengthMM: 5)

        let r = LatticeRegionEmission.variantRegions(
            groups: [group], roles: [gid: LatticeGroupRole.include],
            primitives: { _ in [(bolt, 1.0)] },
            includePrimitives: [])

        XCTAssertEqual(r.regions.count, 1,
                       "Z11: only the explicit geometry predicate is emitted")
        XCTAssertEqual(r.regions[0].kind, LatticeRegionSpec.Kind.bolt)
        XCTAssertEqual(r.regions[0].role, LatticeGroupRole.include)
        XCTAssertEqual(r.regions[0].axisPoint, SIMD3<Double>(1, 2, 3),
                       "Z9: and it lands on variant geometry — model-space coordinates "
                       + "the core resolves directly against this design's voxels")
        XCTAssertEqual(r.skippedFaces, 2,
                       "Z11: the face selections are COUNTED, not silently synthesised "
                       + "from the original part's B-rep")
    }

    func testVariantAuthoringTurnsFaceTappingOffWithAReason() {
        let off = LatticeVariantAuthoring.compute(variant: context())
        XCTAssertFalse(off.faceTapEnabled,
                       "Z11: a marching-cubes variant has no selectable faces")
        XCTAssertTrue(off.primitivePlacementEnabled,
                      "Z11: placing a region is the authoring that DOES work here")
        XCTAssertFalse(off.note.isEmpty, "Z11: and the page says why")
        XCTAssertTrue(off.note.contains("no selectable faces"))

        let on = LatticeVariantAuthoring.compute(variant: nil)
        XCTAssertTrue(on.faceTapEnabled, "the workspace entry is unchanged")
        XCTAssertTrue(on.note.isEmpty)
    }

    // MARK: Z10 — a lattice role is a COMPLETE declaration

    func testLatticeRoleGroupDoesNotBlockOptimize() {
        let (sel, ids) = groups([3])
        let gid = ids[0]
        var fm = ForceModel()
        fm.setGravity(faceNormal: SIMD3<Float>(0, 0, 1), face: 0)
        fm.sync(groups: sel.groups)

        // Before: a group with no anchor/load role blocks Optimize.
        XCTAssertTrue(fm.hasPending(in: sel.groups),
                      "an undeclared group is genuinely pending")
        XCTAssertFalse(fm.canOptimize(in: sel.groups, minimizePlastic: true))

        // Z10: the same group, marked "lattice here", is a COMPLETE declaration.
        XCTAssertFalse(fm.hasPending(in: sel.groups, latticeRoleGroups: [gid]),
                       "Z10: a group set to 'lattice here' is declared, not pending")
        XCTAssertTrue(fm.canOptimize(in: sel.groups, minimizePlastic: true,
                                     latticeRoleGroups: [gid]),
                      "Z10: Optimize is REACHABLE with only lattice-role groups present")
        XCTAssertEqual(fm.optimizeSummary(in: sel.groups, latticeRoleGroups: [gid]),
                       "needs an anchor and a load",
                       "Z10: and the reason shown is the real one, not 'finish the "
                       + "pending group'")
    }

    func testLatticeRoleGroupReadsAsItsRoleNotPending() {
        let (sel, ids) = groups([3])
        let gid = ids[0]
        var fm = ForceModel()
        fm.sync(groups: sel.groups)
        XCTAssertEqual(fm.panelKindLabel(for: gid), "Pending…")
        XCTAssertEqual(fm.panelKindLabel(for: gid, latticeRole: .include),
                       "Lattice here")
        XCTAssertEqual(fm.panelKindLabel(for: gid, latticeRole: .exclude),
                       "No lattice here")
    }

    func testDefaultsKeepEveryExistingCallerUnchanged() {
        let (sel, _) = groups([1])
        var fm = ForceModel()
        fm.setGravity(faceNormal: SIMD3<Float>(0, 0, 1), face: 0)
        fm.sync(groups: sel.groups)
        XCTAssertEqual(fm.hasPending(in: sel.groups),
                       fm.hasPending(in: sel.groups, latticeRoleGroups: []),
                       "the new parameter defaults to the pre-existing behaviour")
    }

    // MARK: Z2 (app side) — the load case is RE-USED, not re-authored

    private func originalJob() -> Data {
        let job: [String: Any] = [
            "model": "bracket.stl",
            "material": "PLA",
            "mode": "minimize_plastic",
            "resolution": 96,
            "output": ["report": "report.json", "mesh_format": "stl",
                       "mesh_prefix": "variant"],
            "loads": [
                "minimize_plastic": true,
                "build_dir": [0, 0, 1],
                "anchor_face_ids": [3, 4],
                "groups": [["face_ids": [11], "force": [0, 0, -450.0]]],
                "clearances": [["face_id": 7, "kind": "bolt",
                                "concentric_margin_mm": 1.5]],
            ],
            // A key this build has never heard of — the transformation must carry
            // it through, because dropping an unknown load-case key is exactly the
            // mesh-job-params defect.
            "some_future_load_key": ["a": 1],
        ]
        return try! JSONSerialization.data(withJSONObject: job, options: [.sortedKeys])
    }

    private func spec() -> LatticeSpec {
        LatticeSpec(topologyID: "octet", cellMM: 4, strutRadiusMM: 0.6,
                    generateRelativeDensity: 0.3, minRelativeDensity: 0.05,
                    maxRelativeDensity: 0.9, emitSTL: true, emit3MF: false,
                    regionScoped: false, skin: "diagrid",
                    minExtrudableWidthMM: 0.42, graded: false, regions: [])
    }

    func testRelatticeJobChangesOnlyTheLatticeQuestion() throws {
        let original = originalJob()
        let relattice = try RelatticeJobBuilder.build(
            original: original, designFingerprint: 0x5EED_0060, achievedVolumeFraction: 0.5983,
            designFileName: "design.bin", lattice: spec())

        XCTAssertEqual(RelatticeJobBuilder.loadCaseDifferences(original, relattice), [],
                       "Z2: NO load-case key moved — the anchors, the force groups, the "
                       + "clearances, the resolution and the material are the SAME bytes "
                       + "that produced the variant")

        let doc = try XCTUnwrap(
            JSONSerialization.jsonObject(with: relattice) as? [String: Any])
        XCTAssertEqual(doc["mode"] as? String, "lattice_variant")
        let v = try XCTUnwrap(doc["variant"] as? [String: Any])
        XCTAssertEqual(v["design"] as? String, "design.bin")
        XCTAssertEqual(v["fingerprint"] as? String, String(0x5EED_0060 as UInt64),
                       "Z2/Z7: the job names the DESIGN the page said it would act on, "
                       + "by identity")
        XCTAssertNil(v["volume_fraction"],
                     "task 2026-08-04: the ladder RUNG no longer travels in a key core "
                     + "validates as a fraction in (0, 1] — that is what killed every "
                     + "growth-ladder re-lattice at schema validation")
        XCTAssertNotNil(doc["lattice"])
        XCTAssertNotNil(doc["some_future_load_key"],
                        "Z2: an unknown key is CARRIED, never dropped — dropping a "
                        + "load-case key is the mesh-job-params defect")
    }

    func testADifferentLoadCaseIsDetectedKeyByKey() throws {
        let original = originalJob()
        var mutated = try XCTUnwrap(
            JSONSerialization.jsonObject(with: original) as? [String: Any])
        mutated["resolution"] = 64
        let other = try JSONSerialization.data(withJSONObject: mutated,
                                               options: [.sortedKeys])
        XCTAssertEqual(RelatticeJobBuilder.loadCaseDifferences(original, other),
                       ["resolution"],
                       "Z2: a moved load-case key is NAMED, so a refusal can say what "
                       + "changed instead of failing vaguely")
    }

    func testAGradedRelatticeJobShipsAGradingBlockNotAUniformFill() throws {
        let graded = LatticeSpec(
            topologyID: "octet", cellMM: 4, strutRadiusMM: 0,
            generateRelativeDensity: 0, minRelativeDensity: 0.05,
            maxRelativeDensity: 0.9, emitSTL: true, emit3MF: false,
            regionScoped: false, skin: "diagrid", minExtrudableWidthMM: 0.42,
            graded: true, regions: [], cellSizeMode: "fixed",
            cellMinMM: 0, cellMaxMM: 0)
        let job = try RelatticeJobBuilder.build(
            original: originalJob(), designFingerprint: 0x5EED_0060, achievedVolumeFraction: 0.5983,
            designFileName: "design.bin", lattice: graded)
        let doc = try XCTUnwrap(
            JSONSerialization.jsonObject(with: job) as? [String: Any])
        let g = try XCTUnwrap(doc["grading"] as? [String: Any])
        XCTAssertEqual(g["cell_mm"] as? Double, 4)
        XCTAssertEqual(g["min_extrudable_width_mm"] as? Double, 0.42)
        let lat = try XCTUnwrap(doc["lattice"] as? [String: Any])
        XCTAssertNil(lat["cell_mm"],
                     "core REFUSES cell_mm inside lattice alongside a grading block")
        XCTAssertNil(lat["strut_radius_mm"])
    }

    func testAJobWithNoLatticeSettingsIsRefusedBeforeSubmission() {
        XCTAssertThrowsError(try RelatticeJobBuilder.build(
            original: originalJob(), designFingerprint: 0x5EED_0060, achievedVolumeFraction: 0.5983,
            designFileName: "design.bin", lattice: nil),
            "there is nothing to lattice without lattice settings")
    }

    func testRegionsRideTheRelatticeJob() throws {
        var region = LatticeRegionSpec(role: .exclude, kind: .bolt)
        region.axisPoint = SIMD3<Double>(1, 2, 3)
        region.axisDir = SIMD3<Double>(0, 0, 1)
        region.radiusMM = 2
        region.halfLengthMM = 5
        let withRegion = LatticeSpec(
            topologyID: "octet", cellMM: 4, strutRadiusMM: 0.6,
            generateRelativeDensity: 0.3, minRelativeDensity: 0.05,
            maxRelativeDensity: 0.9, emitSTL: true, emit3MF: false,
            regionScoped: true, skin: "diagrid", minExtrudableWidthMM: 0.42,
            graded: false, regions: [region])
        let job = try RelatticeJobBuilder.build(
            original: originalJob(), designFingerprint: 0x5EED_0060, achievedVolumeFraction: 0.5983,
            designFileName: "design.bin", lattice: withRegion)
        let doc = try XCTUnwrap(
            JSONSerialization.jsonObject(with: job) as? [String: Any])
        let lat = try XCTUnwrap(doc["lattice"] as? [String: Any])
        let regions = try XCTUnwrap(lat["regions"] as? [[String: Any]])
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0]["role"] as? String, "exclude")
        let geo = try XCTUnwrap(regions[0]["geometry"] as? [String: Any])
        XCTAssertEqual(geo["axis_point"] as? [Double], [1, 2, 3],
                       "Z9: a region authored on the lattice page lands on variant "
                       + "geometry in the EMITTED job")
    }
}
