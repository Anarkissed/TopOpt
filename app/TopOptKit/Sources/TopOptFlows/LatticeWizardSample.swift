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
// ★ B8 (his answer 2026-10-24): the full-screen settings page that drew the cantilever sample is DELETED, and the
// cantilever with it (its size, its baked field, its tint, its densest point, its disclaimer). What stays is `cube`: the
// organic sample's 40 mm body, which the organic variant path (`OrganicSampleCube`) still clips its march to.
//
// Pure value types + arithmetic, so the sample is headlessly testable.

import Foundation
import simd

public enum LatticeWizardSample {

    /// ★ THE ORGANIC SAMPLE'S BODY: the PR 353 test cube's own 40 mm box, centred on
    /// the origin like the span file's grid (`GRID 0 0 0 0.625 64 64 64` ⇒ 0…40 mm), so
    /// it is placed at the spans' coordinates, not the origin's. Drawn at body alpha 0;
    /// it exists to clip the march to the part exactly as a run's part does.
    public static func cube(edgeMM: Double, at origin: SIMD3<Float>, subdiv: Int = 6) -> ViewerMesh {
        let e = Float(edgeMM)
        return box(sx: e, sy: e, sz: e, subdiv: subdiv, origin: origin)
    }

    private static func box(sx: Float, sy: Float, sz: Float, subdiv: Int,
                            origin: SIMD3<Float>? = nil) -> ViewerMesh {
        let n = max(2, subdiv)
        var pos: [Float] = []
        var idx: [Int32] = []

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
        let o = origin ?? SIMD3<Float>(-sx / 2, -sy / 2, -sz / 2)
        addFace(origin: o, u: X, v: Y)                    // bottom
        addFace(origin: o + Z, u: Y, v: X)                // top
        addFace(origin: o, u: Z, v: X)                    // front
        addFace(origin: o + Y, u: X, v: Z)                // back
        addFace(origin: o, u: Y, v: Z)                    // root
        addFace(origin: o + X, u: Z, v: Y)                // tip
        return ViewerMesh(vertices: pos, indices: idx, faceIDs: [], smoothShaded: false)
    }
}
