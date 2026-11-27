import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★★ WHERE THE SAMPLE CUBE'S SECONDS GO (his walk, 2026-09-07: "took ~30 seconds for
/// the first image … It should be a singular sample cube that pops up in 2 seconds MAX",
/// and "Took ~35 seconds to get this new cube up and generated. Where are the cached
/// ones???").
///
/// Not an opinion about speed: the phase clock, printed. The bridge times the trace,
/// core's emission and the field bake separately (header [56..58]), so a slow cube can
/// be attributed to a phase instead of guessed at.
final class OrganicSampleCubeSpeedProbe: XCTestCase {

    func testWhereTheSampleCubesSecondsGo() async throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        let root: URL = {
            var u = URL(fileURLWithPath: #filePath); for _ in 0..<5 { u.deleteLastPathComponent() }; return u
        }()
        OrganicSampleCube.configPaths = (
            root.appendingPathComponent("core/src/materials/materials.json").path,
            root.appendingPathComponent("core/src/settings/rules.json").path)
        var s = LatticeSettings(); s.enabled = true
        var m = LatticeWizardModel(settings: s); m.selectOrganic()
        var v = m.applied(to: s)
        v.organicGrowth = true                 // his walk: Grown
        v.cellSizeMode = .auto
        var picks = OrganicSampleCube.Picks(settings: v, layerHeightMM: 0.2, showRepairs: false)
        // A look he has moved, so the variant cache cannot hold it — his actual case.
        picks.separationMinMM = 3.78; picks.separationMaxMM = 3.78
        let key = OrganicVariantCache.key(picks: picks, fieldIdentity: OrganicSampleCube.fieldIdentity)
        try? FileManager.default.removeItem(at: OrganicVariantCache.cachedURL(for: key))
        print("")
        print("  bake voxel .......... \(String(format: "%.3f", picks.bakeVoxelMM)) mm")
        // ★ The cube's own field first, timed on its own: it is solved once and then
        // read from disk, and a read that costs seconds is a different defect from a
        // trace that does.
        let tf = Date()
        _ = await OrganicSampleCube.field()
        print("  cube field .......... \(String(format: "%.2f", Date().timeIntervalSince(tf))) s (solve or disk)")
        let t0 = Date()
        let baked = await OrganicSampleCube.baked(picks: picks, latticeID: "octet")
        let total = Date().timeIntervalSince(t0)
        let b = try XCTUnwrap(baked)
        let ph = b.scene.organicPhaseSeconds
        print("  total ............... \(String(format: "%.1f", total)) s")
        if let ph {
            print("  trace ............... \(String(format: "%.2f", ph.trace)) s")
            print("  core's emission ..... \(String(format: "%.2f", ph.emit)) s")
            print("  field bake .......... \(String(format: "%.2f", ph.bake)) s")
        }
        print("  capsules ............ \(b.scene.organicCapsules.count)")
        // A second call must be a cache read, not a trace.
        let t1 = Date()
        _ = await OrganicSampleCube.baked(picks: picks, latticeID: "octet")
        let again = Date().timeIntervalSince(t1)
        print("  same picks again .... \(String(format: "%.2f", again)) s (the cache)")
        XCTAssertGreaterThan(b.scene.organicCapsules.count, 0)
        XCTAssertLessThan(again, total,
                          "★ a second bake of the same picks must read the cache")
    }
}
