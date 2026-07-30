// LatticeSDFPreview.swift — the geometry + honesty model behind the RAYMARCHED
// lattice preview (handoff 2026-07-29-lattice-preview). Where the density proxy
// (`LatticeDensityProxy`) shades the part surface by relative density, this shows
// the ACTUAL struts — but with zero lattice geometry on the device, exactly like
// the transform gizmo (PR 205): the strut lattice is an analytic distance field,
// so a fragment shader can sphere-trace it per pixel with NO triangles at all. The
// cost is per-pixel and INDEPENDENT of cell size — the scaling property this
// problem needs — where a real lattice mesh grows as (1/cell)³ and blows the iOS
// memory ceiling before a frame is drawn (PR 184 / LatticeDensityProxy).
//
// This file is the PURE, headless-testable half (the /app/ standard): it turns the
// on-device lattice family (`LatticeType`, the faithful mirror of the worker's
// segment tables) into the small centred segment soup the shader tiles, and it
// carries the honest labelling contract. The Metal that consumes it is in
// `LatticeSDFMetal.swift`; the occupancy mask that clips it to the part is in
// `LatticePreviewOccupancy.swift`.
//
// HONESTY (bar P1): a sphere-traced SDF is the TRUE strut geometry, but it is NOT
// the byte-for-byte exported mesh — the marching surface is a smooth iso-surface of
// the analytic field, and node fillets / print-tessellation differ from the
// worker's STL. `isApproximate` is always true and `previewLabel` names it a
// PREVIEW so the maintainer never mistakes it for the export he is about to slice.

import Foundation
import simd

/// One strut segment in CENTRED, cell-normalised coordinates: the cell spans
/// `[-0.5, 0.5]³` and endpoints are the strut ends in that frame. The shader folds a
/// world point into this frame (`p/cell - round(p/cell)`), so one small segment soup
/// tiles the infinite lattice.
///
/// `owner` is the WORKER'S canonical-midpoint ownership, ported exactly: every
/// canonical strut's midpoint lies inside its own cell, so a copy translated by `t`
/// is owned by the neighbouring cell at offset `t`. The shader shows a strut IFF its
/// owning cell is active — whole struts, never razor-cut mid-span — which is
/// precisely how the generator emits geometry (PR 201's segment tables).
public struct LatticeSegment: Equatable, Sendable {
    public var a: SIMD3<Float>
    public var b: SIMD3<Float>
    /// Owning-cell offset from the fold cell, each component in {-1, 0, 1}.
    public var owner: SIMD3<Int32>

    public init(_ a: SIMD3<Float>, _ b: SIMD3<Float>, owner: SIMD3<Int32> = .zero) {
        self.a = a; self.b = b; self.owner = owner
    }

    /// The owner packed as a 0…26 index: (x+1)·9 + (y+1)·3 + (z+1). The shader
    /// prefetches the 27-cell neighbourhood once per marched cell and looks struts up
    /// by this index.
    public var ownerIndex: Int {
        Int(owner.x + 1) * 9 + Int(owner.y + 1) * 3 + Int(owner.z + 1)
    }
}

/// The geometry + honesty model for the raymarched preview of one lattice.
public struct LatticeSDFPreview: Equatable, Sendable {

    public let lattice: LatticeType
    /// The centred segment soup the shader tiles (see `LatticeSegment`). Includes the
    /// struts that cross into the neighbouring cells, so a point folded to the central
    /// cell always has its true-nearest strut in this list (no cell-seam gaps).
    public let segments: [LatticeSegment]

    public init(lattice: LatticeType) {
        self.lattice = lattice
        self.segments = Self.centeredSegments(lattice)
    }

    public init(latticeID: String) { self.init(lattice: LatticeType.named(latticeID)) }

    // MARK: honesty (bar P1)

    /// Always true: a sphere-traced iso-surface of the analytic field is the true
    /// strut TOPOLOGY, but not the byte-identical exported STL (node fillets and print
    /// tessellation differ). The UI must label it.
    public var isApproximate: Bool { true }

    /// The banner the overlay shows so the preview is never read as the export.
    public var previewLabel: String { "LATTICE PREVIEW — live strut geometry, not the exported mesh" }

    // MARK: the grading map the shader radius rides on

    /// The strut radius, in CELL-NORMALISED units (radius / cell), that gives relative
    /// density `rho`. Inverts ρ ≈ K·(r/L)² → r/L = √(ρ/K); because it is normalised it
    /// is cell-size independent — the shader multiplies by the world cell size. Clamped
    /// so a graded field can pass raw densities.
    public func normalizedRadius(relativeDensity rho: Double) -> Float {
        let r = max(0, min(1, rho))
        return Float((r / lattice.densityCoefficient).squareRoot())
    }

    /// The relative density a normalised radius produces (forward map, for reporting).
    public func relativeDensity(normalizedRadius rn: Double) -> Double {
        lattice.densityCoefficient * rn * rn
    }

    // MARK: centred segment generation (faithful to the worker's cell)

    /// Fold the lattice's canonical per-cell struts (in `LatticeType`, integer `L/S`
    /// units) into the centred `[-0.5,0.5]³` frame, replicating across the 3×3×3 block
    /// of neighbouring cells and keeping only the segments that can be NEAREST to some
    /// point in the central cell — those whose distance to the central box `[-0.5,0.5]³`
    /// is below `reach`. This is the minimal correct soup: any q the shader folds into
    /// the central cell has its true-nearest strut in this list, with none of the far
    /// copies that only cost the fragment shader time. Deduped by rounded endpoints.
    /// Derived from the SAME table the worker generates from, so the previewed cell is
    /// the cell that would print.
    ///
    /// `reach` bounds how far outside the cell a nearest strut can be: the emptiest
    /// interior point of an octet-class cell is well under half a cell from a strut, and
    /// the fattest graded strut adds ≈0.14 (√(0.9/K_octet)); 0.30 covers both with margin.
    static func centeredSegments(_ lattice: LatticeType, reach: Float = 0.30) -> [LatticeSegment] {
        let S = Float(lattice.denominator)
        func norm(_ n: LatticeType.Node) -> SIMD3<Float> {
            SIMD3<Float>(Float(n.x) / S - 0.5, Float(n.y) / S - 0.5, Float(n.z) / S - 0.5)
        }
        // Distance² from segment [a,b] to the box [-0.5,0.5]³ (0 if it enters the box):
        // sample the segment finely and take the min point-to-box distance — exact enough
        // for a build-time cull with the generous `reach`.
        func segBoxDist(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            func ptBox(_ p: SIMD3<Float>) -> Float {
                let d = simd_max(simd_abs(p) - SIMD3<Float>(repeating: 0.5), SIMD3<Float>(repeating: 0))
                return simd_length(d)
            }
            var best = Float.greatestFiniteMagnitude
            let steps = 24
            for i in 0...steps {
                let t = Float(i) / Float(steps)
                best = Swift.min(best, ptBox(a + (b - a) * t))
            }
            return best
        }
        var seen = Set<[Int]>()
        var out: [LatticeSegment] = []
        for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
            let t = SIMD3<Float>(Float(dx), Float(dy), Float(dz))
            for s in lattice.struts {
                let a = norm(s.a) + t, b = norm(s.b) + t
                guard segBoxDist(a, b) <= reach else { continue }
                let ka = [Int((a.x * 1e4).rounded()), Int((a.y * 1e4).rounded()), Int((a.z * 1e4).rounded())]
                let kb = [Int((b.x * 1e4).rounded()), Int((b.y * 1e4).rounded()), Int((b.z * 1e4).rounded())]
                let key = ka.lexicographicallyPrecedes(kb) ? ka + kb : kb + ka
                if seen.insert(key).inserted {
                    // Canonical midpoints lie in their own cell, so the copy translated
                    // by t is owned by the cell at offset t — the worker's rule.
                    out.append(LatticeSegment(a, b, owner: SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))))
                }
            }
        } } }
        return out
    }
}
