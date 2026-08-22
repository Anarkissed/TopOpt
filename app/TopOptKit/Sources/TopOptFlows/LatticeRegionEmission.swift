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
        /// ★ `outlineLoops` IS THE FACE ITSELF, in the plane's (u, v) mm relative
        /// to `center` — see `LatticeFaceOutline`. The half-extents are its
        /// BOUNDING BOX and are kept because core still reads them; on a face with
        /// anything cut out of it they overstate the region badly (41.2% and 29.8%
        /// correct on his two lattice walls), which is why the loops now ride
        /// along. Empty ⇒ the rectangle, exactly as before.
        case plane(center: SIMD3<Double>, normal: SIMD3<Double>,
                   halfUMM: Double, halfWMM: Double,
                   outlineLoops: [[SIMD2<Double>]] = [])
    }

    /// The planar `ResolvedFace` the app builds, in ONE place, so a test cannot
    /// accidentally construct it in a different frame from production's.
    public static func planeFor(face: FaceID, in mesh: ViewerMesh) -> ResolvedFace? {
        guard let geo = mesh.faceGeometry(Int32(face)), geo.isPlane,
              let o = mesh.facePlaneOutline(face,
                                            planeNormal: SIMD3<Float>(geo.planeNormal),
                                            planeOrigin: SIMD3<Float>(geo.planeOrigin))
        else { return nil }
        return .plane(center: SIMD3<Double>(o.center), normal: geo.planeNormal,
                      halfUMM: Double(o.halfU), halfWMM: Double(o.halfV),
                      // ★★★ IN THE **FACE'S** FRAME, WHICH IS WHAT `spec` ASSUMES — and
                      // this passed the INWARD normal, so the mirror was applied TWICE.
                      //
                      // ★ `LatticeFaceOutline.loops` projects into `basis(whatever it is
                      // handed)`. Handed `-planeNormal` it produces loops already in the
                      // SLAB's frame; `spec(for:.plane:)` then re-expresses them from
                      // `basis(+normal)` into `basis(-normal)` a second time. Two
                      // mirrors where one was intended is a mirror, so the outline
                      // landed reflected about v — on his own faces, 33 of 61 and 31 of
                      // 73 of each face's OWN centroids fell OUTSIDE the region that
                      // face declares. Near chance, which is the reflected signature
                      // (`testTheFacesOwnSurfaceIsInsideItsOwnRegion`).
                      //
                      // ★ THE CONVERSION IN `spec` IS THE RIGHT PLACE FOR IT — it is
                      // written down, argued and tested there. This side simply has to
                      // hand it what it says it takes: the face's own outward frame.
                      outlineLoops: LatticeFaceOutline.loops(
                          face: face, in: mesh,
                          normal: ManualPrimitive.unit(geo.planeNormal),
                          origin: SIMD3<Double>(o.center)))
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
    /// ★ `expandMM` GROWS THE SLAB IN PLANE ONLY (maintainer, 2026-08-17) — the
    /// two half-extents perpendicular to the depth, never the depth itself. A
    /// face's slab is exactly that face's outline, so a chamfer just off its edge
    /// is outside it; this reaches past the outline to take the surrounding wall
    /// in. A BOLT region has no in-plane extents to grow — its radius is its
    /// shape — so it ignores the value rather than pretending to widen.
    public static func spec(for face: ResolvedFace, role: LatticeGroupRole,
                            depthMM: Double, faceID: Int? = nil,
                            expandMM: Double = 0)
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
        case .plane(let center, let normal, let halfU, let halfW, let loops):
            // ★★★ NO OUTLINE, NO REGION — for a B-REP FACE. The half-extents are a
            // BOUNDING BOX (41.2% / 29.8% face on his two lattice walls), so emitting
            // one in place of an outline declares material he never marked, which the
            // ruling of 2026-08-21 forbids outright. The caller counts a nil as a
            // SKIPPED face and the surface says so — drawing less than he marked, out
            // loud, beats drawing 2.4x more than he marked in silence.
            //
            // A region with no `faceID` is a manual primitive, whose shape genuinely IS
            // the rectangle; it never reaches here (it comes through `spec(for:
            // ManualPrimitive)` above).
            if faceID != nil, loops.isEmpty { return nil }
            var s = LatticeRegionSpec(role: role, kind: .face)
            s.faceID = faceID
            // Core's slab runs origin + s·normal, s ∈ [0, depth]. The part's
            // material lies OPPOSITE the outward face normal, so flip it — the
            // slab must reach INTO the part, not out of it.
            s.origin = center
            s.normal = -ManualPrimitive.unit(normal)
            // ★ IN PLANE ONLY. `depthMM` is untouched below.
            // ★★ AND THE SIGN IS THE USER'S (maintainer, 2026-08-18, having typed
            // one: "I did a test where I did a negative expansion to make the
            // edges of the model's walls visible and the lattice only in the
            // centre … the lattice doesn't change and allow for that extra
            // space. There needs to be this type of fidelity and control").
            //
            // ★ THE DEFECT WAS A HAND-ROLLED DUPLICATE. This line read
            // `expandMM > 0 ? expandMM : 0` — it clamped every SHRINK to zero,
            // so the one control the user reached for could not reach the slab
            // at all. `LatticeSlabExpand.expanded` has handled the negative case
            // correctly since the sign was freed (`testItIsClampedAndNowShrinks-
            // OnPurpose`, `testANegativeMarginShrinksBothInPlaneAxes`), floors
            // each axis independently so a shrink past the face collapses to a
            // sliver instead of inverting — and was simply not called here.
            // There is now ONE expander, and the emission goes through it.
            let e = LatticeSlabExpand.expanded(halfUMM: halfU, halfWMM: halfW,
                                               by: expandMM)
            s.halfUMM = e.halfUMM
            s.halfWMM = e.halfWMM
            // ★★ AND THE REAL OUTLINE, WITH THE REACH AS ITS OWN NUMBER. Against
            // an outline the expand is Minkowski dilation by a ball — the same
            // operation `FaceOffsetShell.dilated` applies to the primitive on
            // screen — so the shape the user drags and the region the run
            // latticed are one shape, not two that happen to agree on a
            // rectangle. The half-extents above still ship for core's reader.
            // ★★★ THE OUTLINE IS RE-EXPRESSED IN THE SLAB'S OWN FRAME — the fix for
            // three of his reports at once (2026-08-21: the declared wall renders
            // solid; the lattice runs past the face into the chamfer; the lattice view
            // cuts the top faces away).
            //
            // ★★ THE OUTLINE WAS BEING MEASURED MIRRORED. `LatticeFaceOutline.loops`
            // projects the face into `LatticeRegionMask.basis(n)` for the FACE normal.
            // The slab then carries `-n`, and `LatticeRegionMask.contains` measures the
            // very same loops in `basis(-n)`. Those are NOT the same frame:
            //
            //     basis(+Y) = (u = (0,0, 1), v = (1,0,0))
            //     basis(-Y) = (u = (0,0,-1), v = (1,0,0))
            //
            // u flips and v does not, so the polygon is reflected about v. Measured on
            // his own two regions, face 15 and face 2 — both mirrored, and on face 15
            // the reflection moves the outline clean off the wall: EVERY sample taken
            // at a point genuinely on that face reported OUTSIDE the region (0 of 22).
            //
            // ★ WHICH IS ALL THREE SYMPTOMS, from one defect. The wall he declared is
            // not in the region, so it is left solid. The reflected outline lands on
            // material he never marked — the chamfer, the top faces — so the lattice
            // "expands when I have not set it to", and the SHELL, which discards
            // wherever this same field says "latticed", cuts those top faces away.
            //
            // ★ AND WHY NO TEST CAUGHT IT: a reflection preserves AREA. Every bar on
            // this outline compares areas or half-extents, and all of them still pass
            // on a mirrored polygon. The check that finds it has to be positional.
            //
            // The conversion is exact and assumes nothing about the mirror: rebuild
            // each point's 3D offset in the frame it was written in, then re-read it
            // in the frame it will be measured in.
            let (uFace, vFace) = LatticeRegionMask.basisForTests(ManualPrimitive.unit(normal))
            let (uSlab, vSlab) = LatticeRegionMask.basisForTests(s.normal)
            s.outlineLoops = loops.map { loop in
                loop.map { p -> SIMD2<Double> in
                    let d = uFace * p.x + vFace * p.y
                    return SIMD2<Double>(simd_dot(d, uSlab), simd_dot(d, vSlab))
                }
            }
            s.inPlaneOffsetMM = loops.isEmpty ? 0 : LatticeSlabExpand.clamp(expandMM)
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
                               groupDensities: [UUID: Double] = [:],
                               // ★ THE PER-SELECTABLE DENSITY (maintainer,
                               // 2026-08-17). The note below used to say a
                               // per-selectable density "needs its own store AND
                               // its own control"; both exist now, and this is
                               // where the store reaches the wire. Empty ⇒ the
                               // group's, so an untouched project is unchanged.
                               selectableDensity: [String: Double] = [:],
                               // ★ THE IN-PLANE EXPAND, per selectable
                               // (maintainer, 2026-08-17). Empty ⇒ 0 ⇒ the slab
                               // is exactly the face, byte-identical to before.
                               selectableExpandMM: [String: Double] = [:],
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
                if var s = spec(for: p, role: role,
                                depthMM: selectableDepthMM[ref.key] ?? d) {
                    // ★ THE DIALLED DENSITY (task 2026-08-16-per-sector-density-
                    // override), applied at the ONE place the emission goes
                    // through — the same argument that put the role gate here.
                    // Absent ⇒ nil ⇒ no key on the wire ⇒ core derives.
                    //
                    // ★ IT IS KEYED ON THE GROUP WHILE ROLE AND DEPTH ARE NOW
                    // KEYED ON THE SELECTABLE (lattice-separation, PR 332). That
                    // is a DELIBERATE, STATED limitation rather than an
                    // oversight: a per-selectable density needs its own store
                    // AND its own control, and inventing one here would ship a
                    // field with no surface. What it MUST do is respect the
                    // RESOLVED role, and it does — `role` here is the
                    // selectable's own, so a primitive switched to exclude
                    // inside an included group carries no density even though
                    // its group states one.
                    s.relativeDensity = density(
                        for: g.id, role: role, densities: groupDensities,
                        stated: selectableDensity[LatticeSelectableRef.primitive(p.id).key])
                    out.append(s)
                }
            }
            for f in g.faces {
                let ref = LatticeSelectableRef.face(group: g.id, face: f)
                guard let role = LatticeSelectableRoles.role(
                    for: ref, groupRole: groupRole, overrides: selectableRoles) else { continue }
                let depth = selectableDepthMM[ref.key] ?? groupDepth
                if let r = resolve(f),
                   var s = spec(for: r, role: role, depthMM: depth,
                                faceID: runFaceID(f),
                                expandMM: selectableExpandMM[ref.key] ?? 0) {
                    // The face's own resolved role, same gate as the primitives
                    // above — see the note there on group- vs selectable-keying.
                    s.relativeDensity = density(
                        for: g.id, role: role, densities: groupDensities,
                        stated: selectableDensity[ref.key])
                    out.append(s)
                } else {
                    skipped += 1
                }
            }
        }
        return Result(regions: out, skippedFaces: skipped)
    }

    /// ★ THE ONE GATE ON A DIALLED DENSITY. A density belongs to an INCLUDE
    /// region and nothing else: an exclude region is frozen solid, so it has no
    /// lattice whose density could be set, and core refuses the pairing outright
    /// ("relative_density on a region that is not latticed"). Rather than let a
    /// stale entry — a group the user dialled and then switched to exclude —
    /// reach the wire and be refused, it is dropped here, where every emission
    /// path passes. A non-positive or non-finite value is also dropped: core's
    /// sentinel for "derive" is exactly `<= 0`, so those two spellings of
    /// "nothing stated" must not become a key.
    /// ★ `stated` is the SELECTABLE's own density and WINS over its group's
    /// (maintainer, 2026-08-17) — the same precedence the role and the depth
    /// already use. The include-only gate and the "non-positive means derive"
    /// rule apply to both, because core refuses the same pairings either way.
    static func density(for id: UUID, role: LatticeGroupRole,
                        densities: [UUID: Double],
                        stated: Double? = nil) -> Double? {
        guard role == .include else { return nil }
        if let d = stated, d.isFinite, d > 0 { return d }
        guard let d = densities[id], d.isFinite, d > 0 else { return nil }
        return d
    }
}
