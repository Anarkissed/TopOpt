// FlexibleSquishFETests — the squish sim through the bridge on C1's 100 × 100 × 20 pad (task
// 2026-09-29-flexible-screens, round 5 batch G). Core's own grid (resolution 100 ⇒ 100 × 100 ×
// 20 voxels of 1 mm, coarsened ×2 by the rule ⇒ a 50 × 50 × 10 FE grid), core's own lattice mask,
// core's own stacks and frames; the requests are built here from simple, symmetric densities so
// each physical claim is checked on its own. Every claim has a RED control (a `control` bit of
// the request that restores the wrong behaviour) that must fail the same assertion.
//
// Maintainer (verbatim): "is there a way to ensure that the squish sim also squeezes out the
// sides of the object? I'd like it to actually bend and move and squish like it would in real
// life."
import XCTest
import simd
@testable import TopOptKit

final class FlexibleSquishFETests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    static var materialsPath: String { repoRoot.appendingPathComponent("core/src/materials/flexible_materials.json").path }
    static var padDir: URL {
        repoRoot.appendingPathComponent("docs/handoffs/evidence/2026-09-28-flexible-squish-maths/a_pad_centre_soft")
    }
    static let law = FlexSquishLawInfo(materialsPath: materialsPath, materialID: "varioshore_tpu", topology: "gyroid",
                                       tempC: 220, shapeOnly: false)
    static let build = FlexBuildParams(topology: "gyroid", beadsPerWall: 1, beadWidthMM: 0.42)
    // C1's pad: 100 bottom, 101 top, 102 −Y, 103 +X, 104 +Y, 105 −X
    static let bottom = 100, top = 101, minusY = 102, plusX = 103, plusY = 104, minusX = 105

    struct Pad {
        let scene: FlexibleScene
        let info: FlexibleScene.Info
        let mask: FlexDensityField
        func centre(_ v: Int) -> SIMD3<Double> {
            let i = v % info.nx, j = (v / info.nx) % info.ny, k = v / (info.nx * info.ny)
            return info.origin + (SIMD3(Double(i), Double(j), Double(k)) + 0.5) * info.spacing
        }
        var count: Int { info.nx * info.ny * info.nz }
        /// ρ per voxel from `rho(p)` on the lattice mask (−1 elsewhere).
        func rho(_ f: (SIMD3<Double>) -> Double) -> [Float] {
            (0..<count).map { mask.density[$0] < 0 ? -1 : Float(f(centre($0))) }
        }
        /// The skin share of a voxel `mm` deep under every face of the pad (the Covered finish).
        func skin(_ mm: Double) -> [Float] {
            (0..<count).map { v in
                let p = centre(v)
                let d = min(p.x, 100 - p.x, p.y, 100 - p.y, p.z, 20 - p.z)
                return Float(min(1, max(0, (mm - (d - info.spacing / 2)) / info.spacing)))
            }
        }
        /// One uniform pressure per column: `weightN` over the face's footprint.
        func press(_ face: Int, weightN: Double) throws -> FlexSquishPressInfo {
            let st = try scene.stack(face: face, rotation: 0)
            return FlexSquishPressInfo(face: face, rotation: 0,
                                       columnPressureMPa: [Double](repeating: weightN / st.footprintAreaMM2, count: st.columns.count))
        }
    }

    static func pad() throws -> Pad {
        let job = try String(contentsOf: padDir.appendingPathComponent("job.json"), encoding: .utf8)
        let scene = try FlexibleScene(jobJSON: job, jobDir: padDir.path)
        let info = try scene.info()
        return Pad(scene: scene, info: info, mask: try scene.latticeMask(build: build))
    }

    static func request(_ pad: Pad, pressed: [FlexSquishPressInfo], resting: [Int], rho: [Float]? = nil,
                        strain: [Float]? = nil, skin: [Float]? = nil, control: Int = 0,
                        tolerance: Double = 1e-4, deadlineMS: Double = 20_000) -> FlexSquishRequestInfo {
        FlexSquishRequestInfo(pressed: pressed, restingIDs: resting,
                              rho: rho ?? pad.rho { _ in 0.2 },
                              strainOp: strain ?? [Float](repeating: 0, count: pad.count),
                              skinFrac: skin ?? [Float](repeating: 0, count: pad.count),
                              law: law, tolerance: tolerance, deadlineMS: deadlineMS, control: control)
    }

    // MARK: helpers on a solution

    /// The node nearest `p`.
    static func node(_ s: FlexSquishSolutionInfo, _ p: SIMD3<Double>) -> Int {
        let q = (p - s.origin) / s.spacing
        let a = min(s.nx - 1, max(0, Int(q.x.rounded()))), b = min(s.ny - 1, max(0, Int(q.y.rounded())))
        let c = min(s.nz - 1, max(0, Int(q.z.rounded())))
        return s.node(a, b, c)
    }
    static func u(_ s: FlexSquishSolutionInfo, _ p: SIMD3<Double>) -> SIMD3<Double> { s.displacement(node(s, p)) }
    static func maxU(_ s: FlexSquishSolutionInfo) -> Double {
        (0..<(s.nx * s.ny * s.nz)).filter { s.solved[$0] }.map { simd_length(s.displacement($0)) }.max() ?? 0
    }
    /// The mean of `f(u)` over the solved nodes on the plane `axis` = `value`.
    static func meanOnPlane(_ s: FlexSquishSolutionInfo, axis: Int, value: Double, _ f: (SIMD3<Double>) -> Double) -> Double {
        var sum = 0.0, n = 0
        for v in 0..<(s.nx * s.ny * s.nz) where s.solved[v] {
            let p = s.position(v)
            guard abs(p[axis] - value) < 1e-6 else { continue }
            sum += f(s.displacement(v)); n += 1
        }
        return n > 0 ? sum / Double(n) : .nan
    }
    /// The top's deepest compression: the largest −u_z over the top surface's nodes (z = 20).
    static func topDeepest(_ s: FlexSquishSolutionInfo) -> Double {
        (0..<(s.nx * s.ny * s.nz)).filter { s.solved[$0] && abs(s.position($0).z - 20) < 1e-6 }
            .map { -s.displacement($0).z }.max() ?? 0
    }

    static func log(_ s: FlexSquishSolutionInfo, _ what: String) {
        print(String(format: "FLEX-G FE %@: ok %@ '%@' bc %@ · c %d · nodes %d×%d×%d · elements %d · iterations %d · levels %d · multigrid %@ · setup %.0f ms · solve %.0f ms · E %.3g…%.3g MPa · max|u| %.4f mm · threads %d/%d/%d",
                     what, "\(s.ok)", s.failure, s.bcMode, s.coarsen, s.nx, s.ny, s.nz, s.elements, s.iterations, s.mgLevels,
                     "\(s.usedMultigrid)", s.setupMS, s.solveMS, s.eMinMPa, s.eMaxMPa, s.ok ? maxU(s) : 0,
                     s.threadsBefore, s.threadsDuring, s.threadsAfter))
    }

    // MARK: - the sides bulge

    func testTopPressBulgesEveryFreeSide() throws {
        let pad = try Self.pad()
        let press = try pad.press(Self.top, weightN: 294.3)
        for (name, skin) in [("bare", nil), ("covered", pad.skin(0.8))] as [(String, [Float]?)] {
            let s = try pad.scene.squishSolve(Self.request(pad, pressed: [press], resting: [Self.bottom], skin: skin))
            Self.log(s, "top press, bottom rests, \(name)")
            XCTAssertTrue(s.ok, s.failure)
            XCTAssertEqual(s.bcMode, "rest")
            let deepest = Self.topDeepest(s)
            XCTAssertGreaterThan(deepest, 0, "the top sinks")
            // the mid-height centre of each free side moves OUTWARD
            let sides: [(SIMD3<Double>, SIMD3<Double>)] = [(SIMD3(0, 50, 10), SIMD3(-1, 0, 0)), (SIMD3(100, 50, 10), SIMD3(1, 0, 0)),
                                                            (SIMD3(50, 0, 10), SIMD3(0, -1, 0)), (SIMD3(50, 100, 10), SIMD3(0, 1, 0))]
            for (p, out) in sides {
                let o = simd_dot(Self.u(s, p), out)
                print(String(format: "FLEX-G FE bulge %@ at (%.0f, %.0f, %.0f): %.4f mm outward (%.1f%% of the top's %.4f mm)",
                             name, p.x, p.y, p.z, o, 100 * o / deepest, deepest))
                if name == "bare" {
                    XCTAssertGreaterThanOrEqual(o, 0.03 * deepest, "the side at \(p) bulges out (bare)")
                } else {
                    XCTAssertGreaterThan(o, 0, "the side at \(p) bulges out (covered)")
                }
            }
        }
        // ★ RED CONTROL (1): ν = 0 — no lateral coupling, no bulge (< 1 % of the deepest)
        let zero = try pad.scene.squishSolve(Self.request(pad, pressed: [press], resting: [Self.bottom], control: 1))
        let d0 = Self.topDeepest(zero)
        let b0 = simd_dot(Self.u(zero, SIMD3(100, 50, 10)), SIMD3(1, 0, 0))
        print(String(format: "FLEX-G FE bulge control ν = 0: %.5f mm (%.2f%% of %.4f)", b0, 100 * b0 / d0, d0))
        XCTAssertLessThan(abs(b0), 0.01 * d0, "control: ν = 0 does not bulge")
    }

    // MARK: - a symmetric pad gives a symmetric field

    func testSymmetricPadGivesASymmetricField() throws {
        let pad = try Self.pad()
        // a dome of density: softer in the middle, symmetric about x = 50 and y = 50
        let rho = pad.rho { p in 0.15 + 0.2 * (abs(p.x - 50) + abs(p.y - 50)) / 100 }
        let press = try pad.press(Self.top, weightN: 294.3)
        let s = try pad.scene.squishSolve(Self.request(pad, pressed: [press], resting: [Self.bottom], rho: rho))
        Self.log(s, "symmetric dome")
        XCTAssertTrue(s.ok, s.failure)
        let asym = Self.mirrorError(s)
        print(String(format: "FLEX-G FE symmetry: max mirror error %.3g of max|u| (x) · %.3g (y)", asym.x, asym.y))
        XCTAssertLessThanOrEqual(asym.x, 1e-3)
        XCTAssertLessThanOrEqual(asym.y, 1e-3)
        // ★ RED CONTROL: an OFF-CENTRE stamp (columns at u, v in [60, 80] pressed) is not symmetric
        let st = try pad.scene.stack(face: Self.top, rotation: 0)
        let stamp = st.columns.map { c -> Double in (60...80).contains(c.uMM) && (60...80).contains(c.vMM) ? 294.3 / 400 : 0 }
        let off = try pad.scene.squishSolve(Self.request(pad, pressed: [FlexSquishPressInfo(face: Self.top, rotation: 0, columnPressureMPa: stamp)],
                                                         resting: [Self.bottom], rho: rho))
        let e = Self.mirrorError(off)
        print(String(format: "FLEX-G FE symmetry control (off-centre stamp): %.3g (x) · %.3g (y)", e.x, e.y))
        XCTAssertGreaterThan(max(e.x, e.y), 0.05, "control: an off-centre stamp is not symmetric")
    }

    /// max |u(p) − M·u(M·p)| / max|u| over the solved nodes, for the mirrors x = 50 and y = 50.
    static func mirrorError(_ s: FlexSquishSolutionInfo) -> SIMD2<Double> {
        let m = maxU(s)
        var ex = 0.0, ey = 0.0
        for v in 0..<(s.nx * s.ny * s.nz) where s.solved[v] {
            let a = v % s.nx, b = (v / s.nx) % s.ny, c = v / (s.nx * s.ny)
            let u = s.displacement(v)
            let mx = s.displacement(s.node(s.nx - 1 - a, b, c)), my = s.displacement(s.node(a, s.ny - 1 - b, c))
            ex = max(ex, simd_length(u - SIMD3(-mx.x, mx.y, mx.z)))
            ey = max(ey, simd_length(u - SIMD3(my.x, -my.y, my.z)))
        }
        return SIMD2(ex, ey) / max(m, 1e-30)
    }

    // MARK: - a pinch with nothing resting (inertia relief + 3-2-1)

    func testPinchMovesBothFacesInAndBulgesTheSides() throws {
        let pad = try Self.pad()
        let pressed = [try pad.press(Self.plusX, weightN: 98.07), try pad.press(Self.minusX, weightN: 98.07)]
        let s = try pad.scene.squishSolve(Self.request(pad, pressed: pressed, resting: []))
        Self.log(s, "±X pinch, nothing rests")
        XCTAssertTrue(s.ok, s.failure)
        XCTAssertEqual(s.bcMode, "free")
        let left = Self.meanOnPlane(s, axis: 0, value: 0) { $0.x }, right = Self.meanOnPlane(s, axis: 0, value: 100) { $0.x }
        let mid = Self.meanOnPlane(s, axis: 0, value: 50) { abs($0.x) }
        print(String(format: "FLEX-G FE pinch: mean u_x on x = 0 %.5f · on x = 100 %.5f · |u_x| on x = 50 %.6f", left, right, mid))
        XCTAssertGreaterThan(left, 0, "the −X face moves in (+x)")
        XCTAssertLessThan(right, 0, "the +X face moves in (−x)")
        XCTAssertEqual(abs(left), abs(right), accuracy: 0.02 * abs(left), "both faces move alike")
        XCTAssertLessThanOrEqual(mid, 0.02 * abs(left), "the mid-plane holds still")
        // the ±Y sides, the top and the bottom move outward (bare)
        XCTAssertGreaterThan(simd_dot(Self.u(s, SIMD3(50, 0, 10)), SIMD3(0, -1, 0)), 0, "−Y bulges")
        XCTAssertGreaterThan(simd_dot(Self.u(s, SIMD3(50, 100, 10)), SIMD3(0, 1, 0)), 0, "+Y bulges")
        XCTAssertGreaterThan(simd_dot(Self.u(s, SIMD3(50, 50, 20)), SIMD3(0, 0, 1)), 0, "the top bulges")
        XCTAssertGreaterThan(simd_dot(Self.u(s, SIMD3(50, 50, 0)), SIMD3(0, 0, -1)), 0, "the bottom bulges")
        // no rigid motion left, and the six pins carry nothing
        let mean = Self.massWeightedMean(s)
        print(String(format: "FLEX-G FE pinch: mass-weighted mean u %.3g mm (max|u| %.4f) · anchor reaction %.3g N of %.1f N applied",
                     simd_length(mean), Self.maxU(s), s.anchorReactionN, s.appliedForceAbsN))
        XCTAssertLessThanOrEqual(simd_length(mean), 1e-3 * Self.maxU(s))
        XCTAssertLessThanOrEqual(s.anchorReactionN, 1e-3 * s.appliedForceAbsN)
        XCTAssertEqual(s.pinnedDOFs.count, 6, "3-2-1: six DOFs")
        // ★ RED CONTROL (2): a naive patch anchor (one corner voxel's nodes fixed, no relief) —
        // the two faces move unalike and the anchor carries load
        let p = try pad.scene.squishSolve(Self.request(pad, pressed: pressed, resting: [], control: 2))
        let pl = Self.meanOnPlane(p, axis: 0, value: 0) { $0.x }, pr = Self.meanOnPlane(p, axis: 0, value: 100) { $0.x }
        print(String(format: "FLEX-G FE pinch control (patch): x = 0 %.5f · x = 100 %.5f · anchor reaction %.3g N", pl, pr, p.anchorReactionN))
        XCTAssertGreaterThan(abs(abs(pl) - abs(pr)), 0.05 * max(abs(pl), abs(pr)), "control: the faces differ")
        XCTAssertGreaterThan(p.anchorReactionN, 1e-3 * p.appliedForceAbsN, "control: the patch carries load")
    }

    static func massWeightedMean(_ s: FlexSquishSolutionInfo) -> SIMD3<Double> {
        // nodal mass ∝ the solid elements around the node; the solved flag is enough on a box
        var sum = SIMD3<Double>.zero, n = 0.0
        for v in 0..<(s.nx * s.ny * s.nz) where s.solved[v] {
            let a = v % s.nx, b = (v / s.nx) % s.ny, c = v / (s.nx * s.ny)
            let w = Double((a == 0 || a == s.nx - 1 ? 1 : 2) * (b == 0 || b == s.ny - 1 ? 1 : 2) * (c == 0 || c == s.nz - 1 ? 1 : 2))
            sum += w * s.displacement(v); n += w
        }
        return sum / n
    }

    func testFreeFreeFieldDoesNotDependOnTheAnchors() throws {
        let pad = try Self.pad()
        let pressed = [try pad.press(Self.plusX, weightN: 98.07), try pad.press(Self.minusX, weightN: 98.07)]
        let a = try pad.scene.squishSolve(Self.request(pad, pressed: pressed, resting: []))
        let b = try pad.scene.squishSolve(Self.request(pad, pressed: pressed, resting: [], control: 512))
        XCTAssertTrue(a.ok && b.ok, a.failure + b.failure)
        XCTAssertNotEqual(Set(a.pinnedDOFs), Set(b.pinnedDOFs), "two DIFFERENT 3-2-1 choices")
        let m = Self.maxU(a)
        let d = Self.maxDifference(a, b)
        print(String(format: "FLEX-G FE anchors: 3-2-1 %@ vs %@ · max diff %.3g of max|u| %.4f", "\(a.pinnedDOFs)", "\(b.pinnedDOFs)", d / m, m))
        XCTAssertLessThanOrEqual(d, 5e-3 * m)
        // ★ RED CONTROL (2): the patch anchor's field is another field
        let p = try pad.scene.squishSolve(Self.request(pad, pressed: pressed, resting: [], control: 2))
        let dp = Self.maxDifference(a, p)
        print(String(format: "FLEX-G FE anchors control (patch): max diff %.3g of max|u|", dp / m))
        XCTAssertGreaterThan(dp, 5e-3 * m, "control: a patch anchor biases the shape")
    }

    static func maxDifference(_ a: FlexSquishSolutionInfo, _ b: FlexSquishSolutionInfo) -> Double {
        var d = 0.0
        for v in 0..<(a.nx * a.ny * a.nz) where a.solved[v] { d = max(d, simd_length(a.displacement(v) - b.displacement(v))) }
        return d
    }

    // MARK: - a resting face is held

    func testRestingFaceIsHeld() throws {
        let pad = try Self.pad()
        let press = try pad.press(Self.top, weightN: 294.3)
        let s = try pad.scene.squishSolve(Self.request(pad, pressed: [press], resting: [Self.bottom]))
        XCTAssertTrue(s.ok, s.failure)
        XCTAssertEqual(s.bcMode, "rest")
        XCTAssertFalse(s.heldNodes.isEmpty)
        XCTAssertTrue(s.heldNodes.allSatisfy { abs(s.position($0).z) < 1e-6 }, "the sole is the bottom")
        XCTAssertEqual(s.heldNodes.count, s.nx * s.ny, "every bottom node")
        for n in s.heldNodes { XCTAssertEqual(s.displacement(n), .zero, "held exactly") }
        let balance = simd_length(s.heldReactionN + s.appliedForceN)
        print(String(format: "FLEX-G FE rest: held reaction (%.3f, %.3f, %.3f) N + applied (%.3f, %.3f, %.3f) N = %.3g N",
                     s.heldReactionN.x, s.heldReactionN.y, s.heldReactionN.z, s.appliedForceN.x, s.appliedForceN.y, s.appliedForceN.z, balance))
        XCTAssertLessThanOrEqual(balance, 1e-3 * s.appliedForceAbsN, "the rest carries the load")
        // ★ RED CONTROL (128): a roller (only the normal fixed) — the sole slides
        let r = try pad.scene.squishSolve(Self.request(pad, pressed: [press], resting: [Self.bottom], control: 128))
        let slide = r.heldNodes.map { simd_length(SIMD2(r.displacement($0).x, r.displacement($0).y)) }.max() ?? 0
        print(String(format: "FLEX-G FE rest control (roller): the sole slides %.4f mm", slide))
        XCTAssertGreaterThan(slide, 1e-4, "control: a roller lets the sole slide")
    }

    // MARK: - the loads

    func testLoadsSumToTheDesignForce() throws {
        let pad = try Self.pad()
        for (pressed, resting) in [([Self.top], [Self.bottom]), ([Self.plusX, Self.minusX], [Self.bottom])] {
            let presses = try pressed.map { try pad.press($0, weightN: 150) }
            let s = try pad.scene.squishSolve(Self.request(pad, pressed: presses, resting: resting))
            XCTAssertTrue(s.ok, s.failure)
            for (k, p) in presses.enumerated() {
                let st = try pad.scene.stack(face: p.face, rotation: 0)
                let want = zip(p.columnPressureMPa, st.columns).reduce(0) { $0 + $1.0 * $1.1.areaMM2 }
                let sum = s.pressLoads[k].reduce(SIMD3<Double>.zero) { $0 + $1.force }
                XCTAssertEqual(simd_length(sum), want, accuracy: 1e-6 * want, "face \(p.face): Σ nodal loads = Σ p · area")
                XCTAssertEqual(simd_dot(simd_normalize(sum), st.load), 1, accuracy: 1e-9, "along the frame's load")
                print(String(format: "FLEX-G FE loads face %d: Σ %.6f N (design %.6f N) · raw Σ p·projected area %.6f N", p.face, simd_length(sum), want, s.pressRawForceN[k]))
            }
        }
        // the pad's top, voxel for voxel: the RAW projected-area sum IS the design force
        let press = try pad.press(Self.top, weightN: 150)
        let s = try pad.scene.squishSolve(Self.request(pad, pressed: [press], resting: [Self.bottom]))
        XCTAssertEqual(s.pressRawForceN[0], 150, accuracy: 0.01 * 150)
        // ★ RED CONTROL (1024): a uniform traction over every exposed face of the slab (no
        // projected-area weight) counts the rim voxels' side faces too — off by more than 1 %
        let u = try pad.scene.squishSolve(Self.request(pad, pressed: [press], resting: [Self.bottom], control: 1024))
        print(String(format: "FLEX-G FE loads control (unprojected): raw %.3f N for 150 N", u.pressRawForceN[0]))
        XCTAssertGreaterThan(abs(u.pressRawForceN[0] - 150), 0.01 * 150, "control: the unprojected traction double-counts the rim")
    }

    func testStampPressIsLocal() throws {
        let pad = try Self.pad()
        let st = try pad.scene.stack(face: Self.top, rotation: 0)
        // a 20 mm disc at the centre (a design stamp: its pressure where it presses, 0 elsewhere)
        let inDisc = st.columns.map { simd_length(SIMD2($0.uMM - 50, $0.vMM - 50)) <= 10 }
        let area = zip(inDisc, st.columns).filter(\.0).reduce(0) { $0 + $1.1.areaMM2 }
        let stamp = FlexSquishPressInfo(face: Self.top, rotation: 0, columnPressureMPa: inDisc.map { $0 ? 98.07 / area : 0 })
        func run(_ control: Int) throws -> (deepestAt: SIMD2<Double>, deepest: Double, rim: Double) {
            let s = try pad.scene.squishSolve(Self.request(pad, pressed: [stamp], resting: [Self.bottom], control: control))
            XCTAssertTrue(s.ok, s.failure)
            var best = (SIMD2<Double>.zero, 0.0), rim = 0.0
            for v in 0..<(s.nx * s.ny * s.nz) where s.solved[v] {
                let p = s.position(v)
                guard abs(p.z - 20) < 1e-6 else { continue }
                let d = -s.displacement(v).z
                if d > best.1 { best = (SIMD2(p.x, p.y), d) }
                if p.x < 1e-6 || p.x > 100 - 1e-6 || p.y < 1e-6 || p.y > 100 - 1e-6 { rim = max(rim, d) }
            }
            return (best.0, best.1, rim)
        }
        let s = try run(0)
        print(String(format: "FLEX-G FE stamp: deepest %.4f mm at (%.1f, %.1f) · the rim %.4f mm (%.1f%%)", s.deepest, s.deepestAt.x, s.deepestAt.y, s.rim, 100 * s.rim / s.deepest))
        XCTAssertLessThanOrEqual(simd_length(s.deepestAt - SIMD2(50, 50)), 10 + 1e-6, "the deepest point is under the stamp")
        XCTAssertLessThan(s.rim, 0.3 * s.deepest, "the rim hardly moves")
        // ★ RED CONTROL (8): the pressure spread uniformly — the whole face sinks, the rim too
        let u = try run(8)
        print(String(format: "FLEX-G FE stamp control (uniform): the rim %.1f%% of the deepest", 100 * u.rim / u.deepest))
        XCTAssertGreaterThan(u.rim, 0.3 * u.deepest, "control: a uniform press moves the rim")
    }

    // MARK: - the solver's posture and tolerance

    func testSolverPostureIsRestored() throws {
        let pad = try Self.pad()
        let press = try pad.press(Self.top, weightN: 294.3)
        let s = try pad.scene.squishSolve(Self.request(pad, pressed: [press], resting: [Self.bottom]))
        XCTAssertTrue(s.ok, s.failure)
        XCTAssertEqual(s.threadsDuring, 1, "the display solve runs on ONE matrix-free thread")
        XCTAssertEqual(s.threadsAfter, s.threadsBefore, "…and gives the count back")
        // a deadline that has already passed: a VALUE (ok = false, the deadline said), not a throw
        let late = try pad.scene.squishSolve(Self.request(pad, pressed: [press], resting: [Self.bottom], deadlineMS: 1))
        print("FLEX-G FE posture: threads \(s.threadsBefore)/\(s.threadsDuring)/\(s.threadsAfter) · 1 ms deadline: ok \(late.ok) '\(late.failure)' · threads after \(late.threadsAfter)")
        XCTAssertFalse(late.ok)
        XCTAssertTrue(late.failure.contains("deadline"), late.failure)
        XCTAssertEqual(late.threadsAfter, late.threadsBefore, "restored on the failure path too")
    }

    func testDisplayToleranceIsEnough() throws {
        let pad = try Self.pad()
        let press = try pad.press(Self.top, weightN: 294.3)
        let rho = pad.rho { p in 0.15 + 0.2 * abs(p.x - 50) / 50 }
        let ref = try pad.scene.squishSolve(Self.request(pad, pressed: [press], resting: [Self.bottom], rho: rho, tolerance: 1e-8))
        let fast = try pad.scene.squishSolve(Self.request(pad, pressed: [press], resting: [Self.bottom], rho: rho, tolerance: 1e-4))
        XCTAssertTrue(ref.ok && fast.ok)
        let m = Self.maxU(ref)
        let d = Self.maxDifference(ref, fast)
        print(String(format: "FLEX-G FE tolerance: 1e-4 vs 1e-8 differ %.3g%% of max|u| (%d vs %d iterations, %.0f vs %.0f ms)",
                     100 * d / m, fast.iterations, ref.iterations, fast.solveMS, ref.solveMS))
        XCTAssertLessThanOrEqual(d, 5e-3 * m)
        // ★ RED CONTROL: 1e-1 is visibly off
        let loose = try pad.scene.squishSolve(Self.request(pad, pressed: [press], resting: [Self.bottom], rho: rho, tolerance: 1e-1))
        let dl = Self.maxDifference(ref, loose)
        print(String(format: "FLEX-G FE tolerance control (1e-1): %.3g%%", 100 * dl / m))
        XCTAssertGreaterThan(dl, 5e-3 * m, "control: a 1e-1 solve is off")
    }

    func testCoarseningRule() {
        XCTAssertEqual(FlexibleCore.squishCoarsen(nx: 64, ny: 64, nz: 13), 1)
        XCTAssertEqual(FlexibleCore.squishCoarsen(nx: 128, ny: 128, nz: 26), 2)
        XCTAssertEqual(FlexibleCore.squishCoarsen(nx: 100, ny: 100, nz: 20), 2)
        XCTAssertEqual(FlexibleCore.squishCoarsen(nx: 200, ny: 200, nz: 40), 4)
        XCTAssertEqual(FlexibleCore.squishCoarsen(nx: 120_000, ny: 1, nz: 1), 1)
        XCTAssertEqual(FlexibleCore.squishCoarsen(nx: 120_001, ny: 1, nz: 1), 2)
    }
}
