import XCTest
import simd
import CryptoKit
@testable import TopOptFlows

/// ★★ EACH REGION'S ANCHOR SEARCH WALKS ITS OWN FOOTPRINT (maintainer, 2026-10-03: "Octree bake:
/// limit each region's anchor search to its footprint. Prove it with identical bakes on two
/// projects. Do it before Default Grade is ever switched on.")
///
/// The claim is BIT-IDENTITY, not closeness: the search skips only slots that add exactly nothing,
/// so every shift's running volume is the same sequence of `+=` operands — the same doubles, the
/// same argmax and ties, the same anchor, the same bake; and the bake's level-0 walk skips only
/// slots its own gate returns from before any effect. So the comparison below is by bit pattern,
/// every array and every one of the 512 shifts' volumes, never a tolerance.
///
/// The scene has ladders on all three axes (512 shifts) and the cases the projects may not
/// exercise: a SEAM whose continuation reads inside past the outline (A), a −normal face with a
/// positive expand and a two-thirds rung whose children overhang their slot (B: base 6, menu
/// 6/4/3/2, kk = round(1.5) = 2), a facet tilted 18° (C, the same overhang), and a region with no
/// outline loops (D, the rectangle).
final class LatticeOctreeFootprintTests: XCTestCase {
    typealias P = LatticePreviewOccupancy

    override func tearDown() {
        P.anchorFootprintEnabled = true
        P.placeFootprintEnabled = true
        P.footprintInsetForTestsMM = 0
        P.footprintSlackSlots = 1
        P.anchorWindowOverrideForTests = nil
        P.octreeBakeObserver = nil
        super.tearDown()
    }

    // MARK: - the scene

    struct Scene {
        let occ: LatticeVoxelGrid
        let demand: LatticeVoxelGrid
        let regions: [LatticeRegionSpec]
        let cells: [Double]
    }

    /// A's L outline; edge 4, (2,18) → (−18,18), is the SEAM (cap 12, tilt 0.8: the next prism
    /// continues 9.6 mm past it, and the plate 12 mm).
    static let outlineA: [SIMD2<Double>] = [SIMD2(-18, -12), SIMD2(18, -12), SIMD2(18, 2),
                                            SIMD2(2, 2), SIMD2(2, 18), SIMD2(-18, 18)]

    static func scene() -> Scene {
        let nx = 90, ny = 70, nz = 90
        let origin = SIMD3<Float>(0.37, 0.63, 0.11)
        let o = SIMD3<Double>(origin)
        var vals = [Float](repeating: 0, count: nx * ny * nz)
        func fill(_ lo: SIMD3<Double>, _ hi: SIMD3<Double>) {
            let i0 = Int(((lo - o).x).rounded(.up)), i1 = Int(((hi - o).x).rounded(.down))
            let j0 = Int(((lo - o).y).rounded(.up)), j1 = Int(((hi - o).y).rounded(.down))
            let k0 = Int(((lo - o).z).rounded(.up)), k1 = Int(((hi - o).z).rounded(.down))
            for k in Swift.max(0, k0)...Swift.min(nz - 1, k1) {
                for j in Swift.max(0, j0)...Swift.min(ny - 1, j1) {
                    for i in Swift.max(0, i0)...Swift.min(nx - 1, i1) { vals[(k * ny + j) * nx + i] = 1 }
                }
            }
        }
        var regions: [LatticeRegionSpec] = []
        // A: a +y face on a 12 mm plate; u = z, v = x. The plate runs 12 mm past the seam (+x).
        fill(SIMD3(6.37, 10.63, 8.11), SIMD3(52.37, 22.63, 52.11))
        var a = LatticeRegionSpec(role: .include, kind: .face)
        a.origin = SIMD3(22.37, 10.63, 30.11); a.normal = SIMD3(0, 1, 0); a.depthMM = 12
        a.halfUMM = 18; a.halfWMM = 15; a.faceID = 1
        a.outlineLoops = [outlineA]
        a.outlineSeams = [[false, false, false, false, true, false]]
        a.outlineSeamTilt = [[0, 0, 0, 0, 0.8, 0]]
        a.outlineSeamDepthMM = [[0, 0, 0, 0, 12, 0]]
        regions.append(a)
        // B: a −x face on the far side of a 12 mm wall, a square outline grown 2 mm; u = z, v = y.
        fill(SIMD3(70.37, 20.63, 28.11), SIMD3(82.37, 50.63, 62.11))
        var b = LatticeRegionSpec(role: .include, kind: .face)
        b.origin = SIMD3(82.37, 35.63, 45.11); b.normal = SIMD3(-1, 0, 0); b.depthMM = 12
        b.halfUMM = 10; b.halfWMM = 10; b.faceID = 2
        b.outlineLoops = [[SIMD2(-10, -10), SIMD2(10, -10), SIMD2(10, 10), SIMD2(-10, 10)]]
        b.inPlaneOffsetMM = 2
        regions.append(b)
        // C: a facet tilted 18° off +z (his stand's foot facet), outline ±12, depth 10.
        fill(SIMD3(12.37, 34.63, 55.11), SIMD3(48.37, 66.63, 82.11))
        var c = LatticeRegionSpec(role: .include, kind: .face)
        let t = 18.0 * Double.pi / 180
        c.origin = SIMD3(30.37, 50.63, 64.11); c.normal = SIMD3(sin(t), 0, cos(t)); c.depthMM = 10
        c.halfUMM = 12; c.halfWMM = 12; c.faceID = 3
        c.outlineLoops = [[SIMD2(-12, -12), SIMD2(12, -12), SIMD2(12, 12), SIMD2(-12, 12)]]
        regions.append(c)
        // D: a −z face with NO outline loops — `contains`' rectangle, 8 × 8; u = y, v = x.
        fill(SIMD3(60.37, 2.63, 70.11), SIMD3(80.37, 18.63, 86.11))
        var d = LatticeRegionSpec(role: .include, kind: .face)
        d.origin = SIMD3(70.37, 10.63, 86.11); d.normal = SIMD3(0, 0, -1); d.depthMM = 8
        d.halfUMM = 4; d.halfWMM = 4
        regions.append(d)

        let spacing = SIMD3<Float>(repeating: 1)
        let occ = LatticeVoxelGrid(nx: nx, ny: ny, nz: nz, origin: origin, spacing: spacing, values: vals)
        var dv = [Float](repeating: 0, count: vals.count)
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx {
            dv[(k * ny + j) * nx + i] = Float(i + 2 * j + 3 * k) / Float(nx + 2 * ny + 3 * nz)
        }}}
        let demand = LatticeVoxelGrid(nx: nx, ny: ny, nz: nz, origin: origin, spacing: spacing, values: dv)
        return Scene(occ: occ, demand: demand, regions: regions, cells: [4, 6, 6, 4])
    }

    struct Bake {
        let field: LatticeCellField
        let stats: P.OctreeBakeStats
    }

    /// One bake with the switches as they stand.
    static func bake(_ s: Scene, dyadic: Bool) throws -> Bake {
        var st = P.OctreeBakeStats()
        let f = try XCTUnwrap(P.octreeCellField(
            occupancy: s.occ, demand: s.demand, regions: s.regions, cellMM: s.cells,
            lineWidthMM: 0.45, realFloorMM: 2, shapeFitBandMM: 5, shapeFit: true, solidBandMM: 0.9,
            densityLo: 0.1, densityHi: 0.3, densityGamma: 1, latticeID: "", dyadicSteps: dyadic, stats: &st))
        return Bake(field: f, stats: st)
    }

    static func setFootprint(_ on: Bool) {
        P.anchorFootprintEnabled = on
        P.placeFootprintEnabled = on
    }

    // MARK: - the comparator (shared with LatticeOctreeFootprintProof)

    /// Every output of the bake that the footprint must not move, by BIT PATTERN; the names of
    /// whatever differs. Times and walk counts are left out on purpose — they are what moves.
    static func differences(_ a: Bake, _ b: Bake) -> [String] {
        var d: [String] = []
        func f32(_ x: [Float]) -> [UInt32] { x.map(\.bitPattern) }
        func f64(_ x: [Double]) -> [UInt64] { x.map(\.bitPattern) }
        func v3(_ x: SIMD3<Double>) -> [UInt64] { [x.x.bitPattern, x.y.bitPattern, x.z.bitPattern] }
        let fa = a.field, fb = b.field
        if (fa.field.nx, fa.field.ny, fa.field.nz) != (fb.field.nx, fb.field.ny, fb.field.nz) { d.append("grid.dims") }
        if f32([fa.field.origin.x, fa.field.origin.y, fa.field.origin.z]) != f32([fb.field.origin.x, fb.field.origin.y, fb.field.origin.z]) { d.append("grid.origin") }
        if f32([fa.field.spacing.x, fa.field.spacing.y, fa.field.spacing.z]) != f32([fb.field.spacing.x, fb.field.spacing.y, fb.field.spacing.z]) { d.append("grid.spacing") }
        if f32(fa.field.values) != f32(fb.field.values) { d.append("field.values") }
        if f32(fa.level) != f32(fb.level) { d.append("level") }
        if f32(fa.steppedCellMM) != f32(fb.steppedCellMM) { d.append("steppedCellMM") }
        if f32(fa.steppedPhase) != f32(fb.steppedPhase) { d.append("steppedPhase") }
        if f32(fa.solidDepthMM) != f32(fb.solidDepthMM) { d.append("solidDepthMM") }
        // SIMD3<Float> carries a padding lane: compare x, y, z only
        if f32(lanes(fa.steppedOrigin)) != f32(lanes(fb.steppedOrigin)) { d.append("steppedOrigin") }
        if cellWords(fa.steppedCells) != cellWords(fb.steppedCells) || fa.steppedCells != fb.steppedCells { d.append("steppedCells") }
        if fa.baseCellMM.bitPattern != fb.baseCellMM.bitPattern { d.append("baseCellMM") }
        if fa.maxLevel != fb.maxLevel { d.append("maxLevel") }
        if fa.fromCorePlan != fb.fromCorePlan { d.append("fromCorePlan") }
        if fa.drawnDensityHi.bitPattern != fb.drawnDensityHi.bitPattern { d.append("drawnDensityHi") }
        if fa.solidBandMM.bitPattern != fb.solidBandMM.bitPattern { d.append("solidBandMM") }
        let sa = a.stats, sb = b.stats
        if f64(sa.anchorBaseVolumes) != f64(sb.anchorBaseVolumes) { d.append("anchorBaseVolumes") }
        if sa.anchorChildVolumes.keys.sorted() != sb.anchorChildVolumes.keys.sorted()
            || sa.anchorChildVolumes.keys.sorted().map({ sa.anchorChildVolumes[$0]!.bitPattern })
                != sb.anchorChildVolumes.keys.sorted().map({ sb.anchorChildVolumes[$0]!.bitPattern }) { d.append("anchorChildVolumes") }
        if v3(sa.anchorShiftMM) != v3(sb.anchorShiftMM) { d.append("anchorShiftMM") }
        let ka = sa.slotsKept.keys.sorted(), kb = sb.slotsKept.keys.sorted()
        if f64(ka) != f64(kb) || ka.map({ sa.slotsKept[$0]! }) != kb.map({ sb.slotsKept[$0]! }) { d.append("slotsKept") }
        if sa.slotsCut != sb.slotsCut { d.append("slotsCut") }
        if sa.texelsPainted != sb.texelsPainted { d.append("texelsPainted") }
        if sa.pitchMM.bitPattern != sb.pitchMM.bitPattern { d.append("pitchMM") }
        if sa.why != sb.why { d.append("why") }
        if sa.paintedByRegion != sb.paintedByRegion { d.append("paintedByRegion") }
        if sa.secondaryRegions != sb.secondaryRegions { d.append("secondaryRegions") }
        if sa.noLadderRegions != sb.noLadderRegions { d.append("noLadderRegions") }
        if sa.cellsPlaced != sb.cellsPlaced { d.append("cellsPlaced") }
        return d
    }

    static func lanes(_ x: [SIMD3<Float>]) -> [Float] { x.flatMap { [$0.x, $0.y, $0.z] } }

    static func cellWords(_ cells: [LatticeSteppedCell]) -> [UInt64] {
        cells.flatMap { [UInt64(bitPattern: Int64($0.region)), $0.originMM.x.bitPattern, $0.originMM.y.bitPattern,
                         $0.originMM.z.bitPattern, $0.sizeMM.bitPattern, $0.rho.bitPattern] }
    }

    /// sha256 (hex, first 16) per output — the per-project summary's fingerprint of each array.
    static func digests(_ b: Bake) -> [(String, String)] {
        func h<T>(_ x: [T]) -> String {
            let digest = x.withUnsafeBytes { SHA256.hash(data: $0) }
            return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
        }
        return [("field.values", h(b.field.field.values.map(\.bitPattern))),
                ("level", h(b.field.level.map(\.bitPattern))),
                ("steppedCellMM", h(b.field.steppedCellMM.map(\.bitPattern))),
                ("steppedPhase", h(b.field.steppedPhase.map(\.bitPattern))),
                ("steppedOrigin", h(lanes(b.field.steppedOrigin).map(\.bitPattern))),
                ("solidDepthMM", h(b.field.solidDepthMM.map(\.bitPattern))),
                ("steppedCells", h(cellWords(b.field.steppedCells))),
                ("anchorBaseVolumes", h(b.stats.anchorBaseVolumes.map(\.bitPattern))),
                ("anchorChildVolumes", h(b.stats.anchorChildVolumes.keys.sorted().flatMap {
                    [UInt64($0), b.stats.anchorChildVolumes[$0]!.bitPattern] }))]
    }

    // MARK: - the identical bake

    func testProductionDefaults() {
        XCTAssertTrue(P.anchorFootprintEnabled, "★ production walks the footprint")
        XCTAssertTrue(P.placeFootprintEnabled, "★ production bounds the level-0 walk")
        XCTAssertEqual(P.footprintInsetForTestsMM, 0)
        XCTAssertEqual(P.footprintSlackSlots, 1)
        XCTAssertNil(P.anchorWindowOverrideForTests)
        XCTAssertNil(P.octreeBakeObserver)
    }

    func testTheFootprintBakeIsBitIdenticalAndWalksLessThanHalf() throws {
        let s = Self.scene()
        for dyadic in [true, false] {
            let tag = dyadic ? "Default Grade" : "Stepped"
            // (i) A/A: two control bakes in one process — or the A/B means nothing
            Self.setFootprint(false)
            let c1 = try Self.bake(s, dyadic: dyadic)
            let c2 = try Self.bake(s, dyadic: dyadic)
            XCTAssertEqual(Self.differences(c1, c2), [], "\(tag): ★ the control bake is deterministic")
            XCTAssertEqual(c1.stats.footprintBounded, [:], "\(tag): the control walks everything")
            XCTAssertEqual(c1.stats.anchorBaseVolumes.count, 512, "\(tag): ladders on all three axes ⇒ 512 shifts")
            // the scene is not trivial: every region paints, the shifts disagree, and the search re-scores
            for r in 0..<4 { XCTAssertGreaterThan(c1.stats.paintedByRegion[r] ?? 0, 0, "\(tag): region \(r) paints") }
            XCTAssertGreaterThan(Set(c1.stats.anchorBaseVolumes).count, 4, "\(tag): the shifts disagree")
            XCTAssertFalse(c1.stats.anchorChildVolumes.isEmpty, "\(tag): the children pass ran")
            // (ii) the footprint, on
            Self.setFootprint(true)
            let f1 = try Self.bake(s, dyadic: dyadic)
            XCTAssertEqual(Self.differences(c1, f1), [], "\(tag): ★★ the footprint bake is BIT-IDENTICAL")
            XCTAssertEqual(f1.stats.footprintUnbounded, [:], "\(tag): no fallback in this scene")
            XCTAssertEqual(f1.stats.footprintBounded["anchor/outline"], 3, "\(tag): A, B, C read rasters, bounded by the outline")
            XCTAssertEqual(f1.stats.footprintBounded["anchor/rect"], 1, "\(tag): D reads the rectangle")
            XCTAssertEqual(f1.stats.footprintBounded["place/outline"], 3, "\(tag): A, B, C gate on the outline")
            XCTAssertEqual(f1.stats.footprintBounded["place/rect"], 1, "\(tag): D gates on the rectangle")
            XCTAssertLessThan(f1.stats.anchorSlotsWalked * 2, c1.stats.anchorSlotsWalked,
                              "\(tag): ★ the search walks under half the slots")
            XCTAssertLessThan(f1.stats.placeSlotsWalked * 2, c1.stats.placeSlotsWalked,
                              "\(tag): ★ the bake's level-0 walk visits under half the slots")
            print("FOOTPRINT-SYNTH \(tag): anchor walked \(c1.stats.anchorSlotsWalked) -> \(f1.stats.anchorSlotsWalked), "
                  + "place walked \(c1.stats.placeSlotsWalked) -> \(f1.stats.placeSlotsWalked), "
                  + "anchor \(f1.stats.anchorShiftMM), anchor s \(String(format: "%.2f -> %.2f", c1.stats.anchorSeconds, f1.stats.anchorSeconds)), "
                  + "cells \(f1.field.steppedCells.count), why \(f1.stats.why.keys.sorted().map { "\($0)=\(f1.stats.why[$0]!)" }.joined(separator: " "))")
            // the anchor search alone, and the level-0 walk alone, are each identical too
            P.anchorFootprintEnabled = true; P.placeFootprintEnabled = false
            let fa = try Self.bake(s, dyadic: dyadic)
            XCTAssertEqual(Self.differences(c1, fa), [], "\(tag): the anchor footprint alone")
            XCTAssertEqual(fa.stats.placeSlotsWalked, c1.stats.placeSlotsWalked)
            P.anchorFootprintEnabled = false; P.placeFootprintEnabled = true
            let fp = try Self.bake(s, dyadic: dyadic)
            XCTAssertEqual(Self.differences(c1, fp), [], "\(tag): the level-0 footprint alone")
            XCTAssertEqual(fp.stats.anchorSlotsWalked, c1.stats.anchorSlotsWalked)
        }
    }

    /// (iii) RED: a footprint shrunk by 4·baseMax + 4 per side MUST move the volumes — the
    /// comparator is sensitive, and the green above is not a comparator that sees nothing.
    func testRedAnInsetFootprintChangesTheVolumes() throws {
        let s = Self.scene()
        for dyadic in [true, false] {
            Self.setFootprint(false)
            let c1 = try Self.bake(s, dyadic: dyadic)
            Self.setFootprint(true)
            P.footprintInsetForTestsMM = 4 * 6 + 4
            let red = try Self.bake(s, dyadic: dyadic)
            P.footprintInsetForTestsMM = 0
            let diff = Self.differences(c1, red)
            XCTAssertTrue(diff.contains("anchorBaseVolumes"), "★ RED (\(dyadic)): the inset must move the volumes: \(diff)")
            XCTAssertTrue(diff.contains("field.values") || diff.contains("steppedCells"), "★ RED (\(dyadic)): and the bake: \(diff)")
            let moved = zip(c1.stats.anchorBaseVolumes, red.stats.anchorBaseVolumes).filter { $0.0.bitPattern != $0.1.bitPattern }.count
            print("FOOTPRINT-RED-INSET \(dyadic ? "Default Grade" : "Stepped"): \(moved) of 512 shifts moved; differs in \(diff)")
        }
    }

    /// (iv) RED: the OUTLINE's bounding box (the handoff's "prism bbox"), with no slack, is NOT
    /// the footprint — past A's seam the raster reads inside, and the cells there fit.
    func testRedTheOutlineBoundingBoxMissesTheSeamContinuation() throws {
        let s = Self.scene()
        for dyadic in [true, false] {
            Self.setFootprint(false)
            let c1 = try Self.bake(s, dyadic: dyadic)
            Self.setFootprint(true)
            P.footprintSlackSlots = 0
            P.anchorWindowOverrideForTests = { r in
                guard r.outlineSeams.contains(where: { $0.contains(true) }) else { return nil }   // A only
                var lo = SIMD2<Double>(repeating: .infinity), hi = -lo
                for q in r.outlineLoops.flatMap({ $0 }) { lo = simd_min(lo, q); hi = simd_max(hi, q) }
                return (lo.x, hi.x, lo.y, hi.y)
            }
            let red = try Self.bake(s, dyadic: dyadic)
            P.anchorWindowOverrideForTests = nil
            XCTAssertEqual(red.stats.footprintBounded["anchor/test"], 1, "the override reached A only")
            let moved = zip(c1.stats.anchorBaseVolumes, red.stats.anchorBaseVolumes).filter { $0.0.bitPattern != $0.1.bitPattern }.count
            XCTAssertGreaterThan(moved, 0, "★ RED (\(dyadic)): the bbox footprint must lose A's cells past the seam")
            // and slack 0 on the RASTER window is still identical — the window, not the slack, is load-bearing
            let rw = try Self.bake(s, dyadic: dyadic)
            XCTAssertEqual(Self.differences(c1, rw), [], "(\(dyadic)) the raster window with no slack is identical")
            print("FOOTPRINT-RED-BBOX \(dyadic ? "Default Grade" : "Stepped"): \(moved) of \(c1.stats.anchorBaseVolumes.count) shifts moved")
        }
    }

    // MARK: - the two property tests

    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Points generated freely in the face's frame (s at random, then filtered on the world axis
    /// coordinate) and tested with the bake's OWN projection, dot(p − o, bu/bv) — never through
    /// footprintBox's solve. Returns the number of points inside window × along that the box
    /// (shrunk by `shrink`) does not hold.
    static func footprintBoxViolations(shrink: Double, cases: Int = 40, samples: Int = 20_000) -> (violations: Int, tested: Int) {
        var rng = SplitMix64(state: 0x5EED_F007)
        var violations = 0, tested = 0
        for _ in 0..<cases {
            let axis = Int.random(in: 0..<3, using: &rng)
            // a normal within 30° of ±axis
            var n = SIMD3<Double>(Double.random(in: -1...1, using: &rng), Double.random(in: -1...1, using: &rng),
                                  Double.random(in: -1...1, using: &rng))
            n[axis] = 0
            let tilt = Double.random(in: 0...(29.0 * Double.pi / 180), using: &rng)
            let side = n.x == 0 && n.y == 0 && n.z == 0 ? SIMD3<Double>(repeating: 0) : simd_normalize(n)
            var dir = SIMD3<Double>(repeating: 0); dir[axis] = Bool.random(using: &rng) ? 1 : -1
            n = simd_normalize(dir * cos(tilt) + side * sin(tilt))
            guard abs(n[axis]) > 0.866 else { continue }
            let o = SIMD3<Double>(Double.random(in: -50...50, using: &rng), Double.random(in: -50...50, using: &rng),
                                  Double.random(in: -50...50, using: &rng))
            let u0 = Double.random(in: -30...10, using: &rng), v0 = Double.random(in: -30...10, using: &rng)
            let w: P.FootprintWindow = (u0, u0 + Double.random(in: 1...40, using: &rng), v0, v0 + Double.random(in: 1...40, using: &rng))
            let z0 = o[axis] + Double.random(in: -20...10, using: &rng)
            let along = (lo: z0, hi: z0 + Double.random(in: 0.5...30, using: &rng))
            guard let box = P.footprintBox(window: w, along: along, origin: o, normal: n, axis: axis) else {
                violations += 1; continue
            }
            let (bu, bv) = LatticeRegionMask.basisForTests(n)
            let reachS = (Swift.max(abs(along.lo - o[axis]), abs(along.hi - o[axis]))
                          + 2 * Swift.max(abs(w.uLo), abs(w.uHi), abs(w.vLo), abs(w.vHi))) / 0.866 + 1
            for _ in 0..<samples {
                func pick(_ lo: Double, _ hi: Double) -> Double {
                    switch Int.random(in: 0..<4, using: &rng) {
                    case 0: return lo
                    case 1: return hi
                    default: return Double.random(in: lo...hi, using: &rng)
                    }
                }
                let u = pick(w.uLo, w.uHi), v = pick(w.vLo, w.vHi)
                let s = Double.random(in: -reachS...reachS, using: &rng)
                let p = o + bu * u + bv * v + n * s
                guard p[axis] >= along.lo, p[axis] <= along.hi else { continue }
                // the bake's projection
                let pu = simd_dot(p - o, bu), pv = simd_dot(p - o, bv)
                guard pu >= w.uLo - 1e-9, pu <= w.uHi + 1e-9, pv >= w.vLo - 1e-9, pv <= w.vHi + 1e-9 else { continue }
                tested += 1
                for a in 0..<3 where p[a] < box.lo[a] + shrink - 1e-9 || p[a] > box.hi[a] - shrink + 1e-9 {
                    violations += 1; break
                }
            }
        }
        return (violations, tested)
    }

    func testFootprintBoxHoldsEveryPreimagePoint() {
        let green = Self.footprintBoxViolations(shrink: 0)
        XCTAssertGreaterThan(green.tested, 50_000, "the property was exercised")
        XCTAssertEqual(green.violations, 0, "★ every point whose (u, v) is in the window and whose axis coordinate is in range lies in the box")
        // RED: the same box shrunk by 1 mm must lose points
        let red = Self.footprintBoxViolations(shrink: 1)
        XCTAssertGreaterThan(red.violations, 0, "★ RED: a box 1 mm short must miss some — or the sampler never reached the box's faces")
        print("FOOTPRINT-PROPERTY box: \(green.tested) points, \(green.violations) outside; shrunk 1 mm: \(red.violations) outside")
    }

    /// The exact level-0 read, as place() computes it.
    static func exactDOut(_ uv: SIMD2<Double>, _ r: LatticeRegionSpec) -> Double {
        -(LatticeFaceOutline.signedDistanceAcrossSeams(uv, loops: r.outlineLoops, seams: r.outlineSeams,
                                                       tilts: r.outlineSeamTilt, caps: r.outlineSeamDepthMM) - r.inPlaneOffsetMM)
    }

    /// Centres outside the gate window that the exact read nevertheless passes.
    static func gateViolations(_ r: LatticeRegionSpec, S: Double, shrink: Double) -> (violations: Int, tested: Int) {
        guard let w = P.gateWindow(region: r, S: S, shrinkMM: shrink).window else { return (-1, 0) }
        var rng = SplitMix64(state: 0xFACE_0FF5)
        var violations = 0, tested = 0
        for _ in 0..<40_000 {
            let uv = SIMD2<Double>(Double.random(in: -45...45, using: &rng), Double.random(in: -45...45, using: &rng))
            guard uv.x < w.uLo || uv.x > w.uHi || uv.y < w.vLo || uv.y > w.vHi else { continue }
            tested += 1
            if !(exactDOut(uv, r) < -0.87 * S) { violations += 1 }
        }
        return (violations, tested)
    }

    func testGateFailsEverywhereOutsideTheGateWindow() {
        let s = Self.scene()
        for (ri, S) in [(0, 4.0), (1, 6.0)] {
            let r = s.regions[ri]
            XCTAssertEqual(P.gateWindow(region: r, S: S).why, "outline")
            let green = Self.gateViolations(r, S: S, shrink: 0)
            XCTAssertGreaterThan(green.tested, 10_000)
            XCTAssertEqual(green.violations, 0, "★ region \(ri): no centre outside the gate window passes the exact gate")
            let red = Self.gateViolations(r, S: S, shrink: 1)
            XCTAssertGreaterThan(red.violations, 0, "★ RED region \(ri): a window 1 mm short must let some through")
            print("FOOTPRINT-PROPERTY gate r\(ri): \(green.tested) centres outside, \(green.violations) pass; shrunk 1 mm: \(red.violations) pass")
        }
        // the fallbacks name themselves
        var seamless = s.regions[0]; seamless.outlineSeamDepthMM = []
        XCTAssertNil(P.gateWindow(region: seamless, S: 4).window)
        XCTAssertEqual(P.gateWindow(region: seamless, S: 4).why, "seam", "a seam with no cap reads inside at any distance")
        var flat = s.regions[1]; flat.outlineLoops = [[SIMD2(-10, -10), SIMD2(10, -10 + 1e-13), SIMD2(10, 10), SIMD2(-10, 10)]]
        XCTAssertEqual(P.gateWindow(region: flat, S: 6).why, "parity", "an edge the crossing test skips")
        var bad = s.regions[1]; bad.inPlaneOffsetMM = .nan
        XCTAssertEqual(P.gateWindow(region: bad, S: 6).why, "nonfinite")
        XCTAssertEqual(P.gateWindow(region: s.regions[3], S: 4).why, "rect")
    }

    /// A fallback walks everything and is still the same bake: a seam with no cap (the exact read
    /// is then unbounded) must not bound the level-0 walk.
    func testAFallbackRegionWalksEverythingAndStaysIdentical() throws {
        var s = Self.scene()
        var regions = s.regions
        regions[0].outlineSeamDepthMM = []
        s = Scene(occ: s.occ, demand: s.demand, regions: regions, cells: s.cells)
        Self.setFootprint(false)
        let c1 = try Self.bake(s, dyadic: true)
        Self.setFootprint(true)
        let f1 = try Self.bake(s, dyadic: true)
        XCTAssertEqual(Self.differences(c1, f1), [])
        XCTAssertEqual(f1.stats.footprintUnbounded["place/seam"], 1, "★ A falls back")
        XCTAssertEqual(f1.stats.footprintBounded["place/outline"], 2)
        XCTAssertEqual(f1.stats.footprintBounded["anchor/raster:seam"], 1, "★ A's search keeps the raster window")
        XCTAssertEqual(f1.stats.footprintBounded["anchor/outline"], 2)
    }

    /// The anchor raster's read, replicated from `OutlineRaster` (nodes of −(signedDistanceAcrossSeams
    /// − offset) at origin + (i, j)·h, blended bilinearly) — on a lattice anchored anywhere, since
    /// the bake's raster origin hangs off the largest region's cell.
    static func rasterRead(_ uv: SIMD2<Double>, _ r: LatticeRegionSpec, origin: SIMD2<Double>, h: Double) -> Double {
        let g = (uv - origin) / h
        let i = g.x.rounded(.down), j = g.y.rounded(.down)
        func node(_ a: Double, _ b: Double) -> Double { exactDOut(origin + SIMD2(a, b) * h, r) }
        let fx = g.x - i, fy = g.y - j
        let a = node(i, j) * (1 - fx) + node(i + 1, j) * fx
        let b = node(i, j + 1) * (1 - fx) + node(i + 1, j + 1) * fx
        return a * (1 - fy) + b * fy
    }

    /// Reads above 0 outside the raster read window (shrunk by `shrink`).
    static func rasterReadViolations(_ r: LatticeRegionSpec, shrink: Double) -> (violations: Int, tested: Int) {
        guard let w = P.rasterReadWindow(region: r, h: 1.0, shrinkMM: shrink).window else { return (-1, 0) }
        var rng = SplitMix64(state: 0x0BAD_CAFE)
        var violations = 0, tested = 0
        for _ in 0..<30_000 {
            let origin = SIMD2<Double>(-60 + Double.random(in: 0..<1, using: &rng), -60 + Double.random(in: 0..<1, using: &rng))
            // concentrated within 4 mm of the window, where a short window would show
            let side = Int.random(in: 0..<4, using: &rng), d = Double.random(in: 0..<4, using: &rng)
            var uv = SIMD2<Double>(Double.random(in: (w.uLo - 4)...(w.uHi + 4), using: &rng),
                                   Double.random(in: (w.vLo - 4)...(w.vHi + 4), using: &rng))
            switch side {
            case 0: uv.x = w.uLo - d
            case 1: uv.x = w.uHi + d
            case 2: uv.y = w.vLo - d
            default: uv.y = w.vHi + d
            }
            guard uv.x < w.uLo || uv.x > w.uHi || uv.y < w.vLo || uv.y > w.vHi else { continue }
            tested += 1
            if rasterRead(uv, r, origin: origin, h: 1.0) > 0 { violations += 1 }
        }
        return (violations, tested)
    }

    /// ★ The anchor footprint is the raster window ∩ the read window: outside the read window
    /// the raster cannot read above 0 (so never `band`), for the seam (A), the expand (B) and the
    /// tilted facet (C). The window is bbox ± (reach + 0.5 + h): RED 1 — shrunk by 2 mm (0.5 mm
    /// inside the reach itself) it must let reads above 0 through; RED 2 — at A's seam the jump
    /// from inside to outside is blended across one raster step, so a window that keeps the
    /// 0.5 mm but drops most of the step (shrunk 1.2 mm) must let some through as well.
    func testTheRasterReadsNothingAboveZeroOutsideItsReadWindow() {
        let s = Self.scene()
        for ri in 0..<3 {
            let r = s.regions[ri]
            XCTAssertEqual(P.rasterReadWindow(region: r, h: 1).why, "outline")
            let green = Self.rasterReadViolations(r, shrink: 0)
            XCTAssertGreaterThan(green.tested, 20_000)
            XCTAssertEqual(green.violations, 0, "★ region \(ri): no read above 0 outside the read window")
            let red = Self.rasterReadViolations(r, shrink: 2)
            XCTAssertGreaterThan(red.violations, 0, "★ RED region \(ri): a read window short of the reach must let some through")
            print("FOOTPRINT-PROPERTY read r\(ri): \(green.tested) reads outside, \(green.violations) above 0; shrunk 2 mm: \(red.violations) above 0")
        }
        let seamRed = Self.rasterReadViolations(s.regions[0], shrink: 1.2)
        XCTAssertGreaterThan(seamRed.violations, 0, "★ RED: at the seam the stencil's step is load-bearing")
        print("FOOTPRINT-PROPERTY read r0 shrunk 1.2 mm (the stencil step): \(seamRed.violations) above 0")
        XCTAssertNil(P.rasterReadWindow(region: s.regions[3], h: 1).window, "no loops ⇒ no raster ⇒ the rectangle")
    }
}
