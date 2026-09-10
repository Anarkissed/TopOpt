import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★★ HIS WALK, 2026-09-07 evening — the sample back to the distance field, a bake
/// stage that took two minutes to do 0.3 s of work, synthetic stress invisible in the
/// stress map, Manual density dropping out of Organic, and a Look control that moved
/// nothing.
final class OrganicLookAndVisibilityTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func wall(depth: Double, halfMM: Double, faceID: Int) -> LatticeRegionSpec {
        var s = LatticeRegionSpec(role: .include, kind: .face)
        s.origin = SIMD3<Double>(0, 0, 0)
        s.normal = SIMD3<Double>(0, 1, 0)
        s.halfUMM = halfMM; s.halfWMM = halfMM; s.depthMM = depth
        s.outlineLoops = [[SIMD2(-halfMM, -halfMM), SIMD2(halfMM, -halfMM),
                           SIMD2(halfMM, halfMM), SIMD2(-halfMM, halfMM)]]
        s.faceID = faceID
        return s
    }

    // MARK: the sample was back to the distance field

    func testACachedVariantCarriesItsCapsules() throws {
        let doc = OrganicBeamLattice3MF.Document(
            spans: [(a: SIMD3<Double>(0, 0, 0), b: SIMD3<Double>(5, 0, 0), r: 0.3),
                    (a: SIMD3<Double>(5, 0, 0), b: SIMD3<Double>(5, 5, 0), r: 0.3)],
            metadata: [:])
        let baked = try XCTUnwrap(OrganicVariantCache.bake(
            doc, origin: SIMD3<Float>(-2, -2, -2), voxelMM: 0.5, dims: (24, 24, 12),
            bandMM: 1.0, source: .bundle))
        XCTAssertEqual(baked.capsules.count, 2,
                       "★ the impostor pass draws these — with none, the march falls back to the field")
        XCTAssertEqual(baked.capsules[0].r, 0.3, accuracy: 1e-6)
        // …and a scene built from them hands them on.
        let mesh = LatticeWizardSample.cube(edgeMM: 20, at: .zero)
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    stageMode: .aesthetic, algorithm: "organic",
                                    organicBaked: baked)
        XCTAssertEqual(scene.organicCapsules.count, 2)
    }

    // MARK: the two-minute stage

    func testTheVoxelRegionPlanIsBuiltOncePerBake() throws {
        let ws = try source("TopOptFlows/WorkspacePlaceholder.swift")
        let builds = ws.components(separatedBy: "OrganicSyntheticStress.plan(").count - 1
        XCTAssertEqual(builds, 1, "★ one plan per bake — it tags every voxel by point-in-polygon")
        XCTAssertTrue(ws.contains("plan: synthPlan,"), "★ …and the auto window is handed that one")
        let aw = try source("TopOptFlows/OrganicAutoWindow.swift")
        XCTAssertFalse(aw.contains("OrganicSyntheticStress.plan("),
                       "★ the auto window must never build its own")
    }

    // MARK: synthetic stress must be visible

    func testTheSynthesisedFieldComesBackAndPaintsTheMap() throws {
        let br = try source("TopOptBridge/bridge.cpp")
        XCTAssertTrue(br.contains("out[59] = 1.0;"), "★ the bridge returns the field the tracer saw")
        let kit = try source("TopOptKit/TopOptKit.swift")
        XCTAssertTrue(kit.contains("public var syntheticVonMises: [Double] = []"))
        XCTAssertTrue(kit.contains("synthVM = Array(raw[vmOff..<(vmOff + n)])"))
        let sdf = try source("TopOptFlows/LatticeSDFMetal.swift")
        XCTAssertTrue(sdf.contains("like: occupancy, field: organicSynthFieldOut ?? stressField ?? field)"),
                      "★ the stress map paints the synthesised field when there is one")
    }

    // MARK: Manual density must not drop out of Organic

    func testTheStrutWidthCannotGoUnderOneBead() throws {
        let wz = try source("TopOptFlows/LatticeSetupWizard.swift")
        XCTAssertTrue(wz.contains("range: beadMM...5"),
                      "★ a strut thinner than one extrusion is refused by core and the "
                      + "preview fell back to the ladder without saying so")
        XCTAssertTrue(wz.contains("model.organicStrutWidthMM = Swift.max($0, beadMM)"))
        XCTAssertFalse(wz.contains("range: 0.2...5"), "★ the old floor is gone")
    }

    // MARK: the Look slider

    func testLookIsAPercentageThatPicksTheCell() {
        let band = TopOptKit.OrganicRecommendBandResult(
            loMM: 2, hiMM: 6, printabilityFloorMM: 0.7, resolutionFloorMM: 1.7,
            memberCeilingMM: 6, extentCeilingMM: 15, collapsed: false,
            lookCellMM: 3, gradeRatio: 1.5, candidates: [])
        // 1 % = the largest cell the wall can hold
        guard let coarse = OrganicAutoWindow.window(percent: 1, band: band),
              let fine = OrganicAutoWindow.window(percent: 100, band: band),
              let mid = OrganicAutoWindow.window(percent: 50, band: band) else {
            return XCTFail("the band did not produce a window")
        }
        // ★★★ THE SLIDER NAMES THE COARSEST CELL, AND THE GRADE OPENS DOWNWARD FROM IT
        // (2026-09-07). The pair used to be `(cell, cell · spread)`, and the preview
        // hands an IDLE voxel the window's HIGH end — so on a lightly loaded part almost
        // every cell was `cell · spread` and the number on the control appeared nowhere
        // in the picture. His own definition decides the end: "1 % is the largest cell
        // across the width possible, 100 % is the smallest cells possible."
        XCTAssertEqual(coarse.hi, 6, accuracy: 1e-9, "★ 1 % ⇒ the largest cell the wall holds")
        XCTAssertEqual(fine.hi, 2, accuracy: 1e-9, "★ 100 % ⇒ the smallest core will print")
        XCTAssertEqual(fine.lo, 2, accuracy: 1e-9, "★ …and the grade cannot go under the band's floor")
        // t = (50 − 1) / 99, so the midpoint of the CONTROL, not of the band.
        let midCell = 6 - (49.0 / 99.0) * (6 - 2)
        XCTAssertEqual(mid.hi, midCell, accuracy: 1e-9, "★ halfway along the slider")
        XCTAssertEqual(mid.lo, midCell / 1.5, accuracy: 1e-9, "the grading spread, opening downward")
        // …and it moves monotonically in between, which "8 cells across" did not.
        XCTAssertLessThan(mid.hi, coarse.hi)
        XCTAssertGreaterThan(mid.hi, fine.hi)
        // ★ THE PROMISED CELL IS NEVER EXCEEDED — the whole point of the flip.
        for pct in stride(from: 1.0, through: 100.0, by: 1.0) {
            guard let w = OrganicAutoWindow.window(percent: pct, band: band) else {
                return XCTFail("no window at \(pct) %")
            }
            XCTAssertLessThanOrEqual(w.lo, w.hi, "★ an inverted window at \(pct) %")
            XCTAssertLessThanOrEqual(w.hi, band.hiMM + 1e-9,
                                     "★ the window left the band at \(pct) %")
            XCTAssertGreaterThanOrEqual(w.lo, band.loMM - 1e-9,
                                        "★ the window left the band at \(pct) %")
        }
        // A wall too thin for any cell: no window, and the region goes solid.
        let collapsed = TopOptKit.OrganicRecommendBandResult(
            loMM: 6, hiMM: 2, printabilityFloorMM: 0.7, resolutionFloorMM: 1.7,
            memberCeilingMM: 2, extentCeilingMM: 15, collapsed: true,
            lookCellMM: 0, gradeRatio: 1, candidates: [])
        XCTAssertNil(OrganicAutoWindow.window(percent: 50, band: collapsed))
    }

    func testTheLookWindowComesFromTheWallsAndReachesTheJob() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        let regions = [wall(depth: 11, halfMM: 40, faceID: 15)]
        let coarse = try XCTUnwrap(OrganicAutoWindow.lookWindow(
            percent: 1, regions: regions, beadMM: 0.45, voxelMM: 1.7, lookCellsAcross: 8))
        let fine = try XCTUnwrap(OrganicAutoWindow.lookWindow(
            percent: 100, regions: regions, beadMM: 0.45, voxelMM: 1.7, lookCellsAcross: 8))
        print("── look 1 % → \(coarse.lo)–\(coarse.hi) mm · look 100 % → \(fine.lo)–\(fine.hi) mm")
        XCTAssertGreaterThan(coarse.hi, fine.hi, "★ 1 % is the coarsest, 100 % the finest")
        XCTAssertGreaterThanOrEqual(fine.lo, 1.7 - 1e-9, "never under the grid's own floor")
        XCTAssertLessThanOrEqual(coarse.hi, 11.0 / 2 + 1e-9, "never wider than the wall holds")
        // The slider writes the job's own cell keys, so the run builds what is shown.
        let wz = try source("TopOptFlows/LatticeSetupWizard.swift")
        XCTAssertTrue(wz.contains("model.organicPickedGradeMM = [w.lo, w.hi]"),
                      "★ the slider writes the grade the job carries")
        // ★ A SLIDER WITH A THUMB AND A TRACK (his walk, 2026-09-07: "Look needs to be
        // a slider, I don't see anything to hold"). The scrub row it replaced was a
        // drag-anywhere field with neither.
        XCTAssertTrue(wz.contains("Slider(value: Binding("), "★ a real slider")
        XCTAssertTrue(wz.contains("in: 1...100, step: 1"), "★ 1 % to 100 %")
        XCTAssertTrue(wz.contains("Text(\"1%\")") && wz.contains("Text(\"100%\")"),
                      "★ …with its ends labelled")
        XCTAssertFalse(wz.contains("unit: \" cells across\""), "★ the cells-across control is gone")
        // ★ AND THE JOB MUST CARRY IT EITHER WAY. Without a stress range the band's
        // spread is 1, so the window collapses to one size — `gradingDictionary` refuses
        // a grade whose ends are equal, and the job would have carried NO cell keys and
        // let core choose. A single size goes out as `cell_mm`.
        XCTAssertTrue(wz.contains("model.organicPickedSeparationMM = w.lo"),
                      "★ a collapsed window is written as a single size")
        var spec = LatticeSpec(topologyID: "octet", cellMM: 8, strutRadiusMM: 0.6,
                               generateRelativeDensity: 0.2, minRelativeDensity: 0.05,
                               maxRelativeDensity: 0.9, graded: true)
        spec.algorithm = "organic"
        if fine.hi > fine.lo + 1e-9 {
            spec.organicPickedGradeMM = [fine.lo, fine.hi]
            let g = try XCTUnwrap(spec.gradingDictionary())
            XCTAssertEqual(g["cell_min_mm"] as? Double, fine.lo)
            XCTAssertEqual(g["cell_max_mm"] as? Double, fine.hi)
        } else {
            spec.organicPickedSeparationMM = fine.lo
            let g = try XCTUnwrap(spec.gradingDictionary())
            XCTAssertEqual(g["cell_mm"] as? Double, fine.lo)
            XCTAssertEqual(g["cell_mode"] as? String, "fit")
        }
    }

    // MARK: two more edge losses

    /// The capsules are analytic geometry; the march's crease-sliver trim is not theirs.
    func testTheCapsuleClipDoesNotErodeThePart() throws {
        // ★ THE CLIP MOVED INTO `cap_clip_field` (2026-09-08) so the wetted join can
        // take its GRADIENT as well as its sign; `cap_inside_clip` is now a thin test
        // over it. The rule this guards is unchanged: no march erosion on an analytic
        // capsule.
        let src = MeshRenderer.organicCapsuleShaderSourceForTesting
        guard let r = src.range(of: "static float cap_clip_field(") else {
            return XCTFail("the capsule clip moved")
        }
        let body = String(src[r.lowerBound...].prefix(1600))
        XCTAssertTrue(body.contains("float dPart = sdfTex.sample(samp, stc).r;"),
                      "★ no trim erosion — it shaved 0.35 mm off every boundary")
        XCTAssertFalse(body.contains("+ delta"), "★ the march's erosion is gone from here")
    }

    /// Region membership is read on the tracer's own grid, not rounded onto another.
    func testTheCandidateSetIsNotResampled() throws {
        let sdf = try source("TopOptFlows/LatticeSDFMetal.swift")
        XCTAssertTrue(sdf.contains("let exactRegions = o.regionIDs.count == tnx * tny * tnz"))
        XCTAssertTrue(sdf.contains("guard o.regionIDs[idx] >= 1, occ.values[oi] > 0.5 || partSolidAt(p) else { continue }"),
                      "★ the region is asked exactly; the occupancy only says whether there is material")
        let ws = try source("TopOptFlows/WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("organicIn?.regionIDs = synthPlan.regionIDs\n            if synthOn"),
                      "★ the ids are handed over whether or not synthesis is on")
    }

    func testTheLookPercentIsSaved() throws {
        var l = LatticeSettings(enabled: true)
        XCTAssertEqual(l.organicLookPercent, 50)
        l.organicLookPercent = 72
        let back = try JSONDecoder().decode(LatticeSettings.self, from: try JSONEncoder().encode(l))
        XCTAssertEqual(back.organicLookPercent, 72)
        let plain = try JSONEncoder().encode(LatticeSettings())
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        XCTAssertNil(obj["organicLookPercent"], "an untouched project carries no key")
    }
}
