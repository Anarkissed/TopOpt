// LatticeBandChips.swift — ★★ WHERE THE BAND'S CHIPS GO (his 2026-09-27: "a system where
// when the user is in Lattice Only view, there are little chips tracked to the faces that,
// when clicked, asks whether it should grade to solid or not").
//
// PURE + HEADLESS. No SwiftUI, no GPU: a scene's `bandDecisions`, the user's
// `bandTreatments`, and the ONE transform the viewer draws the part with go in; screen
// points come out. `WorkspacePlaceholder` calls `layout` on every render (the camera
// projection is republished on every orbit), so each chip rides its face.
//
// ★ THE TRANSFORM IS THE RENDERER'S, NOT A SECOND DERIVATION. The part is drawn with
// `P · V · M`, where `P · V` is exactly what `CameraProjection.viewProjection` holds (built
// from the renderer's camera and the view's size) and `M` is the SETTLE — a rotation about
// the model centre (`ViewerModelFrame.matrix`, which `MeshRenderer.modelMatrix()` itself
// calls). A band decision's anchor is in MODEL space, so projecting it through `P · V`
// alone would put every chip where the part was BEFORE gravity rotated it onto the floor.
// `LatticeBandChipFrame` holds the composed clip-from-model and projects with
// `CameraProjection.project` — the same arithmetic every other overlay uses.

import Foundation
import CoreGraphics
import simd

/// ★ THE MODEL MATRIX THE VIEWER DRAWS WITH — a rotation about the model centre, which
/// keeps the centre fixed. ONE definition: `MeshRenderer.modelMatrix()` returns this for
/// its own centre and rotation, and every overlay that needs a model-space point on
/// screen composes the same one with the published camera.
public enum ViewerModelFrame {
    public static func matrix(centre: SIMD3<Float>, rotation: simd_quatf) -> simd_float4x4 {
        func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
            var m = matrix_identity_float4x4
            m.columns.3 = SIMD4<Float>(t, 1)
            return m
        }
        return translation(centre) * simd_float4x4(rotation) * translation(-centre)
    }
}

/// The viewer's clip-from-MODEL transform plus its viewport — what a chip needs to sit on
/// a model-space point. Built from the published `CameraProjection` (world → clip) and the
/// settle (model → world), composed in the renderer's own order.
public struct LatticeBandChipFrame: Equatable, Sendable {
    /// `P · V · M` — the body's own mvp (`ViewerUniforms.mvp`, `clipFromModel` in the
    /// lattice layer's uniforms).
    public let clipFromModel: simd_float4x4
    /// The stage's size in points (the MTKView's bounds).
    public let viewportSize: CGSize

    public init(clipFromModel: simd_float4x4, viewportSize: CGSize) {
        self.clipFromModel = clipFromModel
        self.viewportSize = viewportSize
    }

    /// The camera the viewer published, composed with the settle the part is drawn
    /// through. `modelCentre` is the DRAWN mesh's bounds centre (what `setMesh` rotates
    /// about); `modelRotation` is the settle quaternion handed to the view.
    public init(projection: CameraProjection, modelCentre: SIMD3<Float>, modelRotation: simd_quatf) {
        self.clipFromModel = projection.viewProjection
            * ViewerModelFrame.matrix(centre: modelCentre, rotation: modelRotation)
        self.viewportSize = projection.viewportSize
    }

    /// The same projector every overlay uses, with MODEL space as its input space.
    private var projector: CameraProjection {
        CameraProjection(viewProjection: clipFromModel, viewportSize: viewportSize)
    }

    /// A model-space point on screen (points, top-left origin, y down); nil behind the
    /// camera or for a degenerate viewport.
    public func project(_ model: SIMD3<Float>) -> CGPoint? { projector.project(model) }

    /// The unit direction, in MODEL space, from the camera through `model` — the
    /// inverse of `project` (`CameraProjection.ray`), so it is right for perspective and
    /// orthographic cameras alike. nil when the point cannot be projected.
    public func viewDirection(at model: SIMD3<Float>) -> SIMD3<Float>? {
        guard let p = projector.project(model) else { return nil }
        return projector.ray(throughViewPoint: p)?.dir
    }
}

/// One chip, placed.
public struct LatticeBandChipPlacement: Equatable, Identifiable, Sendable {
    public var id: String { decision.key }
    public let decision: LatticeBandDecision
    /// The chip's centre: the anchor lifted `liftMM` along its outward normal, projected.
    public let point: CGPoint
    /// What the chip SHOWS — the user's stored choice, else the rule's default. Shown at
    /// once, before the rebake it asked for has landed.
    public let solid: Bool
    /// The user has a choice stored for this key (the chip's dot).
    public let overridden: Bool
    /// What the chip shows differs from what the current bake drew — a rebake is due.
    public let pending: Bool
}

/// ★ THE CHIP LAYOUT. Hidden, in order: everything when lattice-only is off; decisions
/// under `minAreaMM2`; anchors behind the camera or facing away from it
/// (`normal · viewDir > backFacingDot`); chips not wholly on screen; chips over the
/// stage's own UI (`keepOut`); and, where two chips' touch targets would overlap, the one
/// on the SMALLER area. Nothing is nudged: a chip either sits on its anchor or is not
/// drawn, so it can never point at the wrong face.
public enum LatticeBandChipLayout {
    /// Faces smaller than this (mm²) get no chip (the brief's floor).
    public static let minAreaMM2: Float = 20
    /// `normal · viewDir` above this ⇒ the anchor faces away from the camera.
    public static let backFacingDot: Float = 0.2
    /// The chip is pinned this far off the surface along its outward normal (mm).
    public static let liftMM: Float = 2
    /// The drawn chip (points).
    public static let chipDiameter: CGFloat = 24
    /// The touch target — the app's one HIG floor (`KeepOutSolver.minTouch`).
    public static var touchSize: CGFloat { KeepOutSolver.minTouch }
    /// A gap kept between a chip and the UI it must stay out of.
    public static var margin: CGFloat { KeepOutSolver.separation }

    public static func layout(scene: LatticeSDFScene?, treatments: [String: Bool],
                              frame: LatticeBandChipFrame?, latticeOnly: Bool,
                              keepOut: [CGRect] = []) -> [LatticeBandChipPlacement] {
        layout(decisions: scene?.bandDecisions ?? [], treatments: treatments, frame: frame,
               latticeOnly: latticeOnly, keepOut: keepOut)
    }

    public static func layout(decisions: [LatticeBandDecision], treatments: [String: Bool],
                              frame: LatticeBandChipFrame?, latticeOnly: Bool,
                              keepOut: [CGRect] = []) -> [LatticeBandChipPlacement] {
        guard latticeOnly, let frame, frame.viewportSize.width > 0,
              frame.viewportSize.height > 0 else { return [] }
        let screen = CGRect(origin: .zero, size: frame.viewportSize)
        var candidates: [LatticeBandChipPlacement] = []
        for d in decisions {
            guard d.areaMM2 >= minAreaMM2 else { continue }
            let len = simd_length(d.normal)
            let n = len > 1e-6 ? d.normal / len : SIMD3<Float>.zero
            // ★ facing away: the camera looks ALONG the normal rather than against it
            if len > 1e-6, let dir = frame.viewDirection(at: d.anchor),
               simd_dot(n, dir) > backFacingDot { continue }
            guard let p = frame.project(d.anchor + n * liftMM) else { continue }
            let drawn = rect(p, chipDiameter)
            guard screen.contains(drawn) else { continue }
            let guarded = drawn.insetBy(dx: -margin, dy: -margin)
            if keepOut.contains(where: { $0.intersects(guarded) }) { continue }
            let chosen = d.storedChoice(in: treatments)     // the first member with a choice, as the band reads it
            let shown = chosen ?? d.defaultSolid
            candidates.append(LatticeBandChipPlacement(
                decision: d, point: p, solid: shown, overridden: chosen != nil,
                pending: shown != d.solid))
        }
        // ★ De-clutter by AREA, largest first (ties by key — deterministic): a chip whose
        // touch target would overlap one already kept is withdrawn, never stacked.
        var kept: [LatticeBandChipPlacement] = []
        for c in candidates.sorted(by: {
            $0.decision.areaMM2 != $1.decision.areaMM2
                ? $0.decision.areaMM2 > $1.decision.areaMM2 : $0.decision.key < $1.decision.key
        }) {
            let t = rect(c.point, touchSize)
            if kept.contains(where: { rect($0.point, touchSize).intersects(t) }) { continue }
            kept.append(c)
        }
        // Stable order for the view's ForEach.
        return kept.sorted { $0.decision.key < $1.decision.key }
    }

    /// ★ WHAT A TAPPED SEGMENT STORES. Picking the rule's own answer stores NO choice —
    /// the key is cleared, so the face follows the rule again and carries no dot; only a
    /// disagreement with the rule is written.
    public static func treatment(choosing solid: Bool, for d: LatticeBandDecision) -> Bool? {
        solid == d.defaultSolid ? nil : solid
    }

    static func rect(_ c: CGPoint, _ s: CGFloat) -> CGRect {
        CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)
    }
}

/// ★ THE WORDS ON A CHIP'S CARD — one line per kind and state (the brief's own lines).
public enum LatticeBandChipText {
    /// The two segments, SOLID first.
    public static func segments(_ kind: LatticeBandDecision.Kind) -> (solid: String, open: String) {
        switch kind {
        case .face: return ("Grade to solid", "Lattice through")
        case .cap:  return ("Rim", "Nothing")
        }
    }

    public static func explanation(_ kind: LatticeBandDecision.Kind, solid: Bool) -> String {
        switch (kind, solid) {
        case (.face, true):  return "Grade to solid — skin, rim and grade under this face"
        case (.face, false): return "Lattice through — the lattice reaches this face"
        case (.cap, true):   return "Rim facing the solid"
        case (.cap, false):  return "Nothing — the lattice is cut here"
        }
    }

    /// What the chip is, for VoiceOver.
    public static func accessibility(_ p: LatticeBandChipPlacement) -> String {
        let s = segments(p.decision.kind)
        return "\(p.decision.label): \(p.solid ? s.solid : s.open)"
            + (p.overridden ? ", your choice" : ", default")
    }
}
