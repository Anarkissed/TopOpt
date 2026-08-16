// SurfaceCut.swift — ★ §6(g)/(h)/(i)/(j): THE HOVERED CUT, AND THE CUT ITSELF
// (task 2026-08-15-lattice-and-face-ui, Surface stage).
//
// ★ THE CUT IS A HALF-SPACE TEST, NOT A LINE DRAWN ON THE FACE. §6(i) says why,
// and PR 331 measured it: a line has no clean meaning on a fillet, and 19.8% of
// his part's surface types land in `Other`. So a cut is a PLANE — a point and a
// normal — and the voxels on each side become sub-regions. `FaceRegionModel
// .splitManual(point:normal:)` already takes exactly that, and `RegionCut` already
// persists exactly that (§6j: never "region 24, half A", which a re-import
// renumbers out from under you).
//
// ★ WHAT THIS FILE ADDS is the part that had no precedent in the app: turning a
// HOVER or a TAP over the model into that point and normal, and rotating the
// normal in 15° detents about the face's own axis (§6h).
//
// ── THE PENCIL HOVER (§6g) ───────────────────────────────────────────────────
//
// "WITH A PENCIL, SHOW THE HOVERED POSITION while attempting a cut — the cut line
// follows the hover before it is committed."
//
// `onContinuousHover` appears exactly ONCE in the app before this (the orientation
// gizmo, for a mouse), so there was nothing to copy. What makes it tractable is
// that hover gives the same thing a tap gives — a point in view space — so it
// runs through the SAME ray cast the picker already uses
// (`FacePicker.pickTriangle`, whose ray parameter this file finally reads
// instead of discarding).
//
// Pure geometry over value types: no SwiftUI, no Metal, no camera object — it
// takes an already-built ray and returns model-space geometry, so the whole cut
// is headlessly testable.

import Foundation
import simd

/// Where a hover or a tap landed on the model, and the cut it implies.
public struct SurfaceCut: Equatable, Sendable {

    /// The point on the surface, in model space — the cut plane passes through it.
    public let point: SIMD3<Double>
    /// The cut plane's normal, in model space. Rotating the cut spins this about
    /// the face's own normal, so the plane always stands UP out of the face.
    public let normal: SIMD3<Double>
    /// The face that was hit — the region the cut will divide.
    public let faceID: FaceID
    /// The face's own outward normal, the axis the rotation turns about.
    public let faceNormal: SIMD3<Double>

    public init(point: SIMD3<Double>, normal: SIMD3<Double>,
                faceID: FaceID, faceNormal: SIMD3<Double>) {
        self.point = point
        self.normal = normal
        self.faceID = faceID
        self.faceNormal = faceNormal
    }

    /// ★ §6(h) — THE DETENT. "A ROTATE DRAG at any angle with DETENTS EVERY 15
    /// DEGREES." Free rotation with a snap, not a stepper: the drag is continuous
    /// and lands on the nearest 15° when released, which is what a detent IS.
    public static let detentDegrees = 15.0

    /// Snap an angle (degrees) to the nearest detent.
    public static func snap(_ degrees: Double) -> Double {
        (degrees / detentDegrees).rounded() * detentDegrees
    }

    /// This cut with its plane rotated `degrees` about the FACE's normal. The
    /// plane keeps standing up out of the face at every angle, which is what makes
    /// the preview line read as a line ON the face.
    public func rotated(by degrees: Double) -> SurfaceCut {
        let axis = simd_length(faceNormal) > 1e-9
            ? simd_normalize(faceNormal) : SIMD3<Double>(0, 0, 1)
        let q = simd_quatd(angle: degrees * .pi / 180, axis: axis)
        return SurfaceCut(point: point, normal: simd_normalize(q.act(normal)),
                          faceID: faceID, faceNormal: faceNormal)
    }

    /// ★ THE PREVIEW LINE (§6g) — the cut plane intersected with the face's own
    /// plane, as a segment of `halfLengthMM` either side of the hovered point.
    /// This is the line that follows the pencil before anything is committed.
    ///
    /// The direction is `faceNormal × normal`: perpendicular to both, so it lies
    /// IN the face and IN the cut plane — the visible trace of one on the other.
    public func previewSegment(halfLengthMM: Double) -> (a: SIMD3<Double>, b: SIMD3<Double>) {
        let d = simd_cross(faceNormal, normal)
        let dir = simd_length(d) > 1e-9 ? simd_normalize(d) : SIMD3<Double>(1, 0, 0)
        return (point - dir * halfLengthMM, point + dir * halfLengthMM)
    }

    // MARK: - building one from a ray

    /// ★ THE HIT POINT THE PICKER ALREADY COMPUTED AND THREW AWAY.
    ///
    /// `FacePicker.pickTriangle` runs Möller–Trumbore, keeps the ray parameter
    /// in `bestT` to find the NEAREST triangle — and then returns only the
    /// triangle index. Every hover and every tap in this mode needs the POINT, so
    /// this asks for both and reconstructs it as `origin + dir·t`.
    ///
    /// The seed normal is the face's own normal rotated a quarter turn in the
    /// face's plane — an arbitrary but STABLE starting orientation, so the preview
    /// does not spin as the pencil moves. The user then rotates it (§6h).
    public static func at(rayOrigin: SIMD3<Float>, rayDir: SIMD3<Float>,
                          mesh: ViewerMesh) -> SurfaceCut? {
        guard let hit = FacePicker.hit(rayOrigin: rayOrigin, rayDir: rayDir,
                                          mesh: mesh) else { return nil }
        let p = SIMD3<Double>(hit.point)
        let n = SIMD3<Double>(hit.normal)
        guard simd_length(n) > 1e-9 else { return nil }
        let fn = simd_normalize(n)
        // Any unit vector in the face's plane; `orthogonal` picks a stable one.
        let seed = orthogonal(to: fn)
        return SurfaceCut(point: p, normal: seed, faceID: hit.faceID, faceNormal: fn)
    }

    /// ★ CENTRED ON A REGION — the piece, not the face it was cut from.
    ///
    /// A region's frame is built from ITS members clipped to ITS half-spaces, so
    /// for one half of a cut face the origin is the middle of that half. Cutting a
    /// half therefore divides the half, which is what the second cut has to mean.
    public static func centred(onRegion region: RegionID, of face: FaceID,
                               regions: FaceRegionModel, in mesh: ViewerMesh) -> SurfaceCut? {
        guard let r = regions.region(region) else { return nil }
        let members = FaceRegionGeometry.members(of: r, in: mesh)
        guard members.contains(face) else { return nil }
        // The centroid of the region's OWN side: the frame is over all members, so
        // clip it to this region's cuts by averaging the vertices that survive.
        var acc = SIMD3<Double>(repeating: 0)
        var n = 0
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            let f: Int32 = tri < mesh.faceIDs.count ? mesh.faceIDs[tri] : -1
            if f >= 0, members.contains(f) {
                for k in 0..<3 {
                    let vi = Int(mesh.indices[t + k]) * 3
                    guard vi + 2 < mesh.positions.count else { continue }
                    let v = SIMD3<Double>(SIMD3<Float>(mesh.positions[vi],
                                                       mesh.positions[vi + 1],
                                                       mesh.positions[vi + 2]))
                    if FaceRegionGeometry.inside(v, r.cuts) { acc += v; n += 1 }
                }
            }
            t += 3
        }
        guard n > 0 else { return centred(onFace: face, in: mesh) }
        let centre = acc / Double(n)
        let fn = faceNormal(of: face, in: mesh)
        guard simd_length(fn) > 1e-9 else { return nil }
        let unit = simd_normalize(fn)
        return SurfaceCut(point: centre, normal: orthogonal(to: unit),
                          faceID: face, faceNormal: unit)
    }

    /// ★ MOVED OFF CENTRE BY HAND (maintainer: "Please add a 4 arrow 'movement'
    /// icon to allow for manually changing the position of the cut, should the 1/2
    /// way point not be good enough").
    ///
    /// The offset is applied ALONG THE PLANE'S OWN NORMAL — the only direction
    /// that moves the cut. Sliding it within its own plane would change nothing,
    /// and sliding it out of the face would be meaningless.
    public func moved(byMM d: Double) -> SurfaceCut {
        SurfaceCut(point: point + normal * d, normal: normal,
                   faceID: faceID, faceNormal: faceNormal)
    }

    /// A unit vector perpendicular to `n`, chosen deterministically so the preview
    /// does not flip as the hover moves across a face.
    static func orthogonal(to n: SIMD3<Double>) -> SIMD3<Double> {
        let a = abs(n.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        return simd_normalize(simd_cross(n, a))
    }
}

extension SurfaceCut {

    /// ★ A CUT CENTRED ON A TAPPED FACE — the Surface panel's own entry point.
    ///
    /// ★ WHY THE CENTROID RATHER THAN THE TAP POINT. The mesh view's pick callback
    /// hands back a FACE, not a position (`onPickFace: ((FaceID) -> Void)`), and
    /// widening it would mean a second gesture layer over the viewport — which is
    /// exactly what took orbit away when it was first tried. So a tap gives the
    /// face, the cut passes through that face's own centre, and the user turns it
    /// (§6h). A pencil HOVER still moves the point off the centre when the hardware
    /// reports one; the centroid is the floor, not the ceiling.
    ///
    /// The same `FaceRegionGeometry.frame` the Regions sheet cuts through, so the
    /// two surfaces place a cut in the same place given the same face.
    public static func centred(onFace face: FaceID, in mesh: ViewerMesh) -> SurfaceCut? {
        let frame = FaceRegionGeometry.frame(members: [face], in: mesh)
        let n = faceNormal(of: face, in: mesh)
        guard simd_length(n) > 1e-9 else { return nil }
        let fn = simd_normalize(n)
        return SurfaceCut(point: frame.origin, normal: orthogonal(to: fn),
                          faceID: face, faceNormal: fn)
    }

    /// The face's outward normal: its DECLARED B-rep normal when the import gave
    /// one, and otherwise the area-weighted normal of its own triangles.
    ///
    /// ★ THE DECLARED NORMAL WINS, for the same reason `FaceOffsetShell` gives: an
    /// STL's manufactured pseudo-faces have no declared normal and fall through to
    /// the triangles, but a STEP face's winding can disagree with what the B-rep
    /// says, and the B-rep is what every other consumer reads.
    static func faceNormal(of face: FaceID, in mesh: ViewerMesh) -> SIMD3<Double> {
        if face >= 0, face < Int32(mesh.faceGeometry.count) {
            let g = mesh.faceGeometry[Int(face)]
            if g.kind == .plane, simd_length(g.planeNormal) > 1e-6 {
                return simd_normalize(g.planeNormal)
            }
        }
        var acc = SIMD3<Float>(0, 0, 0)
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            if tri < mesh.faceIDs.count, mesh.faceIDs[tri] == face {
                func v(_ k: Int) -> SIMD3<Float> {
                    let b = Int(mesh.indices[t + k]) * 3
                    return SIMD3(mesh.positions[b], mesh.positions[b + 1], mesh.positions[b + 2])
                }
                // Un-normalised cross product: its length IS twice the triangle's
                // area, so summing weights each triangle by its own size.
                acc += simd_cross(v(1) - v(0), v(2) - v(0))
            }
            t += 3
        }
        return simd_length(acc) > 1e-12
            ? SIMD3<Double>(simd_normalize(acc)) : SIMD3<Double>(0, 0, 1)
    }
}
