import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ RULINGS V1 / V2 (maintainer, 2026-09-29, re-lattice). A variant's job (Check sizes,
/// forecast, re-lattice: one builder) carries placed shapes only (bar Z11), so:
///  V1 — a face wall left out is SAID, in one plain line, on all three surfaces — never a
///       silent result; face-region walls count too, a wall set to Off is no wall.
///  V2 — a primitive's own role (Solid / Off inside an include group) is read as the main
///       job reads it: emitted as exclude (never flagged, no density) or not at all.
@MainActor
final class LatticeVariantFaceWallsTests: XCTestCase {

    private func bolt(_ y: Double) -> ManualPrimitive {
        ManualPrimitive(kind: .bolt, center: SIMD3(0, y, 5), axis: SIMD3(0, 0, 1), radiusMM: 3, halfLengthMM: 5)
    }

    // MARK: V1 — the count and the line

    func testTheLineIsSaidOnlyWhenAWallWasLeftOut() {
        XCTAssertNil(LatticeVariantFaceWalls.line(leftOut: 0), "control: nothing left out, nothing said")
        XCTAssertEqual(LatticeVariantFaceWalls.line(leftOut: 1), LatticeVariantFaceWalls.leftOutLine)
        XCTAssertEqual(LatticeVariantFaceWalls.leftOutLine,
                       "On a variant, only placed shapes are checked; your face walls aren’t included yet.")
    }

    /// Face REGIONS are face walls too (his stand: face region 101 was never counted), and
    /// a wall set to Off is no wall; an exclude wall is still a wall left out.
    func testEveryFaceWallLeftOutIsCounted() {
        let gid = UUID()
        let region = SelectionGroup(id: gid, name: "g", colorIndex: 0, faces: [], regionIDs: [3])
        let r1 = LatticeRegionEmission.variantRegions(groups: [region], roles: [gid: .include],
                                                     primitives: { _ in [] }, includePrimitives: [])
        XCTAssertEqual(r1.skippedFaces, 1, "★ a face-region wall is left out too")
        let mixed = SelectionGroup(id: gid, name: "g", colorIndex: 0, faces: [7, 9], regionIDs: [3, 4])
        let off = [LatticeSelectableRef.face(group: gid, face: 9).key: LatticeSelectableRole.off,
                   LatticeSelectableRef.region(group: gid, region: 4).key: LatticeSelectableRole.exclude]
        let r2 = LatticeRegionEmission.variantRegions(groups: [mixed], roles: [gid: .include],
                                                     primitives: { _ in [] }, includePrimitives: [],
                                                     selectableRoles: off)
        XCTAssertEqual(r2.skippedFaces, 3, "face 7, region 3, and region 4 (exclude) — face 9 is Off")
        // controls
        let prims = SelectionGroup(id: gid, name: "g", colorIndex: 0)
        XCTAssertEqual(LatticeRegionEmission.variantRegions(groups: [prims], roles: [gid: .include],
                                                            primitives: { _ in [(self.bolt(0), 1)] },
                                                            includePrimitives: []).skippedFaces, 0)
        XCTAssertEqual(LatticeRegionEmission.variantRegions(groups: [mixed], roles: [:],
                                                            primitives: { _ in [] }, includePrimitives: []).skippedFaces, 0,
                       "a group with no role carries nothing")
    }

    /// The line travels with each answer and each result, and every surface draws it.
    func testTheLineReachesCheckSizesTheForecastAndTheRelattice() throws {
        // the re-lattice result: its notes carry the line, and it survives the store
        let report = LatticeReport(topologyID: "octet", cellMM: 8, generateRelativeDensity: 0.5,
                                   minRelativeDensity: 0.2, maxRelativeDensity: 0.5, regionScoped: true,
                                   generated: .init(emitSTL: true, emit3MF: false, latticedCells: 1234,
                                                    regionVoxels: 5678, triangles: 987654,
                                                    strutRadiusMinMM: 0.8, strutRadiusMaxMM: 1.4),
                                   variantFaceWallsLeftOut: 2)
        let o = OptimizeOutcome(variants: [], stoppedOnMargin: false, cancelled: false,
                                acceptedCount: 0, latticeReport: report)
        let back = try OutcomeCodec.decode(try OutcomeCodec.encode(OutcomeCodec.dto(from: o)))
        XCTAssertEqual(back.latticeReport?.variantFaceWallsLeftOut, 2)
        XCTAssertTrue(ResultsModel.latticeNotes(back.latticeReport).contains(LatticeVariantFaceWalls.leftOutLine))
        // control: 0 ⇒ no line, and the stored outcome is written exactly as before (no key)
        let plain = LatticeReport(topologyID: "octet", cellMM: 8, generateRelativeDensity: 0.5,
                                  minRelativeDensity: 0.2, maxRelativeDensity: 0.5, regionScoped: true)
        XCTAssertFalse(ResultsModel.latticeNotes(plain).contains(LatticeVariantFaceWalls.leftOutLine))
        let bytes = try OutcomeCodec.encode(OutcomeCodec.dto(from: OptimizeOutcome(
            variants: [], stoppedOnMargin: false, cancelled: false, acceptedCount: 0, latticeReport: plain)))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("variantFaceWallsLeftOut"))
        // the Check-sizes answer carries its count through the project file; an old one has none
        var probe = try XCTUnwrap(OrganicForecast.parse(try JSONSerialization.data(
            withJSONObject: ["organic_probe_version": 1, "candidates": []] as [String: Any])))
        XCTAssertNil(probe.faceWallsLeftOut)
        probe.faceWallsLeftOut = 2
        let again = try JSONDecoder().decode(OrganicForecast.self, from: try JSONEncoder().encode(probe))
        XCTAssertEqual(again.faceWallsLeftOut, 2)
        // every surface draws it — and the old, never-seen note is gone
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<3 { root.deleteLastPathComponent() }
        func src(_ f: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("Sources/TopOptFlows/\(f)"), encoding: .utf8)
        }
        let ws = try src("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("probe.faceWallsLeftOut = job.faceWallsLeftOut"), "Check sizes stamps its answer")
        XCTAssertTrue(ws.contains("variantFaceWallsLeftOut: leftOut))"), "the re-lattice result carries it")
        XCTAssertTrue(ws.contains("variantFaceWallsLeftOut: latticeVariantFaceWallsLeftOut)"), "the forecast drawer gets it")
        XCTAssertFalse(ws.contains("noteSkippedFaces") || ws.contains("were not carried"), "the unseen note is gone")
        XCTAssertTrue(try src("LatticePage.swift").contains("if let scope = LatticeVariantFaceWalls.line(leftOut: variantFaceWallsLeftOut)"))
        XCTAssertTrue(try src("LatticeSetupWizard.swift").contains(
            "LatticeVariantFaceWalls.line(leftOut: project.lattice.organicForecast?.faceWallsLeftOut ?? 0)"))
        XCTAssertTrue(try src("ResultsModel.swift").contains("LatticeVariantFaceWalls.line(leftOut: r.variantFaceWallsLeftOut)"))
        let all = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Sources/TopOptFlows").path)
            .filter { $0.hasSuffix(".swift") }.map { try src($0) }.joined()
        XCTAssertEqual(all.components(separatedBy: "only placed shapes are checked").count - 1, 1, "one sentence, one home")
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
        // the variant path passes the overrides
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<3 { root.deleteLastPathComponent() }
        let pm = try String(contentsOf: root.appendingPathComponent("Sources/TopOptFlows/ProjectModel.swift"), encoding: .utf8)
        XCTAssertTrue(pm.contains("selectableRoles: lattice.selectableRoles,\n            // ★ ruling 1"))
    }
}
