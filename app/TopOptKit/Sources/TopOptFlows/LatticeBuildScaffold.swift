// LatticeBuildScaffold — ★ notes30, his word on the strut lattice's build for SLOW parts (2026-11-26): "open up the walls first,
// then start with the vertical struts and horizontal struts - like having scaffolding put in place"; "I don't think scaffolds
// ever differ in heights"; "little stair/diagonal sections to really hammer in the 'Scaffold' effect"; "we can remove the
// scaffolding afterwards". The scaffold's look, made from the ROUGH cut-open (LatticeLayoutSession.gridRough: the lattice's
// area before its cells are laid) the moment it is made, before the lay:
//   * ONE EVEN GRID: uprights on square bays, every lift one height (a lift is one of the timelapse's floors, so the real floors
//     replace the scaffold lift for lift), horizontal ledgers ringing each lift just under its top;
//   * standing ROUND the lattice's area (as a building's scaffold stands round the building: its outline in plan, lift by lift),
//     never through it — the real lattice goes up inside it (`ringOnly`, his to switch);
//   * diagonal braces in some bays, turning each lift (a zig-zag), and one zig-zag stair (a flight a lift, with its treads);
//   * THIN and PALE (`widthShare`, `colour`): clearly temporary, never mistakable for the lattice's struts;
//   * only where it stands whole in the area (every member sampled along its length: never out through a wall).
// Pure: the rough map and the frame in, the members out (7 floats each, as core's bars). The renderer draws them with the bars'
// own pass (LatticeLayoutBarsPass), one pale colour, lift by lift by LatticeBuildTimelapse.
import Foundation
import simd

enum LatticeBuildScaffold {
    // MARK: the look (his to tune)

    /// The bays: one even grid, each bay this share of a lift's height (1: square bays).
    static let bayShare: Float = 1.0
    /// A member's width: this share of a lift's height, between `widthLeastMM` and `widthMostMM` — thin, never a strut's.
    static let widthShare: Float = 0.035
    static let widthLeastMM: Float = 0.3
    static let widthMostMM: Float = 0.8
    /// Pale straw: clearly temporary, never the lattice's colour.
    static let colour = SIMD4<Float>(0.96, 0.89, 0.60, 1)
    /// Round the lattice's area only (a building's scaffold); false — through all of it.
    static let ringOnly = true
    /// A diagonal brace in every `braceEvery`-th bay of the ring, its direction turning each lift (a zig-zag).
    static let braceEvery = 3
    /// The stair: one flight a lift in one bay, turning back each lift (a zig-zag stair), this many treads a flight.
    static let stairTreads = 4
    /// The stair's near stringer this share of a bay inside the ring, its width this share of a bay.
    static let stairInsetShare: Float = 0.15
    static let stairWidthShare: Float = 0.4
    /// The ledgers ring a lift this share of it under its top (so they count with that lift's snaps).
    static let ledgerDrop: Float = 0.02
    /// The grid kept this share of a bay inside the area's box.
    static let edgeInsetShare: Float = 0.05
    /// The rough cut-open's voxel: this many times the exact map's (`LatticeLayoutPreview.mapGeometry`): a few tens of
    /// milliseconds before the lay, never a wait.
    static let roughVoxelScale: Float = 2
    /// A member is in the area when these points along it are (open and inside the part).
    static let samples: [Float] = [0.04, 0.27, 0.5, 0.73, 0.96]

    // MARK: the rough cut-open

    /// The rough cut-open as the engine made it: 2 signed bytes a voxel (open, inside), x fastest; voxel (0,0,0)'s centre at
    /// `origin`, model mm.
    struct Rough: Sendable {
        var origin: SIMD3<Float>
        var voxel: Float
        var dims: SIMD3<Int32>
        var rg: [Int8]

        var isWhole: Bool { dims.x > 0 && dims.y > 0 && dims.z > 0 && rg.count == 2 * Int(dims.x) * Int(dims.y) * Int(dims.z) }

        /// `p` lies in the lattice's area (its nearest voxel open and inside the part).
        func inArea(_ p: SIMD3<Float>) -> Bool {
            let q = (p - origin) / voxel
            let i = Int(q.x.rounded()), j = Int(q.y.rounded()), k = Int(q.z.rounded())
            guard i >= 0, j >= 0, k >= 0, i < Int(dims.x), j < Int(dims.y), k < Int(dims.z) else { return false }
            let v = 2 * ((k * Int(dims.y) + j) * Int(dims.x) + i)
            return rg[v] > 0 && rg[v + 1] > 0
        }

        /// The area's box in the part's own coordinates (nil: nothing open).
        var openBox: (lo: SIMD3<Float>, hi: SIMD3<Float>)? {
            guard isWhole else { return nil }
            let nx = Int(dims.x), ny = Int(dims.y), nz = Int(dims.z)
            var lo = SIMD3<Int>(repeating: .max), hi = SIMD3<Int>(repeating: .min)
            var v = 0
            for k in 0..<nz { for j in 0..<ny { for i in 0..<nx {
                if rg[v] > 0 && rg[v + 1] > 0 {
                    lo = pointwiseMin(lo, SIMD3(i, j, k)); hi = pointwiseMax(hi, SIMD3(i, j, k))
                }
                v += 2
            }}}
            guard lo.x <= hi.x else { return nil }
            let h = SIMD3<Float>(repeating: voxel / 2)
            return (origin + SIMD3<Float>(lo) * voxel - h, origin + SIMD3<Float>(hi) * voxel + h)
        }
    }

    /// What is made off the main thread from the rough cut-open: the members (7 floats each), the frame they stand on, and the
    /// map drawn (smoothed, the solid view; nil in X-ray).
    struct Made: Sendable {
        var bars: [Float]
        var frame: LatticeBuildTimelapse.Frame
        var rough: Rough
        var drawn: [Int8]?
        var members: Int { bars.count / 7 }
    }

    /// The scaffold on the rough cut-open `r`, its floors along `up`, its bays along `across` (the view's, or the print's):
    /// nil — no area.
    static func make(_ r: Rough, up: SIMD3<Float>, across: SIMD3<Float>, walls: Bool) -> Made? {
        guard let box = r.openBox else { return nil }
        let f = LatticeBuildTimelapse.Frame(lo: box.lo, hi: box.hi, up: up, across: across)
        let dp = f.depth
        var dLo = Float.greatestFiniteMagnitude, dHi = -dLo
        for i in 0..<8 {
            let p = SIMD3<Float>(i & 1 == 0 ? box.lo.x : box.hi.x, i & 2 == 0 ? box.lo.y : box.hi.y, i & 4 == 0 ? box.lo.z : box.hi.z)
            let d = simd_dot(dp, p)
            dLo = Swift.min(dLo, d); dHi = Swift.max(dHi, d)
        }
        let bars = members(f, depthLow: dLo, depthW: Swift.max(dHi - dLo, 1e-3), inArea: r.inArea)
        let drawn = walls ? LatticeLayoutSolidGrid.cutSmoothed(r.rg, dims: r.dims) : nil
        return Made(bars: bars, frame: f, rough: r, drawn: drawn)
    }

    /// The scaffold the show holds and the renderer draws with its own bars pass.
    struct Drawing {
        let token: Int
        let inputs: LatticeLayoutBarsInputs
        let frame: LatticeBuildTimelapse.Frame
        var members: Int { inputs.bars.count / 7 }
    }
    static func drawing(_ m: Made, token: Int) -> Drawing {
        let n = m.members
        let map = m.drawn.map { LatticeLayoutSolidGrid(token: token, origin: m.rough.origin, voxel: m.rough.voxel,
                                                       dims: m.rough.dims, rg: $0, smooth: true) }
        let inputs = LatticeLayoutBarsInputs(token: token, bars: m.bars, solid: map, flags: [],
                                             colours: [SIMD4<Float>](repeating: colour, count: n), colourKey: token)
        return Drawing(token: token, inputs: inputs, frame: m.frame)
    }

    // MARK: the members

    /// A member's width on lifts `liftH` tall.
    static func width(liftH: Float) -> Float { Swift.min(widthMostMM, Swift.max(widthLeastMM, liftH * widthShare)) }

    /// The scaffold's members on `f` (its floors the lifts): uprights, ledgers, braces and a stair, every one whole in the area
    /// (`inArea`); `depthLow`, `depthW` — the area along the frame's depth.
    static func members(_ f: LatticeBuildTimelapse.Frame, depthLow dLo: Float, depthW dW: Float,
                        inArea: (SIMD3<Float>) -> Bool) -> [Float] {
        let up = f.up, ac = f.across, dp = f.depth
        let s = Swift.max(f.floorH * bayShare, 1e-3), inset = edgeInsetShare * s
        let nA = Swift.min(200, Swift.max(0, Int(((f.acrossW - 2 * inset) / s + 1e-4).rounded(.down))))
        let nD = Swift.min(200, Swift.max(0, Int(((dW - 2 * inset) / s + 1e-4).rounded(.down))))
        let a0 = f.acrossLow + (f.acrossW - Float(nA) * s) / 2, d0 = dLo + (dW - Float(nD) * s) / 2
        func at(_ a: Float, _ d: Float, _ h: Float) -> SIMD3<Float> { ac * (a0 + a * s) + dp * (d0 + d * s) + up * h }
        func fits(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool { samples.allSatisfy { inArea(a + (b - a) * $0) } }
        let w = width(liftH: f.floorH)
        var out: [Float] = []
        func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>) { out += [a.x, a.y, a.z, b.x, b.y, b.z, w] }
        func lift(_ k: Int) -> (h0: Float, h1: Float, hl: Float) {
            let h0 = f.low + Float(k) * f.floorH
            return (h0, h0 + f.floorH, h0 + f.floorH * (1 - ledgerDrop))
        }
        // which uprights stand on each lift (whole in the area), and which of them the scaffold keeps (its ring)
        var kept: [[[Bool]]] = []
        for k in 0..<f.floors {
            let (h0, h1, _) = lift(k)
            var stand = [[Bool]](repeating: [Bool](repeating: false, count: nD + 1), count: nA + 1)
            for i in 0...nA { for j in 0...nD { stand[i][j] = fits(at(Float(i), Float(j), h0), at(Float(i), Float(j), h1)) } }
            func on(_ i: Int, _ j: Int) -> Bool { i >= 0 && j >= 0 && i <= nA && j <= nD && stand[i][j] }
            var keep = stand
            if ringOnly {
                for i in 0...nA { for j in 0...nD where stand[i][j] {
                    keep[i][j] = !(on(i - 1, j) && on(i + 1, j) && on(i, j - 1) && on(i, j + 1))
                }}
            }
            kept.append(keep)
        }
        func ledgerAcross(_ k: Int, _ i: Int, _ j: Int) -> Bool {
            guard i < nA, kept[k][i][j], kept[k][i + 1][j] else { return false }
            let hl = lift(k).hl
            return fits(at(Float(i), Float(j), hl), at(Float(i + 1), Float(j), hl))
        }
        func ledgerDepth(_ k: Int, _ i: Int, _ j: Int) -> Bool {
            guard j < nD, kept[k][i][j], kept[k][i][j + 1] else { return false }
            let hl = lift(k).hl
            return fits(at(Float(i), Float(j), hl), at(Float(i), Float(j + 1), hl))
        }
        // the stair's bay: the bay along the ring with the most lifts (the front row first, then the left)
        var stair: (i: Int, j: Int)?
        var best = 0
        for j in 0...nD { for i in 0..<Swift.max(nA, 0) {
            let lifts = (0..<f.floors).filter { ledgerAcross($0, i, j) }.count
            if lifts > best { best = lifts; stair = (i, j) }
        }}
        let inward: Float = (stair?.j ?? 0) < nD ? 1 : -1   // the stair stands inside the ring
        for k in 0..<f.floors {
            let (h0, h1, hl) = lift(k)
            let turn = k % 2 == 1   // the braces and the stair turn back each lift: a zig-zag
            for i in 0...nA { for j in 0...nD where kept[k][i][j] { add(at(Float(i), Float(j), h0), at(Float(i), Float(j), h1)) } }
            for i in 0...nA { for j in 0...nD {
                if ledgerAcross(k, i, j) {
                    add(at(Float(i), Float(j), hl), at(Float(i + 1), Float(j), hl))
                    let isStair = stair.map { $0.i == i && $0.j == j } ?? false
                    if !isStair, (i + 2 * j) % braceEvery == 0 {
                        let a = at(Float(turn ? i + 1 : i), Float(j), h0), b = at(Float(turn ? i : i + 1), Float(j), hl)
                        if fits(a, b) { add(a, b) }
                    }
                }
                if ledgerDepth(k, i, j), (2 * i + j) % braceEvery == 1 {
                    let a = at(Float(i), Float(turn ? j + 1 : j), h0), b = at(Float(i), Float(turn ? j : j + 1), hl)
                    if fits(a, b) { add(a, b) }
                }
            }}
            // the stair's flight this lift: two stringers rising across the bay (turning back each lift) and its treads
            if let st = stair, ledgerAcross(k, st.i, st.j) {
                let d1 = Float(st.j) + inward * stairInsetShare, d2 = d1 + inward * stairWidthShare
                let u0: Float = turn ? 0.95 : 0.05, u1: Float = turn ? 0.05 : 0.95
                var flight: [(SIMD3<Float>, SIMD3<Float>)] = []
                for d in [d1, d2] { flight.append((at(Float(st.i) + u0, d, h0), at(Float(st.i) + u1, d, hl))) }
                for q in 1...Swift.max(1, stairTreads) {
                    let t = Float(q) / Float(stairTreads + 1)
                    let u = u0 + (u1 - u0) * t, h = h0 + (hl - h0) * t
                    flight.append((at(Float(st.i) + u, d1, h), at(Float(st.i) + u, d2, h)))
                }
                if flight.allSatisfy({ fits($0.0, $0.1) }) { for (a, b) in flight { add(a, b) } }
            }
        }
        return out
    }
}
