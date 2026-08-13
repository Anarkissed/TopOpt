// LatticeRegionEmission.swift — build the job's `lattice.regions` entries from the
// ONE selection model (round-2, the headline item + M3).
//
// PR 256 landed `lattice.regions` in the core job schema (role include|exclude,
// kind bolt|face, strictly validated at job.cpp:805-876) and PR 254's page copy
// claiming "core's schema carries no region yet" went stale. This file is the
// emission that was missing: it maps
//   • a selection GROUP carrying a lattice role (LatticeSettings.groupRoles —
//     an attribute on the TO page's own groups, never a second group store):
//       – each of the group's manual primitives → a bolt/face region entry;
//       – each of the group's B-rep faces → a region entry synthesised from the
//         face's exact geometry (cylinder → bolt, plane → face slab, the same
//         numbers `convertAutoClearanceToManual` materialises);
//   • the LEGACY include primitives (LatticeSettings.includePrimitives) →
//     role=include entries, so pre-round-2 projects gain the emission too
// onto the exact wire shape core accepts. Entries core would refuse (zero
// extents, no usable geometry — e.g. an STL pseudo-face with no B-rep surface)
// are SKIPPED and counted, never emitted broken.
//
// Pure derivation over value types: mesh geometry arrives through a small
// resolved-face closure so the whole mapping is headlessly unit-tested (M3).

import Foundation
import simd

public enum LatticeRegionEmission {

    /// A face's resolved geometry, as the synthesis needs it. Supplied by the
    /// caller (ProjectModel reads the viewer mesh); nil when the face has no
    /// usable B-rep surface (STL pseudo-face, cone, spline…).
    public enum ResolvedFace {
        /// A cylindrical face: its axis, radius, and through-part axial span.
        case cylinder(axisPoint: SIMD3<Double>, axisDir: SIMD3<Double>,
                      radiusMM: Double, spanLoMM: Double, spanHiMM: Double)
        /// A planar face: its fitted outline centre, outward normal, half-extents.
        case plane(center: SIMD3<Double>, normal: SIMD3<Double>,
                   halfUMM: Double, halfWMM: Double)
    }

    public struct Result: Equatable, Sendable {
        public let regions: [LatticeRegionSpec]
        /// Faces that could not be synthesised (no usable B-rep geometry) — counted
        /// so the surface can say so instead of silently emitting less than marked.
        public let skippedFaces: Int
    }

    /// One manual primitive → one region entry with `role`. `depthMM` is the
    /// slab depth a face-kind region needs (core requires depth_mm > 0), ALREADY
    /// RESOLVED by the caller through the same `clearanceMetric` chain the chips
    /// and the rendered volume read — run == picture == chips (DEFECT 1). A bolt
    /// region ignores it. The primitive IS the region: no margins are added.
    public static func spec(for p: ManualPrimitive, role: LatticeGroupRole,
                            depthMM: Double) -> LatticeRegionSpec? {
        switch p.kind {
        case .bolt:
            var s = LatticeRegionSpec(role: role, kind: .bolt)
            s.axisPoint = p.center
            s.axisDir = p.axis
            s.radiusMM = p.radiusMM
            s.halfLengthMM = p.halfLengthMM
            return s.isValid ? s : nil
        case .face:
            var s = LatticeRegionSpec(role: role, kind: .face)
            s.origin = p.center
            s.normal = p.axis
            s.halfUMM = p.halfUMM
            s.halfWMM = p.halfWMM
            s.depthMM = depthMM
            return s.isValid ? s : nil
        }
    }

    /// One resolved B-rep face → one region entry with `role`. A cylinder becomes a
    /// bolt region over its exact axial span; a plane becomes a face slab reaching
    /// `depthMM` into the part (the depth the user dragged that face's primitive
    /// to). `faceID` rides along so core can check the depth tie (§0a).
    public static func spec(for face: ResolvedFace, role: LatticeGroupRole,
                            depthMM: Double, faceID: Int? = nil)
        -> LatticeRegionSpec? {
        switch face {
        case .cylinder(let axisPoint, let axisDir, let radius, let lo, let hi):
            var s = LatticeRegionSpec(role: role, kind: .bolt)
            s.faceID = faceID
            let dir = ManualPrimitive.unit(axisDir)
            let mid = 0.5 * (lo + hi)
            s.axisPoint = axisPoint + dir * mid
            s.axisDir = dir
            s.radiusMM = radius
            s.halfLengthMM = 0.5 * (hi - lo)
            return s.isValid ? s : nil
        case .plane(let center, let normal, let halfU, let halfW):
            var s = LatticeRegionSpec(role: role, kind: .face)
            s.faceID = faceID
            // Core's slab runs origin + s·normal, s ∈ [0, depth]. The part's
            // material lies OPPOSITE the outward face normal, so flip it — the
            // slab must reach INTO the part, not out of it.
            s.origin = center
            s.normal = -ManualPrimitive.unit(normal)
            s.halfUMM = halfU
            s.halfWMM = halfW
            s.depthMM = depthMM
            return s.isValid ? s : nil
        }
    }

    /// The full emission for a project state. `primitives` supplies each role
    /// group's manual primitives WITH their resolved slab depth (the caller reads
    /// the same metric chain the chips do); `resolve` supplies each face's exact
    /// geometry (nil → skipped + counted). Group order and face order are the
    /// selection's own, so the emission is deterministic.
    ///
    /// ★ `groupDepthMM` is THE ONE NUMBER (task 2026-08-12 §0a): the depth the
    /// user dragged THAT group's primitive to, which is also the depth its faces
    /// are protected to. `faceDepthMM` remains only as the fallback for a group
    /// the user has never dragged.
    /// ★ `selectableRoles` and `selectableDepthMM` are the PER-PRIMITIVE overrides
    /// (task 2026-08-14-lattice-separation §3c/§3d), keyed by
    /// `LatticeSelectableRef.key`. Empty ⇒ every primitive follows its group ⇒ the
    /// emission is byte-identical to the one before the separation, which is why
    /// they default to empty rather than being threaded through every call site.
    ///
    /// A group with no declaration still contributes nothing: the eligibility gate
    /// (§1a — only a roled face may be latticed) lives on the GROUP, and a
    /// per-primitive override must not be a way around it.
    public static func regions(groups: [SelectionGroup],
                               roles: [UUID: LatticeGroupRole],
                               primitives: (UUID) -> [(prim: ManualPrimitive, depthMM: Double)],
                               includePrimitives: [(prim: ManualPrimitive, depthMM: Double)],
                               faceDepthMM: Double,
                               groupDepthMM: (UUID) -> Double = { _ in .nan },
                               runFaceID: @escaping (FaceID) -> Int = { Int($0) },
                               selectableRoles: [String: LatticeSelectableRole] = [:],
                               selectableDepthMM: [String: Double] = [:],
                               resolve: (FaceID) -> ResolvedFace?) -> Result {
        var out: [LatticeRegionSpec] = []
        var skipped = 0
        for (p, d) in includePrimitives {
            if let s = spec(for: p, role: .include, depthMM: d) { out.append(s) }
        }
        for g in groups {
            guard let groupRole = roles[g.id] else { continue }
            let gd = groupDepthMM(g.id)
            let groupDepth = gd.isFinite ? gd : faceDepthMM
            for (p, d) in primitives(g.id) {
                let ref = LatticeSelectableRef.primitive(p.id)
                guard let role = LatticeSelectableRoles.role(
                    for: ref, groupRole: groupRole, overrides: selectableRoles) else { continue }
                // A manual primitive carries its own resolved depth already (the
                // clearance-metric chain); the per-primitive override wins over it
                // exactly as it does for a face.
                if let s = spec(for: p, role: role,
                                depthMM: selectableDepthMM[ref.key] ?? d) {
                    out.append(s)
                }
            }
            for f in g.faces {
                let ref = LatticeSelectableRef.face(group: g.id, face: f)
                guard let role = LatticeSelectableRoles.role(
                    for: ref, groupRole: groupRole, overrides: selectableRoles) else { continue }
                let depth = selectableDepthMM[ref.key] ?? groupDepth
                if let r = resolve(f),
                   let s = spec(for: r, role: role, depthMM: depth,
                                faceID: runFaceID(f)) {
                    out.append(s)
                } else {
                    skipped += 1
                }
            }
        }
        return Result(regions: out, skippedFaces: skipped)
    }
}
