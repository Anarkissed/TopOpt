// LatticeThinWallGlow.swift — ★ his 11-09: "If the structural lattice cannot make lattice somewhere … highlight the area that
// it can't lattice … by dimming everywhere else", then "Dim and electric blue", then "more of a GLOW of electric blue
// rather than a solid colour".
//
// The walls Structural leaves solid (a voxel mask on the preview's grid — today `LatticeStructuralThinWalls.mask`, core's
// own solid-fallback reasons once LatticeTypes' SOLID slice lands, reviewer 20:10Z) become a per-vertex tint buffer for the
// part: those walls glow (strength in `flags.w`, which the mesh shader turns into an additive electric-blue emission with a
// Fresnel rim and a slow breathe), the glow fades out over a few millimetres into the part around them, and everything
// else is dimmed. Pure, so it is headless-testable (`LatticeThinWallGlowTests`).

import Foundation
import simd

public enum LatticeThinWallGlow {
    /// How far the glow fades into the part around a wall (mm).
    public static let falloffMM = 4.0
    /// The dim the rest of the part takes: its albedo pulled toward this, by this much.
    public static let dimRGBA = SIMD4<Float>(0.10, 0.11, 0.14, 0.62)
    /// The glowing walls' albedo tint (the emission is the shader's).
    public static let blueRGBA = SIMD3<Float>(0.16, 0.60, 1.0)

    /// Any vertex glowing (flags.w of the 8-float layout)?
    public static func anyGlow(_ rgba: [Float]) -> Bool {
        var i = 7
        while i < rgba.count { if rgba[i] > 0.001 { return true }; i += 8 }
        return false
    }

    /// The glow per voxel of `grid`: 1 on the walls (`thin`), fading to 0 over `falloffMM` through the part (`inside`,
    /// the part's own solid; air stays 0 so a surface samples the side the material is on).
    public static func field(thin: [Bool], inside: [Bool], grid: LatticeVoxelGrid, falloffMM: Double = falloffMM) -> [Float] {
        let n = grid.nx * grid.ny * grid.nz
        guard thin.count == n, inside.count == n else { return [] }
        let h = Double(Swift.min(grid.spacing.x, Swift.min(grid.spacing.y, grid.spacing.z)))
        let steps = Swift.max(1, Int((falloffMM / h).rounded()))
        var d = [Int](repeating: .max, count: n)
        var queue: [Int] = []
        for i in 0..<n where thin[i] { d[i] = 0; queue.append(i) }
        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            guard d[i] < steps else { continue }
            let x = i % grid.nx, y = (i / grid.nx) % grid.ny, z = i / (grid.nx * grid.ny)
            for (dx, dy, dz) in [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)] {
                let X = x + dx, Y = y + dy, Z = z + dz
                guard X >= 0, Y >= 0, Z >= 0, X < grid.nx, Y < grid.ny, Z < grid.nz else { continue }
                let j = (Z * grid.ny + Y) * grid.nx + X
                if inside[j], d[j] == .max { d[j] = d[i] + 1; queue.append(j) }
            }
        }
        return d.map { v in
            guard v != .max else { return 0 }
            let t = 1 - Double(v) / Double(steps + 1)
            return Float(t * t)   // soft: a quick fall from the wall, a long faint tail
        }
    }

    /// The part's per-vertex tints (8 floats per draw vertex, the mesh's index order): glowing where the field is, the
    /// dim elsewhere. Each vertex samples the voxel half a voxel either side of its triangle's plane and keeps the larger
    /// (the mesh's winding is mixed; air carries 0, so the material side answers).
    public static func vertexTints(mesh: ViewerMesh, grid: LatticeVoxelGrid, field: [Float]) -> [Float] {
        let n = grid.nx * grid.ny * grid.nz
        guard field.count == n, mesh.indices.count >= 3 else { return [] }
        let h = Swift.min(grid.spacing.x, Swift.min(grid.spacing.y, grid.spacing.z))
        func pos(_ k: Int32) -> SIMD3<Float> {
            let i = Int(k) * 3
            return SIMD3(mesh.positions[i], mesh.positions[i + 1], mesh.positions[i + 2])
        }
        func sample(_ p: SIMD3<Float>) -> Float {
            let g = (p - grid.origin) / grid.spacing
            let x = Int(g.x.rounded()), y = Int(g.y.rounded()), z = Int(g.z.rounded())
            guard x >= 0, y >= 0, z >= 0, x < grid.nx, y < grid.ny, z < grid.nz else { return 0 }
            return field[(z * grid.ny + y) * grid.nx + x]
        }
        var out = [Float](repeating: 0, count: mesh.indices.count * 8)
        var t = 0
        while t + 2 < mesh.indices.count {
            let a = pos(mesh.indices[t]), b = pos(mesh.indices[t + 1]), c = pos(mesh.indices[t + 2])
            let cr = simd_cross(b - a, c - a)
            let nrm = simd_length(cr) > 1e-12 ? simd_normalize(cr) : SIMD3<Float>(0, 0, 1)
            for (k, p) in [a, b, c].enumerated() {
                let g = Swift.max(sample(p - nrm * (0.6 * h)), sample(p + nrm * (0.6 * h)))
                let o = (t + k) * 8
                if g > 0.03 {
                    out[o] = blueRGBA.x; out[o + 1] = blueRGBA.y; out[o + 2] = blueRGBA.z; out[o + 3] = 0.45 * g
                    out[o + 7] = g
                } else {
                    out[o] = dimRGBA.x; out[o + 1] = dimRGBA.y; out[o + 2] = dimRGBA.z; out[o + 3] = dimRGBA.w
                }
            }
            t += 3
        }
        return out
    }
}
