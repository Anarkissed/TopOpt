// LatticeWizardSample.swift — ★ THE SAMPLE, AND ONLY THE SAMPLE
// (task 2026-08-12-lattice-page-redesign §3a).
//
// THE MAINTAINER'S RULING, VERBATIM: "it's literally just a SAMPLE… it's about
// the lattice SETTINGS nothing else. NOT what will be." So this is a FIXED part
// with a PRE-COMPUTED field, baked in. ★ NO FEA RUNS TO DRAW A PREVIEW.
//
// WHY IT IS COMPILED IN RATHER THAN A FILE ON DISK. It has to be on screen in the
// first frame of the page, and a resource load — bundle lookup, decode, upload —
// is the one cost that cannot be hidden behind an animation. The mesh is 8 fixed
// corner coordinates and the field is a closed-form evaluation over them, both
// committed here as constants: loading it is arithmetic, not I/O. It is an asset
// in every sense that matters (fixed, versioned, reviewed, not a solve); it just
// does not need a file to be one.
//
// THE FIELD IS A CANTILEVER'S BENDING STRESS, evaluated once per vertex:
// |sigma| ∝ (L − x)·|z − z_mid|, normalised to [0, 1]. It is the textbook field
// for the textbook shape — high at the root, high at the skins, low at the tip
// and low on the neutral axis. That is exactly the picture the density-follows-
// stress explanation needs, and it is honest about being a sample and nothing
// more: `provenanceNote` says so in nine words.
//
// Pure value types + arithmetic, so the sample is headlessly testable.

import Foundation
import simd

public enum LatticeWizardSample {

    /// The sample's own size (mm). A stubby cantilever — big enough that a 2–8 mm
    /// cell tiles it visibly, small enough that tessellating it is trivial.
    public static let lengthMM = 60.0
    public static let widthMM = 20.0
    public static let heightMM = 24.0

    /// Nine words. The whole disclaimer (§3b) — not a paragraph, not a banner.
    public static let provenanceNote = "A sample part. Your settings, not your result."

    /// The sample's triangle mesh: a rectangular cantilever, subdivided so the
    /// per-vertex stress tint has somewhere to land. `subdiv` cells per axis.
    public static func mesh(subdiv: Int = 12) -> ViewerMesh {
        let n = max(2, subdiv)
        var pos: [Float] = []
        var idx: [Int32] = []
        let sx = Float(lengthMM), sy = Float(widthMM), sz = Float(heightMM)

        // A subdivided box: six faces, each an n×n grid, so vertices are dense
        // enough for the field to read as a gradient rather than four corners.
        func addFace(origin: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>) {
            let base = Int32(pos.count / 3)
            for j in 0...n {
                for i in 0...n {
                    let p = origin + u * (Float(i) / Float(n)) + v * (Float(j) / Float(n))
                    pos += [p.x, p.y, p.z]
                }
            }
            let row = Int32(n + 1)
            for j in 0..<Int32(n) {
                for i in 0..<Int32(n) {
                    let a = base + j * row + i
                    idx += [a, a + 1, a + row + 1, a, a + row + 1, a + row]
                }
            }
        }
        let X = SIMD3<Float>(sx, 0, 0), Y = SIMD3<Float>(0, sy, 0), Z = SIMD3<Float>(0, 0, sz)
        let o = SIMD3<Float>(-sx / 2, -sy / 2, -sz / 2)
        addFace(origin: o, u: X, v: Y)                    // bottom
        addFace(origin: o + Z, u: Y, v: X)                // top
        addFace(origin: o, u: Z, v: X)                    // front
        addFace(origin: o + Y, u: X, v: Z)                // back
        addFace(origin: o, u: Y, v: Z)                    // root
        addFace(origin: o + X, u: Z, v: Y)                // tip
        return ViewerMesh(vertices: pos, indices: idx, faceIDs: [], smoothShaded: false)
    }

    /// The BAKED field, one normalised value in [0, 1] per vertex of `mesh`.
    /// Closed form, no solve: bending stress in a cantilever loaded at the tip.
    public static func stress(for mesh: ViewerMesh) -> [Float] {
        let p = mesh.positions
        let count = p.count / 3
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        let halfL = Float(lengthMM) / 2, halfH = Float(heightMM) / 2
        var peak: Float = 0
        for i in 0..<count {
            let x = p[i * 3], z = p[i * 3 + 2]
            // Moment falls linearly from the root (x = -L/2) to the tip; the
            // fibre stress rises linearly from the neutral axis to the skins.
            let moment = max(0, (halfL - x)) / Float(lengthMM)
            let fibre = abs(z) / max(1e-6, halfH)
            let s = moment * fibre
            out[i] = s
            peak = max(peak, s)
        }
        if peak > 0 { for i in 0..<count { out[i] /= peak } }
        return out
    }

    /// The field as the renderer's per-vertex tint (`MetalMeshView.stressTints`),
    /// through the SAME density ramp the lattice overlay uses — one colour
    /// language across the app, never a second table.
    public static func stressTints(for mesh: ViewerMesh) -> [SIMD4<Float>] {
        stress(for: mesh).map { s in
            let c = LatticeDensityProxy.densityColor(fraction: Double(s))
            return SIMD4<Float>(Float(c.r), Float(c.g), Float(c.b), 1)
        }
    }

    /// Where the field is DENSEST — the point the "dive into the denser part"
    /// move flies to (§2 Stage C). Derived from the baked field, never guessed.
    public static func densestPoint(for mesh: ViewerMesh) -> SIMD3<Float> {
        let f = stress(for: mesh)
        let p = mesh.positions
        var best = 0, bestV: Float = -1
        for i in 0..<f.count where f[i] > bestV { bestV = f[i]; best = i }
        guard best * 3 + 2 < p.count else { return .zero }
        return SIMD3<Float>(p[best * 3], p[best * 3 + 1], p[best * 3 + 2])
    }
}
