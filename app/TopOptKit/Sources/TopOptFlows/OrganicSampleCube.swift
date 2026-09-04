// OrganicSampleCube.swift — the wizard's ORGANIC sample is the PR 353 test cube,
// RE-TRACED WITH THE USER'S SETTINGS (maintainer, 2026-09-03: "this is ONE example of
// what organic should be able to do — they should change as well … a base to build on").
//
// The base is CUBE_FINAL — PR 353 round 4, the job the printed cube came from
// (`evidence/2026-08-21-organic-lattice/cube/final_organic.json`: 40 mm cube, 64³, PLA,
// anchored on face 0, −200 N axial on face 1, aesthetic, swept 3–6 mm). Its printed
// spans and receipt are bundled too (`PR353_CUBE_FINAL_*`) as the render-test fixture.
//
// LIVE, ON DEVICE, THROUGH THE PRODUCTION FUNCTIONS: the cube's stress tensor comes
// from the app's own FEA (`TopOptKit.analyzeSolidLoadCase`, the same call the part's
// Simulate Stresses runs — solved once per launch, cached), and every change of an
// organic control re-traces it through the preview bridge, which calls core's
// `trace_organic_lattice` / `grow_organic_lattice` — the very functions the run uses.
// The result renders through the same path a run's spans take (`LatticeSDFScene` bake
// + the march).
//
// A 20 mm CORNER of the cube's field, not a rescale: at bead-width struts the bake must
// sit at ≤ r_min/2 (≈ 0.1 mm) to show beams rather than ribbons (measured 2026-09-03 at
// the 0.35 mm floor: sheets), and 40 mm at that voxel is 55 M voxels — over the cap. The
// 20 mm cut keeps the strut-to-spacing ratio exactly; the label says it is a cut.
import Foundation
import simd
import TopOptKit

public enum OrganicSampleCube {
    /// 40 mm, as printed; the sample traces a 20 mm corner of it.
    public static let edgeMM: Double = 40
    public static let cutMM: Double = 20
    /// The printed job's separation window (swept 3–6 mm) — the base the user scales.
    public static let printedWindowMM: (lo: Double, hi: Double) = (3, 6)
    /// The printed job's bead (min_extrudable_width_mm 0.42) — strut r = 0.21.
    public static let printedBeadMM: Double = 0.42

    /// The app's materials/rules, handed over by `AppModel.init`.
    public static var configPaths: (materials: String, rules: String)?

    // MARK: bundled fixture (the printed spans, for the render test and the receipt check)

    public static var spansURL: URL? {
        Bundle.module.url(forResource: "PR353_CUBE_FINAL_SPANS", withExtension: "txt",
                          subdirectory: "OrganicSample")
    }
    public static var receiptURL: URL? {
        Bundle.module.url(forResource: "PR353_CUBE_FINAL_receipt", withExtension: "json",
                          subdirectory: "OrganicSample")
    }
    public static var modelURL: URL? {
        Bundle.module.url(forResource: "PR353_cube40", withExtension: "stl",
                          subdirectory: "OrganicSample")
    }
    public static func index(cellMM: Float = 4) -> OrganicSpanIndex? {
        guard let u = spansURL else { return nil }
        return try? OrganicSpanIndex.read(path: u.path, cellMM: cellMM)
    }
    public static func receipt() -> OrganicRunReceipt? {
        guard let u = receiptURL, let data = try? Data(contentsOf: u),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return OrganicRunReceipt(info: obj)
    }

    public static let label = "The PR 353 test cube (a 20 mm corner), re-traced with your settings. Your part will differ."

    // MARK: the user's picks → what the tracer is told

    /// Everything the sample's trace depends on. Hashable so the wizard re-traces
    /// exactly when one of these changes and never otherwise.
    public struct Picks: Hashable, Sendable {
        public var grow: Bool
        public var layerHeightMM: Double
        public var separationMinMM: Double
        public var separationMaxMM: Double
        public var strutDiameterMM: Double        // 0 ⇒ core derives it from the band
        public var overhangDeg: Double            // traced only; 0 leaves it to core
        public var rhoMin: Double
        public var rhoMax: Double
        public var structural: Bool
        /// ★ Shape fit (always on for organic — his item 3; `only` drops the stress
        /// grading). Without it the sample is a ragged blob; with it, a cube.
        public var shapeFit: Bool
        public var shapeFitOnly: Bool
        /// ★ Covered ⇒ a shell is written and ends anchor on it; otherwise the lattice
        /// is BARE — "no outline, ONLY lattice" (maintainer, 2026-09-03) — and core
        /// trims ends that leave the region back to their last connector.
        public var covered: Bool

        /// From the settings the user has on the sheet. The window is the printed job's
        /// 3–6 mm scaled by the user's spacing scale; under Fit it is one separation —
        /// the user's pick among certification's, else the middle of the window.
        public init(settings s: LatticeSettings, layerHeightMM: Double) {
            let scale = s.organicScale > 0 ? s.organicScale : 1
            var lo = printedWindowMM.lo * scale, hi = printedWindowMM.hi * scale
            if s.cellSizeMode == .fit {
                let one = s.organicPickedSeparationMM > 0 ? s.organicPickedSeparationMM : 0.5 * (lo + hi)
                lo = one; hi = one
            }
            grow = s.organicGrowth && layerHeightMM > 0
            self.layerHeightMM = layerHeightMM
            separationMinMM = lo; separationMaxMM = hi
            strutDiameterMM = s.organicStrutWidthMM > 0 ? s.organicStrutWidthMM : 0
            overhangDeg = grow ? 0 : s.organicOverhangDeg
            rhoMin = s.minRelativeDensity; rhoMax = max(s.maxRelativeDensity, s.minRelativeDensity)
            structural = (s.stageMode ?? .structural) == .structural
            shapeFit = s.organicShapeFit
            shapeFitOnly = s.organicShapeFit && s.organicShapeFitOnly
            covered = s.boundary == .covered
        }

        /// The thinnest strut this trace can make: the stated diameter, else the bead.
        public var thinnestRadiusMM: Double { (strutDiameterMM > 0 ? strutDiameterMM : printedBeadMM) / 2 }
        /// The bake voxel that shows that strut as a beam: ≤ r_min / 2.
        public var bakeVoxelMM: Double { max(0.06, thinnestRadiusMM / 2) }
    }

    // MARK: the cube's field, solved once

    public struct Field: Sendable {
        public let tensor: [Double]
        public let vonMises: [Float]
        public let nx: Int, ny: Int, nz: Int
        public let origin: SIMD3<Double>
        public let spacingMM: Double
    }
    private static var fieldCache: Field?
    private static var fieldInflight: Task<Field?, Never>?

    /// The app's own FEA on the bundled cube — the printed job's load case. nil when the
    /// model or the config paths are missing, or the solve did not converge.
    public static func field() async -> Field? {
        if let f = await MainActor.run(body: { fieldCache }) { return f }
        let task: Task<Field?, Never> = await MainActor.run {
            if let t = fieldInflight { return t }
            let t = Task.detached(priority: .userInitiated) { () -> Field? in
                guard let model = modelURL, let cfg = configPaths else { return nil }
                guard let r = try? TopOptKit.analyzeSolidLoadCase(
                    modelPath: model.path, material: "PLA",
                    materialsPath: cfg.materials, rulesPath: cfg.rules, resolution: 64,
                    anchorFaceIDs: [0],
                    loadGroups: [TopOptKit.LoadGroupSpec(faceIDs: [1], force: SIMD3(0, 0, -200))],
                    buildDirection: SIMD3(0, 0, 1)),
                      !r.nonConvergent,
                      r.stressTensorField.count == 6 * r.gridNX * r.gridNY * r.gridNZ else { return nil }
                return Field(tensor: r.stressTensorField, vonMises: r.vonMisesField,
                             nx: r.gridNX, ny: r.gridNY, nz: r.gridNZ,
                             origin: r.gridOrigin, spacingMM: r.spacingMM)
            }
            fieldInflight = t
            return t
        }
        let result = await task.value
        await MainActor.run { fieldCache = result; fieldInflight = nil }
        return result
    }

    // MARK: the sample, traced for one set of picks

    public struct Baked: Sendable {
        public let scene: LatticeSDFScene
        public let mesh: ViewerMesh
        public let measurement: String
        public let picks: Picks
    }
    private static var lastBaked: Baked?

    /// Trace the cube's 20 mm corner with these picks. Cached for the last picks only —
    /// every control change re-traces, which is the point.
    public static func baked(picks: Picks, latticeID: String) async -> Baked? {
        if let b = await MainActor.run(body: { lastBaked }), b.picks == picks { return b }
        guard let f = await field() else { return nil }
        let result: Baked? = await Task.detached(priority: .userInitiated) { () -> Baked? in
            // the 20 mm corner at the cube's own origin (the STL spans 0…40 mm)
            let corner = SIMD3<Float>(Float(f.origin.x), Float(f.origin.y), Float(f.origin.z))
            let box = LatticeWizardSample.cube(edgeMM: cutMM, at: corner)
            let stress = StressField(nx: f.nx, ny: f.ny, nz: f.nz,
                                     origin: SIMD3<Float>(Float(f.origin.x), Float(f.origin.y), Float(f.origin.z)),
                                     spacing: Float(f.spacingMM), values: f.vonMises)
            let input = LatticeOrganicInput(
                tensor: f.tensor, dims: (f.nx, f.ny, f.nz), originMM: f.origin,
                spacingMM: f.spacingMM, minExtrudableWidthMM: printedBeadMM,
                buildDirection: SIMD3(0, 0, 1),
                separationMinMM: picks.separationMinMM, separationMaxMM: picks.separationMaxMM,
                rhoMin: picks.rhoMin, rhoMax: picks.rhoMax,
                strutDiameterMM: picks.strutDiameterMM, grow: picks.grow,
                layerHeightMM: picks.layerHeightMM, overhangAngleDeg: picks.overhangDeg,
                shapeFit: picks.shapeFit, shapeFitOnly: picks.shapeFitOnly,
                anchorAtBoundary: picks.covered)
            let scene = LatticeSDFScene(mesh: box, field: stress, latticeID: latticeID,
                                        stageMode: picks.structural ? .structural : .aesthetic,
                                        algorithm: "organic",
                                        organic: input,
                                        organicBakeVoxelMM: picks.bakeVoxelMM)
            guard scene.organicField != nil else { return nil }
            var m = label
            if !scene.organicSummary.isEmpty { m += " " + scene.organicSummary }
            m += String(format: " · %@%@%@ · window %.1f–%.1f mm · voxel %.2f mm",
                        picks.grow ? "grown" : "traced",
                        picks.shapeFit ? (picks.shapeFitOnly ? ", shape-fit only" : ", shape-fit") : ", no shape fit",
                        picks.covered ? ", covered (ends anchor on the shell)" : ", bare (no outline; ends trimmed)",
                        picks.separationMinMM, picks.separationMaxMM, picks.bakeVoxelMM)
            return Baked(scene: scene, mesh: box, measurement: m, picks: picks)
        }.value
        await MainActor.run { lastBaked = result }
        return result
    }
}
