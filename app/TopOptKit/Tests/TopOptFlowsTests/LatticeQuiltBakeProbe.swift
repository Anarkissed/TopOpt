import XCTest
import Metal
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★★ THE BAKE BEHIND HIS SCREEN — reproduced headlessly, and CHECKED against the
/// app's own DIAG line rather than assumed.
///
/// Captured from the running app on 2026-08-26 04:44 (device
/// A030C20C…, project 68BF7B74…, stepped · aesthetic · single-cell ON · fullSkin ·
/// band 10 mm · sim density · octet · face 15 @ 12 mm, face 2 @ 13 mm):
///
///     DIAG stepped regions=2 stated=[10.312240362167358, 12.030947089195251]
///          finest=10.312… printableFloor=1.2890300452709198 nCap=8 bandMM=10.0
///          sizes=[1.72=13 2.01=30 3.44=12 4.01=17 5.16=82 6.02=56 10.31=197 12.03=121]
///     DIAG steppedGrade painted=528 … n=[n1=456 n3=72]
///          w[min=10.31 max=13.75 n=409 shrunk=181]
///
/// `testTheHeadlessBakeMatchesTheApp` asserts that histogram EXACTLY. If it ever
/// stops matching, the harness has drifted from the product and no number it
/// produces means anything — that is the failure mode that cost this investigation
/// two nights, so it is a test and not a comment.
final class LatticeQuiltBakeProbe: XCTestCase {

    /// His settings, from his own `project.json`.
    struct His {
        /// ★ 128 — `LatticeSDFScene`'s DEFAULT, and `WorkspacePlaceholder` never
        /// passes a `maxDim`, so this IS the preview's grid. The Fast·64³/Fine·128³
        /// chip is the JOB's resolution and never reaches this bake — which is why
        /// flipping it gave a "pixel-identical" picture, and why that observation
        /// did NOT rule resolution out.
        var maxDim = 128
        var boundaryFinishWritten = true       // singleCellMembers && boundary != .none
        var shapeFitBandMM = 10.0
        var lineWidthMM = 0.45
        var skinMM = 0.9
        var rhoMin = 0.05
        var rhoMax = 0.90
        var gamma = 1.0
        var shapeFit = true
        var dyadicSteps = false
        var stageMode: LatticeStageMode = .aesthetic
        /// ★ SINGLE-CELL PER MEMBER: the cells-per-member floor forced to 1, which is
        /// what `project.lattice.singleCellMembers` means — "the largest single cell
        /// across the entire model, per voxel". nil = take the stage mode's own floor.
        var cellsPerMemberFloorOverride: Double? = nil
    }

    /// ★ THE APP'S OWN DIAG HISTOGRAM, VERBATIM — the number this harness is held to.
    ///
    /// ★ RE-PINNED 2026-08-28, build 7029b267, single-cell members OFF — the state he
    /// is actually looking at. Read off the running app's own line:
    ///
    ///     DIAG stepped regions=2 stated=[6.0, 5.1561] finest=5.1561
    ///       printableFloor=1.2890 nCap=4 bandMM=10.0 baked=true
    ///       sizes=[1.29=369 1.43=16 1.50=497 1.72=346 2.00=290 4.30=18
    ///              5.16=1049 6.00=784]
    ///     DIAG steppedGrade painted=3369 ... n=[n1=1851 n3=652 n4=866]
    ///
    /// The 2026-08-27 pin (2,952 cells) is superseded by two further measured changes:
    /// the overshoot ring keeps the region's cell instead of being subdivided to the
    /// floor, and the occupancy gate became an OVERLAP test so cells straddling a
    /// curved outline are painted at all (+417 cells, all on the curves).
    ///
    /// The previous pin (build e6b19570, single-cell ON) is superseded by three
    /// deliberate changes, each measured: the fit-distance correction, the aesthetic
    /// ladder cap that ends the grade in SOLID, and overlap ownership at the outline.
    /// It is RE-PINNED, never loosened — a harness that is allowed to drift from the
    /// app is a harness that can prove anything.
    /// ★ RE-PINNED 2026-08-28, build b54215d7, single-cell members OFF — read off the
    /// RUNNING app's own line after his ruling *"Once you hit the printability floor go
    /// solid"*:
    ///
    ///     DIAG stepped regions=2 stated=[6.0, 5.156120181083679] finest=5.156120181083679
    ///       printableFloor=5.156120181083679 nCap=1 bandMM=10.0 baked=true
    ///       sizes=[4.30=34 5.16=1764 6.00=1571]
    ///     DIAG steppedGrade painted=3369 ... solidRim=488 gradedToSolid=126 n=[n1=3369]
    ///
    /// ★ WHY IT IS STRONGER, NOT LOOSER. The previous pin (eight rungs down to 1.29 mm)
    /// recorded a ladder that ran PAST the printability floor: those rungs could only be
    /// drawn by raising the density to the floor — 52.1% at 1.29 mm — which is above the
    /// 47.5% at which fix #1 measured an octet merging into a sheet with periodic holes.
    /// So the old pin was pinning the defect. The new one pins a ladder that stops where
    /// the lattice stops being printable and hands the rest to SOLID: `gradedToSolid`
    /// 0 -> 126 and `solidRim` 89 -> 488 are the terminus actually firing, which the old
    /// histogram never showed.
    static let appSizes: [String: Int] = [
        "4.30": 34, "5.16": 1764, "6.00": 1571,
    ]

    // MARK: - the scene, assembled the way the app assembles it

    struct Inputs {
        var scene: LatticeSDFScene
        var cells: [Double]
        var boundary: [[Double]?]
        var rim: [[Double]?]
        var widths: [[Double]?]
        var phase: [Float]
        var finest: Double
        var h: His
    }

    static func inputs(_ h: His = His(),
                       faces: [(FaceID, Double)] = [(FaceID(15), 12.0), (FaceID(2), 13.0)])
        throws -> Inputs {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var specs: [LatticeRegionSpec] = []
        for (face, depth) in faces {
            guard let pl = LatticeRegionEmission.planeFor(face: face, in: mesh),
                  let s = LatticeRegionEmission.spec(for: pl, role: .include,
                                                     depthMM: depth, faceID: Int(face))
            else { throw XCTSkip("no plane for face \(face)") }
            specs.append(s)
        }
        let sc = LatticeSDFScene(
            mesh: mesh, field: nil, latticeID: "octet",
            stageMode: h.stageMode, algorithm: "stepped",
            boundaryFinishWritten: h.boundaryFinishWritten,
            maxDim: h.maxDim, regions: specs,
            rhoMin: h.rhoMin, rhoMax: h.rhoMax, gamma: h.gamma,
            whenEmpty: .latticeNothing, skinMM: h.skinMM)
        let occ = sc.occupancy

        // `WorkspacePlaceholder.latticeRegionCellsMM(widthPercentile: 0.5)`.
        let floor = h.cellsPerMemberFloorOverride
            ?? h.stageMode.cellsPerMemberFloor(
                topology: "octet", utilisation: .nan,
                boundaryFinishWritten: h.boundaryFinishWritten)
        let cells: [Double] = specs.map { r in
            var w = r.depthMM
            let d0 = LatticeMeasuredRegionWidth.wallWidthAlongNormalMM(
                region: r, occupancy: occ, partSDF: sc.partSDF, percentile: 0.5)
            if d0 > 0 { w = d0 }
            let d = TopOptKit.latticeRegionDerivation(
                topology: "octet", memberWidthMM: w,
                minExtrudableWidthMM: h.lineWidthMM, cellsPerMemberFloor: floor)
            guard d.valid, d.cellMM > 0 else { return 0 }
            let eff = w > 0 ? Swift.min(r.depthMM, w) : r.depthMM
            return eff / Swift.max(1, (eff / d.cellMM).rounded())
        }

        let cand = occ.values.map { $0 > 0.5 }
        let boundary = LatticeBoundaryDistance.inPlanePerRegion(
            regions: specs, candidate: cand,
            nx: occ.nx, ny: occ.ny, nz: occ.nz, spacing: occ.spacing)
        let rim = LatticeBoundaryDistance.inPlanePerRegion(
            regions: specs, candidate: cand,
            nx: occ.nx, ny: occ.ny, nz: occ.nz, spacing: occ.spacing,
            seed: LatticeSDFRenderer.attachedSeed(scene: sc))
        let widths: [[Double]?] = specs.map { r in
            LatticeMeasuredRegionWidth.wallWidthFieldAlongNormalMM(
                region: r, occupancy: occ, partSDF: sc.partSDF)
        }
        let finestStated = cells.filter { $0 > 0 }.min() ?? 0
        let phase = LatticeSDFRenderer.faceTilingPhase(
            regions: specs, cellMM: cells, fallbackCellMM: finestStated,
            origin: occ.origin)
        // `steppedFinestPrintableCellMM`.
        // ★ AGAINST `rhoMin`, NOT `rhoMax` — mirrors the product after his ruling of
        // 2026-08-28 (*"Once you hit the printability floor go solid"*). This harness
        // carries its own copy of the rule, so it has to move with it or it stops
        // being a check on the app and becomes a second opinion.
        var floorMM = finestStated
        let lat = LatticeType.named("octet")
        while floorMM > 0 {
            let half = floorMM / 2
            let binds = LatticeSDFRenderer.floorTestAtCeiling ? h.rhoMax : h.rhoMin
            if lat.printabilityDensityFloor(lineWidthMM: h.lineWidthMM,
                                            cellMM: half) > binds + 1e-9 { break }
            floorMM = half
        }
        return Inputs(scene: sc, cells: cells, boundary: boundary, rim: rim,
                      widths: widths, phase: phase, finest: floorMM, h: h)
    }

    static func bake(_ i: Inputs) -> LatticeCellField? {
        LatticePreviewOccupancy.steppedCellField(
            occupancy: i.scene.occupancy, demand: nil, regions: i.scene.regions,
            cellMM: i.cells, baseCellMM: i.cells.filter { $0 > 0 }.min() ?? 1,
            regionPhase: i.phase,
            memberThickness: i.scene.memberThicknessMM,
            minCellsPerMember: i.scene.minCellsPerMember,
            cellsPerMemberFloor: i.scene.cellsPerMemberFloorPerVoxel,
            boundaryDistancePerRegion: i.boundary,
            widthPerRegion: i.widths,
            rimDistancePerRegion: i.rim,
            finestCellMM: i.finest,
            shapeFitBandMM: i.h.shapeFitBandMM,
            lineWidthMM: i.h.lineWidthMM,
            densityLo: i.h.rhoMin, densityHi: i.h.rhoMax, densityGamma: i.h.gamma,
            latticeID: "octet", shapeFit: i.h.shapeFit,
            dyadicSteps: i.h.dyadicSteps, cellIsUserStated: [])
    }

    static func histogram(_ f: LatticeCellField?) -> [String: Int] {
        var out: [String: Int] = [:]
        for v in f?.steppedCellMM ?? [] where v > 0 {
            out[String(format: "%.2f", v), default: 0] += 1
        }
        return out
    }

    static func line(_ h: [String: Int]) -> String {
        h.keys.sorted { (Double($0) ?? 0) < (Double($1) ?? 0) }
            .map { "\($0)=\(h[$0]!)" }.joined(separator: " ")
    }

    // MARK: - 1. the harness is held to the app

    func testTheHeadlessBakeMatchesTheApp() throws {
        // ★ SINGLE-CELL MEMBERS **OFF** — the toggle the pinned DIAG was read at.
        // `boundaryFinishWritten` is that flag on this path; see the four sites in
        // `WorkspacePlaceholder` that read `singleCellMembers`.
        var h = His()
        h.boundaryFinishWritten = false
        let i = try Self.inputs(h, faces: LatticeRefusedCellProbe.hisFaces)
        let got = Self.histogram(Self.bake(i))
        print("app   : " + Self.line(Self.appSizes))
        print("here  : " + Self.line(got))
        XCTAssertEqual(got, Self.appSizes,
            "★ the headless bake no longer reproduces the app's own DIAG histogram — "
            + "fix the harness before believing any number it prints")
    }

    // MARK: - 2. WHERE S/2 COMES FROM

    /// ★★★ 260 NANOMETRES OF FLOAT ROUNDING HALVES THE CELL.
    ///
    /// He stated the rule (2026-08-26): *"Stepped grade means NOT dyadic (any number
    /// but 1/2 is ok)."* S/2 is not a size stepped may produce — and 138 of 528
    /// painted cells (26%) sit at exactly S/2 (5.16 = 10.31/2, 6.02 = 12.03/2).
    ///
    /// The per-spot rule divides by `n = ceil(s / target - 1e-6)` where `target` is
    /// the measured wall. On this part the region cell IS the p50 of that wall, so
    /// `s` and `target` are THE SAME NUMBER — except `s` has been through
    /// `halfRepresentable`, which rounds 10.312240362167358 UP to 10.3125. The ratio
    /// is 1.0000252, the absolute `1e-6` cannot absorb it, and `ceil` returns 2.
    ///
    /// This probe counts how many of the 181 shrinks are that, and how many are a
    /// wall that is genuinely thinner than its cell.
    func testHowManyShrinksAreFloatNoise() throws {
        let i = try Self.inputs()
        let occ = i.scene.occupancy
        let S = i.cells.map { Double(LatticePreviewOccupancy.halfRepresentable(Float($0))) }
        print("region cells: stated \(i.cells)")
        print("              half-rounded \(S)  "
              + "delta \(zip(S, i.cells).map { String(format: "%+.9f", $0 - $1) })")

        // Walk the same cell grid the bake walks, and classify every per-spot divide.
        var noise = 0, real = 0, none = 0
        var worstNoise = 1.0, bestReal = Double.infinity
        for (r, w) in i.widths.enumerated() {
            guard let w, r < S.count, S[r] > 0 else { continue }
            for v in w where v > 0 {
                let target = Swift.min(i.scene.regions[r].depthMM, v)
                let ratio = S[r] / target
                if ratio <= 1 { none += 1; continue }
                // "noise" = the overshoot is smaller than one half-float step at
                // this magnitude, i.e. the two numbers are the same number.
                let step = Double(abs(LatticePreviewOccupancy.halfRepresentable(Float(S[r] * 1.001))
                                      - Float(S[r])))
                if S[r] - target <= Swift.max(step, 1e-6) {
                    noise += 1; worstNoise = Swift.max(worstNoise, ratio)
                } else {
                    real += 1; bestReal = Swift.min(bestReal, ratio)
                }
            }
        }
        let tot = noise + real + none
        print(String(format: "measured voxels %d:  fits as-is %d (%.1f%%)   "
                     + "divided by FLOAT NOISE %d (%.1f%%, worst ratio %.7f)   "
                     + "divided by a REAL thin wall %d (%.1f%%, closest ratio %.4f)",
                     tot, none, 100 * Double(none) / Double(tot),
                     noise, 100 * Double(noise) / Double(tot), worstNoise,
                     real, 100 * Double(real) / Double(tot),
                     bestReal.isFinite ? bestReal : 0))
        XCTAssertGreaterThan(noise, 0,
            "★ if nothing is float noise the diagnosis is wrong — say so and move on")
    }
}

/// ★★★ THE PERMUTATION SWEEP — every combination that produces a lattice, scored
/// against the rules he stated on 2026-08-26:
///
///   * "Stepped grade means NOT dyadic (any number but 1/2 is ok)."   -> S/2 is a
///     FAILURE on the stepped path. On DEFAULT grade halving IS the step, so S/2 is
///     expected there and is not counted against it.
///   * "single-cell/member means make the largest single cell across the entire
///     model — per voxel."                                            -> under
///     single-cell the body of the wall must sit at the local wall thickness, not
///     at some division of it.
///   * "when not in single-cell/member mode … we can always have 2 cell lattice.
///     That is the floor for THIS model."                             -> two across.
///
/// It reports, per combination: how many distinct cell sizes the wall carries, the
/// smallest, and what fraction of painted cells sits below a third of the region
/// cell — the fabric measure.
final class LatticeQuiltSweepProbe: XCTestCase {

    struct Row {
        var name: String
        var painted = 0
        var sizes: [String: Int] = [:]
        var regionCells: [Double] = []
        var line: String {
            let ordered = sizes.keys.sorted { (Double($0) ?? 0) < (Double($1) ?? 0) }
            let S = regionCells.filter { $0 > 0 }.max() ?? 1
            let fabric = sizes.filter { (Double($0.key) ?? 0) < S / 3.0001 }
                .values.reduce(0, +)
            let minMM = ordered.first.flatMap { Double($0) } ?? 0
            return String(format: "%-46@ sizes %d  min %5.2f  below-S/3 %4d (%4.1f%%)  %@",
                          name as NSString, ordered.count, minMM, fabric,
                          100 * Double(fabric) / Double(Swift.max(1, painted)),
                          ordered.map { "\($0)=\(sizes[$0]!)" }
                            .joined(separator: " ") as NSString)
        }
    }

    func testEveryCombination() throws {
        var rows: [Row] = []
        for singleCell in [true, false] {
            for dyadic in [false, true] {                 // stepped grade / default grade
                for (gradeName, shapeFit, band) in [
                    ("shape", true, 10.0), ("no-grade", false, 0.0),
                ] {
                    var h = LatticeQuiltBakeProbe.His()
                    h.boundaryFinishWritten = singleCell   // he keeps a finish on
                    h.shapeFit = shapeFit
                    h.shapeFitBandMM = band
                    h.dyadicSteps = dyadic
                    let i = try LatticeQuiltBakeProbe.inputs(h)
                    var r = Row(name: "single-cell \(singleCell ? "ON " : "OFF")"
                                + " · \(dyadic ? "default-grade" : "stepped-grade ")"
                                + " · \(gradeName)")
                    r.regionCells = i.cells
                    r.sizes = LatticeQuiltBakeProbe.histogram(LatticeQuiltBakeProbe.bake(i))
                    r.painted = r.sizes.values.reduce(0, +)
                    rows.append(r)
                }
            }
        }
        print("=== THE PERMUTATION SWEEP (bake) ===")
        for r in rows { print("  " + r.line) }

        // ★ THE RULE: on the STEPPED path no cell may be exactly half its region's
        // cell. Reported, not asserted, until every combination is also confirmed in
        // the simulator — a green test here is not a verdict.
        print("--- S/2 audit (stepped grade only; halving IS the step on default) ---")
        for r in rows where r.name.contains("stepped-grade") {
            var bad = 0
            for (k, n) in r.sizes {
                guard let v = Double(k) else { continue }
                for S in r.regionCells where S > 0 {
                    if abs(v - S / 2) <= 0.02 { bad += n }
                }
            }
            print(String(format: "  %-46@ at S/2: %d", r.name as NSString, bad))
        }
    }
}

/// ★★★ WHERE THE STRUTS ARE CUT — neighbour boundaries the march cannot draw across.
///
/// `lsdf_march` prefetches the 3x3x3 neighbourhood and keeps only neighbours whose
/// cell size matches:
///
///     sameLattice = abs(rgb.b - LC.S) <= 1e-3 * max(LC.S, 1.0)
///
/// A neighbour that fails contributes NOTHING — its struts are never evaluated in
/// this cell — so every strut crossing that boundary is cut and both ends float.
/// That is stepped's declared contract (`LatticeSteppedStats::floating_ends`) when
/// the sizes really differ.
///
/// It is NOT the contract when the two sizes are the same cell to any physical
/// reading. The tolerance is 0.1% — 0.012 mm on a 12 mm cell — and the bake now
/// produces 12.00 (the DECLARED depth, capping region 0) beside 12.03 (region 1's
/// measured wall). They differ by 0.031 mm: 2.6x the tolerance, and 1.8% of the
/// 1.72 mm step the wall was MEASURED in. The march cuts every strut between them
/// for a difference the measurement cannot even express.
final class LatticeCutStrutProbe: XCTestCase {

    func testHowManyNeighbourBoundariesTheMarchCannotDrawAcross() throws {
        let i = try LatticeQuiltBakeProbe.inputs()
        guard let f = LatticeQuiltBakeProbe.bake(i) else { return XCTFail("no bake") }
        let g = f.field
        func size(_ x: Int, _ y: Int, _ z: Int) -> Double {
            guard x >= 0, y >= 0, z >= 0, x < g.nx, y < g.ny, z < g.nz else { return -1 }
            return Double(f.steppedCellMM[(z * g.ny + y) * g.nx + x])
        }
        let walk = Double(Swift.min(i.scene.occupancy.spacing.x,
                        Swift.min(i.scene.occupancy.spacing.y,
                                  i.scene.occupancy.spacing.z)))
        var pairs = 0, cut = 0, cutButSameToTheWalk = 0
        var offenders: [String: Int] = [:]
        for z in 0..<g.nz { for y in 0..<g.ny { for x in 0..<g.nx {
            let a = size(x, y, z)
            guard a > 0 else { continue }
            for (dx, dy, dz) in [(1, 0, 0), (0, 1, 0), (0, 0, 1)] {
                let b = size(x + dx, y + dy, z + dz)
                guard b > 0 else { continue }
                pairs += 1
                // The shader's own test, verbatim.
                if abs(b - a) > 1e-3 * Swift.max(a, 1.0) {
                    cut += 1
                    let key = String(format: "%.2f|%.2f", Swift.min(a, b), Swift.max(a, b))
                    offenders[key, default: 0] += 1
                    // ...but is the difference even expressible by the walk that
                    // measured the wall?
                    if abs(b - a) < walk { cutButSameToTheWalk += 1 }
                }
            }
        } } }
        print(String(format: "walk step %.4f mm   neighbour pairs %d", walk, pairs))
        print(String(format: "  CUT by the same-lattice gate: %d (%.1f%%)",
                     cut, 100 * Double(cut) / Double(Swift.max(1, pairs))))
        print(String(format: "  ...of which the two sizes differ by LESS THAN ONE WALK "
                     + "STEP (a difference the wall measurement cannot express): "
                     + "%d (%.1f%% of all pairs)",
                     cutButSameToTheWalk,
                     100 * Double(cutButSameToTheWalk) / Double(Swift.max(1, pairs))))
        print("  the pairs, most common first:")
        for (k, n) in offenders.sorted(by: { $0.value > $1.value }).prefix(10) {
            let parts = k.split(separator: "|").compactMap { Double($0) }
            let d = parts.count == 2 ? parts[1] - parts[0] : 0
            print(String(format: "    %@ mm  x%d   (differ by %.3f mm = %.1f%% of a walk step)",
                         k.replacingOccurrences(of: "|", with: " vs ") as NSString,
                         n, d, 100 * d / walk))
        }
    }
}

/// ★★★ IS THE SIZE FIELD COHERENT, OR IS IT DITHERING?
///
/// The wall walk steps in whole occupancy voxels, so its answer is quantised to `h`
/// (1.72 mm). A wall that is truly, say, 11.5 mm thick reads as 6h = 10.31 mm or
/// 7h = 12.03 mm depending purely on where the voxel centres fall — so on a smoothly
/// varying wall, ADJACENT cells alternate between the two. That is a dither, not
/// geometry, and every boundary in it cuts struts.
///
/// This distinguishes the two. For every painted cell, count how many of its six
/// face-neighbours carry a DIFFERENT size:
///
///   coherent patches  ->  most cells have 0; only patch borders have 1-2.
///   dither            ->  a large population with 3+ differing neighbours, i.e.
///                         cells that disagree with almost everything around them.
final class LatticeSizeCoherenceProbe: XCTestCase {

    func testWhetherTheCellSizeFieldIsCoherentOrDithering() throws {
        let i = try LatticeQuiltBakeProbe.inputs()
        guard let f = LatticeQuiltBakeProbe.bake(i) else { return XCTFail("no bake") }
        let g = f.field
        func size(_ x: Int, _ y: Int, _ z: Int) -> Double {
            guard x >= 0, y >= 0, z >= 0, x < g.nx, y < g.ny, z < g.nz else { return -1 }
            return Double(f.steppedCellMM[(z * g.ny + y) * g.nx + x])
        }
        var hist = [Int](repeating: 0, count: 7)
        var painted = 0
        var isolated = 0            // differs from EVERY painted neighbour it has
        for z in 0..<g.nz { for y in 0..<g.ny { for x in 0..<g.nx {
            let a = size(x, y, z)
            guard a > 0 else { continue }
            painted += 1
            var differ = 0, seen = 0
            for (dx, dy, dz) in [(1, 0, 0), (-1, 0, 0), (0, 1, 0),
                                 (0, -1, 0), (0, 0, 1), (0, 0, -1)] {
                let b = size(x + dx, y + dy, z + dz)
                guard b > 0 else { continue }
                seen += 1
                if abs(b - a) > 1e-3 * Swift.max(a, 1.0) { differ += 1 }
            }
            hist[Swift.min(6, differ)] += 1
            if seen > 0, differ == seen { isolated += 1 }
        } } }
        print("painted \(painted).  cells by NUMBER OF FACE-NEIGHBOURS OF A DIFFERENT SIZE:")
        for (n, c) in hist.enumerated() where c > 0 {
            print(String(format: "   %d differing: %4d (%4.1f%%)", n, c,
                         100 * Double(c) / Double(Swift.max(1, painted))))
        }
        print(String(format: "cells that differ from EVERY painted neighbour they have: "
                     + "%d (%.1f%%)", isolated,
                     100 * Double(isolated) / Double(Swift.max(1, painted))))
    }
}

/// ★★★ THE DEBRIS AT THE BASE — cells with almost no material in them.
///
/// Where the face prism runs into the base plate the preview draws disconnected
/// strut CROSS-SECTIONS lying on the shell, not lattice (see
/// `evidence/…/f2/00_shipped_front.png`, bottom strip). His rule for that place is
/// explicit — *"the face-prism only makes what's solid into lattice … if it overlaps
/// with a floor, that floor overlap gets a bit of lattice"* — and, for the residue,
/// *"get to the point where the lattice is as small as is printable and fill the
/// rest with solid material"*.
///
/// The per-spot rule measures the wall ALONG THE REGION'S NORMAL, which near the
/// base is still the full plate thickness — so it sees nothing wrong. What is
/// actually wrong is that the cell is mostly OUTSIDE the part: the surface cuts
/// through it at a shallow angle and every strut in it is sliced.
///
/// This measures the distribution of "how much of each painted cell is inside the
/// part", so the fix can be a MEASURED threshold rather than a guessed band width.
final class LatticeCellFillFractionProbe: XCTestCase {

    func testHowFullEachPaintedCellIs() throws {
        let i = try LatticeQuiltBakeProbe.inputs()
        guard let f = LatticeQuiltBakeProbe.bake(i) else { return XCTFail("no bake") }
        let g = f.field
        let occ = i.scene.occupancy
        // Occupancy is the REGION-CLIPPED solid, which is exactly "material the
        // lattice is allowed to fill" — the right denominator for this question.
        var frac: [Double] = []
        var i0 = 0
        for k in 0..<g.nz { for y in 0..<g.ny { for x in 0..<g.nx {
            defer { i0 += 1 }
            let s = Double(f.steppedCellMM[i0])
            guard s > 0 else { continue }
            // The base voxel's own box, sampled on the occupancy grid.
            let lo = SIMD3<Float>(g.origin.x + Float(x) * g.spacing.x - g.spacing.x / 2,
                                  g.origin.y + Float(y) * g.spacing.y - g.spacing.y / 2,
                                  g.origin.z + Float(k) * g.spacing.z - g.spacing.z / 2)
            var inside = 0, total = 0
            let n = 4
            for a in 0..<n { for b in 0..<n { for c in 0..<n {
                let p = lo + SIMD3<Float>(
                    (Float(a) + 0.5) / Float(n) * g.spacing.x,
                    (Float(b) + 0.5) / Float(n) * g.spacing.y,
                    (Float(c) + 0.5) / Float(n) * g.spacing.z)
                let q = (p - occ.origin) / occ.spacing
                let ix = Int(q.x.rounded()), iy = Int(q.y.rounded()), iz = Int(q.z.rounded())
                total += 1
                guard ix >= 0, iy >= 0, iz >= 0,
                      ix < occ.nx, iy < occ.ny, iz < occ.nz else { continue }
                if occ.values[(iz * occ.ny + iy) * occ.nx + ix] > 0.5 { inside += 1 }
            } } }
            frac.append(Double(inside) / Double(Swift.max(1, total)))
        } } }
        frac.sort()
        func q(_ t: Double) -> Double { frac[Int(t * Double(frac.count - 1))] }
        print(String(format: "painted %d.  fraction of each cell INSIDE the latticed material:",
                     frac.count))
        print(String(format: "   min %.2f  p05 %.2f  p10 %.2f  p25 %.2f  p50 %.2f  max %.2f",
                     frac.first ?? 0, q(0.05), q(0.10), q(0.25), q(0.5), frac.last ?? 0))
        for t in [0.05, 0.10, 0.20, 0.30, 0.50] {
            let n = frac.filter { $0 < t }.count
            print(String(format: "   cells less than %2.0f%% full: %4d (%4.1f%%)",
                         t * 100, n, 100 * Double(n) / Double(Swift.max(1, frac.count))))
        }
    }
}

/// ★★★ THE EMPTY SPACE — in-region cells the bake REFUSES.
///
/// With the density defect fixed the quilt is gone and what is left is his second
/// complaint: flat grey patches inside the declared wall. Those are not background
/// (see-through measures 0.00%), so they are either the shell or SOLID FILL — and a
/// cell the bake refuses is drawn solid by the march (`F = dClip` when nothing is
/// active).
///
/// So: how many base cells sit inside a declared region, and how many of those does
/// the bake actually paint? The difference is the empty space, in cells.
final class LatticeRefusedCellProbe: XCTestCase {

    /// ★ HIS PAIRING, NOT MINE. His DIAG at 17:56 reads
    ///     depth=12.0 measuredW=12.031 -> final=12.0
    ///     depth=11.0 measuredW=10.312 -> final=10.312
    /// In this fixture face 2's wall measures 12.031 and face 15's measures 10.312,
    /// so he has 12 mm on face 2 and 11 mm on face 15 — the opposite of the pairing
    /// this file assumed. Modelling the wrong pairing gave 528 painted cells against
    /// the app's 376, and a probe that disagrees with the app by 30% is measuring a
    /// different part.
    static let hisFaces: [(FaceID, Double)] = [(FaceID(2), 12.0), (FaceID(15), 11.0)]

    func testHowManyInRegionCellsAreRefused() throws {
        for (label, oneCell) in [("single-cell ON ", true), ("single-cell OFF", false)] {
            var h = LatticeQuiltBakeProbe.His()
            h.boundaryFinishWritten = oneCell
            let i = try LatticeQuiltBakeProbe.inputs(h, faces: Self.hisFaces)
            guard let f = LatticeQuiltBakeProbe.bake(i) else { continue }
            let g = f.field
            var inRegion = 0, painted = 0, refused = 0
            var i0 = 0
            for k in 0..<g.nz { for y in 0..<g.ny { for x in 0..<g.nx {
                defer { i0 += 1 }
                let p = SIMD3<Double>(
                    Double(g.origin.x) + Double(x) * Double(g.spacing.x),
                    Double(g.origin.y) + Double(y) * Double(g.spacing.y),
                    Double(g.origin.z) + Double(k) * Double(g.spacing.z))
                let inside = i.scene.regions.contains {
                    $0.role == .include && LatticeRegionMask.contains(p, region: $0)
                }
                guard inside else { continue }
                inRegion += 1
                if f.steppedCellMM[i0] > 0 { painted += 1 } else { refused += 1 }
            } } }
            print(String(format: "%@ region cells %@  base grid %dx%dx%d @ %.2fmm",
                         label, i.cells.map { String(format: "%.2f", $0) }
                            .joined(separator: "/"),
                         g.nx, g.ny, g.nz, Double(g.spacing.x)))
            print(String(format: "   in-region cells %5d   painted %5d   REFUSED %5d (%.1f%%)",
                         inRegion, painted, refused,
                         100 * Double(refused) / Double(Swift.max(1, inRegion))))
        }
    }
}

/// ★★★ IS THE "EMPTY SPACE" AN UNDECLARED CAD FACE?
///
/// Once the quilt went, what is left is flat grey areas inside the wall with
/// STRAIGHT, POLYGONAL edges. A lattice failure has ragged edges; a straight edge is
/// a face boundary. And `expand-coplanar` is a no-op on a B-rep (measured: 22 taps
/// gave 22 faces), so a wall split into several coplanar CAD faces is latticed only
/// where he happened to tap.
///
/// This lists every face COPLANAR with the two he declared — same normal, same
/// plane — and how much area each carries. If the declared pair is a minority of
/// that area, the empty space is undeclared faces and not a preview defect at all.
final class LatticeCoplanarFaceProbe: XCTestCase {

    func testHowManyFacesShareThePlanesHeDeclared() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        // Area and plane per face id, straight off the triangles.
        var area: [Int: Double] = [:]
        var normal: [Int: SIMD3<Double>] = [:]
        var offset: [Int: Double] = [:]
        let idx = mesh.indices, pos = mesh.positions
        for t in stride(from: 0, to: idx.count, by: 3) {
            let f = Int(mesh.faceIDs[t / 3])
            func v(_ n: Int) -> SIMD3<Double> {
                let i = Int(idx[t + n]) * 3
                return SIMD3(Double(pos[i]), Double(pos[i + 1]), Double(pos[i + 2]))
            }
            let a = v(0), b = v(1), c = v(2)
            let n = simd_cross(b - a, c - a)
            let m = simd_length(n)
            guard m > 1e-12 else { continue }
            area[f, default: 0] += 0.5 * m
            let u = n / m
            normal[f] = u
            offset[f] = simd_dot(u, a)
        }
        for target in [15, 2] {
            guard let tn = normal[target], let to = offset[target] else { continue }
            var group: [(Int, Double)] = []
            for (f, n) in normal {
                guard let o = offset[f] else { continue }
                // Same plane: normals parallel (either sense) and offsets agree.
                let par = abs(simd_dot(n, tn))
                let sameSide = simd_dot(n, tn) > 0
                guard par > 0.999, abs((sameSide ? o : -o) - to) < 0.05 else { continue }
                group.append((f, area[f] ?? 0))
            }
            group.sort { $0.1 > $1.1 }
            let tot = group.reduce(0.0) { $0 + $1.1 }
            let mine = area[target] ?? 0
            print(String(format: "face %d: %d faces share its plane, %.0f mm2 total; "
                         + "face %d itself is %.0f mm2 (%.1f%%)",
                         target, group.count, tot, target, mine,
                         100 * mine / Swift.max(1e-9, tot)))
            for (f, a) in group.prefix(8) {
                print(String(format: "    face %3d  %8.0f mm2%@", f, a,
                             f == target ? "   <- declared" : ""))
            }
        }
    }
}

/// ★★★ IS THE EMPTY SPACE WALL THAT THE PRISM NEVER REACHED?
///
/// Looking into the channel you see the FAR wall's inner surface. The face prism
/// starts at the OUTER face and runs `depth` inward — so wherever the wall is
/// THICKER than the depth he typed, the innermost slice is never latticed, and from
/// inside it reads as a flat grey area with a straight edge. That is exactly the
/// shape of the empty patches in his 18:02 capture.
///
/// This measures it: per declared region, the distribution of (local wall − declared
/// depth) over the voxels the region covers. A positive value is unlatticed material
/// behind the lattice.
final class LatticeUnreachedWallProbe: XCTestCase {

    func testHowMuchWallThePrismNeverReaches() throws {
        let h = LatticeQuiltBakeProbe.His()
        let i = try LatticeQuiltBakeProbe.inputs(h, faces: LatticeRefusedCellProbe.hisFaces)
        for (r, region) in i.scene.regions.enumerated() where region.role == .include {
            guard r < i.widths.count, let w = i.widths[r] else { continue }
            let declared = region.depthMM
            var over: [Double] = []
            for v in w where v > 0 { over.append(v - declared) }
            guard !over.isEmpty else { continue }
            over.sort()
            func q(_ t: Double) -> Double { over[Int(t * Double(over.count - 1))] }
            let unreached = over.filter { $0 > 0.5 }.count
            print(String(format:
                "region %d  declared depth %.1f mm  over %d measured voxels: "
                + "wall−depth  min %+.2f  p25 %+.2f  p50 %+.2f  p75 %+.2f  max %+.2f",
                r, declared, over.count, over.first ?? 0, q(0.25), q(0.5), q(0.75),
                over.last ?? 0))
            print(String(format:
                "           voxels where the wall is MORE than 0.5 mm deeper than the "
                + "prism (never latticed): %d (%.1f%%)",
                unreached, 100 * Double(unreached) / Double(over.count)))
        }
    }
}

/// ★★★ THE EMPTY REGION — `contains` vs `signedDistance`, per region.
///
/// His 19:39–19:43 taps are the decisive evidence:
///
///     empty rectangle          5% · 0.94 mm strut · 10.31 mm cell
///     coarse lattice beside it 5% · 1.10 mm strut · 12.00 mm cell
///
/// The empty area REPORTS A CELL, so the bake painted it — and 10.31 vs 12.00 are
/// the two DIFFERENT regions. One whole region draws; the other is empty. Same in
/// two-cell mode (5.16 empty, 6.00 drawn). And it does not move when he orbits, so
/// it is not the eye-facing cap rule of `7885e3cd`.
///
/// There are two descriptions of "inside the region" in this codebase:
///   the BAKE  paints a cell when `LatticeRegionMask.contains(p, region:)`
///   the MARCH stops struts at `regionSDF`, built from
///             `LatticeRegionMask.signedDistance(p, regions:)`
/// and the shell cuts its hole from that same SDF. If the two disagree for one
/// region, that region is painted but never drawn AND the shell never opens over it
/// — which is a flat grey area with a cell reading, exactly what he photographed.
final class LatticeRegionAgreementProbe: XCTestCase {

    func testTheBakeAndTheMarchAgreeAboutEachRegion() throws {
        let h = LatticeQuiltBakeProbe.His()
        let i = try LatticeQuiltBakeProbe.inputs(h, faces: LatticeRefusedCellProbe.hisFaces)
        let occ = i.scene.occupancy
        let regions = i.scene.regions
        var perRegion: [Int: (inBake: Int, inMarch: Int, bakeOnly: Int, marchOnly: Int)] = [:]
        var idx = 0
        for k in 0..<occ.nz {
            for j in 0..<occ.ny {
                for x in 0..<occ.nx {
                    defer { idx += 1 }
                    guard occ.values[idx] > 0.5 else { continue }
                    let p = SIMD3<Double>(
                        Double(occ.origin.x) + Double(x) * Double(occ.spacing.x),
                        Double(occ.origin.y) + Double(j) * Double(occ.spacing.y),
                        Double(occ.origin.z) + Double(k) * Double(occ.spacing.z))
                    // The march / shell reading: the UNION's signed distance.
                    let sd = LatticeRegionMask.signedDistance(p, regions: regions)
                    for (r, region) in regions.enumerated() where region.role == .include {
                        let inBake = LatticeRegionMask.contains(p, region: region)
                        // A voxel this region owns, as the march would see the union.
                        let inMarch = sd <= 0
                        var e = perRegion[r] ?? (0, 0, 0, 0)
                        if inBake { e.inBake += 1 }
                        if inBake && inMarch { e.inMarch += 1 }
                        if inBake && !inMarch { e.bakeOnly += 1 }
                        if !inBake && inMarch { e.marchOnly += 1 }
                        perRegion[r] = e
                    }
                }
            }
        }
        print("occupancy voxel \(occ.spacing.x) mm   regions \(regions.count)")
        for (r, e) in perRegion.sorted(by: { $0.key < $1.key }) {
            let cell = r < i.cells.count ? i.cells[r] : 0
            print(String(format:
                "region %d  cell %.2f mm  depth %.1f  normal %@",
                r, cell, regions[r].depthMM,
                String(format: "(%.0f,%.0f,%.0f)", regions[r].normal.x,
                       regions[r].normal.y, regions[r].normal.z) as NSString))
            print(String(format:
                "   voxels the BAKE calls inside: %6d   of those the MARCH also calls "
                + "inside: %6d (%.1f%%)   BAKE-ONLY (painted, never drawn): %6d",
                e.inBake, e.inMarch,
                100 * Double(e.inMarch) / Double(Swift.max(1, e.inBake)), e.bakeOnly))
        }
    }
}

/// ★★★ WHICH CELLS THE MARCH WILL DRAW SOLID — the shader's own test, on the CPU.
///
/// His taps: the empty rectangle REPORTS `10.31 mm cell`, the lattice beside it
/// reports `12.00 mm`. Painted, in-region by both readers, and still no struts. The
/// only remaining path in `lsdf_march` is
///
///     F = anyActive ? max(dn * cellHere, dClip) : dClip
///
/// — with no active same-size neighbour the cell is drawn SOLID, and solid sits
/// strictly inside the part surface, so the SHELL covers it. Flat grey with a cell
/// reading is exactly that.
///
/// `anyActive` walks the 3x3x3 with a SAME-CELL-SIZE gate:
///     sameLattice = abs(rgb.b - LC.S) <= 1e-3 * max(LC.S, 1.0)
/// so a cell whose whole neighbourhood is a DIFFERENT size sees nothing. With two
/// regions at 12.00 and 10.31 mm — 16% apart, 160x the tolerance — every cell near
/// their boundary is at risk, and a whole region is at risk if its own block centre
/// lands in the other region's base voxel.
///
/// This replicates the walk exactly (block centre, phase, size gate) and reports the
/// count and SIZES of the cells that will render solid.
final class LatticeSolidOnHisSceneProbe: XCTestCase {

    func testHowManyCellsTheMarchDrawsSolid() throws {
        for (label, oneCell) in [("single-cell ON ", true), ("single-cell OFF", false)] {
            var h = LatticeQuiltBakeProbe.His()
            h.boundaryFinishWritten = oneCell
            let i = try LatticeQuiltBakeProbe.inputs(h, faces: LatticeRefusedCellProbe.hisFaces)
            guard let f = LatticeQuiltBakeProbe.bake(i) else { continue }
            let g = f.field
            let S0 = f.baseCellMM
            func sizeAt(_ x: Int, _ y: Int, _ z: Int) -> Double {
                guard x >= 0, y >= 0, z >= 0, x < g.nx, y < g.ny, z < g.nz else { return -1 }
                return Double(f.steppedCellMM[(z * g.ny + y) * g.nx + x])
            }
            func activeAt(_ x: Int, _ y: Int, _ z: Int) -> Float {
                guard x >= 0, y >= 0, z >= 0, x < g.nx, y < g.ny, z < g.nz else { return -1 }
                return g.values[(z * g.ny + y) * g.nx + x]
            }
            var painted = 0, solid = 0
            var solidSizes: [String: Int] = [:]
            var paintedSizes: [String: Int] = [:]
            for z in 0..<g.nz { for y in 0..<g.ny { for x in 0..<g.nx {
                let idx = (z * g.ny + y) * g.nx + x
                let S = Double(f.steppedCellMM[idx])
                guard S > 0 else { continue }
                painted += 1
                paintedSizes[String(format: "%.2f", S), default: 0] += 1
                let m = S / S0
                let packed = Double(f.steppedPhase[idx])
                let ax = Int(packed + 1e-4)
                let frac = packed - Double(ax)
                var ph = SIMD3<Double>(0, 0, 0)
                if ax >= 0, ax <= 2 { ph[ax] = frac * m }
                let cb = SIMD3<Double>(Double(x), Double(y), Double(z))
                let blk = SIMD3<Double>(((cb.x - ph.x) / m).rounded(.down),
                                        ((cb.y - ph.y) / m).rounded(.down),
                                        ((cb.z - ph.z) / m).rounded(.down))
                var any = false
                outer: for oz in -1...1 { for oy in -1...1 { for ox in -1...1 {
                    let nb = blk + SIMD3<Double>(Double(ox), Double(oy), Double(oz))
                    let cc = SIMD3<Double>(((nb.x + 0.5) * m + ph.x).rounded(.down),
                                           ((nb.y + 0.5) * m + ph.y).rounded(.down),
                                           ((nb.z + 0.5) * m + ph.z).rounded(.down))
                    let ns = sizeAt(Int(cc.x), Int(cc.y), Int(cc.z))
                    let na = activeAt(Int(cc.x), Int(cc.y), Int(cc.z))
                    if ns > 0, na >= 0, abs(ns - S) <= 1e-3 * Swift.max(S, 1.0) {
                        any = true; break outer
                    }
                } } }
                if !any { solid += 1; solidSizes[String(format: "%.2f", S), default: 0] += 1 }
            } } }
            print(String(format: "%@ base %.2f mm  painted %d  WILL DRAW SOLID %d (%.1f%%)",
                         label, S0, painted, solid,
                         100 * Double(solid) / Double(Swift.max(1, painted))))
            print("   painted sizes: " + LatticeQuiltBakeProbe.line(paintedSizes))
            print("   SOLID   sizes: " + (solidSizes.isEmpty ? "none"
                                          : LatticeQuiltBakeProbe.line(solidSizes)))
        }
    }
}

/// ★★★ THE RIM'S TEST, AND WHY IT SCATTERS.
///
/// `lsdf_outline_mm` NEAREST-reads one float per base cell — the rim distance the
/// bake sampled at that cell's CENTRE — and the march makes the whole cell solid
/// when `dOutline <= solidOutlineBandMM`.
///
///   the field  is measured ON the occupancy grid, so its smallest non-zero value
///              inside material is ONE VOXEL: his DIAG says `dCentre[min = 1.72]`
///   the band   is `max(finestPrintableCell, oneVoxel) = max(1.289, 1.719) = 1.719`
///
/// The same number. So the test fires exactly where the field sits at its floor —
/// and it is sampled once per 10.31 mm cell over a 1.72 mm field, a 6:1 lottery. The
/// result is a scatter of isolated solid cells instead of a ring at the outline.
///
/// This prints the distribution of the per-cell rim distance and, for each candidate
/// band rule, how many cells go solid — so the rule is chosen from the numbers.
final class LatticeRimBandRuleProbe: XCTestCase {

    func testWhichBandRuleGivesARingRatherThanAScatter() throws {
        let h = LatticeQuiltBakeProbe.His()
        let i = try LatticeQuiltBakeProbe.inputs(h, faces: LatticeRefusedCellProbe.hisFaces)
        guard let f = LatticeQuiltBakeProbe.bake(i) else { return XCTFail("no bake") }
        let voxel = Double(Swift.max(i.scene.occupancy.spacing.x,
                     Swift.max(i.scene.occupancy.spacing.y, i.scene.occupancy.spacing.z)))
        // The g channel is the rim distance per painted cell; 1e3 is "unmeasured".
        var d: [(Double, Double)] = []       // (rim distance, that cell's size)
        for k in 0..<f.level.count where f.steppedCellMM[k] > 0 {
            let v = Double(f.level[k])
            guard v > 0, v < 1e3 else { continue }
            d.append((v, Double(f.steppedCellMM[k])))
        }
        let sorted = d.map { $0.0 }.sorted()
        func q(_ t: Double) -> Double { sorted[Int(t * Double(sorted.count - 1))] }
        print(String(format: "voxel %.3f mm   painted-with-a-distance %d", voxel, d.count))
        print(String(format: "rim distance: min %.2f  p05 %.2f  p10 %.2f  p25 %.2f  "
                     + "p50 %.2f  max %.2f", sorted.first ?? 0, q(0.05), q(0.10),
                     q(0.25), q(0.5), sorted.last ?? 0))
        let finestPrintable = i.finest
        let lineW = h.lineWidthMM
        let rules: [(String, (Double) -> Double)] = [
            ("SHIPPED  max(finestPrintable, voxel)", { _ in
                Swift.max(finestPrintable, voxel) }),
            ("physical max(finestPrintable/2, 3*bead)", { _ in
                Swift.max(0.5 * finestPrintable, 3 * lineW) }),
            ("half the LOCAL cell   0.5 * S", { s in 0.5 * s }),
            ("a third of the LOCAL cell 0.33 * S", { s in s / 3 }),
            ("a quarter of the LOCAL cell 0.25 * S", { s in 0.25 * s }),
        ]
        for (name, rule) in rules {
            var solid = 0
            var sizes: [String: Int] = [:]
            for (dist, s) in d where dist <= rule(s) {
                solid += 1
                sizes[String(format: "%.2f", s), default: 0] += 1
            }
            print(String(format: "  %-40@ solid %4d of %d (%4.1f%%)   %@",
                         name as NSString, solid, d.count,
                         100 * Double(solid) / Double(Swift.max(1, d.count)),
                         LatticeQuiltBakeProbe.line(sizes) as NSString))
        }
    }
}

/// ★★★ THE ATTACHED SEED LEAKS DOWN THE DEPTH.
///
///     attachedSeed = occ.values[i] <= 0.5 && memberThicknessMM[i] > 0
///
/// i.e. "part material that is not in the latticed set". The BFS that turns it into
/// the rim distance is IN-PLANE — the thickness direction is dropped — so a seed
/// voxel ANYWHERE along a depth column marks that whole in-plane column as distance
/// zero. His prism is 12.0 mm on a wall that measures 12.03, so a 0.03 mm sliver of
/// unlatticed material sits behind essentially every in-plane position of the
/// region, and the rim reads ~one voxel EVERYWHERE instead of only at the face's
/// outline.
///
/// The tell is already in his DIAG: the FIT distance (the face's real outline) never
/// drops below 6.87 mm, while the RIM distance bottoms out at 1.72 mm. Two fields
/// that should agree about where the boundary is, disagreeing by 4x.
final class LatticeAttachedSeedProbe: XCTestCase {

    func testHowFarTheRimAndTheFitDisagree() throws {
        let h = LatticeQuiltBakeProbe.His()
        let i = try LatticeQuiltBakeProbe.inputs(h, faces: LatticeRefusedCellProbe.hisFaces)
        let occ = i.scene.occupancy
        guard let seed = LatticeSDFRenderer.attachedSeed(scene: i.scene) else {
            return XCTFail("no seed")
        }
        let seeded = seed.filter { $0 }.count
        // Of those seeds, how many sit at an in-plane position the region DOES cover
        // (i.e. they are outside only in DEPTH)? Those are the ones that leak.
        var leaks = 0
        var idx = 0
        for k in 0..<occ.nz {
            for j in 0..<occ.ny {
                for x in 0..<occ.nx {
                    defer { idx += 1 }
                    guard seed[idx] else { continue }
                    let p = SIMD3<Double>(
                        Double(occ.origin.x) + Double(x) * Double(occ.spacing.x),
                        Double(occ.origin.y) + Double(j) * Double(occ.spacing.y),
                        Double(occ.origin.z) + Double(k) * Double(occ.spacing.z))
                    // Project onto each region's plane and ask in-plane containment by
                    // walking the depth: if ANY depth along the region's normal from
                    // this point is inside the region, the seed is a depth-only escape.
                    for r in i.scene.regions where r.role == .include && r.kind == .face {
                        let n = simd_normalize(r.normal)
                        var inPlane = false
                        var t = 0.0
                        while t <= r.depthMM + 1e-6 {
                            if LatticeRegionMask.contains(p - n * 0 + n * 0, region: r) {
                                inPlane = true; break
                            }
                            // step along the normal from the region's own origin plane
                            let s0 = simd_dot(p - r.origin, n)
                            let q = p - n * (s0 - t)
                            if LatticeRegionMask.contains(q, region: r) { inPlane = true; break }
                            t += Double(occ.spacing.x)
                        }
                        if inPlane { leaks += 1; break }
                    }
                }
            }
        }
        print(String(format: "seed voxels %d   of those, in-plane INSIDE a region "
                     + "(outside only in DEPTH) %d (%.1f%%)",
                     seeded, leaks, 100 * Double(leaks) / Double(Swift.max(1, seeded))))

        // And the two fields, side by side, over the painted cells.
        var rim: [Double] = [], fit: [Double] = []
        for (r, f) in i.rim.enumerated() {
            guard let f, r < i.boundary.count, let b = i.boundary[r] else { continue }
            for n in 0..<min(f.count, b.count) where f[n] > 0 && b[n] > 0 {
                rim.append(f[n]); fit.append(b[n])
            }
        }
        rim.sort(); fit.sort()
        func q(_ a: [Double], _ t: Double) -> Double { a[Int(t * Double(a.count - 1))] }
        print(String(format: "over %d voxels:  RIM min %.2f p25 %.2f p50 %.2f   "
                     + "FIT min %.2f p25 %.2f p50 %.2f",
                     rim.count, rim.first ?? 0, q(rim, 0.25), q(rim, 0.5),
                     fit.first ?? 0, q(fit, 0.25), q(fit, 0.5)))
    }
}

/// ★★★ HOW CLOSE THE LATTICE GETS TO THE FACE'S OWN OUTLINE.
///
/// His 20:34 capture shows the struts stopping roughly a cell short of the wall's
/// edge, leaving a bare band between the last node and the chamfer. The bake paints a
/// cell when the region CONTAINS ITS CENTRE, so a cell straddling the outline with
/// its centre outside is never painted — and that leaves a band up to S/2 wide (5.16
/// mm on a 10.31 mm cell) of wall with nothing on it.
///
/// This measures it: over the painted cells, the FIT field (distance to the face's
/// full outline) sampled at each cell's own centre. If the minimum is around half a
/// cell, the band is real and it is that rule.
final class LatticeReachToOutlineProbe: XCTestCase {

    func testHowCloseToTheOutlineTheLatticeReaches() throws {
        let h = LatticeQuiltBakeProbe.His()
        let i = try LatticeQuiltBakeProbe.inputs(h, faces: LatticeRefusedCellProbe.hisFaces)
        guard let f = LatticeQuiltBakeProbe.bake(i) else { return XCTFail("no bake") }
        let g = f.field
        let occ = i.scene.occupancy
        func fitAt(_ p: SIMD3<Double>, _ r: Int) -> Double {
            guard r < i.boundary.count, let field = i.boundary[r] else { return -1 }
            let q = (SIMD3<Float>(p) - occ.origin) / occ.spacing
            let a = Int(q.x.rounded()), b = Int(q.y.rounded()), c = Int(q.z.rounded())
            guard a >= 0, a < occ.nx, b >= 0, b < occ.ny, c >= 0, c < occ.nz else { return -1 }
            let n = (c * occ.ny + b) * occ.nx + a
            return n < field.count ? field[n] : -1
        }
        var per: [Int: [Double]] = [:]
        var idx = 0
        for k in 0..<g.nz { for y in 0..<g.ny { for x in 0..<g.nx {
            defer { idx += 1 }
            guard f.steppedCellMM[idx] > 0 else { continue }
            let p = SIMD3<Double>(
                Double(g.origin.x) + Double(x) * Double(g.spacing.x),
                Double(g.origin.y) + Double(y) * Double(g.spacing.y),
                Double(g.origin.z) + Double(k) * Double(g.spacing.z))
            for (r, region) in i.scene.regions.enumerated()
            where region.role == .include && LatticeRegionMask.contains(p, region: region) {
                let d = fitAt(p, r)
                if d > 0 { per[r, default: []].append(d) }
                break
            }
        } } }
        for (r, var v) in per.sorted(by: { $0.key < $1.key }) {
            v.sort()
            let S = r < i.cells.count ? i.cells[r] : 0
            func q(_ t: Double) -> Double { v[Int(t * Double(v.count - 1))] }
            print(String(format:
                "region %d  cell %.2f mm  half-cell %.2f mm   painted cells %d",
                r, S, S / 2, v.count))
            print(String(format:
                "   distance from cell CENTRE to the face outline: "
                + "min %.2f  p05 %.2f  p25 %.2f  p50 %.2f",
                v.first ?? 0, q(0.05), q(0.25), q(0.5)))
            print(String(format:
                "   -> the lattice never gets closer than %.2f mm to the outline; "
                + "half a cell is %.2f mm", v.first ?? 0, S / 2))
        }
    }
}

// MARK: - the march's SELF-NEIGHBOUR lookup, replayed on the baked field
//
// ★ WHAT THIS TESTS. In `lsdf_march` the 3x3x3 prefetch resolves every neighbour —
// INCLUDING THE CELL THE RAY IS STANDING IN — by the covering block's CENTRE:
//
//     float3 cc = floor((nb + 0.5) * LC.m + LC.phase);
//     bool sameLattice = abs(rgb.b - LC.S) <= 1e-3 * max(LC.S, 1.0);
//
// but `LC.S` was read at `bi = round(cb)`, the base cell the point is actually in.
// Where the bake wrote a DIFFERENT size at the block's centre — which is exactly what
// a per-spot cell rule does, since it sizes each base cell from its own local wall —
// the self test fails, `anyActive` stays false, `dn` stays 1e9, and the march draws
// NOTHING. No strut, and no solid either: the ray passes through the wall.
//
// That is a hole you cannot tap, aligned to the cell grid, and it must be commoner
// with single-cell-per-member ON, because that is the mode whose whole purpose is to
// vary the cell from spot to spot.
//
// The probe replays that arithmetic at each painted base cell's CENTRE and counts the
// disagreements. No rendering, no camera, no eyeballing.
final class LatticeSelfNeighbourProbe: XCTestCase {

    /// Fraction of painted base cells whose SELF lookup lands on a different size.
    private func blind(_ i: LatticeQuiltBakeProbe.Inputs,
                       _ label: String) throws -> (painted: Int, blind: Int) {
        let f = try XCTUnwrap(LatticeQuiltBakeProbe.bake(i))
        let g = f.field
        let nx = g.nx, ny = g.ny, nz = g.nz
        let s0 = Float(f.baseCellMM)
        let sizes = f.steppedCellMM
        let phases = f.steppedPhase
        guard !sizes.isEmpty else { throw XCTSkip("not a stepped bake") }

        var painted = 0, blind = 0
        var byCell: [String: (Int, Int)] = [:]
        for z in 0..<nz { for y in 0..<ny { for x in 0..<nx {
            let i0 = (z * ny + y) * nx + x
            let S = sizes[i0]
            guard S > 0 else { continue }
            painted += 1
            let m = S / max(s0, 1e-6)
            // `steppedPhase` packs `axis + fraction`; the shader unpacks it into a
            // per-axis shift of `fraction * m` BASE cells.
            let packed = max(0, phases[i0])
            let axis = Int(floor(packed + 1e-4))
            let frac = packed - Float(axis)
            var ph = SIMD3<Float>(repeating: 0)
            if axis >= 0, axis <= 2 { ph[axis] = frac * m }
            // The ray at this base cell's CENTRE: cb == the integer index.
            let cb = SIMD3<Float>(Float(x), Float(y), Float(z))
            let blk = ((cb - ph) / max(m, 1e-6)).rounded(.down)
            // ★ `anyActive` is an OR over the WHOLE 3x3x3, so a hole needs every one
            // of the 27 to miss. Self alone missing only silences THIS cell's struts.
            var selfSame = false, anySame = false
            for oz in -1...1 { for oy in -1...1 { for ox in -1...1 {
                let nb = blk + SIMD3<Float>(Float(ox), Float(oy), Float(oz))
                let cc = ((nb + 0.5) * m + ph).rounded(.down)
                let a = Int(cc.x), b = Int(cc.y), c = Int(cc.z)
                var other: Float = 0
                if a >= 0, a < nx, b >= 0, b < ny, c >= 0, c < nz {
                    other = sizes[(c * ny + b) * nx + a]
                }
                if abs(other - S) <= 1e-3 * max(S, 1) {
                    anySame = true
                    if ox == 0, oy == 0, oz == 0 { selfSame = true }
                }
            } } }
            // ★ SELF IS THE ONE THAT MATTERS FOR THE PICTURE. `segs` are the unit
            // cell's capsules, each TAGGED with the 0..26 index of the neighbour that
            // owns it, and the march skips every segment whose owner has `rn < 0`.
            // A cell whose SELF entry misses therefore loses the segments it owns —
            // most of the strutwork you stand in — while `anyActive` stays true off a
            // neighbour, so nothing is reported and the ray still marches. That is a
            // thinned, patchy cell, not a fully dark one.
            _ = anySame
            let same = selfSame
            let key = String(format: "%.2f", S)
            var e = byCell[key] ?? (0, 0)
            e.0 += 1
            if !same { blind += 1; e.1 += 1 }
            byCell[key] = e
        } } }

        let pct = painted > 0 ? 100.0 * Double(blind) / Double(painted) : 0
        print(String(format: "SELFMISS %@  painted=%d  self-miss=%d (%.1f%%)",
                     label, painted, blind, pct))
        for k in byCell.keys.sorted(by: { (Double($0) ?? 0) < (Double($1) ?? 0) }) {
            let (n, b) = byCell[k]!
            print(String(format: "     cell %@ mm: %d painted, %d blind (%.0f%%)",
                         k, n, b, n > 0 ? 100.0 * Double(b) / Double(n) : 0))
        }
        return (painted, blind)
    }

    /// His two faces, both toggles — the two pictures he reported.
    func testSelfLookupIsBlindOnHisScene() throws {
        // ★ `boundaryFinishWritten` IS the single-cell flag on this path — see the
        // four sites in `WorkspacePlaceholder` that read `singleCellMembers`. ON is
        // the harness's own default, which is why it reproduces the app's 376-cell
        // DIAG; OFF is the 2,649-cell one.
        var off = LatticeQuiltBakeProbe.His()
        off.stageMode = .aesthetic
        off.boundaryFinishWritten = false
        let a = try blind(try LatticeQuiltBakeProbe.inputs(
            off, faces: LatticeRefusedCellProbe.hisFaces), "single-cell OFF")

        // Single-cell per member is `cellsPerMemberFloor == 1` — one cell across a
        // member, sized from that member's own local wall.
        var on = LatticeQuiltBakeProbe.His()
        on.stageMode = .aesthetic
        on.boundaryFinishWritten = true
        let b = try blind(try LatticeQuiltBakeProbe.inputs(
            on, faces: LatticeRefusedCellProbe.hisFaces), "single-cell ON")

        print("SELF SUMMARY off=\(a.blind)/\(a.painted)  on=\(b.blind)/\(b.painted)")
    }
}
