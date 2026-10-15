// FlexibleWallHeat — round 7 batch X1 VERIFY: THE HEAT ON THE WALLS (task 2026-09-29-flexible-screens).
// His words (2026-10-14, his answer on the R7-V handoff's Q9, binding): "X-ray mode should show the inside of the SOLID
// showing the extent of the face prism/bend amount/heat map etc. … If lattice is on without x-ray view, we see the lattice
// plus the solid. If the user adds x-ray, we see through the solid."
// ★ WHY. The X1 verify (its blocker): with Heat on, X-ray kept the pressed face's heat as an OPAQUE lid — from his img5 top
// camera X-ray showed one heat-coloured square and none of the lattice the default view showed; with Group C picked, two
// purple boxes with nothing inside. And (its major) in the printed view the heat lay only on the solid part — over the
// lattice the face is open — which on his pad is a flat 0 mm blue: "The view of the heatmap doesn't actually change
// anything" (his img3).
// ★ WHAT. Whenever Heat is on and the walls are DRAWN (X-ray, or the printed view), the WALLS carry the heat: each wall
// takes the squish of the pressed face's COLUMN it stands in — the same number the face's heat map is coloured by there
// (core's buildable depth on the column route, the 3D sim's compression on the FE route), on the same rainbow and the same
// scale (the legend's top) — and the lid stops hiding them: in X-ray it is a faint heat-tinted skin (the ghost), in the
// printed view the solid part is the plain part (it does not squish). A wall under no pressed column reads 0 mm.
// ★ TWO COPIES, ONE RULE: `value(at:faces:cells:)` here (the tap's reading, the tests) and the MSL `flx_wall_heat`
// (FlexibleLatticeShader) — FlexibleLatticePassTests holds them equal (`probeHeat`).

import Foundation
import simd
import TopOptKit

/// The walls' heat for one lattice view: per squish FACE (the pass's slots, `FlexibleGeneratedLattice.squishFaces` order),
/// per cell (iu, iv) at `iv·nu + iu` — the face's own grid (FlexibleSquishFace.cells) — the column's squish in mm at full
/// load (< 0: no column there), and the scale's top (the legend's).
public struct FlexibleWallHeat: Equatable, Sendable {
    public var cells: [[Float]]
    public var topMM: Float
    /// What the pass uploads the tables by (a new table, a new scale).
    public var token: Int

    public init(cells: [[Float]], topMM: Float) {
        self.cells = cells
        self.topMM = topMM
        var h = Hasher()
        h.combine(topMM)
        for c in cells { h.combine(c.count); for v in c { h.combine(v) } }
        token = h.finalize()
    }

    /// How far (mm) a rest point may sit outside its column's [entry, exit] and still be read as in it (a wall cut at the
    /// pressed face's own surface, the region's half-voxel edge).
    public static let spanSlackMM: Float = 0.5

    /// ★ THE SWIFT TWIN of `flx_wall_heat`: the heat (mm) of the wall whose REST point is `p0` — the largest over the faces
    /// whose column holds it; 0 under no pressed column; nil with no table.
    public static func value(at p0: SIMD3<Float>, faces: [FlexibleSquishFace], cells: [[Float]]) -> Float? {
        guard !cells.isEmpty else { return nil }
        var h: Float = 0
        for (f, face) in faces.prefix(FlexibleSquishField.maxFaces).enumerated() where f < cells.count {
            guard face.nu > 0, face.nv > 0, face.pitchMM > 0 else { continue }
            let d = p0 - face.centroid
            let t = simd_dot(d, face.load)
            let u = simd_dot(d, face.xAxis) - face.uMin, v = simd_dot(d, face.yAxis) - face.vMin
            let iu = Int((u / face.pitchMM).rounded(.down)), iv = Int((v / face.pitchMM).rounded(.down))
            guard iu >= 0, iv >= 0, iu < face.nu, iv < face.nv else { continue }
            let k = iv * face.nu + iu
            let c = face.cells[k]
            guard c.w >= 0.5, t >= c.y - spanSlackMM, t <= c.z + spanSlackMM, k < cells[f].count else { continue }
            h = Swift.max(h, cells[f][k])
        }
        return h
    }

    /// One face's table from its stack and one heat per COLUMN (core's column order; nil / missing = 0): the face's cells
    /// map to columns through `st.cell`, exactly as FlexibleSquishFace(stack:depthsMM:) builds its own cells.
    public static func cells(stack st: FlexStackInfo, face: FlexibleSquishFace, perColumn: [Double?]) -> [Float] {
        let n = Swift.max(0, face.nu * face.nv)
        guard st.nu == face.nu, st.nv == face.nv else { return [Float](repeating: -1, count: n) }
        return (0..<n).map { k in
            let col = k < st.cell.count ? st.cell[k] : -1
            guard col >= 0, col < st.columns.count else { return -1 }
            let v = col < perColumn.count ? (perColumn[col] ?? 0) : 0
            return Float(Swift.max(0, v.isFinite ? v : 0))
        }
    }
}
