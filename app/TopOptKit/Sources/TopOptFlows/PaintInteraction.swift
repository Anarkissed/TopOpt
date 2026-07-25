// PaintInteraction.swift — the GPU-free geometry behind paint mode and the
// tap pre-highlight (handoff 2026-07-24).
//
// Two pure helpers, both plain simd math so they are unit-tested headlessly (the
// /app/ standard); the SwiftUI gesture layer and the Metal tint consume them:
//
//   * BrushHitTest — which triangles a brush stroke covers. A stroke is a screen
//     point + radius; the hit set is the front-facing triangles whose projected
//     centroid falls inside the brush disc. Deterministic (ascending triangle
//     order), so replaying a stroke paints the same triangles every time — the
//     "paint selects/deselects deterministically" bar.
//
//   * TapSelection — what a TAP will select, computed BEFORE it commits, so the
//     viewer can pre-highlight EXACTLY the pseudo-face (and its hole face-loop)
//     the tap would add. This is the fix for the surprise over-select: the user
//     sees the extent first, and if it is wrong, paint mode is the escape.

import CoreGraphics
import Foundation
import simd

/// Resolve a brush stroke to the triangles it paints.
public enum BrushHitTest {

    /// The triangles under a circular brush.
    ///
    /// - Parameters:
    ///   - centerPoint: brush centre in VIEW points (top-left origin, y down — the
    ///     same space `CameraProjection.project` returns and gestures report).
    ///   - radiusPoints: brush radius in view points.
    ///   - frontFacing: when true (default), skip triangles facing away from the
    ///     camera, so a stroke never paints through the part onto its back wall.
    ///   - modelRotation: the SETTLE rotation the viewer applies to the model (gravity →
    ///     floor). The mesh positions are model-space, but the RENDERED part is rotated by
    ///     this about `modelCenter`; the brush must project the SAME settled positions the
    ///     user sees, or it paints the wrong face (e.g. the opposite wall). Default identity
    ///     (un-settled) keeps the pure-geometry tests unchanged.
    ///   - modelCenter: the centre the settle rotates about (the mesh bounds centre).
    /// - Returns: covered triangle indices, ascending (deterministic).
    public static func triangles(under centerPoint: CGPoint, radiusPoints: CGFloat,
                                 mesh: ViewerMesh, projection: CameraProjection,
                                 frontFacing: Bool = true,
                                 modelRotation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
                                 modelCenter: SIMD3<Float> = .zero) -> [Int] {
        guard projection.isUsable, !mesh.isEmpty, radiusPoints > 0 else { return [] }
        // View direction through the brush centre, for front-face culling. If the
        // ray is unavailable (degenerate transform) we simply keep every triangle.
        let viewDir = projection.ray(throughViewPoint: centerPoint)?.dir
        let r2 = Float(radiusPoints * radiusPoints)

        // Positions in the SETTLED world the viewer draws (identity when un-settled).
        func pos(_ i: Int) -> SIMD3<Float> {
            let raw = SIMD3<Float>(mesh.positions[i * 3], mesh.positions[i * 3 + 1],
                                   mesh.positions[i * 3 + 2])
            return modelCenter + modelRotation.act(raw - modelCenter)
        }

        var out: [Int] = []
        let idx = mesh.indices
        var t = 0
        var tri = 0
        while t + 2 < idx.count {
            let i0 = Int(idx[t]), i1 = Int(idx[t + 1]), i2 = Int(idx[t + 2])
            let vc = mesh.vertexCount
            if i0 < vc, i1 < vc, i2 < vc {
                let p0 = pos(i0), p1 = pos(i1), p2 = pos(i2)
                let normal = simd_cross(p1 - p0, p2 - p0)  // outward winding
                let facesCamera = viewDir.map { simd_dot(normal, $0) < 0 } ?? true
                if !frontFacing || facesCamera {
                    let centroid = (p0 + p1 + p2) / 3
                    if let sp = projection.project(centroid) {
                        let dx = Float(sp.x - centerPoint.x)
                        let dy = Float(sp.y - centerPoint.y)
                        if dx * dx + dy * dy <= r2 { out.append(tri) }
                    }
                }
            }
            t += 3
            tri += 1
        }
        return out
    }
}

/// Resolve what a TAP will select, for the confirm-before-commit pre-highlight.
public enum TapSelection {

    /// The face ids a tap at `point` (normalized view coords, top-left, y down)
    /// would select: the picked pseudo-face, expanded by the hole face-loop walk
    /// so a tap on a bore pre-highlights the whole tube. Empty on a miss or an STL
    /// with no face ids. This is the SAME resolution the commit uses, so the
    /// pre-highlight cannot disagree with what actually gets selected.
    public static func preview(mesh: ViewerMesh, camera: OrbitCamera, aspect: Float,
                               point: CGPoint) -> [FaceID] {
        guard let face = FacePicker.pick(mesh: mesh, camera: camera, aspect: aspect,
                                         point: point) else { return [] }
        return FaceTopology.loop(fromFace: face, in: mesh)
    }

    /// The triangle indices a set of faces covers — what the viewer paints as the
    /// pending pre-highlight. Ascending (deterministic).
    public static func triangles(forFaces faces: [FaceID], in mesh: ViewerMesh) -> [Int] {
        guard !faces.isEmpty, !mesh.faceIDs.isEmpty else { return [] }
        let want = Set(faces)
        var out: [Int] = []
        for (t, f) in mesh.faceIDs.enumerated() where want.contains(f) { out.append(t) }
        return out
    }
}
