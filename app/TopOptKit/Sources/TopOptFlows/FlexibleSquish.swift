// FlexibleSquish — the squish's value types, with no Metal in them (task
// 2026-09-29-flexible-screens, in-pass round). Moved here verbatim from the retired
// FlexibleLatticeRenderer.swift so the page, the model and the tests can use them without
// the renderer.
//
// ★ THE SQUISH (02-squish-model §6 — the ramp FlexibleOverlay.displacements draws): a rest
// point at t along the load inside column c moves by s·d·(exit − t)/(exit − entry) along
// +load. The Flexible pass INVERTS it per sample (MSL `flx_pullback`, FlexibleLatticeShader);
// `FlexibleSquishField` below is the Swift copy the tests hold it to. s = 0 skips the whole
// path, so it draws the rest lattice bit for bit.
//
// ★ ONE NUMBER. s is MeshRenderer's `flexScale` — the same float the dent's vertices are
// scaled by — so the dent and the walls cannot drift out of phase.

import Foundation
import simd
import TopOptKit

// MARK: - the squish inputs

/// One loaded face's stack, as the squish needs it: core's frame (FlexStackInfo) and one
/// depth per column cell.
public struct FlexibleSquishFace: Equatable, Sendable {
    public let centroid: SIMD3<Float>
    public let xAxis: SIMD3<Float>
    public let yAxis: SIMD3<Float>
    /// Unit, INTO the part.
    public let load: SIMD3<Float>
    public let uMin: Float, vMin: Float, pitchMM: Float
    public let nu: Int, nv: Int
    /// `nu·nv` cells, cell (iu, iv) at `iv·nu + iu` (core's `column_at` order):
    /// x = depth mm at full scale, y = entryT, z = exitT, w = 1 if a column exists there.
    public let cells: [SIMD4<Float>]
    /// The largest depth of a column that moves (0 = no column of this face moves).
    public let maxDepthMM: Float
    /// Whether any column of this face moves at all (a positive depth over a real span).
    public var moves: Bool { maxDepthMM > 0 }
    /// The stack's extent along the load: min entryT … max exitT over its columns.
    public let tMin: Float, tMax: Float

    public init(centroid: SIMD3<Float>, xAxis: SIMD3<Float>, yAxis: SIMD3<Float>, load: SIMD3<Float>,
                uMin: Float, vMin: Float, pitchMM: Float, nu: Int, nv: Int, cells: [SIMD4<Float>]) {
        self.centroid = centroid; self.xAxis = xAxis; self.yAxis = yAxis; self.load = load
        self.uMin = uMin; self.vMin = vMin; self.pitchMM = pitchMM
        self.nu = Swift.max(0, nu); self.nv = Swift.max(0, nv)
        var c = cells
        if c.count != self.nu * self.nv {   // a short table reads as "no column" past its end
            c = Array(c.prefix(self.nu * self.nv))
            c += [SIMD4<Float>](repeating: .zero, count: self.nu * self.nv - c.count)
        }
        self.cells = c
        var lo = Float.infinity, hi = -Float.infinity, deepest: Float = 0
        for x in c where x.w >= 0.5 {
            lo = Swift.min(lo, x.y); hi = Swift.max(hi, x.z)
            if x.x > 0, x.z - x.y > 1e-6 { deepest = Swift.max(deepest, x.x) }
        }
        self.maxDepthMM = pitchMM > 0 ? deepest : 0
        self.tMin = lo.isFinite ? lo : 0
        self.tMax = hi.isFinite ? hi : 0
    }

    /// The displacement (mm along +load, at s = 1, before the 0.95 clamp) of the rest point
    /// at `t0` in this cell — 02 §6's ramp; 0 outside the column or where none exists.
    static func displacement(_ c: SIMD4<Float>?, _ t0: Float) -> Float {
        guard let c, c.w >= 0.5, c.x > 0, c.z - c.y > 1e-6, t0 >= c.y, t0 <= c.z else { return 0 }
        return c.x * (c.z - t0) / (c.z - c.y)
    }

    /// Per cell: the largest difference between its displacement and any 4-neighbour's, over
    /// all t (mm at s = 1) — how far the deformed field can JUMP across that cell's walls.
    /// Both ramps are piecewise linear in t with steps at the entries, so the maximum sits at
    /// a breakpoint, taken from both sides. A cell off the grid or with no column moves 0.
    func columnJumps() -> [Float] {
        func at(_ iu: Int, _ iv: Int) -> SIMD4<Float>? {
            guard iu >= 0, iv >= 0, iu < nu, iv < nv else { return nil }
            let c = cells[iv * nu + iu]
            return c.w >= 0.5 ? c : nil
        }
        var out = [Float](repeating: 0, count: cells.count)
        for iv in 0..<nv {
            for iu in 0..<nu {
                let c = at(iu, iv)
                var j: Float = 0
                for (du, dv) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let n = at(iu + du, iv + dv)
                    let bs = [c?.y, c?.z, n?.y, n?.z].compactMap { $0 }
                    for b in bs {
                        let e = Swift.max(1e-4, abs(b) * 1e-5)
                        for t in [b - e, b, b + e] {
                            j = Swift.max(j, abs(Self.displacement(c, t) - Self.displacement(n, t)))
                        }
                    }
                }
                out[iv * nu + iu] = j
            }
        }
        return out
    }

    /// From core's stack and one depth per COLUMN, in core's column order (the same array
    /// FlexibleOverlay.displacements takes). nil or ≤ 0 = that column does not move.
    public init(stack st: FlexStackInfo, depthsMM: [Double?]) {
        var cells = [SIMD4<Float>](repeating: .zero, count: Swift.max(0, st.nu * st.nv))
        for k in cells.indices {
            let col = k < st.cell.count ? st.cell[k] : -1
            guard col >= 0, col < st.columns.count else { continue }
            let c = st.columns[col]
            let d = col < depthsMM.count ? (depthsMM[col] ?? 0) : 0
            cells[k] = SIMD4(Float(Swift.max(d, 0)), Float(c.entryT), Float(c.exitT), 1)
        }
        self.init(centroid: SIMD3<Float>(st.centroid), xAxis: SIMD3<Float>(st.xAxis),
                  yAxis: SIMD3<Float>(st.yAxis), load: SIMD3<Float>(st.load),
                  uMin: Float(st.uMin), vMin: Float(st.vMin), pitchMM: Float(st.pitchMM),
                  nu: st.nu, nv: st.nv, cells: cells)
    }

    /// A loaded face at core's buildable depths: a column core left without lattice, or
    /// whose buildable depth it could not reach, does not move.
    public init(stack st: FlexStackInfo, design: FlexFaceDesignInfo) {
        self.init(stack: st, depthsMM: Self.buildableDepths(stack: st, design: design))
    }

    /// Core's BUILDABLE depth per column, nil where there is no lattice or core could not
    /// reach one — the exact array the squish faces are built from AND the dent is drawn
    /// with while the lattice is shown (one source for both).
    public static func buildableDepths(stack st: FlexStackInfo, design: FlexFaceDesignInfo) -> [Double?] {
        st.columns.indices.map { k in
            guard k < design.columns.count else { return nil }
            let d = design.columns[k]
            return d.status != "no_lattice" && d.buildableOK ? d.buildableDepthMM : nil
        }
    }

    /// Core's `column_at` + the cell's row, or nil off the grid / where no column exists.
    func cell(u: Float, v: Float) -> SIMD4<Float>? {
        let iu = Int((u / pitchMM).rounded(.down)), iv = Int((v / pitchMM).rounded(.down))
        guard iu >= 0, iv >= 0, iu < nu, iv < nv else { return nil }
        let c = cells[iv * nu + iu]
        return c.w >= 0.5 ? c : nil
    }
}

extension Array where Element == FlexibleSquishFace {
    /// The largest scale s at which no moving column's face travels past the shader's
    /// clamp: min over moving cells of 0.95·span/d (+∞ when nothing moves). An exaggeration
    /// at or below this draws the walls exactly where the dent's column ramp puts them.
    public var maxSafeScale: Double {
        var best = Double.infinity
        for f in self.prefix(FlexibleSquishField.maxFaces) {
            for c in f.cells where c.w >= 0.5 && c.x > 0 && c.z - c.y > 1e-6 {
                best = Swift.min(best, Double(FlexibleSquishField.maxRatio) * Double(c.z - c.y) / Double(c.x))
            }
        }
        return best
    }
}

/// The Swift copy of the shader's squish (`flx_pullback` / `flx_deformed`), so the tests
/// can hold the GPU to it. `squish` is the EFFECTIVE s (the renderer's flexScale).
public enum FlexibleSquishField {
    /// The largest share of a column's span the face may travel (the inverse divides by 1 − a).
    public static let maxRatio: Float = 0.95
    /// The shader's face slots. ★ ROUND 3 BATCH B: more pressed faces no longer refuse the
    /// lattice — the walls use every face, the faces are handed over LARGEST FIRST and the
    /// squish is shown on the first four ("squish shown on the 4 largest of 7 faces").
    public static let maxFaces = 4

    public struct Pull: Equatable, Sendable {
        /// The rest point the lattice is evaluated at.
        public var p0: SIMD3<Float>
        /// The column's contraction along the load (a rest distance × scale is a safe step).
        public var scale: Float
        /// > 0: the point is in the gap a pressed face left, this far (mm) above it. −1 otherwise.
        public var air: Float
    }

    /// Deformed → rest, faces in order (each sees the point the previous one pulled back).
    public static func pullback(_ p: SIMD3<Float>, faces: [FlexibleSquishFace], squish s: Float) -> Pull {
        var r = Pull(p0: p, scale: 1, air: -1)
        guard s > 0 else { return r }
        for face in faces.prefix(maxFaces) where face.moves {
            let d = r.p0 - face.centroid
            let t = simd_dot(d, face.load)
            guard t >= face.tMin, t <= face.tMax else { continue }
            let u = simd_dot(d, face.xAxis) - face.uMin, v = simd_dot(d, face.yAxis) - face.vMin
            guard let c = face.cell(u: u, v: v) else { continue }
            let span = c.z - c.y
            guard c.x > 0, span > 1e-6, t >= c.y, t <= c.z else { continue }
            let a = Swift.min(s * c.x / span, maxRatio)
            let front = c.y + a * span
            if t < front { r.air = Swift.max(r.air, front - t); continue }
            let t0 = (t - a * c.z) / (1 - a)
            r.p0 += face.load * (t0 - t)
            r.scale *= (1 - a)
        }
        return r
    }

    /// Rest → deformed (the forward ramp), faces applied in REVERSE so `pullback` undoes it.
    public static func forward(_ p0: SIMD3<Float>, faces: [FlexibleSquishFace], squish s: Float) -> SIMD3<Float> {
        guard s > 0 else { return p0 }
        var p = p0
        for face in faces.prefix(maxFaces).reversed() where face.moves {
            let d = p - face.centroid
            let t0 = simd_dot(d, face.load)
            let u = simd_dot(d, face.xAxis) - face.uMin, v = simd_dot(d, face.yAxis) - face.vMin
            guard let c = face.cell(u: u, v: v) else { continue }
            let span = c.z - c.y
            guard c.x > 0, span > 1e-6, t0 >= c.y, t0 <= c.z else { continue }
            let a = Swift.min(s * c.x / span, maxRatio)
            p += face.load * (a * (c.z - t0))
        }
        return p
    }

    /// The lattice at a DEFORMED point (what the preview draws while squishing).
    /// ★ BATCH G: with an FE field (`fe`), the point is pulled back through THAT field (the MSL's
    /// flx_fe_pullback) — no columns, no air.
    public static func lattice(at p: SIMD3<Float>, _ f: FlexibleLatticeInputs,
                               faces: [FlexibleSquishFace], squish s: Float, fe: FlexibleFEField? = nil) -> Float {
        if let fe { return FlexibleLatticeField.lattice(at: fe.pullback(p, s), f) }
        let pb = pullback(p, faces: faces, squish: s)
        return pb.air > 0 ? pb.air : FlexibleLatticeField.lattice(at: pb.p0, f)
    }
}

// MARK: - what MeshRenderer is handed

/// The Flexible lattice as an INPUT to `MetalMeshView` (the octet's `LatticeLayerInputs`
/// precedent): the grids, the squish faces, the generation token and whether it is hidden.
///
/// ★ EQUAL BY TOKEN AND HIDDEN ONLY. The grids are megabytes; comparing them on every
/// SwiftUI update would cost more than the frame. The page bumps the token per Generate,
/// so a redraw never re-uploads and a new lattice always does.
public struct FlexibleLatticeLayerInputs: Equatable {
    public var lattice: FlexibleLatticeInputs
    public var faces: [FlexibleSquishFace]
    public var token: Int
    /// True while a new lattice is being built: the superseded one must not draw (the
    /// octet's `latticeHidden` rule during a rebake).
    public var hidden: Bool
    /// ★ BATCH B: the MAIN page's squish loop — the renderer steps it every frame
    /// (MeshRenderer+FlexibleLattice.stepFlexibleLoop), so the squish never publishes into
    /// WorkspacePlaceholder's body. nil ⇒ the view's own flexScale (the Settings page).
    public var loop: FlexibleSquishLoop?
    /// ★ ROUND 4 (D2): the token the squish FACES are uploaded by — the player's group pick
    /// changes which faces squish without a new lattice (FlexibleLatticePass.uploadFaces), so
    /// the volumes are not re-uploaded. Defaults to `token`.
    public var facesToken: Int
    /// ★ BATCH G: the squeeze groups' FE fields (one continuous displacement field per group), the
    /// mesh displacement of each (the ghost and the heat plane at their REST vertices — swapped in
    /// by the renderer WITH the field), and the sequence the loop plays (indices into `fe`: a pick
    /// is [g], "Play all" every landed group in turn). Empty ⇒ today's column squish.
    public var fe: [FlexibleFEField] = []
    public var feMesh: [[Float]] = []
    public var feSequence: [Int] = []
    /// The token the fields are uploaded by (the generation and the set of landed fields).
    public var feToken: Int = 0
    /// ★ BATCH G VERIFICATION: under "Play all", each group's OWN tints (only its faces coloured), by
    /// sim id — a reference the page keeps current; the renderer swaps them in WITH the group's
    /// field and mesh. nil (or no entry) ⇒ the page's one tint array stands.
    public var feTints: FlexibleFETints?

    public init(lattice: FlexibleLatticeInputs, faces: [FlexibleSquishFace], token: Int, hidden: Bool = false,
                loop: FlexibleSquishLoop? = nil, facesToken: Int? = nil) {
        self.lattice = lattice; self.faces = faces; self.token = token; self.hidden = hidden; self.loop = loop
        self.facesToken = facesToken ?? token
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.token == b.token && a.hidden == b.hidden && a.loop === b.loop && a.facesToken == b.facesToken
            && a.feToken == b.feToken && a.feSequence == b.feSequence
    }
}
