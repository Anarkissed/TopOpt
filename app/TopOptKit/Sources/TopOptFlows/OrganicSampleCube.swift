// OrganicSampleCube.swift — the wizard's ORGANIC sample is a 20 mm TEST CUBE,
// RE-TRACED WITH THE USER'S SETTINGS (maintainer, 2026-09-03: "this is ONE example of
// what organic should be able to do — they should change as well … a base to build on").
//
// The base is the printed PR 353 cube's job (`evidence/2026-08-21-organic-lattice/cube/
// final_organic.json`: 64³, PLA, anchored on face 0, −200 N axial on face 1, aesthetic,
// swept 3–6 mm) on a WHOLE 20 mm cube (`TestCube20.stl`, the 40 mm fixture scaled by
// 0.5, same face order — maintainer, 2026-09-03 item 6: a corner cut of the 40 mm field
// left the far corner empty; a whole cube carries field on every face). The printed
// spans and receipt stay bundled (`PR353_CUBE_FINAL_*`) as the render-test fixture. The
// user-facing name is "a 20 mm test cube" — never the PR number (item 1).
//
// ★ SIMULATE STRESSES (maintainer, 2026-09-03, item 7, amended the same night: "this
// is way too uniform — bring back the way you had it last time"): the struts ALWAYS
// follow the cube's own field. ON ⇒ graded by it (the waves in spacing and width);
// OFF ⇒ ungraded — shape fit only, one spacing — which is exactly what core's run does
// with `organic_shape_fit_only` on a solved field, so sample and run agree. (A
// synthetic uniform tensor was tried and rejected: a bare cubic grid.)
//
// LIVE, ON DEVICE, THROUGH THE PRODUCTION FUNCTIONS: the cube's stress tensor comes
// from the app's own FEA (`TopOptKit.analyzeSolidLoadCase`, the same call the part's
// Simulate Stresses runs — solved once per launch, cached), and every change of an
// organic control re-traces it through the preview bridge, which calls core's
// `trace_organic_lattice` / `grow_organic_lattice` — the very functions the run uses.
// The result renders through the same path a run's spans take (`LatticeSDFScene` bake
// + the march).
//
// 20 mm, whole: at bead-width struts the bake must sit at ≤ r_min/2 (≈ 0.1 mm) to show
// beams rather than ribbons (measured 2026-09-03 at the 0.35 mm floor: sheets); 20 mm at
// that voxel is ~7 M voxels, 40 mm would be 55 M — over the cap.
import Foundation
import simd
import TopOptKit

public enum OrganicSampleCube {
    /// The whole 20 mm cube is traced.
    public static let edgeMM: Double = 20
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
        Bundle.module.url(forResource: "TestCube20", withExtension: "stl",
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

    /// The banner (item 1: short, and no PR number). The census lives behind the (i).
    public static let label = "A 20 mm test cube, re-traced with your settings. Your part will differ."

    // MARK: the user's picks → what the tracer is told

    /// Everything the sample's trace depends on. Hashable so the wizard re-traces
    /// exactly when one of these changes and never otherwise.
    public struct Picks: Hashable, Sendable {
        public var grow: Bool
        public var layerHeightMM: Double
        public var separationMinMM: Double
        public var separationMaxMM: Double
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
        /// ★ false ⇒ the traced curves are shown, not the file's repaired spans
        /// (2026-09-05). A topology pick: it changes what is baked, so it keys the
        /// cache; the shipped variants are with repairs.
        public var showRepairs: Bool
        /// ★ core `organic_overhang_fillet` (a job setting, 2026-09-05).
        public var overhangFillet: Bool
        /// ★★★ THE TRANSFER TIES (`organic_transfer_ties`) and their swirl — the
        /// cross-members between grown pillars. Core applies them on the GROWN path
        /// only, so they key the cache only when `grow` is set.
        public var transferTies: Bool = true
        public var tieSwirl: Double = 1.0
        /// ★★★ THE DEPTH-VARIATION TEST (2026-09-08). A preview-only deformation, so it
        /// keys the cache — otherwise the sample would answer from a variant traced
        /// without it and the toggle would appear to do nothing on the cube, which is
        /// exactly what he saw on the part.
        public var depthStagger: Bool = false
        /// ★ The solid band at the block's edges (0 = none). Part of the topology, so
        /// part of the cache key — but only when it is non-zero, so a sample without one
        /// still finds the variants this build ships.
        public var solidRimMM: Double = 0

        /// ★★★ THE STATED STRUT WIDTH, WHICH THE TRACE MUST SEE (his walk, 2026-09-09:
        /// "The sample cube when the print repairs are on looks awful … how did it go
        /// from a cube which had grade to shape to whatever the fuck this is?").
        ///
        /// It was treated as a LIVE number — a radius uniform on the draw, never given
        /// to the tracer — and the cache key says so in as many words ("NOT in the key:
        /// … the strut width (live)"). That was true of a field march, whose radius
        /// really is a uniform. It is not true of the geometry: core's emission merges
        /// any two endpoints closer than a share of the STRUT RADIUS and then drops what
        /// is left as degenerate, so the radius decides how much of the weave survives.
        /// With no width stated the preview let core derive a bead from the window —
        /// 1.59 mm on his cube against the 0.90 mm he typed — and node_merge ate the
        /// lattice for a thickness that was not his: 2606 struts → 61 traced, 1671 mm →
        /// 325 mm at that one stage. The run has always had the number
        /// (`organic_strut_width_mm` is a job key, and the PART preview passes it); only
        /// the sample did not.
        public var strutWidthMM: Double = 0

        /// From the settings the user has on the sheet. The window is the printed job's
        /// 3–6 mm scaled by the user's spacing scale; under Fit it is one separation —
        /// the user's pick among certification's, else the middle of the window.
        public init(settings s: LatticeSettings, layerHeightMM: Double, showRepairs: Bool = true) {
            let scale = s.organicScale > 0 ? s.organicScale : 1
            var lo = printedWindowMM.lo * scale, hi = printedWindowMM.hi * scale
            if s.cellSizeMode == .fit {
                let one = s.organicPickedSeparationMM > 0 ? s.organicPickedSeparationMM : 0.5 * (lo + hi)
                lo = one; hi = one
            }
            grow = s.organicGrowth && layerHeightMM > 0
            self.layerHeightMM = layerHeightMM
            separationMinMM = lo; separationMaxMM = hi
            overhangDeg = grow ? 0 : s.organicOverhangDeg
            rhoMin = s.minRelativeDensity; rhoMax = max(s.maxRelativeDensity, s.minRelativeDensity)
            structural = (s.stageMode ?? .structural) == .structural
            shapeFit = s.organicShapeFit
            shapeFitOnly = s.organicShapeFit && s.organicShapeFitOnly
            covered = s.boundary == .covered
            self.showRepairs = showRepairs
            overhangFillet = s.organicOverhangFillet
            strutWidthMM = Swift.max(0, s.organicStrutWidthMM)
            transferTies = s.organicTransferTies
            tieSwirl = s.organicTieSwirl
            depthStagger = s.organicDepthStagger
            // ★ The rim the run would apply: an OUTLINE one strut wide at the block's
            // edges (his rule for the cube, 2026-09-07: "cover the edges of the cube"),
            // never a border of cells. See `LatticeSettings.organicRunSolidRimMM(beadMM:)`.
            // ★ The cube's own printability floor: the bead term against the cube's
            // 64³ grid over 20 mm.
            solidRimMM = s.organicRunSolidRimMM(
                floorMM: OrganicSizeCheck.floor(beadMM: printedBeadMM,
                                                voxelMM: edgeMM / 64).mm)
        }

        /// ★ THICKNESS IS NOT A PICK (2026-09-04): the Thicker slider is a live radius
        /// on the march, so it never re-traces. The bake voxel follows the bead.
        public var thinnestRadiusMM: Double { printedBeadMM / 2 }
        /// ★★★ THE FIELD IS A FALLBACK, NOT THE PICTURE (his walk, 2026-09-07: "It should
        /// be a singular sample cube that pops up in 2 seconds MAX").
        ///
        /// ★ 0.105 mm ON A 20 mm CUBE IS TWELVE MILLION CELLS, and the bake stamps every
        /// span into every cell within its reach. That voxel was chosen when the DISTANCE
        /// FIELD was what the renderer drew and a strut had to survive trilinear
        /// interpolation. Organic has been drawn by ray-cast capsule impostors since
        /// 2026-09-06 — exact geometry, no bake — and under them the field is not read at
        /// all. It is still baked so that a device whose capsule pipeline fails to build
        /// has something to show, and a fallback does not need a tenth of a millimetre.
        /// Half a cell resolves the strut spacing, which is what a fallback has to
        /// convey, and it costs roughly a thousandth of the cells.
        public var bakeVoxelMM: Double {
            let cell = max(separationMinMM, separationMaxMM)
            let fromCell = cell > 0 ? cell / 8 : 0
            return max(0.35, min(1.0, fromCell > 0 ? fromCell : 0.35))
        }
    }


    // ★ A SHIPPED CUBE AS A STAND-IN WAS TRIED HERE AND WITHDRAWN (2026-09-07). It
    // showed one of the four bundled cubes while his own traced, so the page opened on a
    // picture instead of a wait — and he was clear that this is worse: "It should be a
    // singular sample cube that pops up in 2 seconds MAX". A cube replaced by a
    // DIFFERENT cube is two pictures, and the first one describes settings that are not
    // his. The cost belongs where it is; see `bakeVoxelMM`.

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

    // ── ★★★ THE CUBE'S SOLVE, KEPT (his walk, 2026-09-07: "Took 12 seconds to load —
    // why is a cached item taking so long? It should take a MAXIMUM of two seconds").
    //
    // ★ A CACHE HIT ALREADY SKIPS THE SOLVE (the variant path). A MISS still had to run
    // it, and it ran ONCE PER LAUNCH because the only cache was a static in memory — so
    // the first time he changed a setting after opening the app he paid the whole 64³
    // finite-element solve again for a field that never changes. It is a pure function
    // of the bundled cube, the material and one load case; `fieldIdentity` names all of
    // it. Written once, read in milliseconds forever after.
    /// ★ A STABLE NAME. `String.hashValue` is seeded per PROCESS in Swift, so a file
    /// named from it is written under one name and looked for under another on the next
    /// launch — a cache that never hits and grows for ever. The identity is a constant;
    /// sanitising it is stable, and readable in the folder besides.
    static var fieldFileName: String {
        let safe = fieldIdentity.map { c -> Character in
            c.isLetter || c.isNumber ? c : "-"
        }
        return "field-v\(fieldBlobVersion)-\(String(safe)).bin"
    }
    private static var fieldURL: URL {
        OrganicVariantCache.directory.appendingPathComponent(fieldFileName)
    }
    private static let fieldBlobVersion: Int32 = 1

    private static func readFieldFromDisk() -> Field? {
        guard let d = try? Data(contentsOf: fieldURL), d.count > 64 else { return nil }
        return d.withUnsafeBytes { raw -> Field? in
            var o = 0
            func take<T>(_ t: T.Type) -> T? {
                guard o + MemoryLayout<T>.size <= raw.count else { return nil }
                let v = raw.loadUnaligned(fromByteOffset: o, as: T.self)
                o += MemoryLayout<T>.size
                return v
            }
            guard let ver = take(Int32.self), ver == fieldBlobVersion,
                  let nx = take(Int32.self), let ny = take(Int32.self), let nz = take(Int32.self),
                  let ox = take(Double.self), let oy = take(Double.self), let oz = take(Double.self),
                  let sp = take(Double.self),
                  let tc = take(Int64.self), let vc = take(Int64.self),
                  nx > 0, ny > 0, nz > 0, sp > 0,
                  tc == Int64(6 * Int(nx) * Int(ny) * Int(nz)), vc == Int64(Int(nx) * Int(ny) * Int(nz)),
                  o + Int(tc) * 8 + Int(vc) * 4 <= raw.count else { return nil }
            // ★★★ BULK, NOT ELEMENT BY ELEMENT (his walk, 2026-09-07: 30 seconds for a
            // cube whose field was already on disk). A 64³ tensor is 1,572,864 doubles
            // and this read them one `loadUnaligned` at a time, then 262,144 floats the
            // same way — about four and a half seconds of a nine-second bake in the
            // Debug build he actually runs. The bytes are contiguous and the file is
            // written from the arrays' own memory, so one copy each does it.
            var tensor = [Double](repeating: 0, count: Int(tc))
            tensor.withUnsafeMutableBytes { dst in
                dst.copyBytes(from: UnsafeRawBufferPointer(rebasing: raw[o ..< (o + Int(tc) * 8)]))
            }
            o += Int(tc) * 8
            var vm = [Float](repeating: 0, count: Int(vc))
            vm.withUnsafeMutableBytes { dst in
                dst.copyBytes(from: UnsafeRawBufferPointer(rebasing: raw[o ..< (o + Int(vc) * 4)]))
            }
            return Field(tensor: tensor, vonMises: vm, nx: Int(nx), ny: Int(ny), nz: Int(nz),
                         origin: SIMD3<Double>(ox, oy, oz), spacingMM: sp)
        }
    }

    private static func writeFieldToDisk(_ f: Field) {
        var d = Data()
        withUnsafeBytes(of: fieldBlobVersion) { d.append(contentsOf: $0) }
        for v in [Int32(f.nx), Int32(f.ny), Int32(f.nz)] { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        for v in [f.origin.x, f.origin.y, f.origin.z, f.spacingMM] { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        withUnsafeBytes(of: Int64(f.tensor.count)) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: Int64(f.vonMises.count)) { d.append(contentsOf: $0) }
        f.tensor.withUnsafeBytes { d.append(contentsOf: $0) }
        f.vonMises.withUnsafeBytes { d.append(contentsOf: $0) }
        try? FileManager.default.createDirectory(at: OrganicVariantCache.directory,
                                                 withIntermediateDirectories: true)
        try? d.write(to: fieldURL, options: .atomic)
    }

    /// The app's own FEA on the bundled cube — the printed job's load case. nil when the
    /// model or the config paths are missing, or the solve did not converge.
    public static func field() async -> Field? {
        if let f = await MainActor.run(body: { fieldCache }) { return f }
        let task: Task<Field?, Never> = await MainActor.run {
            if let t = fieldInflight { return t }
            let t = Task.detached(priority: .userInitiated) { () -> Field? in
                // ★ THE DISK FIRST — the solve is the same every launch.
                if let f = readFieldFromDisk() { return f }
                guard let model = modelURL, let cfg = configPaths else { return nil }
                guard let r = try? TopOptKit.analyzeSolidLoadCase(
                    modelPath: model.path, material: "PLA",
                    materialsPath: cfg.materials, rulesPath: cfg.rules, resolution: 64,
                    anchorFaceIDs: [0],
                    loadGroups: [TopOptKit.LoadGroupSpec(faceIDs: [1], force: SIMD3(0, 0, -200))],
                    buildDirection: SIMD3(0, 0, 1)),
                      !r.nonConvergent,
                      r.stressTensorField.count == 6 * r.gridNX * r.gridNY * r.gridNZ else { return nil }
                let f = Field(tensor: r.stressTensorField, vonMises: r.vonMisesField,
                              nx: r.gridNX, ny: r.gridNY, nz: r.gridNZ,
                              origin: r.gridOrigin, spacingMM: r.spacingMM)
                writeFieldToDisk(f)
                return f
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
        /// The census — what was traced and how (behind the banner's (i)).
        public let measurement: String
        public let picks: Picks
    }
    private static var lastBaked: Baked?

    /// The field's identity in the cache key: the model, its load case, its grid.
    public static let fieldIdentity = "TestCube20|PLA|anchor0|load1:-200z|res64"

    /// Trace the whole cube with these picks — or, when this topology was traced before
    /// (shipped in the bundle, or by this device), bake its beam-lattice 3MF in a second
    /// instead. Cached in memory for the last picks only.
    public static func baked(picks: Picks, latticeID: String) async -> Baked? {
        if let b = await MainActor.run(body: { lastBaked }), b.picks == picks { return b }
        let key = OrganicVariantCache.key(picks: picks, fieldIdentity: fieldIdentity)
        // ★ THE CACHE FIRST (2026-09-04): a topology traced before — shipped in the bundle
        // or by this device — is handed to the scene as its beam-lattice document and
        // baked on the scene's own grid; the trace and the emission are skipped.
        let hit = OrganicVariantCache.load(key: key)

        // ★★★ A CACHED CUBE MUST NOT WAIT ON THE CUBE'S SOLVE (his walk, 2026-09-07:
        // "first cube took 18 seconds to show … Can't we have a cached cube to be used
        // automatically?").
        //
        // ★ IT DID WAIT, AND FOR NOTHING IT NEEDED. `field()` runs a finite-element
        // solve of the 20 mm cube at 64³ — once per launch, and it is the whole 18
        // seconds. The cached path then threw the tensor away: the spans come from the
        // file, and the solve's grid was used only to size the bake. So a cache hit
        // paid the full solve to draw a lattice it already had on disk.
        //
        // The file carries its own geometry, and the cube's bounds are a constant. Bake
        // the spans on a grid derived from THOSE and the shipped variant is on screen
        // in well under a second, with no solve at all. The solve is still what a NEW
        // topology needs — that path is unchanged below.
        if let hit {
            let box = LatticeWizardSample.cube(edgeMM: edgeMM, at: SIMD3<Float>(0, 0, 0))
            let pad = Float(max(picks.separationMaxMM, 1))
            let mn = box.bounds.min - pad, mx = box.bounds.max + pad
            let ext = mx - mn
            var fs = picks.bakeVoxelMM > 0 ? picks.bakeVoxelMM : 0.35
            while (Double(ext.x) / fs + 2) * (Double(ext.y) / fs + 2)
                    * (Double(ext.z) / fs + 2) > 12_000_000 { fs *= 1.25 }
            let dims = (max(2, Int(Double(ext.x) / fs) + 2),
                        max(2, Int(Double(ext.y) / fs) + 2),
                        max(2, Int(Double(ext.z) / fs) + 2))
            if let baked = OrganicVariantCache.bake(
                hit.doc, origin: mn, voxelMM: fs, dims: dims,
                bandMM: LatticeSDFScene.organicBakeHeadroomMM, source: hit.source) {
                    let scene = LatticeSDFScene(mesh: box, field: nil, latticeID: latticeID,
                                            stageMode: picks.structural ? .structural : .aesthetic,
                                            algorithm: "organic",
                                            organicBaked: baked,
                                            maxDim: 64)   // see the note on the traced path
                let m = baked.summary + String(format: " · %@ · window %.1f–%.1f mm · voxel %.2f mm · key %@ · no solve needed",
                                               picks.grow ? "grown" : "traced",
                                               picks.separationMinMM, picks.separationMaxMM, fs, key)
                let out = Baked(scene: scene, mesh: box, measurement: m, picks: picks)
                await MainActor.run { lastBaked = out }
                return out
            }
        }

        guard let f = await field() else { return nil }
        let cachedDoc: (doc: OrganicBeamLattice3MF.Document, sourceLabel: String)? = nil
        let result: Baked? = await Task.detached(priority: .userInitiated) { () -> Baked? in
            // ★ the sample's own clock, beside the scene's (`DIAG scene phases`)
            let sampleT0 = Date()
            var tMesh = 0.0, tScene = 0.0
            // the whole cube at the STL's own bounds (0…20 mm), so its bottom face IS
            // the stage floor (item 4.2)
            let box = LatticeWizardSample.cube(edgeMM: edgeMM, at: SIMD3<Float>(0, 0, 0))
            tMesh = Date().timeIntervalSince(sampleT0)
            let stress = StressField(nx: f.nx, ny: f.ny, nz: f.nz,
                                     origin: SIMD3<Float>(Float(f.origin.x), Float(f.origin.y), Float(f.origin.z)),
                                     spacing: Float(f.spacingMM), values: f.vonMises)
            var input = LatticeOrganicInput(
                tensor: f.tensor, dims: (f.nx, f.ny, f.nz), originMM: f.origin,
                spacingMM: f.spacingMM, minExtrudableWidthMM: printedBeadMM,
                buildDirection: SIMD3(0, 0, 1),
                separationMinMM: picks.separationMinMM, separationMaxMM: picks.separationMaxMM,
                rhoMin: picks.rhoMin, rhoMax: picks.rhoMax,
                strutDiameterMM: picks.strutWidthMM, grow: picks.grow,
                layerHeightMM: picks.layerHeightMM, overhangAngleDeg: picks.overhangDeg,
                transferTies: picks.transferTies, tieSwirl: picks.tieSwirl,
                shapeFit: picks.shapeFit, shapeFitOnly: picks.shapeFitOnly,
                anchorAtBoundary: picks.covered, showRepairs: picks.showRepairs,
                overhangFillet: picks.overhangFillet)
            input.solidRimMM = picks.solidRimMM
            // ★ the depth-variation TEST, scaled to the cube's own cell
            input.depthStaggerCellMM = picks.depthStagger
                ? Swift.max(picks.separationMinMM, picks.separationMaxMM) : 0
            let scene = LatticeSDFScene(mesh: box, field: stress, latticeID: latticeID,
                                        // ★★★ A 20 mm BOX DOES NOT NEED 128³ (measured
                                        // 2026-09-07). The preview's standard grid is
                                        // 128 across the longest side; on a part that
                                        // is a plain cube that is 0.156 mm voxels — 2.1
                                        // million of them — to describe six flat faces,
                                        // and every per-voxel pass in this initialiser
                                        // pays for it (occupancy, signed distance, the
                                        // demand resample, the stress ramp). The
                                        // TRACER's grid is the cube's own 64³ field and
                                        // is untouched; this is only the mesh's
                                        // occupancy, and a box is exact at any
                                        // resolution. Eight times fewer voxels.
                                        stageMode: picks.structural ? .structural : .aesthetic,
                                        algorithm: "organic",
                                        organic: input,
                                        organicBakeVoxelMM: picks.bakeVoxelMM,
                                        organicCached: cachedDoc,
                                        maxDim: 64)
            tScene = Date().timeIntervalSince(sampleT0) - tMesh
            guard scene.organicField != nil else { return nil }
            // ★★★ STORE THE TOPOLOGY as a beam-lattice 3MF, so the next visit bakes it.
            //
            // ★ AND STORE IT WHEN THE REPAIRS ARE HIDDEN TOO (his walk, 2026-09-07:
            // "Took ~35 seconds to get this new cube up and generated. Where are the
            // cached ones???"). This read `organicEmittedSpans`, which is core's
            // EMISSION — and the bridge does not run the emission when repairs are
            // hidden, which is the switch he had off. So the traced cube was drawn,
            // shown, and then thrown away: every visit to the page re-traced it, for
            // ever, and the cache he was asking about was never written. The capsules
            // are the geometry that was drawn either way, and `showRepairs` is already
            // in the cache key, so a repairs-hidden cube is simply its own entry.
            let spansToStore: [(a: SIMD3<Double>, b: SIMD3<Double>, r: Double)] = {
                if let e = scene.organicEmittedSpans, !e.isEmpty { return e }
                return scene.organicCapsules.map {
                    (a: SIMD3<Double>($0.a), b: SIMD3<Double>($0.b), r: Double($0.r))
                }
            }()
            if cachedDoc == nil, !spansToStore.isEmpty {
                let spans = spansToStore
                let doc = OrganicBeamLattice3MF.Document(
                    spans: spans,
                    metadata: ["census": scene.organicSummary, "core": CoreFingerprint.value,
                               "field": fieldIdentity, "key": key,
                               "picks": String(format: "%@ · window %.2f–%.2f · layer %.3f · shape fit %d/%d · covered %d",
                                               picks.grow ? "grown" : "traced", picks.separationMinMM, picks.separationMaxMM,
                                               picks.layerHeightMM, picks.shapeFit ? 1 : 0, picks.shapeFitOnly ? 1 : 0, picks.covered ? 1 : 0)])
                // ★★★ AND IT IS NOT ON THE WAY TO THE PICTURE (his walk, 2026-09-07,
                // measured: scene 4.7 s, this 4.5 s, of a 9.2 s cube). Writing 14,060
                // spans as a zipped beam-lattice 3MF is half the wait, and it is a
                // CACHE WRITE — nothing on screen depends on it. It goes to a detached
                // task so the cube is handed back the moment it is baked; the file
                // lands a few seconds later, in time for the next visit, which is the
                // only thing that reads it.
                Task.detached(priority: .utility) {
                    OrganicVariantCache.store(key: key, doc: doc)
                }
            }
            var m = scene.organicSummary
            m += String(format: " · %@%@%@ · window %.1f–%.1f mm · voxel %.2f mm · key %@",
                        picks.grow ? "grown" : "traced",
                        picks.shapeFit ? (picks.shapeFitOnly ? ", shape-fit only" : ", shape-fit") : ", no shape fit",
                        picks.covered ? ", covered (ends anchor on the shell)" : ", bare (no outline; ends trimmed)",
                        picks.separationMinMM, picks.separationMaxMM, picks.bakeVoxelMM, key)
            NSLog("DIAG sample cube: mesh %.2f s · scene %.2f s · after %.2f s · total %.2f s",
                  tMesh, tScene,
                  Date().timeIntervalSince(sampleT0) - tMesh - tScene,
                  Date().timeIntervalSince(sampleT0))
            return Baked(scene: scene, mesh: box, measurement: m, picks: picks)
        }.value
        await MainActor.run { lastBaked = result }
        return result
    }
}
