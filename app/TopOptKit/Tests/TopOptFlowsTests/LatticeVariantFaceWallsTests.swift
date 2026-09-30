import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ RULINGS V1 / V2 (maintainer, 2026-09-29, re-lattice), under THE FACE-PRISM ROUTE (same
/// day): a variant's job (Check sizes, forecast, re-lattice: one builder) carries the stage's
/// walls, each face wall as its prism, so:
///  V1 — the synthetic-stress flags ride on those walls exactly as on the stage's job; and a
///       face wall is left out only where the stage leaves it out too (a marked face with no
///       shape to lattice), which is SAID, in one plain line, on all three surfaces — never
///       a silent result — and nothing is said when every wall is carried.
///  V2 — a primitive's own role (Solid / Off inside an include group) is read as the main
///       job reads it: emitted as exclude (never flagged, no density) or not at all.
@MainActor
final class LatticeVariantFaceWallsTests: XCTestCase {

    private func bolt(_ y: Double) -> ManualPrimitive {
        ManualPrimitive(kind: .bolt, center: SIMD3(0, y, 5), axis: SIMD3(0, 0, 1), radiusMM: 3, halfLengthMM: 5)
    }

    private static let root: URL = {
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        return u
    }()
    private func src(_ f: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent("Sources/TopOptFlows/\(f)"), encoding: .utf8)
    }

    // MARK: V1 — the flags ride along

    /// ★★ RULING 1 ON A VARIANT: every include wall is flagged — the face walls now too — each
    /// with its own count (a face region's member faces share the region's), else the default,
    /// exactly as the stage's job flags them; and the gate is the stage's.
    func testTheSyntheticFlagsRideAlongOnTheFaceWalls() throws {
        let (p, gid, rid) = VariantFacePrismFixture.project(organic: true)
        p.writeLatticeSyntheticFoci(.region(group: gid, region: rid), foci: 2)
        let variant = p.variantLatticeJobRegions().regions
        let faces = variant.filter { $0.kind == .face }
        XCTAssertEqual(faces.count, 3, "face 1 and the region's two member faces")
        XCTAssertTrue(variant.allSatisfy(\.syntheticStress), "★ every include wall, the face walls included")
        XCTAssertEqual(faces.filter { $0.rawFaceID == 1 }.compactMap(\.syntheticFoci), [4], "the default")
        XCTAssertEqual(faces.filter { $0.rawFaceID != 1 }.compactMap(\.syntheticFoci), [2, 2],
                       "★ the region's own count, on each member face")
        XCTAssertEqual(variant.map(\.syntheticFoci), p.latticeJobRegions().regions.map(\.syntheticFoci),
                       "as the stage's job flags them")
        // …on the wire of every variant document
        if TopOptKit.organicSyntheticStressWired {
            for (label, doc) in try VariantFacePrismFixture.variantDocuments(p) {
                let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: doc) as? [String: Any])
                let wire = try XCTUnwrap((obj["lattice"] as? [String: Any])?["regions"] as? [[String: Any]], label)
                let faceWire = wire.filter { $0["kind"] as? String == "face" }
                XCTAssertEqual(faceWire.count, 3, label)
                XCTAssertTrue(faceWire.allSatisfy { $0["synthetic_stress"] as? Bool == true }, "★ \(label)")
                XCTAssertEqual(faceWire.compactMap { $0["synthetic_foci"] as? Int }.sorted(), [2, 2, 4], label)
            }
        }
        // the gate is the stage's: the simulation off flags nothing, on the variant as on the stage
        p.lattice.setSimulateStresses(false)
        XCTAssertFalse(p.variantLatticeJobRegions().regions.contains(where: \.syntheticStress))
        XCTAssertFalse(p.latticeJobRegions().regions.contains(where: \.syntheticStress))
    }

    // MARK: V1 — the notice appears only when a wall is left out

    /// ★★ The line appears only when a variant's job leaves a face wall out — a marked face
    /// with no shape to lattice, which the stage's job leaves out too — and disappears when
    /// every wall is carried. The line V1 shipped ("only placed shapes are checked") is gone:
    /// the route made it untrue.
    func testTheNoticeAppearsOnlyWhenAFaceWallIsLeftOut() throws {
        let (p, _, _) = VariantFacePrismFixture.project()
        // every wall carried ⇒ nothing said
        XCTAssertEqual(p.variantLatticeJobRegions().skippedFaces, 0, "★ the walls are carried, so none is left out")
        XCTAssertNil(LatticeVariantFaceWalls.line(withoutShape: p.variantLatticeJobRegions().skippedFaces))
        // a marked face with no shape to lattice (face 42: not in the mesh) ⇒ left out of BOTH
        // jobs, and said
        p.selection.pickFaces([42])
        XCTAssertEqual(p.latticeJobRegions().skippedFaces, 1, "control: the stage leaves it out too")
        XCTAssertEqual(p.variantLatticeJobRegions().skippedFaces, 1)
        XCTAssertEqual(p.variantLatticeJobRegions().regions, p.latticeJobRegions().regions,
                       "the rest of the walls still travel")
        XCTAssertEqual(LatticeVariantFaceWalls.line(withoutShape: 1),
                       "1 marked face has no shape to lattice and is left out.")
        XCTAssertEqual(LatticeVariantFaceWalls.line(withoutShape: 3),
                       "3 marked faces have no shape to lattice and are left out.")
        // the re-lattice result carries its count through the store, and its notes say it
        let report = LatticeReport(topologyID: "octet", cellMM: 8, generateRelativeDensity: 0.5,
                                   minRelativeDensity: 0.2, maxRelativeDensity: 0.5, regionScoped: true,
                                   generated: .init(emitSTL: true, emit3MF: false, latticedCells: 1234,
                                                    regionVoxels: 5678, triangles: 987654,
                                                    strutRadiusMinMM: 0.8, strutRadiusMaxMM: 1.4),
                                   variantFacesWithoutShape: 1)
        let back = try OutcomeCodec.decode(try OutcomeCodec.encode(OutcomeCodec.dto(from: OptimizeOutcome(
            variants: [], stoppedOnMargin: false, cancelled: false, acceptedCount: 0, latticeReport: report))))
        XCTAssertEqual(back.latticeReport?.variantFacesWithoutShape, 1)
        XCTAssertTrue(ResultsModel.latticeNotes(back.latticeReport).contains("1 marked face has no shape to lattice and is left out."))
        // control: 0 ⇒ no line, and the stored outcome is written exactly as before (no key)
        let plain = LatticeReport(topologyID: "octet", cellMM: 8, generateRelativeDensity: 0.5,
                                  minRelativeDensity: 0.2, maxRelativeDensity: 0.5, regionScoped: true)
        XCTAssertFalse(ResultsModel.latticeNotes(plain).contains { $0.contains("no shape to lattice") })
        let bytes = try OutcomeCodec.encode(OutcomeCodec.dto(from: OptimizeOutcome(
            variants: [], stoppedOnMargin: false, cancelled: false, acceptedCount: 0, latticeReport: plain)))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("WithoutShape"))
        // the Check-sizes answer carries its count through the project file; V1's count (every
        // face wall, under its old key) is never read as this one
        var probe = try XCTUnwrap(OrganicForecast.parse(try JSONSerialization.data(
            withJSONObject: ["organic_probe_version": 1, "candidates": []] as [String: Any])))
        XCTAssertNil(probe.facesWithoutShape)
        probe.facesWithoutShape = 2
        let again = try JSONDecoder().decode(OrganicForecast.self, from: try JSONEncoder().encode(probe))
        XCTAssertEqual(again.facesWithoutShape, 2)
        var v1 = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(probe)) as? [String: Any])
        v1["faceWallsLeftOut"] = 3; v1["facesWithoutShape"] = nil
        XCTAssertNil(try JSONDecoder().decode(OrganicForecast.self, from: try JSONSerialization.data(withJSONObject: v1))
            .facesWithoutShape, "★ a V1 answer's count meant every face wall — not read as this one")
        // every surface draws it, from the job's own count
        let ws = try src("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("return (json, spec, emission.skippedFaces, emission.skippedRegionNames, coreRefusal)"),
                      "the job's own count, with the job's own spec (and core's verdict, ruling 3)")
        XCTAssertTrue(ws.contains("probe.facesWithoutShape = job.facesWithoutShape"), "Check sizes stamps its answer")
        XCTAssertTrue(ws.contains("probe.regionsWithoutShape = job.regionsWithoutShape.isEmpty ? nil : job.regionsWithoutShape"))
        XCTAssertTrue(ws.contains("variantFacesWithoutShape: withoutShape,\n                variantRegionsWithoutShape: regionsWithoutShape))"),
                      "the re-lattice result carries it")
        XCTAssertTrue(ws.contains("variantFacesWithoutShape: pass.facesWithoutShape,\n                    variantRegionsWithoutShape: pass.regionsWithoutShape,"),
                      "the forecast drawer gets it, from ONE emission per pass")
        XCTAssertTrue(try src("LatticePage.swift").contains(
            "if let scope = LatticeVariantFaceWalls.line(withoutShape: variantFacesWithoutShape,\n"
            + "                                                        regions: variantRegionsWithoutShape) {"))
        XCTAssertTrue(try src("LatticeSetupWizard.swift").contains(
            "LatticeVariantFaceWalls.line(withoutShape: project.lattice.currentOrganicForecast?.facesWithoutShape ?? 0,\n"
            + "                                                   regions: project.lattice.currentOrganicForecast?.regionsWithoutShape ?? [])"))
        let results = try src("ResultsModel.swift")
        XCTAssertTrue(results.contains("LatticeVariantFaceWalls.line(withoutShape: r.variantFacesWithoutShape,"))
        XCTAssertTrue(results.contains("regions: r.variantRegionsWithoutShape)].compactMap { $0 }"))
        XCTAssertTrue(results.contains("LatticeVariantFaceWalls.legacyLine(leftOut: r.variantLegacyFaceWallsLeftOut)"))
        // ★ the line V1 shipped is gone — the route made it untrue
        let all = try FileManager.default.contentsOfDirectory(atPath: Self.root.appendingPathComponent("Sources/TopOptFlows").path)
            .filter { $0.hasSuffix(".swift") }.map { try src($0) }.joined()
        XCTAssertEqual(all.components(separatedBy: "only placed shapes are checked").count - 1, 0,
                       "★ the V1 line is gone")
        XCTAssertEqual(all.components(separatedBy: " no shape to lattice and ").count - 1, 1,
                       "one sentence, one home: the builder the banner shares (ruling g)")
    }

    // MARK: ruling (g) — a dropped cut sector is counted and named

    /// The one sentence (ruling f's words, extended by ruling g): face-only output is the
    /// accepted notice byte for byte; the banner's clause is the same sentence, unfinished.
    func testTheSentenceForDroppedWalls() {
        typealias W = LatticeWallsWithoutShape
        XCTAssertNil(W.text(faces: 0, regions: [], ending: .leftOut), "nothing dropped, nothing said")
        XCTAssertEqual(W.text(faces: 1, regions: [], ending: .leftOut), "1 marked face has no shape to lattice and is left out.")
        XCTAssertEqual(W.text(faces: 3, regions: [], ending: .leftOut), "3 marked faces have no shape to lattice and are left out.")
        XCTAssertEqual(W.text(faces: 0, regions: ["wall A"], ending: .leftOut),
                       "The region “wall A” has no shape to lattice and is left out.")
        XCTAssertEqual(W.text(faces: 1, regions: ["wall A", "wall B"], ending: .leftOut),
                       "1 marked face and the regions “wall A” and “wall B” have no shape to lattice and are left out.")
        XCTAssertEqual(W.text(faces: 0, regions: ["a", "b", "c", "d", "e"], ending: .leftOut),
                       "The regions “a”, “b”, “c” and 2 more have no shape to lattice and are left out.")
        XCTAssertEqual(W.text(faces: 1, regions: [], ending: .notShown), "1 marked face has no shape to lattice and is not shown",
                       "★ the banner's old \"1 … are not shown\" is fixed")
        XCTAssertEqual(LatticeVariantFaceWalls.line(withoutShape: 0, regions: ["wall A"]),
                       W.text(faces: 0, regions: ["wall A"], ending: .leftOut))
    }

    /// ★★ RULING (g) (maintainer, 2026-09-30): a face region the run cannot consume — a cut
    /// sector — is counted and NAMED, on the stage and on variants, in the same notice; never a
    /// silent drop. A child whose whole-face parent emitted in the same group is NOT named: the
    /// parent's prisms carry its surface.
    func testACutSectorIsCountedAndNamedOnTheStageAndTheVariant() throws {
        let (p, gid, rid) = VariantFacePrismFixture.project()
        XCTAssertEqual(p.latticeJobRegions().skippedRegionNames, [], "control: nothing dropped")
        let before = p.latticeJobRegions().regions
        let kids = p.faceRegions.splitManual(rid, point: SIMD3(10, 5, 5), normal: SIMD3(0, 1, 0))
        XCTAssertEqual(kids.count, 2)
        // the parent and its cut children in ONE group: the parent emits, the children ride it
        p.selection.addRegions(kids, to: gid)
        XCTAssertNotNil(p.latticeRegionMembers(rid), "control: the parent is whole faces")
        XCTAssertNil(p.latticeRegionMembers(kids[0]), "control: a child is a cut sector")
        XCTAssertEqual(p.latticeJobRegions().skippedRegionNames, [], "★ an emitted parent carries its children")
        // …but only with the CHILD'S OWN role: an Off parent emits nothing, and a parent with
        // another role drops the child's own choice — either way the child is named
        let parentKey = LatticeSelectableRef.region(group: gid, region: rid).key
        let childKey = LatticeSelectableRef.region(group: gid, region: kids[0]).key
        p.lattice.selectableRoles[parentKey] = .off
        XCTAssertTrue(p.latticeJobRegions().skippedRegionNames.contains("wall A"), "★ an Off parent carries nothing")
        p.lattice.selectableRoles[parentKey] = nil
        p.lattice.selectableRoles[childKey] = .exclude
        XCTAssertEqual(p.latticeJobRegions().skippedRegionNames, ["wall A"], "★ a Solid child under a Lattice parent")
        p.lattice.selectableRoles[childKey] = nil
        XCTAssertEqual(p.latticeJobRegions().skippedRegionNames, [], "control: same role again ⇒ carried")
        // the cut child ALONE: dropped from the job, and NAMED
        p.selection.setRegions([kids[0]], for: gid)
        let stage = p.latticeJobRegions()
        XCTAssertEqual(stage.skippedRegionNames, ["wall A"], "★ counted and named, never silent")
        XCTAssertFalse(stage.regions.contains { $0.selectableKey == LatticeSelectableRef.region(group: gid, region: kids[0]).key },
                       "control: it really is not in the job")
        XCTAssertEqual(stage.regions.count, before.count - 2, "the whole region's two prisms are gone; nothing else moved")
        // …and the variant says the same, in the same sentence
        let variant = p.variantLatticeJobRegions()
        XCTAssertEqual(variant.skippedRegionNames, ["wall A"])
        XCTAssertEqual(LatticeVariantFaceWalls.line(withoutShape: variant.skippedFaces, regions: variant.skippedRegionNames),
                       "The region “wall A” has no shape to lattice and is left out.")
        // …and the stage's banner names it
        let scene = LatticePreviewSummaryValues(interiorVoxelCount: 10, previewLabel: "L",
                                                skippedRegionNames: stage.skippedRegionNames)
        XCTAssertEqual(LatticePreviewBanner.make(previewOn: true, hasModel: true, scene: scene),
                       .drawing("L · the region “wall A” has no shape to lattice and is not shown"))
        // a region set to Off is no wall: not named
        p.lattice.selectableRoles[LatticeSelectableRef.region(group: gid, region: kids[0]).key] = .off
        XCTAssertEqual(p.latticeJobRegions().skippedRegionNames, [])
        // the empty preview still names a drop, never only the depth advice
        let empty = LatticePreviewSummaryValues(interiorVoxelCount: 0, previewLabel: "L",
                                                partInteriorVoxelCount: 100, skippedRegionNames: ["wall A"])
        XCTAssertEqual(LatticePreviewBanner.make(previewOn: true, hasModel: true, scene: empty),
                       .empty("Nothing to lattice — the region “wall A” has no shape to lattice and is not shown. "
                              + "The rest reach no material: try a deeper slab."))
        // every wall dropped: the stage clips to NOTHING, so there is no "rest" to deepen
        let allDropped = LatticePreviewSummaryValues(interiorVoxelCount: 0, previewLabel: "L",
                                                     partInteriorVoxelCount: 100, skippedRegionNames: ["wall A"],
                                                     hasIncludeRegion: false)
        XCTAssertEqual(LatticePreviewBanner.make(previewOn: true, hasModel: true, scene: allDropped),
                       .empty("Nothing to lattice — the region “wall A” has no shape to lattice and is not shown."))
        let emptyNoDrop = LatticePreviewSummaryValues(interiorVoxelCount: 0, previewLabel: "L", partInteriorVoxelCount: 100)
        XCTAssertEqual(LatticePreviewBanner.make(previewOn: true, hasModel: true, scene: emptyNoDrop),
                       .empty("Nothing to lattice — the faces you marked do not reach any material. Try a deeper slab."),
                       "control: unchanged when nothing was dropped")
    }

    /// A re-lattice result stored by the V1 build (its key, its meaning: every face wall left out)
    /// keeps a line that is still true of it — never a silent result after the key changed.
    func testAV1EraResultKeepsATrueLine() throws {
        let plain = LatticeReport(topologyID: "octet", cellMM: 8, generateRelativeDensity: 0.5,
                                  minRelativeDensity: 0.2, maxRelativeDensity: 0.5, regionScoped: true,
                                  generated: .init(emitSTL: true, emit3MF: false, latticedCells: 1234,
                                                   regionVoxels: 5678, triangles: 987654,
                                                   strutRadiusMinMM: 0.8, strutRadiusMaxMM: 1.4))
        let stored = try OutcomeCodec.encode(OutcomeCodec.dto(from: OptimizeOutcome(
            variants: [], stoppedOnMargin: false, cancelled: false, acceptedCount: 0, latticeReport: plain)))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("variantFaceWallsLeftOut"),
                       "control: a new result never writes V1's key")
        // a V1 file: the same outcome with V1's key in its lattice report
        func inject(_ o: Any) -> Any {
            if var d = o as? [String: Any] {
                if d["topologyID"] != nil, d["cellMM"] != nil { d["variantFaceWallsLeftOut"] = 3 }
                return d.mapValues(inject)
            }
            if let a = o as? [Any] { return a.map(inject) }
            return o
        }
        // (the store is a binary property list)
        let v1 = try PropertyListSerialization.data(
            fromPropertyList: inject(try PropertyListSerialization.propertyList(from: stored, options: 0, format: nil)),
            format: .binary, options: 0)
        let back = try OutcomeCodec.decode(v1)
        XCTAssertEqual(back.latticeReport?.variantLegacyFaceWallsLeftOut, 3, "★ read from V1's key")
        let notes = ResultsModel.latticeNotes(back.latticeReport)
        XCTAssertTrue(notes.contains("Made before face walls reached variants: 3 face walls were left out."), "\(notes)")
        XCTAssertFalse(notes.contains { $0.contains("no shape to lattice") }, "never read as the new count")
        // …and kept when the outcome is saved again
        let again = try OutcomeCodec.decode(try OutcomeCodec.encode(OutcomeCodec.dto(from: back)))
        XCTAssertEqual(again.latticeReport?.variantLegacyFaceWallsLeftOut, 3)
        XCTAssertEqual(LatticeVariantFaceWalls.legacyLine(leftOut: 1), "Made before face walls reached variants: 1 face wall was left out.")
        XCTAssertNil(LatticeVariantFaceWalls.legacyLine(leftOut: 0))
    }

    /// The names travel with each variant answer and result, through the store.
    func testTheRegionNamesTravelWithTheAnswerAndTheResult() throws {
        let report = LatticeReport(topologyID: "octet", cellMM: 8, generateRelativeDensity: 0.5,
                                   minRelativeDensity: 0.2, maxRelativeDensity: 0.5, regionScoped: true,
                                   generated: .init(emitSTL: true, emit3MF: false, latticedCells: 1234,
                                                    regionVoxels: 5678, triangles: 987654,
                                                    strutRadiusMinMM: 0.8, strutRadiusMaxMM: 1.4),
                                   variantRegionsWithoutShape: ["wall A"])
        let back = try OutcomeCodec.decode(try OutcomeCodec.encode(OutcomeCodec.dto(from: OptimizeOutcome(
            variants: [], stoppedOnMargin: false, cancelled: false, acceptedCount: 0, latticeReport: report))))
        XCTAssertEqual(back.latticeReport?.variantRegionsWithoutShape, ["wall A"])
        XCTAssertTrue(ResultsModel.latticeNotes(back.latticeReport)
            .contains("The region “wall A” has no shape to lattice and is left out."))
        var probe = try XCTUnwrap(OrganicForecast.parse(try JSONSerialization.data(
            withJSONObject: ["organic_probe_version": 1, "candidates": []] as [String: Any])))
        XCTAssertNil(probe.regionsWithoutShape)
        probe.regionsWithoutShape = ["wall A"]
        XCTAssertEqual(try JSONDecoder().decode(OrganicForecast.self, from: try JSONEncoder().encode(probe)).regionsWithoutShape,
                       ["wall A"])
    }

    // MARK: V2 — the per-primitive role on a variant

    /// A bolt set to Solid inside an include group is EXCLUDE on the variant — never
    /// flagged, no dialled density; a bolt set to Off is not a region. As the main job.
    @MainActor func testTheReLatticeJobReadsThePerPrimitiveRoleOverride() throws {
        let p = ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        var sel = SelectionModel(); let gi = sel.addGroup(); let ge = sel.addGroup(); p.selection = sel
        let keep = p.force.addManualPrimitive(bolt(0), to: gi)
        let solid = p.force.addManualPrimitive(bolt(20), to: gi)
        let off = p.force.addManualPrimitive(bolt(40), to: gi)
        let flipped = p.force.addManualPrimitive(bolt(60), to: ge)
        // declared groups: the variant's job is the stage's, which lattices only an eligible
        // group (protected, anchor or load — `latticeEligibleRoles`)
        p.force.sync(groups: p.selection.groups)
        p.force.setProtected(gi, true); p.force.setProtected(ge, true)
        p.lattice.enabled = true
        p.lattice.groupRoles = [gi: .include, ge: .exclude]
        p.lattice.algorithm = "organic"; p.lattice.stageMode = .aesthetic
        p.lattice.simulateStresses = true; p.lattice.organicSyntheticStresses = true
        p.lattice.groupDensities[gi] = 0.3
        func at(_ y: Double) -> [LatticeRegionSpec] {
            p.variantLatticeJobRegions().regions.filter { $0.axisPoint == SIMD3<Double>(0, y, 5) }
        }
        // control: no override ⇒ every bolt follows its group
        XCTAssertEqual(p.variantLatticeJobRegions().regions.count, 4)
        XCTAssertEqual(at(20).first?.role, .include)
        // the chip's writes
        p.lattice.selectableRoles[LatticeSelectableRef.primitive(solid).key] = .exclude
        p.lattice.selectableRoles[LatticeSelectableRef.primitive(off).key] = .off
        p.lattice.selectableRoles[LatticeSelectableRef.primitive(flipped).key] = .include
        let regions = p.variantLatticeJobRegions().regions
        XCTAssertEqual(regions.count, 3, "★ an Off bolt is not a region")
        XCTAssertTrue(at(40).isEmpty)
        let s = try XCTUnwrap(at(20).first)
        XCTAssertEqual(s.role, .exclude, "★ a Solid bolt inside an include group is exclude")
        XCTAssertFalse(s.syntheticStress); XCTAssertNil(s.syntheticFoci)
        XCTAssertNil(s.relativeDensity, "★ core refuses a density on an exclude region")
        XCTAssertNil(s.wireDictionary["relative_density"]); XCTAssertNil(s.wireDictionary["synthetic_stress"])
        let k = try XCTUnwrap(at(0).first)
        XCTAssertEqual(k.role, .include); XCTAssertTrue(k.syntheticStress); XCTAssertEqual(k.relativeDensity, 0.3)
        let f = try XCTUnwrap(at(60).first)
        XCTAssertEqual(f.role, .include, "an include override inside an exclude group is include, as regions() has it")
        XCTAssertTrue(f.syntheticStress)
        _ = keep
        // the variant's job IS the stage's emission, overrides and all
        XCTAssertEqual(regions, p.latticeJobRegions().regions)
        XCTAssertTrue(try src("ProjectModel.swift").contains(
            "public func variantLatticeJobRegions() -> LatticeRegionEmission.Result {\n        latticeJobRegions()\n    }"))
    }
}
