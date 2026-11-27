// LoadAim — B3, ledger note 5 (approved design 2026-11-02, mockup #topo-setup-load): "Need to add a way to manually set the
// Push/Pull direction of a load".
//
// A load's Kind (Gravity · Push · Pull) says what it is; its AIM says which way it points. The Direction row offers
// Into the face (Push) / Away from the face (Pull) · Along X · Along Y · Along Z · Pick on the part · Flipped, and the load
// arrow carries a round handle at its free end: drag it to aim, in 15° steps from the face, snapping onto an axis. The
// exact angles sit behind Details. The job already carries a force vector per load group, so nothing new reaches core: the
// vector just points where he aimed it. With no aim set the project and its job are byte-identical to before.
//
// The sense rule (asked of the reviewer 11-03 21:46Z, this is the pick): an axis keeps the Kind's sense — a Push presses
// INTO the face, a Pull draws AWAY from it — and a face side-on to the axis gets −axis (Along Z on a top face: (0, 0, −F)).
// A custom aim is stored in the Push sense, so Pull reverses it; Flipped reverses whatever is set. Gravity follows gravity.

import Foundation
import simd

public enum LoadAim: Equatable, Sendable, Codable {
    /// Into the face (Push) / away from it (Pull): today's direction.
    case face
    /// Along a model axis: 0 = X, 1 = Y, 2 = Z.
    case axis(Int)
    /// A custom direction in the model frame (unit, in the Push sense): the handle, Pick on the part, Details.
    case vector(SIMD3<Float>)
}

public enum LoadAimMath {
    /// The handle's step from the face, and how close to an axis a drag snaps onto it.
    public static let stepDeg: Float = 15
    public static let axisSnapDeg: Float = 7.5

    static func unit(_ i: Int) -> SIMD3<Float> { i == 0 ? SIMD3(1, 0, 0) : i == 1 ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1) }

    /// The aimed direction in the model frame (unit, before the Kind's sense): `base` is the Push direction (−n).
    static func pushDirection(_ aim: LoadAim, base: SIMD3<Float>) -> SIMD3<Float> {
        switch aim {
        case .face: return base
        case .axis(let i):
            let a = unit(i), s = simd_dot(a, base)
            return abs(s) < 1e-3 ? -a : (s > 0 ? a : -a)
        case .vector(let v):
            let l = simd_length(v)
            return l > 1e-6 ? v / l : base
        }
    }

    /// The load's unit direction in the model frame, from its Kind, its face normal `n`, its aim and Flipped. nil for Gravity
    /// (gravity decides) and for a pending group.
    public static func direction(_ kind: LoadDirection, faceNormal n: SIMD3<Float>, aim: LoadAim?, flipped: Bool) -> SIMD3<Float>? {
        guard kind != .gravity else { return nil }
        var d = pushDirection(aim ?? .face, base: -n)
        if kind == .pull { d = -d }
        return flipped ? -d : d
    }

    /// The angles Details shows: from the face (0° = straight into it, for a Push) and around it (0° at the reference).
    public static func angles(of push: SIMD3<Float>, base: SIMD3<Float>) -> (fromFace: Float, around: Float) {
        let b = simd_normalize(base), d = simd_normalize(push)
        let from = acos(max(-1, min(1, simd_dot(b, d)))) * 180 / .pi
        let (r, s) = frame(b)
        let p = d - simd_dot(d, b) * b
        guard simd_length(p) > 1e-5 else { return (from, 0) }
        var around = atan2(simd_dot(p, s), simd_dot(p, r)) * 180 / .pi
        if around < 0 { around += 360 }
        return (from, around)
    }

    /// The Push direction at those angles.
    public static func direction(fromFace: Float, around: Float, base: SIMD3<Float>) -> SIMD3<Float> {
        let b = simd_normalize(base), (r, s) = frame(b)
        let t = fromFace * .pi / 180, a = around * .pi / 180
        return simd_normalize(cos(t) * b + sin(t) * (cos(a) * r + sin(a) * s))
    }

    /// A reference pair perpendicular to `b` (the least-aligned model axis, made perpendicular), so "around" is stable.
    static func frame(_ b: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let ax = [unit(0), unit(1), unit(2)].min { abs(simd_dot($0, b)) < abs(simd_dot($1, b)) }!
        let r = simd_normalize(ax - simd_dot(ax, b) * b)
        return (r, simd_cross(b, r))
    }

    /// A dragged Push direction, stepped: 15° steps from the face and around it, then onto an axis when within 7.5°.
    /// Returns the aim to store (an axis when it lands on one in the Kind's sense, else a vector).
    public static func stepped(_ push: SIMD3<Float>, base: SIMD3<Float>) -> LoadAim {
        let (f, a) = angles(of: push, base: base)
        let q = { (x: Float) in (x / stepDeg).rounded() * stepDeg }
        var d = direction(fromFace: q(f), around: q(a).truncatingRemainder(dividingBy: 360), base: base)
        // back onto the face's own direction first: that is "Into the face", which follows the face
        if acos(max(-1, min(1, simd_dot(d, simd_normalize(base))))) * 180 / .pi <= axisSnapDeg { return .face }
        for i in 0..<3 {
            for s: Float in [1, -1] where acos(max(-1, min(1, simd_dot(d, s * unit(i))))) * 180 / .pi <= axisSnapDeg {
                d = s * unit(i)
                if pushDirection(.axis(i), base: base) == d { return .axis(i) }
            }
        }
        return .vector(d)
    }

    /// The dragged free end `finger` (screen points) → the Push direction it aims, in the WORLD frame. The finger moves in the
    /// plane through the arrow's base facing the camera; `into`: the arrow's tip sits at the face, so its free end is the tail
    /// and the force points from the finger toward the base.
    public static func dragged(finger: CGPoint, base: SIMD3<Float>, into: Bool, projection: CameraProjection) -> SIMD3<Float>? {
        guard let p = projection.project(base), let viewRay = projection.ray(throughViewPoint: p),
              let ray = projection.ray(throughViewPoint: finger) else { return nil }
        let nrm = viewRay.dir
        let denom = simd_dot(ray.dir, nrm)
        guard abs(denom) > 1e-6 else { return nil }
        let t = simd_dot(base - ray.origin, nrm) / denom
        let hit = ray.origin + t * ray.dir
        let v = into ? base - hit : hit - base
        let l = simd_length(v)
        return l > 1e-6 ? v / l : nil
    }
}

/// The Direction row's words (mockup #topo-setup-load).
public enum LoadAimCopy {
    public static let title = "Direction"
    public static func label(_ aim: LoadAim?, kind: LoadDirection, flipped: Bool) -> String {
        guard kind != .gravity else { return followsGravity }
        let base: String
        switch aim ?? .face {
        case .face: base = kind == .pull ? "Away from the face" : "Into the face"
        case .axis(let i): base = "Along \(["X", "Y", "Z"][i])"
        case .vector: base = "Aimed on the part"
        }
        return flipped ? base + " \u{00B7} flipped" : base
    }
    /// ≤ 5 words (U6): a Gravity load follows gravity; the fix is to make it a Push.
    public static let followsGravity = "Follows gravity"
    public static let choosePush = "Choose Push"
    public static func choices(kind: LoadDirection) -> [String] {
        [kind == .pull ? "Away from the face" : "Into the face", "Along X", "Along Y", "Along Z", pick, flippedTitle]
    }
    public static let pick = "Pick on the part"
    public static let flippedTitle = "Flipped"
    public static let pickHint = "Tap a point on the part; the arrow aims at it"
    public static let info = "Into the face pushes straight into it. Pick an axis, or drag the arrow\u{2019}s round handle on the part. "
        + "Exact angles are in Details."
    public static let details = "Details"
    public static let fromFace = "From the face"
    public static let around = "Around"
}

extension ForceModel {
    /// ★ B3 (note 5): a load's aim; nil = into / away from the face, as before.
    public func aim(for id: UUID) -> LoadAim? { loadAims?[id] }
    public func aimIsFlipped(_ id: UUID) -> Bool { loadFlips?.contains(id) ?? false }

    public mutating func setAim(_ id: UUID, _ aim: LoadAim?) {
        guard kind(for: id).isLoad else { return }
        var m = loadAims ?? [:]
        m[id] = aim == .face ? nil : aim
        loadAims = m.isEmpty ? nil : m
    }

    public mutating func setFlipped(_ id: UUID, _ on: Bool) {
        guard kind(for: id).isLoad else { return }
        var s = loadFlips ?? []
        if on { s.insert(id) } else { s.remove(id) }
        loadFlips = s.isEmpty ? nil : s
    }

    /// The load's unit direction in the model frame for Push / Pull, aim and Flipped applied (nil for Gravity / not a load).
    public func aimedDirection(_ id: UUID, faceNormal n: SIMD3<Float>) -> SIMD3<Float>? {
        guard let k = kind(for: id).loadDirection else { return nil }
        return LoadAimMath.direction(k, faceNormal: n, aim: aim(for: id), flipped: aimIsFlipped(id))
    }

    /// From `sync(groups:)`: a deleted group's aim goes with it.
    mutating func syncAims(live: Set<UUID>) {
        if let m = loadAims { let p = m.filter { live.contains($0.key) }; loadAims = p.isEmpty ? nil : p }
        if let s = loadFlips { let p = s.intersection(live); loadFlips = p.isEmpty ? nil : p }
    }
}
