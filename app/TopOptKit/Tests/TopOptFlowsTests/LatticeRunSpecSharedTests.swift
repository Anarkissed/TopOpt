import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ RULING (b) (maintainer, 2026-09-30): LatticeAutoPosture on the variant job, as the stage
/// does — ONE spec builder, `ProjectModel.latticeRunSpec`, for the stage's request, a variant's
/// re-lattice (run, forecast, Check sizes) and its receipt echo. The stage's spec, and so its job
/// bytes, must not move.
@MainActor
final class LatticeRunSpecSharedTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static func core(_ rel: String) -> String { repoRoot.appendingPathComponent("core/\(rel)").path }

    /// THE STAGE'S RECIPE AS IT SHIPPED (aecef72c, `AppModel.makeRunRequest`), rebuilt inline:
    /// the reference the moved builder must equal, setting for setting.
    /// (`emitted` is passed in: two emissions can list an outline's loops in different hash
    /// orders, so a comparison between specs uses ONE.)
    private func shippedStageRecipe(_ p: ProjectModel, _ emitted: LatticeRegionEmission.Result) -> LatticeSpec? {
        let includeCount = emitted.regions.filter { $0.role == .include }.count
        let resolved = LatticeAutoPosture.applied(
            to: p.lattice, includeRegionCount: includeCount,
            regionWidthsMM: emitted.regions.filter { $0.role == .include }.map { $0.depthMM },
            lineWidthMM: p.printParams.strutLineWidthMM)
        var s = resolved.runSpec(topology: p.lattice.topologyID, memberMM: p.lattice.regionMemberMM ?? 0,
                                 lineWidthMM: p.printParams.strutLineWidthMM, regions: emitted.regions,
                                 minimizePlastic: p.minimizePlastic, layerHeightMM: p.printParams.layerHeightMM)
        s?.steppedCells = p.latticePreviewSteppedCells
        return s
    }

    /// THE VARIANT'S RECIPE BEFORE (b) (`relatticeJobJSON`, aecef72c): no posture.
    private func unposturedVariantRecipe(_ p: ProjectModel, _ emitted: LatticeRegionEmission.Result) -> LatticeSpec? {
        var s = p.lattice.runSpec(topology: p.lattice.topologyID, memberMM: p.lattice.regionMemberMM ?? 0,
                                  lineWidthMM: p.printParams.strutLineWidthMM,
                                  regions: emitted.regions,
                                  layerHeightMM: p.printParams.layerHeightMM)
        s?.steppedCells = p.latticePreviewSteppedCells
        return s
    }

    /// The settings the matrix walks: every cell mode, organic, and the two toggles Auto reads.
    private func settings() -> [(String, (inout LatticeSettings) -> Void)] {
        [("octet auto", { _ in }),
         ("octet fixed", { $0.cellSizeMode = .fixed }),
         ("octet swept", { $0.cellSizeMode = .swept; $0.cellMinMM = 4; $0.cellMaxMM = 8 }),
         ("octet fit", { $0.cellSizeMode = .fit }),
         ("octet auto + retain sub-floor", { $0.retainSubfloorInUnloadedRegions = true }),
         ("octet auto + allow quilt", { $0.allowQuilt = true }),
         ("organic auto", { $0.algorithm = "organic" })]
    }

    /// ★ The stage's spec is the shipped recipe's, byte for byte, in every setting.
    func testTheSharedBuilderIsTheShippedStageRecipe() throws {
        for (label, change) in settings() {
            let (p, _, _) = VariantFacePrismFixture.project()
            change(&p.lattice)
            let e = p.latticeJobRegions()
            let shipped = shippedStageRecipe(p, e)
            XCTAssertNotNil(shipped, "\(label): control — a spec is built")
            XCTAssertEqual(p.latticeRunSpec(emission: e), shipped, "★ \(label)")
        }
    }

    /// ★ THE CALL SITE, not the value: the stage's request carries exactly the builder's spec.
    func testTheStageRequestCarriesTheSharedBuildersSpec() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-run-spec-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let m = AppModel(materialsPath: Self.core("src/materials/materials.json"),
                         rulesPath: Self.core("src/settings/rules.json"),
                         store: ProjectStore(rootDir: tmp),
                         presetStore: PrintParamsPresetStore(rootDir: tmp))
        m.loadMaterials(); m.newTopOpt(); m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.core("tests/fixtures/stl/cube_10mm.stl"), displayName: "Cube.stl"))
        m.continueToWorkspace()
        let p = try XCTUnwrap(m.project)
        p.lattice.enabled = true
        p.lattice.densityMode = .sim
        // an include wall declared through a protected group — a LEGACY include primitive would
        // set a member width, and the cells-per-member ceiling would refuse the default cell
        let gid = p.selection.addGroup()
        p.force.sync(groups: p.selection.groups)
        p.force.setProtected(gid, true)
        _ = p.force.addManualPrimitive(.defaultBolt(at: SIMD3(5, 5, 5), radiusMM: 2, halfLengthMM: 3), to: gid)
        p.lattice.groupRoles[gid] = .include
        XCTAssertNil(p.lattice.regionMemberMM, "control: no legacy member width")
        XCTAssertTrue(p.latticeJobRegions().regions.contains { $0.role == .include }, "control: an include wall")
        let e = p.latticeJobRegions()
        let spec = try XCTUnwrap(p.latticeRunSpec(emission: e))
        XCTAssertNotNil(m.makeRunRequest()?.lattice, "control: a nil can never pass as equal")
        XCTAssertNotNil(m.makeLatticeRunRequest()?.lattice)
        XCTAssertEqual(m.makeRunRequest()?.lattice, spec, "★ the Optimize request")
        XCTAssertEqual(m.makeLatticeRunRequest()?.lattice, spec, "★ the Lattice request")
        XCTAssertEqual(spec, shippedStageRecipe(p, e), "and it is the shipped recipe")
    }

    /// ★★ The variant's job now carries the stage's Auto-RESOLVED spec (octet Auto: the swept
    /// window from the walls and the bead, the per-region report). POSITIVE CONTROL: the
    /// variant's old, unpostured recipe differs, so this test fails against it.
    func testTheVariantJobCarriesTheStagesAutoResolvedSpec() throws {
        let (p, _, _) = VariantFacePrismFixture.project()
        XCTAssertEqual(p.lattice.cellSizeMode, .auto, "precondition: Auto")
        XCTAssertFalse(p.lattice.isOrganic)
        let e = p.latticeJobRegions()
        let stage = try XCTUnwrap(p.latticeRunSpec(emission: e))
        let variant = try XCTUnwrap(p.latticeRunSpec(emission: p.variantLatticeJobRegions()))
        func text(_ o: Any?) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: o ?? [:], options: [.sortedKeys]), as: UTF8.self)
        }
        XCTAssertEqual(try text(variant.gradingDictionary()), try text(stage.gradingDictionary()),
                       "★ the stage's Auto-resolved grading")
        XCTAssertEqual(variant.regions, stage.regions, "and the stage's walls")
        XCTAssertEqual(variant.cellSizeMode, stage.cellSizeMode)
        XCTAssertEqual(variant.reportRegionCells, stage.reportRegionCells)
        XCTAssertEqual(stage.cellSizeMode, "swept", "control: Auto resolved to a swept window")
        XCTAssertTrue(stage.reportRegionCells, "control: …with the per-region report")
        XCTAssertNotEqual(unposturedVariantRecipe(p, e), stage,
                          "★ positive control: the variant's old recipe did NOT carry it")
        // …and it reaches every variant document's grading block
        let grading = try XCTUnwrap(stage.gradingDictionary())
        for (label, doc) in try VariantFacePrismFixture.variantDocuments(p) {
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: doc) as? [String: Any])
            let g = try XCTUnwrap(obj["grading"] as? [String: Any], label)
            XCTAssertEqual(g["cell_mode"] as? String, "swept", label)
            XCTAssertEqual(g["cell_min_mm"] as? Double, grading["cell_min_mm"] as? Double, label)
            XCTAssertEqual(g["cell_max_mm"] as? Double, grading["cell_max_mm"] as? Double, label)
            XCTAssertEqual(g["report_region_cells"] as? Bool, true, label)
            XCTAssertNil(TopOptKit.jobSchemaError(doc), label)
        }
    }

    /// The posture acts only on non-organic Auto: organic and every other cell mode give the
    /// variant the spec it had — so organic variant and Check-sizes documents do not move.
    func testOrganicAndNonAutoVariantSpecsDoNotMove() throws {
        for (label, change) in settings() where label != "octet auto" && !label.hasPrefix("octet auto +") {
            let (p, _, _) = VariantFacePrismFixture.project()
            change(&p.lattice)
            let e = p.variantLatticeJobRegions()
            XCTAssertEqual(p.latticeRunSpec(emission: e), unposturedVariantRecipe(p, e),
                           "\(label): unchanged by the posture")
        }
    }

    /// One builder, three callers; no second recipe left behind.
    func testOneBuilderNoSecondRecipe() throws {
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<3 { root.deleteLastPathComponent() }
        func src(_ f: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("Sources/TopOptFlows/\(f)"), encoding: .utf8)
        }
        let app = try src("AppModel.swift"), ws = try src("WorkspacePlaceholder.swift")
        XCTAssertTrue(app.contains("let latticeSpec = project.latticeRunSpec(emission: emission)"))
        XCTAssertTrue(app.contains("let emission = project.latticeJobRegions()"), "one emission (ruling 2)")
        XCTAssertFalse(app.contains("LatticeAutoPosture.applied("), "the recipe moved")
        XCTAssertFalse(app.contains(".runSpec("), "the recipe moved")
        XCTAssertTrue(ws.contains("guard let spec = project.latticeRunSpec(emission: emission),"), "the variant's job")
        XCTAssertTrue(ws.contains("let echo = job.spec"), "the receipt echo is the submitted spec")
        XCTAssertFalse(ws.contains("project.lattice.runSpec("), "no unpostured variant recipe left")
        XCTAssertTrue(ws.contains("regionCellsJSON: spec.reportRegionCells ? result.receiptJSON : nil"))
    }
}
