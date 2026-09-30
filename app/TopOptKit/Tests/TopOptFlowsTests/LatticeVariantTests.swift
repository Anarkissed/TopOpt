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
//  Z11  FACE TAPPING ON A VARIANT STAYS REFUSED (maintainer, 2026-09-30, ruling a).
//       Face walls marked on the part travel as the stage's full prisms, face_id
//       included as provenance, so core's depth tie is live on the variant's job;
//       with no include wall the job is refused in the stage's words (ruling c).
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

    // MARK: Z11 — face walls travel as the stage's prisms; face tapping stays refused

    /// ★★ THE FACE-PRISM ROUTE (2026-09-29; face ids kept, ruling a, 2026-09-30). The variant's
    /// regions ARE the stage's, entry for entry and in order — a face, a face
    /// region's member faces, a placed bolt — so Check sizes, the forecast and the re-lattice
    /// include the walls the page shows. Before, the variant carried the bolt alone.
    func testTheVariantJobCarriesEachFaceWallAsItsPrism() throws {
        let (p, _, _) = VariantFacePrismFixture.project()
        let stage = p.latticeJobRegions(), variant = p.variantLatticeJobRegions()
        // positive control: the stage has the three face walls, each with its outline and id
        let faces = stage.regions.filter { $0.kind == .face }
        XCTAssertEqual(Set(faces.compactMap(\.rawFaceID)), [1, 3, 8],
                       "face 1 and the face region's two member faces")
        XCTAssertTrue(faces.allSatisfy { $0.faceID != nil && !$0.outlineLoops.isEmpty })
        XCTAssertEqual(stage.regions.filter { $0.kind == .bolt }.count, 1)
        XCTAssertEqual(stage.skippedFaces, 0)
        // ★ the variant carries every one of them, unchanged
        XCTAssertEqual(variant.regions, stage.regions, "★ the variant's walls are the stage's")
        XCTAssertEqual(variant.skippedFaces, 0, "★ no face wall is left out")
    }

    /// ★★ THE VARIANT'S JOB CARRIES THE STAGE'S REGIONS, FACE IDS INCLUDED (ruling a,
    /// 2026-09-30). Each lattice region on the wire IS the stage's entry, byte for byte — the
    /// prism and its `face_id` as provenance — in the run, the forecast and the Check-sizes
    /// documents. The retained load case protects face 1, so core's parser accepting them
    /// means the depth tie PASSED, not that it was skipped.
    func testTheVariantJobCarriesTheStagesRegionsFaceIDsIncluded() throws {
        for organic in [false, true] {
            let (p, _, _) = VariantFacePrismFixture.project(organic: organic)
            let stage = p.latticeJobRegions().regions
            let retained = try VariantFacePrismFixture.original(protecting: p)
            // control: the retained job really protects a face the variant lattices
            let loads = try XCTUnwrap((try JSONSerialization.jsonObject(with: retained) as? [String: Any])?["loads"]
                                      as? [String: Any])
            XCTAssertNotNil(loads["face_protections"], "control: a protection is in play")
            let docs = try VariantFacePrismFixture.variantDocuments(p, retained: retained)
            XCTAssertEqual(docs.count, organic ? 3 : 2)
            for (label, doc) in docs {
                let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: doc) as? [String: Any])
                let wire = try XCTUnwrap((obj["lattice"] as? [String: Any])?["regions"] as? [[String: Any]], label)
                XCTAssertEqual(wire.count, stage.count, label)
                for (w, s) in zip(wire, stage) {
                    XCTAssertEqual(try VariantFacePrismFixture.wireText(w),
                                   try VariantFacePrismFixture.wireText(s.wireDictionary),
                                   "★ \(label): the stage's entry, face_id included")
                }
                XCTAssertEqual(wire.filter { $0["kind"] as? String == "face" && $0["face_id"] == nil }.count, 0,
                               "★ \(label): every face prism keeps its id")
                XCTAssertEqual(wire.filter { $0["kind"] as? String == "face" }.count, 3, label)
                // the face prisms carry their outline, and the frame exactly when this core takes it
                for w in wire where w["kind"] as? String == "face" {
                    let g = try XCTUnwrap(w["geometry"] as? [String: Any], label)
                    XCTAssertNotNil(g["outline_uv"], label)
                    XCTAssertEqual(g["frame_u"] != nil, TopOptKit.regionFrameAxesWired, label)
                    XCTAssertEqual(g["frame_w"] != nil, TopOptKit.regionFrameAxesWired, label)
                }
                // Z9: the bolt lands where it was placed
                let bolt = try XCTUnwrap(wire.first { $0["kind"] as? String == "bolt" }, label)
                XCTAssertEqual((bolt["geometry"] as? [String: Any])?["axis_point"] as? [Double], [5, 5, 5], label)
                // Z2: the load case is the retained one — its clearance keeps its face id
                let clearances = try XCTUnwrap((obj["loads"] as? [String: Any])?["clearances"] as? [[String: Any]], label)
                XCTAssertEqual(clearances.first?["face_id"] as? Int, 7, label)
                let refused = TopOptKit.jobSchemaError(doc)
                XCTAssertNil(refused, "core refused the \(label) document the app built: \(refused ?? "")")
            }
        }
    }

    /// ★★ ONE ORDER FOR ONE OUTLINE (maintainer, 2026-09-30, ruling 1). The emission's outline
    /// loops came out in hash order — the same polygon rotated or reordered from call to call,
    /// so the stage's job bytes differed between launches. The emission now fixes the order at
    /// its source (`LatticeFaceOutline`), so the stage, its job document and the variant's
    /// documents are each ONE byte string, however many times they are built.
    func testOneOutlineOrderForTheStageAndTheVariant() throws {
        let (p, _, _) = VariantFacePrismFixture.project()
        var emissions = Set<String>(), stages = Set<Data>(), variants = Set<Data>()
        for _ in 0..<200 {
            let e = p.latticeJobRegions()
            emissions.insert(e.regions.map { "\($0.outlineLoops)" }.joined(separator: "|"))
            stages.insert(try VariantFacePrismFixture.sorted(e.regions.map { $0.wireDictionary }))
            variants.insert(try XCTUnwrap(VariantFacePrismFixture.variantDocuments(p).first?.1))
        }
        let env = ProcessInfo.processInfo.environment["SWIFT_DETERMINISTIC_HASHING"] ?? "unset"
        print("ONE ORDER emissions \(emissions.count), stage wires \(stages.count), variant documents \(variants.count) of 200; SWIFT_DETERMINISTIC_HASHING=\(env)")
        XCTAssertEqual(emissions.count, 1, "★ one outline order")
        XCTAssertEqual(stages.count, 1, "★ one stage wire")
        XCTAssertEqual(variants.count, 1, "★ one variant document")
    }

    /// ★★ RULING (a) (maintainer, 2026-09-30): core's depth tie (job.cpp, inside `parse_job`) is
    /// LIVE on a variant's job — asked of core's own parser, never re-implemented. The retained
    /// run froze face 1 at 20 mm; a wall that states another depth is refused in core's words.
    func testCoresDepthTieIsLiveOnAVariantJob() throws {
        let (p, gid, _) = VariantFacePrismFixture.project()
        let run1 = try XCTUnwrap(p.latticeJobRegions().regions.first { $0.rawFaceID == 1 }?.faceID)
        let retained = try VariantFacePrismFixture.original(protecting: p)   // face 1 frozen at 20 mm
        // control: the wall states what the run froze ⇒ accepted
        for (label, doc) in try VariantFacePrismFixture.variantDocuments(p, retained: retained) {
            XCTAssertNil(TopOptKit.jobSchemaError(doc), label)
        }
        // the wall's depth changed after the run ⇒ refused, in core's words, before any solve
        p.writeLatticeDepthMM(.face(group: gid, face: 1), mm: 12)
        for (label, doc) in try VariantFacePrismFixture.variantDocuments(p, retained: retained) {
            let why = try XCTUnwrap(TopOptKit.jobSchemaError(doc), "★ \(label): two depths for one face")
            XCTAssertTrue(why.contains("face \(run1) is BOTH protected and a lattice region, at two different depths"), why)
            XCTAssertTrue(why.contains("the protection is 20.000000 mm and the lattice region is 12.000000 mm"), why)
            // negative control: the refusal IS the tie, keyed on the id — the same bytes with the
            // regions' face_id stripped (the first draft of the route) are accepted
            var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: doc) as? [String: Any])
            var lat = try XCTUnwrap(obj["lattice"] as? [String: Any])
            lat["regions"] = (lat["regions"] as? [[String: Any]] ?? []).map { r -> [String: Any] in
                var r = r; r["face_id"] = nil; return r }
            obj["lattice"] = lat
            XCTAssertNil(TopOptKit.jobSchemaError(try JSONSerialization.data(withJSONObject: obj)),
                         "\(label): without the id the tie cannot run — which is why it is kept")
        }
    }

    // MARK: ruling (c) — no include wall, no variant job

    /// ★★ RULING (c) (maintainer, 2026-09-30): a variant job with zero include walls refuses, in
    /// the stage's words — never lattice the whole variant silently (core lattices every printed
    /// voxel of a job that declares no include: J6 of the face-prism proof).
    func testAVariantJobWithNoIncludeWallRefusesInTheStagesWords() throws {
        let (p, gid, _) = VariantFacePrismFixture.project()
        XCTAssertNil(p.variantLatticeJobRefusal(), "control: include walls ⇒ the job may be written")
        // exclude-only: walls ARE emitted, none of them an include
        p.lattice.groupRoles[gid] = .exclude
        let regions = p.variantLatticeJobRegions().regions
        XCTAssertFalse(regions.isEmpty, "control: the walls are still emitted")
        XCTAssertFalse(regions.contains { $0.role == .include })
        XCTAssertEqual(p.variantLatticeJobRefusal(), "nothing set to lattice")
        XCTAssertEqual(p.variantLatticeJobRefusal(), LatticeJobIncludeGate.nothingSetToLattice)
        // a legacy include primitive IS an include wall
        p.lattice.includePrimitives = [.defaultBolt(at: SIMD3(5, 5, 5), radiusMM: 1, halfLengthMM: 2)]
        XCTAssertNil(p.variantLatticeJobRefusal())
        p.lattice.includePrimitives = []
        // lattice off: the stage's first reason
        p.lattice.enabled = false
        XCTAssertEqual(p.variantLatticeJobRefusal(), "lattice mode is off")
        // the stage's own summary reads the same words, from one home
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<3 { root.deleteLastPathComponent() }
        let ws = try String(contentsOf: root.appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift"),
                            encoding: .utf8)
        XCTAssertTrue(ws.contains("guard project.lattice.enabled else { return LatticeJobIncludeGate.latticeModeOff }"))
        XCTAssertTrue(ws.contains("if n == 0 { return LatticeJobIncludeGate.nothingSetToLattice }"))
        XCTAssertFalse(ws.contains("return \"nothing set to lattice\""), "one home for the words")
        // every variant document is gated: the one builder refuses, the run and Check sizes say why
        XCTAssertTrue(ws.contains("guard LatticeJobIncludeGate.refusal(latticeEnabled: project.lattice.enabled,")
                      && ws.contains("regions: emission.regions) == nil else { return nil }"),
                      "relatticeJobJSON — the forecast, Check sizes and the run all come from it")
        XCTAssertTrue(ws.contains("model.toast = \"Can’t lattice this variant: \\(why).\""))
        XCTAssertTrue(ws.contains("throw RelatticeError(\"Can’t check sizes: \\(why).\")"))
        XCTAssertTrue(ws.contains("variantJobRefusal: pass.refusal,"), "the page gets it")
    }

    /// The re-lattice button and the forecast drawer carry the refusal — pure, no SwiftUI.
    func testTheRelatticeButtonAndTheForecastCarryTheIncludeRefusal() throws {
        let ok = LatticePageActions.compute(variant: context(), optimizeSurface: surface(), running: false)
        XCTAssertEqual(ok.relattice?.enabled, true, "control: no refusal ⇒ enabled")
        let refused = LatticePageActions.compute(variant: context(), optimizeSurface: surface(), running: false,
                                                 jobRefusal: LatticeJobIncludeGate.nothingSetToLattice)
        XCTAssertEqual(refused.relattice?.enabled, false, "★ never lattice the whole variant")
        XCTAssertEqual(refused.relattice?.sub, "nothing set to lattice", "★ in the stage's words")
        XCTAssertEqual(refused.optimize, ok.optimize, "Optimize from scratch is untouched")
        // running and a run that kept no design still say their own reason first
        let running = LatticePageActions.compute(variant: context(), optimizeSurface: surface(), running: true,
                                                 jobRefusal: LatticeJobIncludeGate.nothingSetToLattice)
        XCTAssertEqual(running.relattice?.sub, VariantEntry.latticeQueuedReason)
        // the drawer says why instead of "Checking…" for a question never sent
        let panel = LatticeForecastPanel.compute(state: .idle, describesCurrentJob: false,
                                                 refusal: LatticeJobIncludeGate.nothingSetToLattice)
        XCTAssertEqual(panel.placeholder, "Can’t forecast: nothing set to lattice.")
        XCTAssertTrue(panel.warn)
        let checking = LatticeForecastPanel.compute(state: .idle, describesCurrentJob: false)
        XCTAssertEqual(checking.placeholder, "Checking what these settings would lattice…", "control")
        // …and the page hands both of them the gate's answer
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<3 { root.deleteLastPathComponent() }
        let page = try String(contentsOf: root.appendingPathComponent("Sources/TopOptFlows/LatticePage.swift"),
                              encoding: .utf8)
        XCTAssertTrue(page.contains("forecast: forecast.forecast(for: forecastJob),\n                                   jobRefusal: variantJobRefusal ?? variantJobCoreRefusal)"),
                      "the page's button reads the gate (and core's own refusal, ruling 3)")
        XCTAssertTrue(page.contains("describesCurrentJob: forecastJob != nil && forecast.describes == forecastJob,\n            refusal: variantJobRefusal, coreRefusal: variantJobCoreRefusal)"),
                      "the page's drawer reads the gate")
    }

    func testVariantAuthoringTurnsFaceTappingOffWithAReason() {
        let off = LatticeVariantAuthoring.compute(variant: context())
        XCTAssertFalse(off.faceTapEnabled,
                       "Z11: a marching-cubes variant has no selectable faces")
        XCTAssertTrue(off.primitivePlacementEnabled,
                      "Z11: placing a region is the authoring that DOES work here")
        // ★ ruling (e) (2026-09-30): ONE sentence, his words
        XCTAssertEqual(off.note,
                       "You can't pick faces on an optimised result — the walls you marked on the part carry over.")

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

/// ★ THE FACE-PRISM FIXTURE (the face-prism route, 2026-09-29): `LatticeSlabExpandTests`'
/// banded cube — face 1 (the top) and a face region over faces 3 and 8 (the +x wall, split
/// at z 9) in one protected include group at depth 20 — plus a placed bolt in that group.
@MainActor
enum VariantFacePrismFixture {
    static func bandedCube() -> ViewerMesh {
        var v: [Float] = []
        func V(_ x: Float, _ y: Float, _ z: Float) { v += [x, y, z] }
        V(0, 0, 0); V(10, 0, 0); V(10, 10, 0); V(0, 10, 0)
        V(0, 0, 10); V(10, 0, 10); V(10, 10, 10); V(0, 10, 10)
        V(10, 0, 9); V(10, 10, 9); V(0, 0, 9); V(0, 10, 9)
        var idx: [Int32] = []
        var faces: [Int32] = []
        func T(_ a: Int32, _ b: Int32, _ c: Int32, _ f: Int32) {
            idx += [a, b, c]; faces.append(f)
        }
        T(0, 3, 2, 0); T(0, 2, 1, 0)
        T(4, 5, 6, 1); T(4, 6, 7, 1)
        T(0, 1, 8, 2); T(0, 8, 10, 2); T(10, 8, 5, 2); T(10, 5, 4, 2)
        T(1, 2, 9, 3); T(1, 9, 8, 3)
        T(2, 3, 11, 4); T(2, 11, 9, 4); T(9, 11, 7, 4); T(9, 7, 6, 4)
        T(3, 0, 10, 5); T(3, 10, 11, 5); T(11, 10, 4, 5); T(11, 4, 7, 5)
        T(8, 9, 6, 8); T(8, 6, 5, 8)
        let normals: [SIMD3<Double>] = [
            SIMD3(0, 0, -1), SIMD3(0, 0, 1), SIMD3(0, -1, 0), SIMD3(1, 0, 0),
            SIMD3(0, 1, 0), SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 0, 1),
            SIMD3(1, 0, 0),
        ]
        return ViewerMesh(vertices: v, indices: idx, faceIDs: faces,
                          faceGeometry: normals.map {
                              StepFaceGeometry(kind: .plane, planeNormal: $0)
                          })
    }

    /// `organic` ⇒ organic, Aesthetic, simulation on, synthesis on (the flags' gate open).
    static func project(organic: Bool = false) -> (ProjectModel, group: UUID, region: RegionID) {
        let p = ProjectModel(id: UUID(), name: "Prism", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = bandedCube()
        let rid = p.faceRegions.union(faces: [3, 8], named: "wall")
        p.selection.addGroup()
        p.selection.pickFaces([1])
        let gid = p.selection.groups[0].id
        p.selection.addRegions([rid], to: gid)
        p.force.sync(groups: p.selection.groups)
        p.force.setProtected(gid, true)
        _ = p.force.addManualPrimitive(.defaultBolt(at: SIMD3(5, 5, 5), radiusMM: 1, halfLengthMM: 2), to: gid)
        p.lattice.enabled = true
        p.lattice.paintDepthMM = 20
        p.lattice.groupRoles[gid] = .include
        p.printParams.strutLineWidthMM = 0.45
        if organic {
            p.lattice.algorithm = "organic"
            p.lattice.stageMode = .aesthetic
            p.lattice.simulateStresses = true
            p.lattice.organicSyntheticStresses = true
        }
        return (p, gid, rid)
    }

    /// A retained optimize document core's parser accepts, with a face-id clearance in its
    /// load case — the optimize path's own serializer. `protecting` ⇒ it also carries that
    /// project's FACE protections as `AppModel.makeRunRequest` reads them
    /// (`faceProtectionSpecs()`), so core's depth tie has something to check.
    static func original(protecting p: ProjectModel? = nil) throws -> Data {
        let prot = p?.faceProtectionSpecs()
        return try original(faceIDs: prot?.faceIDs ?? [], depthMM: prot?.depthMM ?? -1, depthsMM: prot?.depthsMM ?? [])
    }

    /// ★ Ruling 3: an OLD retained run — its protections as BARE face ids at the global depth
    /// (no per-face depths: the shape a run made before per-face depths, or with the wall's group
    /// protect-only, is written in). `depthMM` ≤ 0 omits the key and core uses its 5 mm default.
    static func original(bareProtection ids: [Int], depthMM: Double) throws -> Data {
        try original(faceIDs: ids, depthMM: depthMM, depthsMM: [])
    }

    static func original(faceIDs: [Int], depthMM: Double, depthsMM: [Double]) throws -> Data {
        let request = RunRequest(
            modelPath: "/tmp/part.step", material: "PLA", materialsPath: "",
            rulesPath: "", resolution: 64, projectName: "prism",
            anchorFaceIDs: [0],
            loadGroups: [TopOptKit.LoadGroupSpec(faceIDs: [4], force: SIMD3(0, 0, -250))],
            minimizePlastic: true, buildDirection: SIMD3(0, 0, 1),
            infillPercent: 40, wallLoops: 3,
            wallLineWidthOuterMM: 0.45, wallLineWidthInnerMM: 0.45,
            clearances: [TopOptKit.ClearanceSpec(faceID: 7, kind: .bolt, concentricMarginMM: 1.5)],
            faceProtections: faceIDs,
            faceProtectionDepthMM: depthMM,
            faceProtectionDepthsMM: depthsMM)
        let run = RemoteRun(config: RemoteRunnerConfig(host: "127.0.0.1", port: 8757, expectedFingerprint: "test"),
                            request: request, progress: { _, _, _ in true }, onVariant: { _ in })
        let job = try JSONSerialization.jsonObject(with: try run.buildJobJSON())
        return try JSONSerialization.data(withJSONObject: job, options: [.sortedKeys])
    }

    /// The variant's documents as the page builds them: the re-lattice run and its forecast
    /// (`RelatticeJobBuilder`), plus the Check-sizes probe on an organic lattice.
    static func variantDocuments(_ p: ProjectModel, retained given: Data? = nil) throws -> [(String, Data)] {
        // ★ ruling (b): the page's own builder — the stage's spec, Auto resolved
        guard let spec = p.latticeRunSpec(emission: p.variantLatticeJobRegions()) else {
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "no run spec"])
        }
        let retained = try given ?? Self.original(protecting: p)
        let run = try RelatticeJobBuilder.build(original: retained, designFingerprint: 0xDEAD_BEEF,
                                                achievedVolumeFraction: 0.42, designFileName: "design.bin",
                                                lattice: spec)
        let forecast = try RelatticeJobBuilder.build(original: retained, designFingerprint: 0xDEAD_BEEF,
                                                     achievedVolumeFraction: 0.42, designFileName: "design.bin",
                                                     lattice: spec, forecastOnly: true)
        var docs = [("run", run), ("forecast", forecast)]
        if p.lattice.algorithm == "organic" {
            docs.append(("probe", try RelatticeRun.probeJob(run, cellsMM: [3.5], gradesMM: [[3, 5]], recommend: .init())))
        }
        return docs
    }

    static func sorted(_ o: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    }

    /// A wire region as text, after a JSON round trip so a stage dictionary and a parsed document
    /// compare like for like (a Swift -0.0 is written "-0" and parses back as 0).
    static func wireText(_ region: [String: Any]) throws -> String {
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: try sorted(region)) as? [String: Any])
        return String(decoding: try sorted(parsed), as: UTF8.self)
    }
}
