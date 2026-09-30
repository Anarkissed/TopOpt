// FlexibleFEField — one squeeze group's squish as a CONTINUOUS 3D displacement field (task
// 2026-09-29-flexible-screens, round 5 batch G).
//
// ★ ONE FIELD MOVES EVERYTHING. The ghost body and the bent heat plane move by u at their REST
// vertices (`meshDisplacements`, uploaded as MetalMeshView's flexDisplacements); the lattice pass
// pulls each deformed sample back through the SAME field (`pullback`, the MSL flx_fe_pullback's
// Swift twin). Both scale by the renderer's one flexScale s, so the three move as one body: a
// point of the top map shared with face 5's map, or with the other sector of a split top,
// samples the same field at the same place — no seam, no flap, no crossing, by construction.
//
// ★ SCALED TO CORE'S SQUISH (`calibrate`): u is the solve's raw field × k, k chosen so the
// DEEPEST ZONE (columns within 90 % of the deepest core squish) compresses exactly what core
// predicts there. The heat map's colours, the legend and tap-to-read stay core's numbers.
//
// ★ SAFE TO EXAGGERATE (`gradientBound`): gmax is the EXACT maximum of ‖∇u‖₂ over every cell
// (the trilinear Jacobian peaks at a cell corner), so at s · gmax ≤ ½ the map p ↦ p + s·u(p) is
// injective and its fixed-point inverse converges (FlexibleShownValues caps the page's ×k by it).

import Foundation
import simd
import TopOptKit

public struct FlexibleFEField: Sendable, Equatable {
    /// "group-1" … — the sim it plays.
    public let simID: String
    /// The lattice generation it was solved for (a new lattice discards it).
    public let generation: Int
    /// NODE counts; node (a, b, c) sits at origin + (a, b, c)·spacing.
    public let nx: Int, ny: Int, nz: Int
    public let origin: SIMD3<Float>
    public let spacing: Float
    /// Per node, mm at FULL load, calibrated (k applied).
    public private(set) var u: [SIMD3<Float>]
    /// Per node: a solid element owns it (the rest is the extension outside the solid).
    public let solved: [Bool]
    /// k: the calibration factor applied to the raw solve.
    public private(set) var scale: Double
    /// max ‖∇u‖₂ over every cell (per unit s) — `gradientBound`.
    public private(set) var gmax: Double
    /// The largest |u| over every node (the march box's dilation per unit s).
    public private(set) var maxDisplacement: Float
    public let bcMode: String
    public let iterations: Int
    public let solveMS: Double
    public let coarsen: Int
    /// No deepest zone to calibrate against (k = 1; the receipt says so).
    public private(set) var uncalibrated: Bool
    /// k as the deepest zone asked for it (before the band): > 2 ⇒ the sim found the part that many
    /// times stiffer than core's columns (FlexibleFE.calibrationBand).
    public private(set) var coreRatio: Double = 1
    /// The sliding rests' solve did not converge and the sim was solved with every rest bonded (a
    /// stiffer picture — FlexibleFERequest.solve's one retry).
    public var restsBonded = false
    /// The band held k back (the field moves less, or more, than the map reads).
    public var clamped: Bool { abs(coreRatio - scale) > 1e-9 * max(1, abs(scale)) && !uncalibrated }
    /// Identity (fields are compared by it, never by their megabytes).
    public let serial: Int

    public static func == (a: Self, b: Self) -> Bool {
        a.serial == b.serial && a.simID == b.simID && a.generation == b.generation && a.scale == b.scale
    }

    private static let serials = SerialCounter()

    /// The raw field of a solve (k = 1, not yet calibrated).
    public init(solution s: FlexSquishSolutionInfo, simID: String, generation: Int) {
        self.simID = simID
        self.generation = generation
        nx = s.nx; ny = s.ny; nz = s.nz
        origin = SIMD3<Float>(s.origin)
        spacing = Float(s.spacing)
        var u = [SIMD3<Float>](repeating: .zero, count: s.nx * s.ny * s.nz)
        for n in u.indices where 3 * n + 2 < s.u.count { u[n] = SIMD3(s.u[3 * n], s.u[3 * n + 1], s.u[3 * n + 2]) }
        self.u = u
        solved = s.solved
        scale = 1
        gmax = 0
        maxDisplacement = 0
        bcMode = s.bcMode
        iterations = s.iterations
        solveMS = s.solveMS
        coarsen = s.coarsen
        uncalibrated = false
        serial = Self.serials.next()
        refreshBounds()
    }

    /// A field from its parts (tests, the probes).
    public init(simID: String, generation: Int, nx: Int, ny: Int, nz: Int, origin: SIMD3<Float>, spacing: Float,
                u: [SIMD3<Float>], solved: [Bool]? = nil, bcMode: String = "rest") {
        self.simID = simID; self.generation = generation
        self.nx = nx; self.ny = ny; self.nz = nz; self.origin = origin; self.spacing = spacing
        self.u = u
        self.solved = solved ?? [Bool](repeating: true, count: u.count)
        scale = 1; gmax = 0; maxDisplacement = 0
        self.bcMode = bcMode; iterations = 0; solveMS = 0; coarsen = 1; uncalibrated = false
        serial = Self.serials.next()
        refreshBounds()
    }

    private mutating func refreshBounds() {
        maxDisplacement = u.reduce(0) { Swift.max($0, simd_length($1)) }
        gmax = gradientBound()
    }

    /// This field with every displacement × k (the calibration). `asked`: the k the deepest zone
    /// asked for (the receipt), when the band held it back.
    public func scaled(by k: Double, uncalibrated: Bool = false, asked: Double? = nil) -> FlexibleFEField {
        var f = self
        let kf = Float(k)
        f.u = u.map { $0 * kf }
        f.scale = scale * k
        f.coreRatio = scale * (asked ?? k)
        f.uncalibrated = uncalibrated
        f.refreshBounds()
        return f
    }

    // MARK: sampling (the GPU's rule: node-centred trilinear, clamped to the node box)

    @inline(__always) public func node(_ a: Int, _ b: Int, _ c: Int) -> Int { (c * ny + b) * nx + a }

    /// u at model point `p` (mm at full load): trilinear between nodes, clamped to the node box
    /// — the same rule as the pass's clamp-to-edge texture.
    public func sample(_ p: SIMD3<Float>) -> SIMD3<Float> {
        guard nx > 0, ny > 0, nz > 0 else { return .zero }
        let q = (p - origin) / spacing
        let qx = Swift.min(Swift.max(q.x, 0), Float(nx - 1))
        let qy = Swift.min(Swift.max(q.y, 0), Float(ny - 1))
        let qz = Swift.min(Swift.max(q.z, 0), Float(nz - 1))
        let a0 = Swift.min(Int(qx), Swift.max(0, nx - 2)), b0 = Swift.min(Int(qy), Swift.max(0, ny - 2))
        let c0 = Swift.min(Int(qz), Swift.max(0, nz - 2))
        let a1 = Swift.min(a0 + 1, nx - 1), b1 = Swift.min(b0 + 1, ny - 1), c1 = Swift.min(c0 + 1, nz - 1)
        let fx = qx - Float(a0), fy = qy - Float(b0), fz = qz - Float(c0)
        let x00 = u[node(a0, b0, c0)] * (1 - fx) + u[node(a1, b0, c0)] * fx
        let x10 = u[node(a0, b1, c0)] * (1 - fx) + u[node(a1, b1, c0)] * fx
        let x01 = u[node(a0, b0, c1)] * (1 - fx) + u[node(a1, b0, c1)] * fx
        let x11 = u[node(a0, b1, c1)] * (1 - fx) + u[node(a1, b1, c1)] * fx
        let y0 = x00 * (1 - fy) + x10 * fy, y1 = x01 * (1 - fy) + x11 * fy
        return y0 * (1 - fz) + y1 * fz
    }

    /// Rest → deformed at scale s.
    public func forward(_ p0: SIMD3<Float>, _ s: Float) -> SIMD3<Float> { p0 + s * sample(p0) }

    /// Deformed → rest: p = x − s·u(p) by fixed-point iteration — the Swift twin of the MSL
    /// `flx_fe_pullback` (the same iteration count and early exit). s = 0 returns x itself.
    public func pullback(_ x: SIMD3<Float>, _ s: Float, iterations: Int = FlexibleFE.pullbackIterations,
                         tolMM: Float = FlexibleFE.pullbackTolMM) -> SIMD3<Float> {
        guard s > 0 else { return x }
        var p = x - s * sample(x)
        if iterations > 1 {
            for _ in 1..<iterations {
                let pn = x - s * sample(p)
                let d = simd_length(pn - p)
                p = pn
                if d < tolMM { break }
            }
        }
        return p
    }

    /// The largest safe scale: s · gmax ≤ ½ (∞ when the field is flat).
    public var maxSafeScale: Double { gmax > 1e-12 ? FlexibleFE.safeGradient / gmax : .infinity }

    // MARK: the gradient bound

    /// The largest spectral norm of the field's Jacobian over every cell (per unit s), extension
    /// included — EXACT for the trilinear field: inside a cell the Jacobian is multi-affine in the
    /// cell's three coordinates (∂u/∂x depends on y and z only, bilinearly, and so on), and the
    /// spectral norm is convex, so its maximum over the cell is at one of the 8 corners, where each
    /// column is that corner's edge difference / h. `solvedOnly`: cells whose 8 corners are solved.
    public func gradientBound(solvedOnly: Bool = false) -> Double {
        guard nx > 1, ny > 1, nz > 1, spacing > 0 else { return 0 }
        var g: Float = 0
        for c in 0..<(nz - 1) { for b in 0..<(ny - 1) { for a in 0..<(nx - 1) {
            if solvedOnly {
                var all = true
                for dc in 0...1 { for db in 0...1 { for da in 0...1 where !solved[node(a + da, b + db, c + dc)] { all = false } } }
                if !all { continue }
            }
            for k in 0...1 { for j in 0...1 { for i in 0...1 {
                let cx = u[node(a + 1, b + j, c + k)] - u[node(a, b + j, c + k)]
                let cy = u[node(a + i, b + 1, c + k)] - u[node(a + i, b, c + k)]
                let cz = u[node(a + i, b + j, c + 1)] - u[node(a + i, b + j, c)]
                g = Swift.max(g, Self.spectralNorm(cx, cy, cz))
            } } }
        } } }
        return Double(g / spacing)
    }

    /// ‖J‖₂ of the 3×3 matrix with columns a, b, c: √λ_max(JᵀJ) (closed-form symmetric eigenvalues).
    static func spectralNorm(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float {
        let m00 = Double(simd_dot(a, a)), m11 = Double(simd_dot(b, b)), m22 = Double(simd_dot(c, c))
        let m01 = Double(simd_dot(a, b)), m02 = Double(simd_dot(a, c)), m12 = Double(simd_dot(b, c))
        let p1 = m01 * m01 + m02 * m02 + m12 * m12
        let tr = m00 + m11 + m22
        guard p1 > 1e-30 else { return Float(Swift.max(m00, Swift.max(m11, m22)).squareRoot()) }
        let q = tr / 3
        let p2 = (m00 - q) * (m00 - q) + (m11 - q) * (m11 - q) + (m22 - q) * (m22 - q) + 2 * p1
        let p = (p2 / 6).squareRoot()
        guard p > 1e-300 else { return Float(q.squareRoot()) }
        let b00 = (m00 - q) / p, b11 = (m11 - q) / p, b22 = (m22 - q) / p
        let b01 = m01 / p, b02 = m02 / p, b12 = m12 / p
        let det = b00 * (b11 * b22 - b12 * b12) - b01 * (b01 * b22 - b12 * b02) + b02 * (b01 * b12 - b11 * b02)
        let r = Swift.min(1, Swift.max(-1, det / 2))
        let lmax = q + 2 * p * cos(acos(r) / 3)
        return Float(Swift.max(0, lmax).squareRoot())
    }

    // MARK: the mesh

    /// One xyz per flat vertex (`positions`, flattened): the field at the vertex's REST place —
    /// the part's kept triangles, their sub-vertices and the heat quads alike.
    public func meshDisplacements(positions: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: positions.count)
        var v = 0
        while v + 2 < positions.count {
            let d = sample(SIMD3(positions[v], positions[v + 1], positions[v + 2]))
            out[v] = d.x; out[v + 1] = d.y; out[v + 2] = d.z
            v += 3
        }
        return out
    }

    // MARK: the calibration (§1.8)

    /// One pressed face's columns as the heat map shows them: core's depth per column (nil = none)
    /// and which columns a pinch halves.
    public struct Target: Sendable {
        public let stack: FlexStackInfo
        public let depthsMM: [Double?]
        public let pinched: [Bool]
        public init(stack: FlexStackInfo, depthsMM: [Double?], pinched: [Bool] = []) {
            self.stack = stack; self.depthsMM = depthsMM; self.pinched = pinched
        }
    }

    /// Column `c`'s compression along its load: (u(entry) − u(exit)) · load, or to the column's
    /// MIDDLE where a pinch halves it (the half this face designs for).
    public func columnCompression(stack st: FlexStackInfo, col c: Int, pinched: Bool) -> Double {
        let col = st.columns[c]
        let entry = FlexibleStackMembership.point(st, column: c, t: col.entryT)
        let end = FlexibleStackMembership.point(st, column: c, t: pinched ? 0.5 * (col.entryT + col.exitT) : col.exitT)
        let du = sample(SIMD3<Float>(entry)) - sample(SIMD3<Float>(end))
        return Double(simd_dot(du, SIMD3<Float>(st.load)))
    }

    /// k = Σ_Z d_core / Σ_Z d_fe over the deepest zone Z (columns with d_core ≥ 90 % of the
    /// deepest), and whether it had nothing to calibrate against (k = 1 then).
    public func calibration(_ targets: [Target]) -> (k: Double, uncalibrated: Bool, zone: Int) {
        let deepest = targets.flatMap { $0.depthsMM.compactMap { $0 } }.max() ?? 0
        guard deepest > 0 else { return (1, true, 0) }
        var core = 0.0, fe = 0.0, zone = 0
        for t in targets {
            for (c, d) in t.depthsMM.enumerated() {
                guard let d, d >= FlexibleFE.deepZone * deepest, c < t.stack.columns.count else { continue }
                core += d
                fe += columnCompression(stack: t.stack, col: c, pinched: c < t.pinched.count && t.pinched[c])
                zone += 1
            }
        }
        guard fe > 1e-9 else { return (1, true, zone) }
        return (core / fe, false, zone)
    }

    /// This field scaled so its deepest zone compresses core's squish there — k kept inside
    /// `band` (nil: unbounded — a shape-only lattice, whose law is in relative units).
    public func calibrated(to targets: [Target], band: ClosedRange<Double>? = FlexibleFE.calibrationBand) -> FlexibleFEField {
        let c = calibration(targets)
        let k = band.map { Swift.min($0.upperBound, Swift.max($0.lowerBound, c.k)) } ?? c.k
        return scaled(by: c.uncalibrated ? 1 : k, uncalibrated: c.uncalibrated, asked: c.k)
    }
}

/// A thread-safe counter for the fields' identities.
final class SerialCounter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}
