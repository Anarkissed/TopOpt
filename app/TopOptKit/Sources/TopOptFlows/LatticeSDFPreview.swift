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

/// Face-role tints ON the lattice (2026-07-30 alignment handoff, bar A4). With the
/// body no longer drawn while the strut preview is up (bar A3), the anchor / load /
/// keep-clear / protect face markings must read on the LATTICE instead. This bakes
/// the mesh view's own `[FaceID: color]` tint dictionary — the single source of
/// truth, no second colour table — into an rgba8 volume on the part-SDF grid: every
/// marked face's triangles stamp their surface voxels (plus the 6-neighbourhood, so
/// the flush-trim's 0.35-voxel erosion still lands inside the stamped shell) with
/// the face's colour. The shader tints a hit by a trilinear sample of this volume.
/// Pure CPU math, headless-testable (the /app/ standard).
public enum LatticeFaceTintVolume {

    /// Bake the tint volume: rgba8 bytes (x fastest, then y, then z — the 3D-texture
    /// layout), one voxel per cell of `grid`. Returns nil when nothing is marked, so
    /// the caller can drop the texture entirely. Colours pass through VERBATIM
    /// (quantised to unorm8) — `LatticeSDFAlignmentTests` asserts the round-trip.
    public static func bake(mesh: ViewerMesh, tints: [FaceID: SIMD4<Float>],
                            like grid: LatticeVoxelGrid) -> [UInt8]? {
        guard !tints.isEmpty, !mesh.faceIDs.isEmpty, grid.count > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: grid.count * 4)
        var any = false
        let minSpacing = Swift.min(grid.spacing.x, Swift.min(grid.spacing.y, grid.spacing.z))
        let sampleStep = Swift.max(1e-4, 0.5 * minSpacing)

        func stamp(_ p: SIMD3<Float>, _ c: SIMD4<Float>) {
            let g = (p - grid.origin) / grid.spacing
            let vx = Int(g.x.rounded()), vy = Int(g.y.rounded()), vz = Int(g.z.rounded())
            // The voxel containing the surface point plus its 6-neighbourhood: the
            // shader samples at flush-trimmed hits ~0.35 voxel INSIDE the face, so
            // the stamped shell must be one voxel thick toward the interior too.
            for (dx, dy, dz) in [(0, 0, 0), (1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)] {
                let x = vx + dx, y = vy + dy, z = vz + dz
                guard x >= 0, x < grid.nx, y >= 0, y < grid.ny, z >= 0, z < grid.nz else { continue }
                let n = ((z * grid.ny + y) * grid.nx + x) * 4
                out[n] = UInt8((Swift.max(0, Swift.min(1, c.x)) * 255).rounded())
                out[n + 1] = UInt8((Swift.max(0, Swift.min(1, c.y)) * 255).rounded())
                out[n + 2] = UInt8((Swift.max(0, Swift.min(1, c.z)) * 255).rounded())
                out[n + 3] = 255
                any = true
            }
        }

        // Deterministic: triangles in index order; a voxel shared by two marked faces
        // takes the later triangle's colour (the same arbitrary-at-the-seam behaviour
        // the body's per-vertex tint has at a face edge).
        let triCount = Swift.min(mesh.triangleCount, mesh.faceIDs.count)
        for t in 0..<triCount {
            guard let color = tints[mesh.faceIDs[t]] else { continue }
            let i0 = Int(mesh.indices[3 * t]), i1 = Int(mesh.indices[3 * t + 1]), i2 = Int(mesh.indices[3 * t + 2])
            func v(_ i: Int) -> SIMD3<Float> {
                SIMD3<Float>(mesh.positions[3 * i], mesh.positions[3 * i + 1], mesh.positions[3 * i + 2])
            }
            let p0 = v(i0), e1 = v(i1) - p0, e2 = v(i2) - p0
            let n1 = Swift.max(1, Int((simd_length(e1) / sampleStep).rounded(.up)))
            let n2 = Swift.max(1, Int((simd_length(e2) / sampleStep).rounded(.up)))
            for a in 0...n1 {
                let fa = Float(a) / Float(n1)
                for b in 0...n2 {
                    let fb = Float(b) / Float(n2)
                    guard fa + fb <= 1.0001 else { break }
                    stamp(p0 + e1 * fa + e2 * fb, color)
                }
            }
        }
        return any ? out : nil
    }
}

/// ★ §5(b) — WHAT THE OVERLAY SAYS, INCLUDING WHEN IT HAS NOTHING TO SAY IT ABOUT
/// (task 2026-08-18-lattice-preview-confetti).
///
/// The banner used to be one string with one condition: `if showStrutPreview, let
/// scene = strutScene`. Read the other way round, that is a preview which — when
/// there is no scene to draw — says NOTHING AT ALL. Turn it on with no mesh, or
/// during the second the bake takes, or on a part with no interior, and the toggle
/// reads "on", the viewport is unchanged, and the user is left to conclude the
/// feature is broken. The maintainer lost two sessions to a silent preview, and the
/// silence is a defect in its own right, independent of what caused the emptiness.
///
/// So the banner is a TOTAL function of the state now: every state the preview can
/// be in has a sentence, and the sentence says WHY.
public enum LatticePreviewBanner: Equatable, Sendable {
    /// There is strut geometry and it is being drawn. Carries the honesty label
    /// (bar P1) unchanged — this is the string that shipped.
    case drawing(String)
    /// There is nothing to draw, and this is the reason, in plain words.
    case empty(String)

    public var text: String {
        switch self {
        case .drawing(let t), .empty(let t): return t
        }
    }

    public var isEmpty: Bool {
        if case .empty = self { return true }
        return false
    }

    /// The banner for the current state, or nil when the preview is off (then there
    /// is no banner at all, which is correct — the user has not asked for one).
    ///
    /// ★ NO JARGON, AND UNDER ~25 WORDS EACH (§5c). Not "occupancy", not "SDF", not
    /// "marched": a user who turned a toggle on is owed a sentence they can act on.
    public static func make(previewOn: Bool,
                            hasModel: Bool,
                            scene: LatticeSDFPreviewSummary?) -> LatticePreviewBanner? {
        guard previewOn else { return nil }
        guard hasModel else {
            return .empty("No lattice to show — there is no model open yet.")
        }
        guard let scene else {
            return .empty("Building the strut preview — this takes a moment.")
        }
        // ★ THE PART ITSELF HAS NOTHING TO FILL — a broken import or a shell with
        // no interior. No setting the user can reach will change this.
        guard scene.partInteriorVoxelCount > 0 else {
            return .empty("No lattice to show — this part has no inside to fill with struts.")
        }
        // ★★ THE REGIONS MATCHED NOTHING (bar 4 of the preview-regions task: "If
        // the mask yields ZERO active cells, it must say so, not render an empty
        // part").
        //
        // ★ THIS IS A DIFFERENT FINDING FROM THE ONE ABOVE and has a different
        // fix: the part is fine, the declaration is not reaching any material —
        // a depth set too shallow, or a face whose slab sits outside the solid.
        // Reporting "this part has no inside" for it would be a confident wrong
        // answer, and it is the one the user would act on.
        guard scene.interiorVoxelCount > 0 else {
            return .empty("Nothing to lattice — the faces you marked do not reach "
                          + "any material. Try a deeper slab.")
        }
        // ★ DRAWING, BUT NOT ALL OF IT. A skipped face means the preview shows
        // LESS than was marked, and the whole point of masking the preview is
        // that it stops over-promising — under-promising in silence is the same
        // defect wearing the other sign.
        if scene.skippedFaces > 0 {
            return .drawing(scene.previewLabel + " · "
                            + "\(scene.skippedFaces) marked "
                            + (scene.skippedFaces == 1 ? "face has" : "faces have")
                            + " no shape to lattice and are not shown")
        }
        return .drawing(scene.previewLabel)
    }
}

/// The little the banner needs to know about a baked scene — so the decision above is
/// pure and testable without a GPU, a mesh or a Metal device anywhere near it.
public struct LatticePreviewSummaryValues: Equatable, Sendable {
    public var interiorVoxelCount: Int
    public var previewLabel: String
    /// ★ Defaults keep every existing construction meaning what it did: a part
    /// with an interior, and no skipped faces.
    public var partInteriorVoxelCount: Int
    public var skippedFaces: Int
    public init(interiorVoxelCount: Int, previewLabel: String,
                partInteriorVoxelCount: Int? = nil, skippedFaces: Int = 0) {
        self.interiorVoxelCount = interiorVoxelCount
        self.previewLabel = previewLabel
        self.partInteriorVoxelCount = partInteriorVoxelCount ?? interiorVoxelCount
        self.skippedFaces = skippedFaces
    }
}

/// What a baked scene can answer for the banner. `LatticeSDFScene` conforms.
public protocol LatticeSDFPreviewSummary {
    /// Voxels of the part's own interior in the baked occupancy grid. Zero means the
    /// solid voxelisation found nothing to fill — there is no lattice, at any setting.
    var interiorVoxelCount: Int { get }
    /// The part's own interior BEFORE the region mask.
    var partInteriorVoxelCount: Int { get }
    /// Faces marked by the user that the emission could not use.
    var skippedFaces: Int { get }
    var previewLabel: String { get }
}

extension LatticePreviewSummaryValues: LatticeSDFPreviewSummary {}

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
