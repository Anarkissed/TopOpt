// LatticeSamplePatch.swift — the "this is what the cells look like" reference: a
// SMALL block (a few cells) of the lattice at TRUE geometry, so the density colours
// on the part are anchored to something real. This is the deliberate second half of
// the proxy (handoff 2026-07-28-lattice-viewer-proxy): the surface shading says
// where/how-dense, this says what the unit cell physically is. It is a handful of
// cells — never the part — so it stays a few thousand triangles, orders below the
// full lattice the device cannot hold.
//
// The primitives mirror the worker's swept-solid generator (PR-201 /
// 2026-07-27-strut-lattice-family): each strut is a capped regular 8-gon prism
// (16 side + 2×8 cap = 32 triangles), each junction a 20-triangle icosahedron blob.
// The strut RADIUS comes from the SAME grading law the proxy shades by —
// r(ρ) = L·√(ρ/K) — so the patch's thickness is the density it is labelled with.
//
// Pure geometry on Float arrays → a `ViewerMesh`, testable headlessly (no GPU). The
// block is built by tiling the lattice's canonical struts over an N³ grid of cells
// and keeping the ones fully inside the block, deduped by endpoint — the same
// canonical-ownership idea the worker uses, at sample scale.

import Foundation
import simd
import TopOptKit

public enum LatticeSamplePatch {

    /// Build an `cells`³-cell block of `lattice` at cell size `cellMM`, with struts
    /// sized to relative density `relativeDensity` via r = L·√(ρ/K). Returns a
    /// render-ready `ViewerMesh` (smooth-shaded — the struts are round) centred on
    /// the origin. `sides` is the prism cross-section (8 → the worker's 32-tri strut).
    public static func mesh(lattice: LatticeType, cellMM: Double, cells: Int,
                            relativeDensity: Double, sides: Int = 8) -> ViewerMesh {
        let n = max(1, cells)
        let S = lattice.denominator
        let unit = Float(cellMM) / Float(S)                 // world mm per integer step
        let radius = Float(lattice.strutRadiusMM(relativeDensity: relativeDensity, cellMM: cellMM))
        let extent = n * S                                   // block spans [0, extent] in L/S units

        // Collect the block's struts: tile canonical struts over the cell grid (plus a
        // one-cell ghost margin to close the high faces), keep those fully inside the
        // block box, dedup by ordered endpoint key.
        var segSet = Set<[Int]>()
        var segments: [(LatticeType.Node, LatticeType.Node)] = []
        var nodeSet = Set<[Int]>()
        var nodePts: [LatticeType.Node] = []

        func consider(_ a0: LatticeType.Node, _ b0: LatticeType.Node) {
            // inside the closed block box
            func inside(_ p: LatticeType.Node) -> Bool {
                p.x >= 0 && p.x <= extent && p.y >= 0 && p.y <= extent && p.z >= 0 && p.z <= extent
            }
            guard inside(a0), inside(b0) else { return }
            let a = a0, b = b0
            let key = order(a, b)
            if segSet.insert(key).inserted { segments.append((a, b)) }
            for p in [a, b] {
                let nk = [p.x, p.y, p.z]
                if nodeSet.insert(nk).inserted { nodePts.append(p) }
            }
        }

        for cz in -1...n { for cy in -1...n { for cx in -1...n {
            let ox = cx * S, oy = cy * S, oz = cz * S
            for s in lattice.struts {
                let a = LatticeType.Node(s.a.x + ox, s.a.y + oy, s.a.z + oz)
                let b = LatticeType.Node(s.b.x + ox, s.b.y + oy, s.b.z + oz)
                consider(a, b)
            }
        } } }

        var pos: [Float] = []
        var idx: [Int32] = []

        func world(_ p: LatticeType.Node) -> SIMD3<Float> {
            SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z)) * unit
                - SIMD3<Float>(repeating: Float(extent) * unit * 0.5)   // centre the block
        }

        for (a, b) in segments { emitStrut(world(a), world(b), radius: radius, sides: sides, pos: &pos, idx: &idx) }
        for p in nodePts { emitNode(world(p), radius: radius, pos: &pos, idx: &idx) }

        return ViewerMesh(vertices: pos, indices: idx, faceIDs: [], smoothShaded: true)
    }

    /// The triangle count of a patch WITHOUT allocating its full mesh — for the cost
    /// table (V1) and to size the inset. tris = struts·(sides·4) + nodes·20.
    public static func triangleCount(lattice: LatticeType, cells: Int, sides: Int = 8) -> Int {
        let m = counts(lattice: lattice, cells: cells)
        return m.struts * sides * 4 + m.nodes * 20
    }

    /// Strut and node counts of the block (the same tiling/dedup as `mesh`, integers
    /// only — cheap).
    public static func counts(lattice: LatticeType, cells: Int) -> (struts: Int, nodes: Int) {
        let n = max(1, cells)
        let S = lattice.denominator
        let extent = n * S
        var segSet = Set<[Int]>()
        var nodeSet = Set<[Int]>()
        func inside(_ p: LatticeType.Node) -> Bool {
            p.x >= 0 && p.x <= extent && p.y >= 0 && p.y <= extent && p.z >= 0 && p.z <= extent
        }
        for cz in -1...n { for cy in -1...n { for cx in -1...n {
            let ox = cx * S, oy = cy * S, oz = cz * S
            for s in lattice.struts {
                let a = LatticeType.Node(s.a.x + ox, s.a.y + oy, s.a.z + oz)
                let b = LatticeType.Node(s.b.x + ox, s.b.y + oy, s.b.z + oz)
                guard inside(a), inside(b) else { continue }
                if segSet.insert(order(a, b)).inserted {
                    nodeSet.insert([a.x, a.y, a.z]); nodeSet.insert([b.x, b.y, b.z])
                }
            }
        } } }
        return (segSet.count, nodeSet.count)
    }

    // MARK: primitives (mirror the worker's swept solid)

    private static func order(_ a: LatticeType.Node, _ b: LatticeType.Node) -> [Int] {
        let ka = [a.x, a.y, a.z], kb = [b.x, b.y, b.z]
        return (kb.lexicographicallyPrecedes(ka)) ? kb + ka : ka + kb
    }

    /// A capped regular `sides`-gon prism from `p0` to `p1`, radius `r`: `sides` side
    /// quads (2 tris each) + two `sides`-triangle end-cap fans = `sides·4` triangles.
    private static func emitStrut(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, radius r: Float,
                                  sides: Int, pos: inout [Float], idx: inout [Int32]) {
        let axis = p1 - p0
        let len = simd_length(axis)
        guard len > 1e-6, r > 1e-6 else { return }
        let w = axis / len
        let (u, v) = orthonormalBasis(w)
        let base = Int32(pos.count / 3)

        func push(_ p: SIMD3<Float>) { pos.append(p.x); pos.append(p.y); pos.append(p.z) }

        // ring 0 (at p0) then ring 1 (at p1)
        for ring in 0..<2 {
            let c = ring == 0 ? p0 : p1
            for s in 0..<sides {
                let a = 2 * Float.pi * Float(s) / Float(sides)
                push(c + (u * cos(a) + v * sin(a)) * r)
            }
        }
        let cap0 = Int32(pos.count / 3); push(p0)
        let cap1 = Int32(pos.count / 3); push(p1)

        func ringIndex(_ ring: Int, _ s: Int) -> Int32 { base + Int32(ring * sides + (s % sides)) }
        for s in 0..<sides {
            let a0 = ringIndex(0, s), a1 = ringIndex(0, s + 1)
            let b0 = ringIndex(1, s), b1 = ringIndex(1, s + 1)
            idx += [a0, b0, b1,  a0, b1, a1]                  // side quad
            idx += [cap0, a1, a0]                              // p0 cap fan
            idx += [cap1, b0, b1]                              // p1 cap fan
        }
    }

    /// A 20-triangle icosahedron of radius `r` at `c` (the junction blob).
    private static func emitNode(_ c: SIMD3<Float>, radius r: Float, pos: inout [Float], idx: inout [Int32]) {
        guard r > 1e-6 else { return }
        let t = Float((1.0 + 5.0.squareRoot()) / 2.0)
        var verts: [SIMD3<Float>] = [
            SIMD3(-1, t, 0), SIMD3(1, t, 0), SIMD3(-1, -t, 0), SIMD3(1, -t, 0),
            SIMD3(0, -1, t), SIMD3(0, 1, t), SIMD3(0, -1, -t), SIMD3(0, 1, -t),
            SIMD3(t, 0, -1), SIMD3(t, 0, 1), SIMD3(-t, 0, -1), SIMD3(-t, 0, 1),
        ]
        let faces: [(Int, Int, Int)] = [
            (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11),
            (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
            (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
            (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1),
        ]
        for i in verts.indices { verts[i] = simd_normalize(verts[i]) * r + c }
        let base = Int32(pos.count / 3)
        for p in verts { pos.append(p.x); pos.append(p.y); pos.append(p.z) }
        for f in faces { idx += [base + Int32(f.0), base + Int32(f.1), base + Int32(f.2)] }
    }

    /// Two unit vectors perpendicular to unit `w` (a stable orthonormal frame).
    private static func orthonormalBasis(_ w: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let ref: SIMD3<Float> = abs(w.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let u = simd_normalize(simd_cross(ref, w))
        let v = simd_cross(w, u)
        return (u, v)
    }
}
