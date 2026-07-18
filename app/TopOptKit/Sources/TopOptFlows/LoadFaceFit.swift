// LoadFaceFit.swift — the sub-voxel load-face warning + Optimize pre-flight
// (handoff 099, "small-face load loss"), as pure value-type math so it is
// unit-tested headlessly (the M7 /app/ standard); the SwiftUI badge + pre-flight
// gate over it are device QA.
//
// THE PROBLEM. The core voxelizes the part at `resolution` voxels along the
// longest bounding-box axis, so a voxel edge is `spacing = longestAxis /
// resolution` (topopt::voxelize). A load is applied by tagging the solid voxels
// whose centre sits within half a voxel of the selected B-rep face
// (topopt::tag_step_face). A face SMALLER than a voxel footprint can therefore tag
// ZERO voxels: its traction is never built, `external_loads` reaches the solver
// empty, and (correctly) the run is refused. The failure is silent until Optimize.
//
// THE FIX HERE is to SURFACE the risk before the run: at selection time we compare
// the face against the current resolution's spacing and, if it is likely to tag
// nothing, badge it and say so in plain English; at Optimize we block a load case
// in which EVERY group is dead. Both are HEURISTICS — only the voxelizer knows for
// sure whether a given face tags a voxel (alignment matters), so the copy always
// says "may not register", never a certainty. The core's require_external_loads
// guard remains the hard backstop; this only makes the failure legible up front.

import Foundation
import simd

/// A load/anchor face's footprint, measured from the tessellation the viewer holds.
public struct FaceFootprint: Equatable, Sendable {
    /// Total surface area of the face's triangles (mm²).
    public let area: Double
    /// The face's narrowest span within its own plane (mm) — the dimension a voxel
    /// grid is most likely to step over. For a planar face this is exact for any
    /// orientation (measured in the face plane, not the axis-aligned bbox); for a
    /// curved face it is an approximation about the mean normal.
    public let thinnestExtent: Double

    public init(area: Double, thinnestExtent: Double) {
        self.area = area
        self.thinnestExtent = thinnestExtent
    }
}

/// The voxel-fit heuristic: derive the voxelizer's spacing, measure a face, and
/// decide whether it is likely to register a load at that resolution.
public enum VoxelFit {

    /// The voxelizer's cubic edge length `h = longest bbox axis / resolution` (mm) —
    /// EXACTLY topopt::voxelize's spacing, so the app derives the same number the
    /// core will. Nil for a degenerate bound / non-positive resolution.
    public static func spacing(forBounds bounds: MeshBounds, resolution: Int) -> Double? {
        guard !bounds.isEmpty, resolution >= 1 else { return nil }
        let ext = bounds.max - bounds.min
        let longest = Double(Swift.max(ext.x, Swift.max(ext.y, ext.z)))
        guard longest > 0 else { return nil }
        return longest / Double(resolution)
    }

    /// Measure the footprint of B-rep face `face` from the mesh triangles. Nil for an
    /// STL (no face ids), an absent face id, or a degenerate (zero-area) face.
    public static func footprint(ofFace face: FaceID, in mesh: ViewerMesh) -> FaceFootprint? {
        guard !mesh.faceIDs.isEmpty else { return nil }
        var verts: [SIMD3<Float>] = []
        var area: Double = 0
        var normalAccum = SIMD3<Float>.zero
        let idx = mesh.indices
        var t = 0
        while t + 2 < idx.count {
            let tri = t / 3
            if tri < mesh.faceIDs.count, mesh.faceIDs[tri] == face {
                let p0 = position(idx[t], mesh)
                let p1 = position(idx[t + 1], mesh)
                let p2 = position(idx[t + 2], mesh)
                let cross = simd_cross(p1 - p0, p2 - p0)   // ‖·‖ == 2 × area
                area += Double(simd_length(cross)) * 0.5
                normalAccum += cross
                verts.append(p0); verts.append(p1); verts.append(p2)
            }
            t += 3
        }
        guard verts.count >= 3, area > 0 else { return nil }
        let thin = thinnestInPlaneExtent(verts, normal: normalAccum)
        return FaceFootprint(area: area, thinnestExtent: thin)
    }

    /// Safety factor applied to `spacing` in the thresholds. Above 1 it makes the
    /// warning fire a little EARLY, which is the intended bias: a false "may not
    /// register" costs the user only a resolution bump or a larger face, whereas a
    /// MISSED warning is exactly the silent load loss this exists to prevent. Tuned
    /// so a face around one voxel wide is flagged while a face two-plus voxels wide
    /// is not (a Fast-resolution warning clears at Fine on the same face).
    public static let safetyFactor = 1.5

    /// Whether `footprint` is LIKELY to tag zero voxels at `spacing` — the heuristic:
    /// its narrowest in-plane span is under ~one voxel, OR its area is under ~one
    /// voxel footprint (both padded by `safetyFactor`). A heuristic, never a
    /// certainty: tag_step_face's exact result depends on how the face aligns with
    /// the voxel-centre lattice, so callers must phrase this "may not register".
    ///
    /// False positives: a compact face a little over one voxel wide can be flagged
    /// though it would in fact tag a voxel (harmless — the user bumps resolution).
    /// False negatives: a LONG, THIN, TILTED sliver (large area, wide in-plane bbox)
    /// can slip past both tests; the core guard still catches it at run time.
    public static func mayTagZeroVoxels(_ footprint: FaceFootprint, spacing: Double) -> Bool {
        guard spacing > 0 else { return false }
        let t = spacing * safetyFactor
        return footprint.thinnestExtent < t || footprint.area < t * t
    }

    /// The plain-English selection-time warning for a load face likely to tag zero
    /// voxels (deliverable 2). Deliberately hedged ("may not register") — the exact
    /// result is the voxelizer's to give.
    public static func warningText(qualityTitle: String, spacingMM: Double) -> String {
        "This face is smaller than a \(qualityTitle)-quality voxel "
      + "(\(String(format: "%.1f", spacingMM)) mm) — the load may not register. "
      + "Use Balanced or Fine, or pick a larger face."
    }

    /// The short badge line for the selections panel (space-constrained form of
    /// `warningText`).
    public static func badgeText(qualityTitle: String, spacingMM: Double) -> String {
        "May not register at \(qualityTitle) (\(String(format: "%.1f", spacingMM)) mm)"
    }

    // MARK: internals

    private static func position(_ i: UInt32, _ mesh: ViewerMesh) -> SIMD3<Float> {
        let b = Int(i) * 3
        return SIMD3<Float>(mesh.positions[b], mesh.positions[b + 1], mesh.positions[b + 2])
    }

    /// The smaller of the face's two in-plane extents: project every vertex onto an
    /// orthonormal basis (u, v) of the plane ⟂ `normal`, and take min(span_u,
    /// span_v). Measuring in the face plane (rather than the axis-aligned bbox) keeps
    /// a tilted planar face's thin dimension honest. Falls back to the bbox median
    /// extent if the normal is degenerate.
    static func thinnestInPlaneExtent(_ verts: [SIMD3<Float>], normal: SIMD3<Float>) -> Double {
        let nLen = simd_length(normal)
        guard nLen > 1e-12 else { return bboxMedianExtent(verts) }
        let n = normal / nLen
        // Any vector not parallel to n gives an in-plane axis.
        let ref = abs(n.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let u = simd_normalize(simd_cross(ref, n))
        let v = simd_normalize(simd_cross(n, u))
        var uLo = Float.greatestFiniteMagnitude, uHi = -Float.greatestFiniteMagnitude
        var vLo = Float.greatestFiniteMagnitude, vHi = -Float.greatestFiniteMagnitude
        for p in verts {
            let pu = simd_dot(p, u), pv = simd_dot(p, v)
            uLo = Swift.min(uLo, pu); uHi = Swift.max(uHi, pu)
            vLo = Swift.min(vLo, pv); vHi = Swift.max(vHi, pv)
        }
        return Double(Swift.min(uHi - uLo, vHi - vLo))
    }

    /// The median of a vertex set's three axis-aligned extents — the in-plane thin
    /// dimension for an axis-aligned planar face (its along-normal extent is ~0, the
    /// smallest, so the median is the narrower of the two spanning dimensions).
    private static func bboxMedianExtent(_ verts: [SIMD3<Float>]) -> Double {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for p in verts { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let e = hi - lo
        var arr = [e.x, e.y, e.z].sorted()
        return Double(arr[1])
    }
}

/// One load group's pre-run health for the Optimize pre-flight (handoff 099).
public enum LoadGroupHealth: Equatable, Sendable {
    /// The group carries a real force on a face that should tag voxels.
    case ok
    /// The group's total force is (near) zero — nothing to apply.
    case zeroForce
    /// Every face in the group is likely to tag zero voxels at this resolution.
    case mayNotRegister

    /// A group in either non-ok state contributes nothing to the run.
    public var isDead: Bool { self != .ok }
}

/// A named load group's diagnosis, for the pre-flight verdict + copy.
public struct LoadGroupDiagnosis: Equatable, Sendable {
    public let label: String
    public let health: LoadGroupHealth
    public init(label: String, health: LoadGroupHealth) {
        self.label = label
        self.health = health
    }
}

/// The Optimize pre-flight (handoff 099, deliverable 3). Blocks a run whose entire
/// load case would reach the solver empty; warns (but allows) when only some groups
/// are dead; otherwise allows. The messages are actionable and name the group and
/// the fix — never the solver's exception text — because the point is to tell the
/// user what to change (resolution or face), before the run, not after it fails.
public enum LoadCasePreflight {

    public enum Verdict: Equatable, Sendable {
        /// Start the run.
        case allow
        /// Start the run, but show this heads-up (some — not all — groups are dead).
        case warn(String)
        /// Do NOT start; show this actionable message instead.
        case block(String)
    }

    /// Decide the verdict for `diagnoses` at a resolution whose voxel edge is
    /// `spacingMM` (for the copy). No load groups → `.allow` (a self-weight / STL run
    /// is a legitimate mode the core handles). Every group dead → `.block`. Some dead
    /// → `.warn`. None dead → `.allow`.
    public static func evaluate(_ diagnoses: [LoadGroupDiagnosis],
                                qualityTitle: String, spacingMM: Double) -> Verdict {
        guard !diagnoses.isEmpty else { return .allow }
        let dead = diagnoses.filter { $0.health.isDead }
        if dead.isEmpty { return .allow }
        if dead.count == diagnoses.count {
            return .block(blockMessage(dead, qualityTitle: qualityTitle, spacingMM: spacingMM))
        }
        return .warn(warnMessage(dead, qualityTitle: qualityTitle, spacingMM: spacingMM))
    }

    // MARK: copy

    private static func spacingPhrase(_ qualityTitle: String, _ spacingMM: Double) -> String {
        "\(qualityTitle)-quality voxels (\(String(format: "%.1f", spacingMM)) mm)"
    }

    /// The all-dead block copy: name the failing groups + the concrete fix.
    static func blockMessage(_ dead: [LoadGroupDiagnosis],
                             qualityTitle: String, spacingMM: Double) -> String {
        let names = dead.map { "“\($0.label)”" }.joined(separator: ", ")
        let anyTooSmall = dead.contains { $0.health == .mayNotRegister }
        let anyZero = dead.contains { $0.health == .zeroForce }
        var why = "no load can reach the solver"
        if anyTooSmall && !anyZero {
            why = "every load is on a face smaller than \(spacingPhrase(qualityTitle, spacingMM))"
        } else if anyZero && !anyTooSmall {
            why = "every load has zero force"
        }
        var fix = "Increase the resolution (Balanced or Fine)"
        if anyTooSmall { fix += ", pick a larger face" }
        if anyZero { fix += ", set a non-zero weight" }
        return "Can’t optimize — \(why): \(names). \(fix), then run again."
    }

    /// The partial-dead warn copy: proceed, but flag the dead group(s).
    static func warnMessage(_ dead: [LoadGroupDiagnosis],
                            qualityTitle: String, spacingMM: Double) -> String {
        let names = dead.map { "“\($0.label)”" }.joined(separator: ", ")
        let plural = dead.count > 1
        return "Optimizing without \(names): th\(plural ? "ose loads" : "at load") may not "
             + "register at \(spacingPhrase(qualityTitle, spacingMM)). Use Balanced or Fine, "
             + "or a larger face, to include \(plural ? "them" : "it")."
    }
}
