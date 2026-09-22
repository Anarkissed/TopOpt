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
                   outlineLoops: [[SIMD2<Double>]] = [],
                   // ★ per outline edge, the face across it (nil: a free edge) — the
                   // emission turns edges shared with another latticed prism into seams
                   neighbours: [[FaceID?]] = [])
    }

    /// The planar `ResolvedFace` the app builds, in ONE place, so a test cannot
    /// accidentally construct it in a different frame from production's.
    public static func planeFor(face: FaceID, in mesh: ViewerMesh) -> ResolvedFace? {
        guard let geo = mesh.faceGeometry(Int32(face)), geo.isPlane,
              let o = mesh.facePlaneOutline(face,
                                            planeNormal: SIMD3<Float>(geo.planeNormal),
                                            planeOrigin: SIMD3<Float>(geo.planeOrigin))
        else { return nil }
        let lw = LatticeFaceOutline.loopsWithNeighbours(
            face: face, in: mesh, normal: ManualPrimitive.unit(geo.planeNormal), origin: SIMD3<Double>(o.center))
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
                      outlineLoops: lw.map { $0.loop }, neighbours: lw.map { $0.neighbours })
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
                            expandMM: Double = 0,
                            // ★ which neighbouring face makes an outline edge a SEAM
                            seamWith: (FaceID) -> Bool = { _ in false })
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
        case .plane(let center, let normal, let halfU, let halfW, let loops, let neighbours):
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
            // the point order is kept by the re-expression above, so edge i is still edge i
            // the raw neighbour across every edge (nil = free); the post-pass in `regions`
            // turns the ones that were actually emitted into seams and adds the tilt
            s.outlineSeamFaces = neighbours.map { $0.map { f in f.map { Int($0) } } }
            s.outlineSeams = neighbours.map { $0.map { f in f.map(seamWith) ?? false } }
            if !s.outlineSeams.contains(where: { $0.contains(true) }) { s.outlineSeams = []; s.outlineSeamFaces = [] }
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
                               // ★ THE UNLOADED WALLS (2026-09-05): selectable key →
                               // foci count, ONLY for walls the bake measured as
                               // unloaded with the switch on (ProjectModel resolves).
                               syntheticWalls: [String: Int] = [:],
                               // ★★★ A GROUP'S FACE REGIONS (his 2026-09-22 00:31: "Face 23
                               // & like it" carried an include role and a depth and reached
                               // nothing — the emission walked `g.faces` only). A region
                               // that is a union of WHOLE faces is N face prisms, each pure
                               // geometry core already takes; the closure hands back its
                               // member faces, or nil for a region the run cannot consume
                               // (a cut sector — a voxel set, PR 331 §6). Every member
                               // emitted carries the REGION's key, role, depth, density.
                               regionMembers: (UUID, RegionID) -> [FaceID]? = { _, _ in nil },
                               // ★ a face that does not resolve to ONE plane or cylinder may
                               // resolve to several planar FACETS (a curved wall) — see
                               // `LatticeFaceFacets`; empty ⇒ the face is skipped as before
                               facets: (FaceID) -> [ResolvedFace] = { _ in [] },
                               resolve: (FaceID) -> ResolvedFace?) -> Result {
        var out: [LatticeRegionSpec] = []
        var skipped = 0
        /// every resolved shape of a face: the one plane/cylinder, else its facets
        func shapes(_ f: FaceID) -> [ResolvedFace] {
            if let r = resolve(f) { return [r] }
            return facets(f)
        }
        // ★ every face that will be LATTICED, known up front: an outline edge shared with
        // one of them (or with the face's own other facets) is a seam, not a rim
        var latticed = Set<FaceID>()
        for g in groups {
            guard let groupRole = roles[g.id] else { continue }
            for f in g.faces where LatticeSelectableRoles.role(
                for: .face(group: g.id, face: f), groupRole: groupRole, overrides: selectableRoles) == .include {
                latticed.insert(f)
            }
            for rid in g.regionIDs where LatticeSelectableRoles.role(
                for: .region(group: g.id, region: rid), groupRole: groupRole, overrides: selectableRoles) == .include {
                for f in regionMembers(g.id, rid) ?? [] { latticed.insert(f) }
            }
        }
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
                    s.selectableKey = ref.key
                    if let n = syntheticWalls[ref.key] { s.syntheticStress = true; s.syntheticFoci = n }
                    out.append(s)
                }
            }
            for f in g.faces {
                let ref = LatticeSelectableRef.face(group: g.id, face: f)
                guard let role = LatticeSelectableRoles.role(
                    for: ref, groupRole: groupRole, overrides: selectableRoles) else { continue }
                let depth = selectableDepthMM[ref.key] ?? groupDepth
                var emitted = 0
                for r in shapes(f) {
                    guard var s = spec(for: r, role: role, depthMM: depth,
                                       faceID: runFaceID(f),
                                       expandMM: selectableExpandMM[ref.key] ?? 0,
                                       seamWith: { $0 == f || (role == .include && latticed.contains($0)) }) else { continue }
                    // The face's own resolved role, same gate as the primitives
                    // above — see the note there on group- vs selectable-keying.
                    s.relativeDensity = density(
                        for: g.id, role: role, densities: groupDensities,
                        stated: selectableDensity[ref.key])
                    s.selectableKey = ref.key
                    s.rawFaceID = f
                    if let n = syntheticWalls[ref.key] { s.syntheticStress = true; s.syntheticFoci = n }
                    out.append(s); emitted += 1
                }
                if emitted == 0 { skipped += 1 }
            }
            // ★ the group's face regions: one prism per member face, under the region's own key
            let direct = Set(g.faces)
            for rid in g.regionIDs {
                let ref = LatticeSelectableRef.region(group: g.id, region: rid)
                guard let role = LatticeSelectableRoles.role(
                    for: ref, groupRole: groupRole, overrides: selectableRoles) else { continue }
                guard let members = regionMembers(g.id, rid) else { continue }
                let depth = selectableDepthMM[ref.key] ?? groupDepth
                for f in members where !direct.contains(f) {
                    var emitted = 0
                    for r in shapes(f) {
                        guard var s = spec(for: r, role: role, depthMM: depth,
                                           faceID: runFaceID(f),
                                           expandMM: selectableExpandMM[ref.key] ?? 0,
                                           seamWith: { $0 == f || (role == .include && latticed.contains($0)) }) else { continue }
                        s.relativeDensity = density(
                            for: g.id, role: role, densities: groupDensities,
                            stated: selectableDensity[ref.key])
                        s.selectableKey = ref.key
                        s.rawFaceID = f
                        if let n = syntheticWalls[ref.key] { s.syntheticStress = true; s.syntheticFoci = n }
                        out.append(s); emitted += 1
                    }
                    if emitted == 0 { skipped += 1 }
                }
            }
        }
        // ★★ THE POST-PASS (review 2026-09-22 #10/#15/#18 + the flare): a seam is an edge whose
        // neighbour face was EMITTED (not merely declared), its face id on the wire is the
        // run id, and it carries the tilt to the prism across it — tan(half the dihedral),
        // positive where the two prisms diverge with depth — so `LatticeRegionMask` can
        // flare each prism to the bisector plane and adjacent prisms meet without a wedge.
        finishSeams(&out, runFaceID: runFaceID)
        return Result(regions: out, skippedFaces: skipped)
    }

    static func finishSeams(_ out: inout [LatticeRegionSpec], runFaceID: (FaceID) -> Int) {
        let emittedRaw = Set(out.compactMap { $0.rawFaceID })
        // world-space edges of every include face region, for the neighbour lookup
        struct Edge { let a: SIMD3<Double>, b: SIMD3<Double>, region: Int }
        var edges: [Edge] = []
        func worldOf(_ r: LatticeRegionSpec) -> ((SIMD2<Double>) -> SIMD3<Double>)? {
            let n = LatticeRegionMask.unit(r.normal)
            guard simd_length(n) > 0.5 else { return nil }
            let (bu, bv) = LatticeRegionMask.basis(n)
            return { uv in r.origin + bu * uv.x + bv * uv.y }
        }
        var isFace = [Bool](repeating: false, count: out.count)
        for (ri, r) in out.enumerated() where r.role == .include && r.kind == .face {
            guard let w = worldOf(r) else { continue }
            isFace[ri] = true
            for loop in r.outlineLoops { for i in loop.indices { edges.append(Edge(a: w(loop[i]), b: w(loop[(i + 1) % loop.count]), region: ri)) } }
        }
        // ★ BY RAW FACE, THEN NEAREST (2026-09-22): the world edge is REBUILT from the
        // facet's (u,v) outline, which drops the vertex's out-of-plane component — the
        // two facets of a curved face rebuild their shared edge ~0.25 mm apart on his
        // 50 mm cylinder, so a 1e-3 match found nothing and no facet ever got a seam.
        // The raw neighbour face is known; among that face's regions the nearest edge
        // (within a tenth of the edge, or a millimetre) is the one across the seam.
        func neighbourRegion(of a: SIMD3<Double>, _ b: SIMD3<Double>, rawFace: Int, notIn ri: Int) -> Int? {
            var best: (Int, Double)? = nil
            let tol = Swift.max(1.0, 0.1 * simd_length(b - a))
            for e in edges where e.region != ri && out[e.region].rawFaceID == FaceID(rawFace) {
                let d = 0.5 * Swift.min(simd_length(e.a - a) + simd_length(e.b - b), simd_length(e.a - b) + simd_length(e.b - a))
                if d < tol, best == nil || d < best!.1 { best = (e.region, d) }
            }
            return best?.0
        }
        // ★★ BY GEOMETRY WHEN THE MESH SHARES NO EDGE (his 2026-09-22 14:55, image 3: "the
        // side one should be removed entirely"). His STEP tessellation does not share edge
        // vertices between adjacent faces — face 15 reported 0 seams against face 23, the
        // facets only their facet-to-facet ones — so the corner between two latticed walls
        // rimmed on both sides. An outline edge that lies ALONG an edge of another latticed
        // region (parallel within 6°, its midpoint within 1.5 mm of that segment and inside
        // its span, or the reverse) is a seam to that region.
        func geometricNeighbour(of a: SIMD3<Double>, _ b: SIMD3<Double>, notIn ri: Int) -> Int? {
            let dA = b - a
            let lA = simd_length(dA)
            guard lA > 1e-9 else { return nil }
            let uA = dA / lA, mA = 0.5 * (a + b)
            var best: (Int, Double)? = nil
            for e in edges where e.region != ri && out[e.region].rawFaceID != out[ri].rawFaceID {
                let dB = e.b - e.a
                let lB = simd_length(dB)
                guard lB > 1e-9 else { continue }
                let uB = dB / lB
                guard abs(simd_dot(uA, uB)) > 0.995 else { continue }
                func segDist(_ p: SIMD3<Double>, _ c: SIMD3<Double>, _ d: SIMD3<Double>) -> (Double, Double) {
                    let cd = d - c; let l2 = simd_dot(cd, cd)
                    let t = l2 > 1e-12 ? simd_dot(p - c, cd) / l2 : 0
                    let q = c + cd * Swift.max(0, Swift.min(1, t))
                    return (simd_length(p - q), t)
                }
                let (d1, t1) = segDist(mA, e.a, e.b)
                let (d2, t2) = segDist(0.5 * (e.a + e.b), a, b)
                let overlap = (t1 >= -0.05 && t1 <= 1.05) || (t2 >= -0.05 && t2 <= 1.05)
                let dist = Swift.min(d1, d2)
                if overlap, dist <= 1.5, best == nil || dist < best!.1 { best = (e.region, dist) }
            }
            return best?.0
        }
        // ★★★ BY THE PRISM BEYOND THE EDGE (his 2026-09-22 14:55, measured on the stand at
        // 15:25): face 23 and the flat walls are not adjacent at all — a fillet face lies
        // between them — yet a probe 0.5 mm beyond face 23's edge, half-way down, is
        // already inside face 15's or face 2's prism on every non-facet edge. "Both sides
        // latticed" is a question about PRISMS, not mesh edges: an outline edge whose
        // outward neighbourhood (0.5, 1 and 2 mm out, at half the shallower depth) lies
        // inside another latticed region's prism is a seam to it. Opposite walls (normals
        // more than 150° apart) never pair — their prisms can overlap in a thin leg with
        // no corner between them.
        func prismNeighbour(mid uv: SIMD2<Double>, outUV: SIMD2<Double>, region ri: Int) -> (Int, Double)? {
            let r = out[ri]
            let nA = LatticeRegionMask.unit(r.normal)
            let (bu, bv) = LatticeRegionMask.basis(nA)
            for off in [0.5, 1.0, 2.0] {
                let q = uv + outUV * off
                for rj in out.indices where rj != ri && isFace[rj] && out[rj].rawFaceID != r.rawFaceID {
                    let o = out[rj]
                    let nB = LatticeRegionMask.unit(o.normal)
                    guard simd_dot(nA, nB) > cos(150 * Double.pi / 180) else { continue }
                    let s = 0.5 * Swift.min(r.depthMM, o.depthMM)
                    let p = r.origin + bu * q.x + bv * q.y + nA * s
                    if LatticeRegionMask.containsWholePrism(p, region: o) { return (rj, off) }
                }
            }
            return nil
        }
        for ri in out.indices where isFace[ri] {
            guard let w = worldOf(out[ri]) else { continue }
            let own = out[ri].rawFaceID
            let nA = LatticeRegionMask.unit(out[ri].normal)
            let (bu, bv) = LatticeRegionMask.basis(nA)
            var seams: [[Bool]] = [], faces: [[Int?]] = [], tilts: [[Double]] = [], capsAll: [[Double]] = []
            var any = false
            for (l, loop) in out[ri].outlineLoops.enumerated() {
                let raw = l < out[ri].outlineSeamFaces.count ? out[ri].outlineSeamFaces[l] : []
                var sl = [Bool](repeating: false, count: loop.count)
                var fl = [Int?](repeating: nil, count: loop.count)
                var tl = [Double](repeating: 0, count: loop.count)
                var cl = [Double](repeating: 0, count: loop.count)
                // the polygon's winding, for the outward edge direction
                var area = 0.0
                for i in loop.indices { let a = loop[i], b = loop[(i + 1) % loop.count]; area += a.x * b.y - b.x * a.y }
                let ccw = area > 0
                for i in loop.indices {
                    let a3 = w(loop[i]), b3 = w(loop[(i + 1) % loop.count])
                    var nj: Int? = nil
                    var gap = 0.0            // how far beyond the edge the neighbour's prism starts (≤)
                    if i < raw.count, let nbRaw = raw[i], let own, nbRaw == Int(own) || emittedRaw.contains(FaceID(nbRaw)) {
                        nj = neighbourRegion(of: a3, b3, rawFace: nbRaw, notIn: ri)
                    }
                    if nj == nil { nj = geometricNeighbour(of: a3, b3, notIn: ri) }
                    if nj == nil {
                        let d2 = loop[(i + 1) % loop.count] - loop[i]
                        let l2 = simd_length(d2)
                        if l2 > 1e-9 {
                            let outUV = (ccw ? SIMD2(d2.y, -d2.x) : SIMD2(-d2.y, d2.x)) / l2
                            if let (j, off) = prismNeighbour(mid: (loop[i] + loop[(i + 1) % loop.count]) * 0.5, outUV: outUV, region: ri) {
                                nj = j; gap = off
                            }
                        }
                    }
                    guard let nj else { continue }
                    sl[i] = true; any = true
                    // the flare yields to the neighbour only as far as its prism reaches from
                    // THIS edge: its depth less the gap (a fillet) between the two — short of
                    // that the two prisms overlap, never a strip nobody owns
                    cl[i] = Swift.max(0.5, out[nj].depthMM - gap)
                    fl[i] = out[nj].rawFaceID.map { runFaceID($0) } ?? out[nj].faceID
                    // the tilt: half the dihedral between the two inward normals, signed by
                    // whether the neighbour's normal leans away from this facet (diverging)
                    let nB = LatticeRegionMask.unit(out[nj].normal)
                    let d2 = loop[(i + 1) % loop.count] - loop[i]
                    let eIn = bu * d2.x + bv * d2.y
                    guard simd_length(eIn) > 1e-9 else { continue }
                    let eDir = simd_normalize(eIn)
                    var eOut = simd_cross(nA, eDir)           // in-plane, perpendicular to the edge
                    // orient outward: CCW ⇒ outward is to the RIGHT of the edge in (u,v)
                    let outUV = ccw ? SIMD2(d2.y, -d2.x) : SIMD2(-d2.y, d2.x)
                    let outWorld = bu * outUV.x + bv * outUV.y
                    if simd_dot(eOut, outWorld) < 0 { eOut = -eOut }
                    let cosA = Swift.max(-1, Swift.min(1, simd_dot(nA, nB)))
                    let half = 0.5 * acos(cosA)
                    let sign: Double = simd_dot(nB, eOut) > 0 ? 1 : -1
                    tl[i] = sign * tan(half)
                }
                seams.append(sl); faces.append(fl); tilts.append(tl); capsAll.append(cl)
            }
            if any {
                out[ri].outlineSeams = seams; out[ri].outlineSeamFaces = faces; out[ri].outlineSeamTilt = tilts
                out[ri].outlineSeamDepthMM = capsAll
            } else {
                out[ri].outlineSeams = []; out[ri].outlineSeamFaces = []; out[ri].outlineSeamTilt = []
                out[ri].outlineSeamDepthMM = []
            }
        }
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
