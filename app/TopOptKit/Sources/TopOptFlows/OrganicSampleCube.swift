// OrganicSampleCube.swift — the wizard's ORGANIC sample is the PR 353 test cube, as
// printed (maintainer, 2026-09-03: "the sample must be the PR 353 cube").
//
// The cube is `evidence/2026-08-21-organic-lattice/cube/final_organic.json` —
// CUBE_FINAL, PR 353 round 4 ("mass within 2% of the goal, gate green"), the job the
// printed cube came from: TRACED organic (no `organic_growth`), aesthetic intent,
// swept 3–6 mm, 40 mm cube, 64³, axial −200 N. Its spans were regenerated from that
// job with `emit_organic_spans` on 2026-09-03 (Release core `ca56654d2805`):
// `evidence/2026-08-21-organic-lattice/cube/final_organic_replay_2026-09-03/` —
// 12,434 spans, 20,233.09 mm, ONE component, strut diameter 0.42 mm (r = 0.21 —
// the schema floor, bead width, exactly what the print shows), 748 support legs,
// free tips kept.
//
// The sample renders those spans through the SAME path a run's spans use —
// `OrganicSpanIndex` bake + the march — at the radius IN THE FILE, and the scene's
// §10 cross-check runs against the receipt bundled beside it, so the sample is a
// MEASUREMENT of the preview path on known geometry, not a picture.
import Foundation

public enum OrganicSampleCube {
    /// 40 mm, as printed. No rescale (a rescale changes strut-to-spacing).
    public static let edgeMM: Double = 40

    public static var spansURL: URL? {
        Bundle.module.url(forResource: "PR353_CUBE_FINAL_SPANS", withExtension: "txt",
                          subdirectory: "OrganicSample")
    }
    public static var receiptURL: URL? {
        Bundle.module.url(forResource: "PR353_CUBE_FINAL_receipt", withExtension: "json",
                          subdirectory: "OrganicSample")
    }

    /// The spans, indexed. nil only if the resource is missing from the bundle.
    public static func index(cellMM: Float = 4) -> OrganicSpanIndex? {
        guard let u = spansURL else { return nil }
        return try? OrganicSpanIndex.read(path: u.path, cellMM: cellMM)
    }

    /// The run's receipt for those spans (`grading.organic.*`), for the §10 check.
    public static func receipt() -> OrganicRunReceipt? {
        guard let u = receiptURL, let data = try? Data(contentsOf: u),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return OrganicRunReceipt(info: obj)
    }

    /// The label the sample carries. True, not reassuring.
    public static let label = "The PR 353 test cube, as printed. Your part will differ."

    /// ★ THE BAKE IS HEAVY AND IMMUTABLE — 12,434 spans into a 150³ field — so it runs
    /// OFF the main thread and ONCE per launch. Measured on the simulator 2026-09-03:
    /// baking it in `rebuild()` pinned the app at 100 % CPU for minutes with the sheet
    /// frozen mid-animation. The scene depends on nothing the wizard's controls change
    /// (the spans are what core built for that job), so one cache serves every sheet.
    public struct Baked: Sendable {
        public let scene: LatticeSDFScene
        public let mesh: ViewerMesh
        public let measurement: String
    }
    private static var cache: Baked?
    private static var inflight: Task<Baked?, Never>?

    /// The cube's scene and box, baked once. nil if the resource is missing.
    public static func baked(latticeID: String) async -> Baked? {
        if let c = await MainActor.run(body: { cache }) { return c }
        let task: Task<Baked?, Never> = await MainActor.run {
            if let t = inflight { return t }
            let t = Task.detached(priority: .userInitiated) { () -> Baked? in
                // ★ Index cell 2 mm ⇒ the scene's band is 2 mm (max(2, cell)), so each
                // span stamps a (2r + 4 mm)³ box instead of (2r + 8 mm)³ — ~8× fewer
                // voxel evaluations. Same path, same march, same file radii; measured
                // on the simulator 2026-09-03: at band 4 the Debug bake ran minutes.
                guard let spans = index(cellMM: 2) else { return nil }
                let box = LatticeWizardSample.cube(edgeMM: edgeMM, at: spans.gridOrigin)
                let scene = LatticeSDFScene(mesh: box, field: nil, latticeID: latticeID,
                                            organicSpans: spans, organicReceipt: receipt(),
                                            algorithm: "organic")
                var m = label
                if let src = scene.organicSpanSource {
                    m += String(format: " %d struts, %.0f mm indexed", src.count, src.lengthMM)
                }
                if let bad = scene.organicReceiptMismatch {
                    m = "★ SAMPLE DOES NOT MATCH ITS RUN — " + bad + "  " + m
                } else if scene.organicSpanSource != nil {
                    m += " — matches the run's receipt."
                }
                return Baked(scene: scene, mesh: box, measurement: m)
            }
            inflight = t
            return t
        }
        let result = await task.value
        await MainActor.run { cache = result; inflight = nil }
        return result
    }
}
