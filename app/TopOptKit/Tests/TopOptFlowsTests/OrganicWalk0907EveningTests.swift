import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★★ HIS WALK, 2026-09-07 (the second one): no horizontal struts anywhere, a lattice
/// that does not reach the edges of the area it was given, a Look slider whose number
/// appeared nowhere in the picture, a rim that changed nothing when it was removed, a
/// 15-second first cube, and a rebake for changes he had not made.
final class OrganicWalk0907EveningTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: "If no changes were made in the lattice settings, then do not rebake"

    func testAnOrganicBakeIsSkippedWhenNothingABakeReadsHasMoved() throws {
        let ws = try source("TopOptFlows/WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("private func buildStrutScene(forceRebuild: Bool = false)"),
                      "★ the bake takes a force flag, so a Refresh is still a rebuild")
        XCTAssertTrue(ws.contains("organicBakeFingerprint == now"),
                      "★ the guard compares what a bake READS, whole")
        XCTAssertTrue(ws.contains("stress: latticeStressFieldKey"),
                      "★★★ INCLUDING THE SOLVE. The first bake of a session runs before "
                      + "the stage's solve lands, so without this the organic rebake "
                      + "that the solve should trigger was skipped and he was left on "
                      + "the octet stand-in (his walk, 22:29).")
        XCTAssertTrue(ws.contains("tensor: latticeStressField?.stressTensor.count"),
                      "★ and whether the tracer had its input at all")
        XCTAssertTrue(ws.contains("project.lattice.previewBakeInputs)"),
                      "★ …and that is `previewBakeInputs`, not a hand-listed subset")
        XCTAssertTrue(ws.contains("buildStrutScene(forceRebuild: true)"),
                      "★ the page's Refresh forces one")
        // ★ The comparison must be the whole settings value: a bake's own writes are
        // stripped by `previewBakeInputs`, and nothing else may be.
        var a = LatticeSettings(enabled: true)
        a.algorithm = "organic"
        var b = a
        XCTAssertEqual(a.previewBakeInputs, b.previewBakeInputs, "identical settings compare equal")
        b.organicTransferTies.toggle()
        XCTAssertNotEqual(a.previewBakeInputs, b.previewBakeInputs,
                          "★ a real setting must not be invisible to the guard")
        b = a
        b.selectableWallStressFraction["f:x:15"] = 0.42
        XCTAssertEqual(a.previewBakeInputs, b.previewBakeInputs,
                       "★ a measurement the bake itself wrote must never re-arm it")
    }

    // MARK: "Can we make the app already have the cube prepared?"

    /// ★★★ ONE CUBE, NOT TWO (his walk, 2026-09-07, 22:27). An hour earlier I showed a
    /// shipped cube as a stand-in while his own traced. He is right that this is worse,
    /// not better: a cube replaced by a DIFFERENT cube is two pictures, and the first
    /// describes settings that are not his.
    func testTheWizardShowsOneCubeAndNoStandIn() throws {
        let wz = try source("TopOptFlows/LatticeSetupWizard.swift")
        XCTAssertFalse(wz.contains("OrganicSampleCube.stock("),
                       "★ no stand-in cube: the first picture must be his own")
        XCTAssertFalse(wz.contains("Showing the standard cube"),
                       "★ …and no status describing one")
    }

    /// The stand-in's picks must be the ones the shipped variants were generated from,
    /// or the bundle is never hit and the stand-in never appears.

    // MARK: the cache version

    /// The ties, the bead and the density floor all change the geometry core emits and
    /// none of them is a "pick", so the key cannot see them. The layout version is what
    /// retires the files baked before them.
    func testTheCacheVersionRetiredTheVariantsBakedWithoutTheTies() {
        XCTAssertGreaterThanOrEqual(OrganicVariantCache.layoutVersion, 5,
                                    "★ variants baked before the ties describe a lattice "
                                    + "this build no longer draws")
    }

    /// ★★★ THE DEPTH-VARIATION TEST IS REACHABLE ON BOTH PATHS (his correction,
    /// 2026-09-08: "The depth variation is only available in Grown Lattice mode. NOT in
    /// Traced. Please move it OUTSIDE of the 'Print fine-tuning' section and place it
    /// after the density selection").
    ///
    /// It had been put beside the transfer ties, which live inside `if
    /// model.organicGrowth` and behind the fine-tuning disclosure — invisible on the
    /// traced path he was actually using. The deformation has nothing to do with growth.
    func testTheDepthVariationToggleIsNotInsideTheGrownOnlySection() throws {
        let wz = try source("TopOptFlows/LatticeSetupWizard.swift")
        let toggle = try XCTUnwrap(wz.range(of: "wizard-organic-depth-stagger"),
                                   "the depth-variation toggle").lowerBound
        let grownOnly = try XCTUnwrap(wz.range(of: "if model.organicGrowth, TopOptKit.gradingSchemaAccepts(key: \"organic_scale\")"),
                                      "the grown-only fine-tuning section").lowerBound
        let density = try XCTUnwrap(wz.range(of: "sectionTitle(\"Density\""),
                                    "the density section").lowerBound
        XCTAssertLessThan(grownOnly, density,
                          "sanity: the grown-only section comes before Density in the file")
        XCTAssertGreaterThan(toggle, density,
                             "★ the toggle must sit AFTER the density selection, which is "
                             + "outside the grown-only fine-tuning block")
        // ★ And it stays an experiment: off by default, never a job key.
        var l = LatticeSettings(enabled: true)
        l.algorithm = "organic"
        XCTAssertFalse(l.organicDepthStagger, "★ an experiment is off by default")
        let settings = try source("TopOptFlows/LatticeSettings.swift")
        XCTAssertFalse(settings.contains("organic_depth_stagger"),
                       "★ the experiment must have no job key at all")
    }

    /// ★★★ THE DEPTH-VARIATION TEST REACHES EVERY PATH (his walk, 2026-09-08: "the depth
    /// variation was ON for images 2 and 3. And OFF for 4 and 5. Yet there is no
    /// difference").
    ///
    /// It had been applied inside the fresh-trace branch only. Four paths produce the
    /// drawn capsules — a pre-baked field, the run's emitted spans, a cached 3MF variant
    /// and a fresh trace — and the part preview does not take the fourth, so the toggle
    /// moved nothing. This pins the deformation to the ONE place every path has already
    /// written its geometry.
    func testTheDepthVariationIsAppliedAfterEveryCapsuleSource() throws {
        let sdf = try source("TopOptFlows/LatticeSDFMetal.swift")
        let apply = try XCTUnwrap(sdf.range(of: "OrganicDepthStagger.apply("),
                                  "the deformation").lowerBound
        // Every assignment of the capsule list must come BEFORE it.
        var last: String.Index? = nil
        var count = 0
        var from = sdf.startIndex
        while let r = sdf.range(of: "organicCapsOut = ", range: from..<sdf.endIndex) {
            if sdf.distance(from: r.lowerBound, to: apply) > 0 { last = r.lowerBound }
            count += 1
            from = r.upperBound
        }
        XCTAssertGreaterThanOrEqual(count, 4,
                                    "★ there are at least four capsule sources; if this "
                                    + "drops, a source was removed and the guard is weaker")
        XCTAssertNotNil(last)
        XCTAssertGreaterThan(sdf.distance(from: last!, to: apply), 0,
                             "★ the deformation must come after the LAST capsule source, "
                             + "so no path can bypass it")
        // And the sample cube carries it too, keyed so a cube traced without it cannot
        // answer for one traced with it.
        let cube = try source("TopOptFlows/OrganicSampleCube.swift")
        XCTAssertTrue(cube.contains("input.depthStaggerCellMM = picks.depthStagger"),
                      "★ the sample cube applies it")
        let key = try source("TopOptFlows/OrganicVariantCache.swift")
        XCTAssertTrue(key.contains("if picks.depthStagger"),
                      "★ …and it keys the variant cache")
        var s = LatticeSettings(); s.enabled = true
        s.algorithm = "organic"
        let off = OrganicSampleCube.Picks(settings: s, layerHeightMM: 0.2)
        s.organicDepthStagger = true
        let on = OrganicSampleCube.Picks(settings: s, layerHeightMM: 0.2)
        XCTAssertNotEqual(OrganicVariantCache.key(picks: on, fieldIdentity: "id"),
                          OrganicVariantCache.key(picks: off, fieldIdentity: "id"),
                          "★ the toggle must not be answered from the other cube's cache")
    }
}
