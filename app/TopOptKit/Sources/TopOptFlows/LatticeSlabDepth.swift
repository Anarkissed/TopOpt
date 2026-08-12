// LatticeSlabDepth.swift — ★ ONE CONTROL, ONE VALUE, ONE SLAB (task
// 2026-08-12-lattice-page-redesign §0a).
//
// THE DEFECT THIS TYPE EXISTS TO MAKE UNREPRESENTABLE. Face protection depth and
// lattice region depth were two independent numbers in two different stores:
//
//     ForceModel.faceProtectDepthMM     ONE global, default 5 mm
//     LatticeSettings.paintDepthMM      ONE global, default 4 mm
//
// On the maintainer's own run they were 5 mm and 7 mm. 5 mm rounds to 3 voxel
// layers on a 1.705 mm grid — 5.115 mm of held material feeding a 7 mm lattice
// region. TO removed everything past 5.115 mm, so the lattice pass found material
// only in the frozen skin: 10,321 of 13,034 latticed voxels, 79%, were the
// protected collar, and 120,821 region voxels were void a lattice cannot conjure
// material into.
//
// THE BARRIER MODEL. The maintainer's sentence — "we are setting a barrier on the
// TO in order to get the lattice to lighten" — says the two are the same act. A
// face marked protect + lattice is held against TO to the depth the user dragged
// the primitive to, and THAT held material is what the lattice lightens. So the
// depth lives in ONE place, per group, and both the protection spec and the
// region emission are derived from it. There is no second number to disagree.
//
// Pure derivation over value types (no view, no model), so the guarantee is
// headlessly testable — and the call sites are pinned by
// `LatticeDepthTieTests.testEveryCallSiteReadsTheOneNumber`, because a value-type
// test that no shipping code calls has shipped a defect five times in this repo.

import Foundation

/// The per-group slab depth: how far, in mm, a face's lattice primitive was
/// dragged out from the face. It is BOTH the protection depth and the lattice
/// region depth for that face — there is no way to express two.
public enum LatticeSlabDepth {

    /// Bounds on the dragged depth (mm). The floor is one min-feature; the ceiling
    /// matches `FaceProtection.maxDepthMM` so the two controls that were merged
    /// cannot disagree about their own range either.
    public static let minMM = 1.0
    public static let maxMM = FaceProtection.maxDepthMM

    /// The depth in force for `group`, in mm: its own dragged depth when it has
    /// one, otherwise the project's default slab depth.
    public static func depthMM(group: UUID,
                               perGroup: [UUID: Double],
                               fallbackMM: Double) -> Double {
        clamp(perGroup[group] ?? fallbackMM)
    }

    public static func clamp(_ v: Double) -> Double {
        Swift.min(maxMM, Swift.max(minMM, v))
    }

    /// One face's resolved slab: the face id the run will use, and the ONE depth.
    public struct Slab: Equatable, Sendable {
        public let faceID: Int
        public let depthMM: Double
        /// Whether this face is held against TO (protect) as well as latticed.
        public let protected: Bool
        public init(faceID: Int, depthMM: Double, protected: Bool) {
            self.faceID = faceID
            self.depthMM = depthMM
            self.protected = protected
        }
    }

    /// Every face that carries a slab, in selection order, deduped by face id.
    ///
    /// `roles` is `LatticeSettings.groupRoles`; a group is protected per
    /// `isProtected`. A face contributes a slab when its group carries a lattice
    /// role, is protected, or both — because both roles are expressed as a depth
    /// into the part and the run needs the same number for either.
    public static func slabs(groups: [SelectionGroup],
                             roles: [UUID: LatticeGroupRole],
                             isProtected: (UUID) -> Bool,
                             perGroupDepthMM: [UUID: Double],
                             fallbackMM: Double,
                             runFaceID: (FaceID) -> Int) -> [Slab] {
        var out: [Slab] = []
        var seen = Set<Int>()
        for g in groups {
            let hasRole = roles[g.id] != nil
            let prot = isProtected(g.id)
            guard hasRole || prot else { continue }
            let d = depthMM(group: g.id, perGroup: perGroupDepthMM,
                            fallbackMM: fallbackMM)
            for f in g.faces {
                let id = runFaceID(f)
                if seen.contains(id) { continue }
                seen.insert(id)
                out.append(Slab(faceID: id, depthMM: d, protected: prot))
            }
        }
        return out
    }

    /// THE ASSERTION (bar R2), as a function rather than a comment: for every face
    /// that is both protected and latticed, the protection depth and the lattice
    /// region depth are the same number. Returns the faces where they are not —
    /// EMPTY is the only shippable answer, and the run path checks it.
    public static func mismatches(protections: [(faceID: Int, depthMM: Double)],
                                  regions: [(faceID: Int, depthMM: Double)])
        -> [(faceID: Int, protectionMM: Double, regionMM: Double)] {
        var byFace: [Int: Double] = [:]
        for p in protections { byFace[p.faceID] = p.depthMM }
        var bad: [(faceID: Int, protectionMM: Double, regionMM: Double)] = []
        for r in regions {
            guard let p = byFace[r.faceID] else { continue }
            if abs(p - r.depthMM) > 1e-9 {
                bad.append((r.faceID, p, r.depthMM))
            }
        }
        return bad
    }
}
