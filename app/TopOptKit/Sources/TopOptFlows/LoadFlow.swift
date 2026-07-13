// LoadFlow.swift — the "alive" load-path flow animation (the handoff 070 redesign),
// ported off the browser prototype into pure, headlessly-tested value-type math.
//
// The prototype (docs/prototypes/loadpath/loadpath-redesign.html) replaced the old
// principal-stress "hedgehog" (a static field of tiny direction glyphs) with a FEW
// flowing red comet-arrows: one arrow per path, each streaming from a LOAD location
// along a curve, wiggling/undulating as it travels, dragging a hot bloom of stress
// with it. This file is the engine behind that, split so the numerics are verified
// without a GPU (the M7 /app/ standard); the Metal tube draw that consumes a
// `CometFrame` / `CometMesh` is device QA.
//
// ARCHITECTURE — the animation is MODE-AGNOSTIC. A "path" is nothing but *a curve
// plus a target* (`FlowCurve`). `CometArrow` animates any curve; it never asks where
// the curve came from. The PATH SOURCE is a separate concern (`LoadFlowField`), keyed
// on `FlowPathMode`. This task builds ONE mode — `.stressPoint` (load → peak-stress
// hot-spot, integrating the viz.4 principal-stress field) — but a second mode
// (`.anchor`, a follow-up) only has to emit different `FlowCurve`s: the comet
// animation, the moving epicenters, and the whole renderer are reused unchanged.
//
// HONESTY. This is a FLOW VISUALISATION layered over the real STATIC stress field.
// The curves follow the genuinely-derived principal-stress directions and terminate
// at the genuinely-located peak-stress voxel; the moving bloom illustrates how load
// travels, it is NOT a claim that stress moves in waves over time. The literal
// static Stress overlay (the Stress chip) stays unchanged and available as the
// truthful readout.

import Foundation
import simd

// ---------------------------------------------------------------------------
// MARK: - Path source (mode-agnostic curve + the mode that generates curves)

/// Which family of curves the flow renders. The animation is identical across
/// modes — only the curve GENERATION differs — so adding a mode is adding a `case`
/// here plus a branch in `LoadFlowField.curves`. THIS TASK ships `.stressPoint`
/// only; `.anchor` (load → clamped anchor) is a deliberate follow-up.
public enum FlowPathMode: Equatable, Sendable {
    /// Load location → follows the principal-stress direction field → terminates at
    /// the peak-stress hot-spot (viz.2). The curves the animation engine renders here.
    case stressPoint
    // case anchor  — FUTURE: load location → down the load path → a clamped anchor.
}

/// One flow path: an arc-length-parameterised polyline (`points`) with its unit
/// `tangents`, plus per-path desync so multiple arrows never beat in lockstep. This
/// is the ONLY thing the comet animation consumes — deliberately blind to whether the
/// curve came from `.stressPoint` or a future mode.
public struct FlowCurve: Equatable, Sendable {
    /// Resampled centreline points (world mm), roughly equal arc-length apart.
    public let points: [SIMD3<Float>]
    /// Unit tangents at each point (central differences; endpoints one-sided).
    public let tangents: [SIMD3<Float>]
    /// Cumulative arc length at each point (`arc[0] == 0`).
    public let arc: [Float]
    /// Total arc length (`arc.last`); 0 for a degenerate (single-point) curve.
    public let total: Float
    /// Start phase offset in [0, 1) — staggers where each arrow begins its loop.
    public let phaseOffset: Float
    /// Multiplier on this path's travel speed — small per-path variation.
    public let speedMul: Float
    /// A slow oscillator phase (radians) for the per-path breathing/pulse desync.
    public let wobblePhase: Float

    public init(points: [SIMD3<Float>], tangents: [SIMD3<Float>], arc: [Float], total: Float,
                phaseOffset: Float, speedMul: Float, wobblePhase: Float) {
        self.points = points; self.tangents = tangents; self.arc = arc; self.total = total
        self.phaseOffset = phaseOffset; self.speedMul = speedMul; self.wobblePhase = wobblePhase
    }

    public var isEmpty: Bool { points.count < 2 || total <= 0 }

    /// Position + unit tangent at arc length `s` (clamped to `[0, total]`), linearly
    /// interpolated between the two bracketing samples. The centreline the comet rides.
    public func sample(at s: Float) -> (pos: SIMD3<Float>, tan: SIMD3<Float>) {
        guard points.count >= 2 else {
            return (points.first ?? .zero, tangents.first ?? SIMD3<Float>(0, 0, 1))
        }
        let target = Swift.min(Swift.max(s, 0), total)
        // Binary search for the first sample whose cumulative arc >= target.
        var lo = 0, hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if arc[mid] < target { lo = mid + 1 } else { hi = mid }
        }
        let i = Swift.max(1, lo)
        let span = arc[i] - arc[i - 1]
        let u = span > 1e-6 ? (target - arc[i - 1]) / span : 0
        let pos = simd_mix(points[i - 1], points[i], SIMD3<Float>(repeating: u))
        let tan = simd_normalize(simd_mix(tangents[i - 1], tangents[i], SIMD3<Float>(repeating: u)))
        return (pos, tan.x.isNaN ? tangents[i] : tan)
    }

    /// Resample an arbitrary polyline into a `FlowCurve` of `resolution` samples
    /// equally spaced by arc length. A polyline with < 2 distinct points → an empty
    /// curve. Central-difference tangents keep the comet's heading smooth.
    public static func resample(_ raw: [SIMD3<Float>], resolution: Int = 96,
                                phaseOffset: Float = 0, speedMul: Float = 1,
                                wobblePhase: Float = 0) -> FlowCurve {
        // Drop consecutive duplicates so arc lengths are strictly increasing.
        var pts: [SIMD3<Float>] = []
        for p in raw where pts.last.map({ simd_distance($0, p) > 1e-5 }) ?? true { pts.append(p) }
        guard pts.count >= 2 else {
            return FlowCurve(points: pts, tangents: pts.map { _ in SIMD3<Float>(0, 0, 1) },
                             arc: pts.map { _ in 0 }, total: 0,
                             phaseOffset: phaseOffset, speedMul: speedMul, wobblePhase: wobblePhase)
        }
        // Cumulative arc length of the raw polyline.
        var cum: [Float] = [0]
        for i in 1..<pts.count { cum.append(cum[i - 1] + simd_distance(pts[i], pts[i - 1])) }
        let total = cum[cum.count - 1]
        let n = Swift.max(2, resolution)
        var outPts: [SIMD3<Float>] = []; outPts.reserveCapacity(n)
        var outArc: [Float] = []; outArc.reserveCapacity(n)
        for k in 0..<n {
            let s = total * Float(k) / Float(n - 1)
            // Walk raw segments to find the one containing arc length s.
            var seg = 1
            while seg < pts.count - 1 && cum[seg] < s { seg += 1 }
            let span = cum[seg] - cum[seg - 1]
            let u = span > 1e-6 ? (s - cum[seg - 1]) / span : 0
            outPts.append(simd_mix(pts[seg - 1], pts[seg], SIMD3<Float>(repeating: u)))
            outArc.append(s)
        }
        // Central-difference unit tangents.
        var tans: [SIMD3<Float>] = []; tans.reserveCapacity(n)
        for k in 0..<n {
            let a = outPts[Swift.max(0, k - 1)]
            let b = outPts[Swift.min(n - 1, k + 1)]
            let d = b - a
            let len = simd_length(d)
            tans.append(len > 1e-6 ? d / len : SIMD3<Float>(0, 0, 1))
        }
        return FlowCurve(points: outPts, tangents: tans, arc: outArc, total: total,
                         phaseOffset: phaseOffset, speedMul: speedMul, wobblePhase: wobblePhase)
    }
}

/// Builds the flow curves for a mode from the fields the app already derives. For
/// `.stressPoint`: integrates a streamline from each load seed THROUGH the
/// principal-stress direction field (the viz.4 glyphs) toward the peak-stress
/// hot-spot (the viz.2 point), then resamples it. Pure math (no GPU, no bridge).
public enum LoadFlowField {
    /// How many samples each resampled comet curve carries. Enough for a smooth,
    /// undulating tube on a phone without heavy per-frame cost (a few curves only).
    public static let curveResolution = 96

    /// Small per-path desync tables (phase, speed, wobble) so N arrows stay out of
    /// lockstep — cycled by index. Mirrors the prototype's `p.offset/phase/speedMul`.
    static let phaseTable: [Float] = [0.0, 0.28, 0.55, 0.8, 0.15, 0.66]
    static let speedTable: [Float] = [1.0, 0.9, 1.12, 0.96, 1.05, 0.92]

    /// Generate the flow curves. `loadSeeds` are the world-mm start points (tagged
    /// load-group centroids, or a derived fallback). `glyphs` is the principal-stress
    /// direction field; `hotSpot` the terminus. `stepLength` (world mm, e.g. the voxel
    /// spacing) sets the integration granularity. Returns one curve per seed that
    /// reaches the hot-spot; seeds with no usable route are dropped.
    public static func curves(mode: FlowPathMode, loadSeeds: [SIMD3<Float>],
                              glyphs: LoadPath, hotSpot: SIMD3<Float>?,
                              stepLength: Float, maxSteps: Int = 400) -> [FlowCurve] {
        switch mode {
        case .stressPoint:
            guard let hotSpot, !glyphs.isEmpty else { return [] }
            var out: [FlowCurve] = []
            for (i, seed) in loadSeeds.enumerated() {
                let raw = streamline(from: seed, to: hotSpot, glyphs: glyphs,
                                     stepLength: stepLength, maxSteps: maxSteps)
                guard raw.count >= 2 else { continue }
                let phase = phaseTable[i % phaseTable.count]
                let speed = speedTable[i % speedTable.count]
                let wobble = Float(i) * 1.9
                out.append(FlowCurve.resample(raw, resolution: curveResolution,
                                              phaseOffset: phase, speedMul: speed, wobblePhase: wobble))
            }
            return out
        }
    }

    /// Integrate a streamline from `seed` to `target` through the principal-stress
    /// field. At each step the heading is the nearest glyph's principal direction —
    /// SIGNED toward the target (a principal axis has no head/tail) — blended with a
    /// straight pull to the target so the path provably terminates at the hot-spot
    /// rather than wandering off along the field. The pull strengthens as the target
    /// nears (a smooth capture), so the middle of the path faithfully follows the
    /// field while the ends are pinned to the real load point and the real hot-spot.
    static func streamline(from seed: SIMD3<Float>, to target: SIMD3<Float>,
                           glyphs: LoadPath, stepLength: Float, maxSteps: Int) -> [SIMD3<Float>] {
        let step = Swift.max(stepLength, 1e-4)
        let startDist = simd_distance(seed, target)
        guard startDist > step else { return [seed, target] }
        var pos = seed
        var pts: [SIMD3<Float>] = [seed]
        for _ in 0..<maxSteps {
            let toTarget = target - pos
            let dist = simd_length(toTarget)
            if dist <= step { break }                     // captured — snap to target below
            let toUnit = toTarget / dist
            var heading = toUnit
            if let field = nearestDirection(to: pos, glyphs: glyphs) {
                // Sign the sign-ambiguous principal axis toward the target.
                let signed = simd_dot(field, toUnit) < 0 ? -field : field
                // Pull grows from `basePull` up to 1 over the last `captureFrac` of the
                // route, guaranteeing convergence without flattening the field's shape.
                let progress = 1 - Swift.min(1, dist / startDist)
                let pull = Swift.max(basePull, progress * progress)
                let mixed = signed * (1 - pull) + toUnit * pull
                let len = simd_length(mixed)
                heading = len > 1e-6 ? mixed / len : toUnit
            }
            pos += heading * step
            pts.append(pos)
        }
        pts.append(target)                                 // pin the terminus exactly
        return pts
    }

    /// The straight-to-target weight applied even mid-route, so a field that locally
    /// points away from the target still makes net progress (no stalls / loops).
    static let basePull: Float = 0.25

    /// The principal direction of the glyph nearest `p` (brute force over the sampled
    /// field — a few hundred glyphs, run once per curve build). Nil if the field is
    /// empty.
    static func nearestDirection(to p: SIMD3<Float>, glyphs: LoadPath) -> SIMD3<Float>? {
        var best = Float.greatestFiniteMagnitude
        var dir: SIMD3<Float>? = nil
        for g in glyphs.glyphs {
            let d = simd_distance_squared(g.position, p)
            if d < best { best = d; dir = g.direction }
        }
        return dir
    }
}

// ---------------------------------------------------------------------------
// MARK: - Motion styles (the three "alive" presets)

/// The three "alive" motion presets from the prototype's Tune → Alive motion style.
/// Each is one point in the same parameter set `{amp, waves, wSpeed, bodyLen,
/// coreR, headR, headLen, speedPulse, breath}` — so the renderer never branches on
/// style, it just reads these numbers.
public enum FlowMotionStyle: String, CaseIterable, Sendable, Equatable {
    /// Gentle single-sine undulation, steady speed. Calm/legible (prototype default).
    case sine
    /// Layered two-sine snake motion, longer tail. Most obviously alive.
    case serpentine
    /// Low lateral wiggle but surging speed + width "breathing". Reads as energy
    /// being pushed through.
    case pulse

    public var title: String {
        switch self {
        case .sine: return "Sine"
        case .serpentine: return "Serpentine"
        case .pulse: return "Pulse"
        }
    }

    /// The tuning params. `bodyLen` is a FRACTION of the curve length (so the comet
    /// scales to any part), unlike the prototype's fixed mm — everything else matches
    /// the prototype's `STYLES` table shape.
    public var params: FlowStyleParams {
        switch self {
        case .sine:       return FlowStyleParams(amp: 0.10, waves: 1.1, wSpeed: 2.2, bodyFrac: 0.42, coreR: 1.15, headR: 2.6, headLenFrac: 0.10, speedPulse: 0.00, breath: 0.08, serpentine: false)
        case .serpentine: return FlowStyleParams(amp: 0.16, waves: 2.3, wSpeed: 3.4, bodyFrac: 0.55, coreR: 1.05, headR: 2.5, headLenFrac: 0.10, speedPulse: 0.02, breath: 0.05, serpentine: true)
        case .pulse:      return FlowStyleParams(amp: 0.075, waves: 1.4, wSpeed: 2.0, bodyFrac: 0.38, coreR: 1.35, headR: 3.0, headLenFrac: 0.12, speedPulse: 0.06, breath: 0.24, serpentine: false)
        }
    }
}

/// The tuning parameters that define a motion style (see `FlowMotionStyle.params`).
/// `amp`/`bodyFrac`/`headLenFrac` are fractions of the curve length so a comet looks
/// the same on a 6 mm bracket and a 600 mm beam.
public struct FlowStyleParams: Equatable, Sendable {
    public let amp: Float          // undulation amplitude as a fraction of curve length
    public let waves: Float        // sine waves along the comet body
    public let wSpeed: Float       // undulation travel speed (radians/sec of clock)
    public let bodyFrac: Float     // comet body length as a fraction of curve length
    public let coreR: Float        // core tube radius scale (× the base radius)
    public let headR: Float        // arrowhead radius scale (× the base radius)
    public let headLenFrac: Float  // arrowhead length as a fraction of curve length
    public let speedPulse: Float   // surge added to travel speed (pulse style)
    public let breath: Float       // head width "breathing" amount
    public let serpentine: Bool    // layer a second faster sine (snake motion)
}

/// How the part body is drawn behind the flow (the prototype's Body segment). All
/// three keep the arrows/blooms legible: two are semi-transparent so they read
/// THROUGH the walls, one is the opaque solid.
public enum FlowBodyMode: String, CaseIterable, Sendable, Equatable {
    /// Semi-transparent neutral clay — arrows/blooms visible through the walls
    /// (the default, the core "see the load path inside the part" ask).
    case xray
    /// Semi-transparent stress heatmap — the load path within a stress view.
    case stress
    /// Opaque solid — the arrows ride on the surface (no see-through).
    case solid

    public var title: String {
        switch self {
        case .xray: return "X-ray"
        case .stress: return "Stress"
        case .solid: return "Solid"
        }
    }

    /// The body's fragment alpha. < 1 draws the mesh translucent (depth-write off) so
    /// the flow shows through; 1 is the opaque solid draw.
    public var bodyAlpha: Float {
        switch self {
        case .xray: return 0.18
        case .stress: return 0.5
        case .solid: return 1.0
        }
    }
    /// Whether this mode paints the body with the stress heatmap (vs neutral clay).
    public var showsStress: Bool { self == .stress }
}

// ---------------------------------------------------------------------------
// MARK: - Comet arrow (the per-frame animated geometry description)

/// One comet-arrow snapshot at a given clock: the undulating centreline (`centers`),
/// its unit `tangents`, the tapered `coreRadii`/`haloRadii`, and the arrowhead. Plus
/// `headPosition` — the point on the CURVE the arrow's head currently sits at, which
/// is ALSO the moving stress epicenter (`CometArrow` guarantees the head carries zero
/// undulation, so it stays on the real curve → the bloom sits inside the body).
public struct CometFrame: Equatable, Sendable {
    public let centers: [SIMD3<Float>]
    public let tangents: [SIMD3<Float>]
    public let coreRadii: [Float]
    public let haloRadii: [Float]
    public let headPosition: SIMD3<Float>
    public let headDirection: SIMD3<Float>
    public let headLength: Float
    public let headRadius: Float
    /// The path's base colour (from its terminus stress on the shared ramp), rgb 0–1.
    public let color: SIMD3<Float>

    public var isEmpty: Bool { centers.count < 2 }
}

/// Animates a `FlowCurve` into a `CometFrame` for a clock time. This is the direct,
/// GPU-free port of the prototype's `updateArrow` — same head-anchored amplitude
/// taper (clean arrowhead), same comet radius taper, same per-path phase/speed
/// desync, same three-style parameterisation.
public enum CometArrow {
    /// Rings along the comet body (tail → head). Enough for a smooth undulating tube.
    public static let bodySegments = 28

    /// The comet frame for `curve` at `clock` seconds. `loopPeriod` is the seconds for
    /// one tail-to-head traverse; `speed`/`wiggle` are the user multipliers; `reduced`
    /// freezes the arrow mid-path with a clean head (the reduced-motion static
    /// presentation). `baseRadius` sets the absolute tube thickness (world mm).
    public static func frame(curve: FlowCurve, style: FlowMotionStyle, clock: Float,
                             loopPeriod: Float, speed: Float, wiggle: Float, reduced: Bool,
                             baseRadius: Float, color: SIMD3<Float>) -> CometFrame {
        guard !curve.isEmpty else {
            return CometFrame(centers: [], tangents: [], coreRadii: [], haloRadii: [],
                              headPosition: curve.points.first ?? .zero,
                              headDirection: SIMD3<Float>(0, 0, 1), headLength: 0, headRadius: 0,
                              color: color)
        }
        let p = style.params
        let M = bodySegments
        let period = Swift.max(loopPeriod, 0.1)
        let bodyLen = p.bodyFrac * curve.total

        // Travel progress u ∈ [0,1): where the HEAD is along the curve. Reduced-motion
        // freezes it partway (offset per path so a frozen field still reads as flow).
        var base = clock / period * curve.speedMul * Swift.max(speed, 0.01) + curve.phaseOffset
        if !reduced && p.speedPulse != 0 {
            base += p.speedPulse * sin(clock * 1.7 + curve.wobblePhase)
        }
        let u = reduced ? (0.55 + curve.phaseOffset * 0.1).truncatingRemainder(dividingBy: 1)
                        : fract(base)
        let headArc = u * curve.total
        let breath = reduced ? 1 : (1 + p.breath * sin(clock * 2.3 + curve.wobblePhase))
        let ampWorld = p.amp * curve.total * Swift.max(wiggle, 0)

        var centers: [SIMD3<Float>] = []; centers.reserveCapacity(M)
        var tangents: [SIMD3<Float>] = []; tangents.reserveCapacity(M)
        var coreR: [Float] = []; coreR.reserveCapacity(M)
        var haloR: [Float] = []; haloR.reserveCapacity(M)
        for i in 0..<M {
            let s = Float(i) / Float(M - 1)                 // 0 tail … 1 head
            let arc = headArc - (1 - s) * bodyLen
            let sampled = curve.sample(at: arc)
            // Undulation: amplitude tapers to ZERO at the head (clean arrowhead), a
            // travelling sine along the body; serpentine layers a second faster sine.
            let env = pow(1 - s, 0.7)
            var wv = sin(s * p.waves * 2 * .pi - (reduced ? 0 : clock) * p.wSpeed + curve.wobblePhase)
            if p.serpentine {
                wv = 0.6 * wv + 0.4 * sin(s * p.waves * 1.9 * 2 * .pi
                                          - (reduced ? 0 : clock) * p.wSpeed * 1.6 + curve.wobblePhase * 1.3)
            }
            let off = ampWorld * env * wv
            // Offset perpendicular to travel (a stable frame), so the wiggle reads as
            // undulation regardless of the part's orientation and never runs along the
            // arrow's own axis.
            let n = perpendicular(to: sampled.tan)
            centers.append(sampled.pos + n * off)
            tangents.append(sampled.tan)
            let cr = p.coreR * pow(s, 0.7) * breath
            coreR.append(Swift.max(0.12, cr) * baseRadius)
            haloR.append(Swift.max(0.3, cr * 2.1) * baseRadius)
        }
        // The head sits on the real curve (env→0 there): the clean-arrowhead point and
        // the moving epicenter.
        let headSample = curve.sample(at: headArc)
        let headLen = p.headLenFrac * curve.total * breath
        let headRad = p.headR * baseRadius * breath
        return CometFrame(centers: centers, tangents: tangents, coreRadii: coreR, haloRadii: haloR,
                          headPosition: headSample.pos, headDirection: headSample.tan,
                          headLength: headLen, headRadius: headRad, color: color)
    }

    /// A unit vector perpendicular to `t` (for the undulation offset). Uses world-up
    /// as the reference, or world-X when `t` is near-vertical, matching the tube
    /// framing in the prototype's `fillTube`.
    static func perpendicular(to t: SIMD3<Float>) -> SIMD3<Float> {
        let ref = abs(t.y) > 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        let n = simd_cross(ref, t)
        let len = simd_length(n)
        return len > 1e-6 ? n / len : SIMD3<Float>(1, 0, 0)
    }

    /// Fractional part in [0, 1) (handles negative inputs).
    static func fract(_ x: Float) -> Float {
        let r = x.truncatingRemainder(dividingBy: 1)
        return r < 0 ? r + 1 : r
    }
}

// ---------------------------------------------------------------------------
// MARK: - Moving stress epicenters (the bloom that follows each arrow head)

/// The moving-epicenter heat blend: reuses the "drive stress colour from an
/// animation parameter" pattern (the flex→stress coupling), now driven by the arrow
/// HEAD positions instead of a scalar load multiple. A vertex's displayed stress
/// fraction is its true static fraction, blended UP toward hot near the nearest
/// arrow head, falling off with distance — a bloom of stress travelling with the
/// load. This is a viz layer; the literal static field stays the truthful readout.
public enum LoadFlowEpicenter {
    /// The heated stress fraction at a vertex: `base` (the true static fraction on the
    /// shared scale) raised by a smooth bloom around the NEAREST head. `radius` is the
    /// bloom's world-mm reach; `strength` is how hot the very centre pushes (in
    /// fraction units, e.g. 0.6 lifts a cool-blue vertex into the warm band as a head
    /// passes). Clamped to [0, 1].
    public static func heatedFraction(base: Double, position: SIMD3<Float>,
                                      heads: [SIMD3<Float>], radius: Float, strength: Double) -> Double {
        guard !heads.isEmpty, radius > 1e-5 else { return Swift.min(1, Swift.max(0, base)) }
        var bloom: Float = 0
        for h in heads {
            let d = simd_distance(position, h)
            if d >= radius { continue }
            let f = 1 - d / radius                          // 1 at the head → 0 at the rim
            let smooth = f * f * (3 - 2 * f)                // smoothstep falloff
            if smooth > bloom { bloom = smooth }            // nearest/hottest head wins
        }
        return Swift.min(1, Swift.max(0, base + strength * Double(bloom)))
    }
}

// ---------------------------------------------------------------------------
// MARK: - Comet tube extrusion (CometFrame → GPU vertices)

/// Extrudes a `CometFrame` into triangle vertices for the Metal draw: a bright core
/// tube, a wider dim halo tube (additive glow), and an arrowhead cone. The output is
/// the SAME `[x, y, z, r, g, b, a]` stride-7 layout the existing ground/line pipeline
/// consumes (so the renderer reuses that vertex format), drawn with ADDITIVE blending
/// so the arrows glow through the semi-transparent x-ray body. Kept pure so the
/// vertex count / layout is asserted headlessly; the actual rasterisation is device QA.
public enum CometMesh {
    /// Sides around each tube ring. 8 reads as round without much cost.
    public static let sides = 8

    /// Build the interleaved stride-7 triangle-vertex buffer for `frame`. `intensity`
    /// scales the additive brightness (1 full; e.g. dimmed for a non-isolated path).
    /// Empty for a degenerate frame.
    public static func build(_ frame: CometFrame, intensity: Float = 1) -> [Float] {
        guard !frame.isEmpty else { return [] }
        var out: [Float] = []
        let c = frame.color
        // Halo first (dim, wide), then core (bright, tapered), then the head cone.
        // All additive, so draw order does not matter — but core-over-halo keeps the
        // centre saturated where they overlap.
        appendTube(&out, centers: frame.centers, tangents: frame.tangents,
                   radii: frame.haloRadii, color: c, alpha: 0.22 * intensity)
        appendTube(&out, centers: frame.centers, tangents: frame.tangents,
                   radii: frame.coreRadii, color: c, alpha: 0.9 * intensity)
        appendCone(&out, tip: frame.headPosition, dir: frame.headDirection,
                   length: frame.headLength, radius: frame.headRadius,
                   color: c, alpha: 1.0 * intensity)
        // A wider, dimmer head halo for the glowing tip.
        appendCone(&out, tip: frame.headPosition, dir: frame.headDirection,
                   length: frame.headLength * 1.25, radius: frame.headRadius * 1.8,
                   color: c, alpha: 0.30 * intensity)
        return out
    }

    /// Extrude a tube along `centers` with per-ring `radii`, appending stride-7 verts
    /// (two triangles per quad face). Premultiplied colour (`rgb·alpha, alpha`) so the
    /// additive pipeline accumulates the emissive contribution.
    static func appendTube(_ out: inout [Float], centers: [SIMD3<Float>], tangents: [SIMD3<Float>],
                           radii: [Float], color: SIMD3<Float>, alpha: Float) {
        let M = centers.count, K = sides
        guard M >= 2, radii.count == M else { return }
        // Build ring vertices with a stable normal frame per section.
        var ring = [[SIMD3<Float>]](repeating: [], count: M)
        for i in 0..<M {
            let t = tangents[i]
            let n = CometArrow.perpendicular(to: t)
            let b = simd_normalize(simd_cross(t, n))
            var pts: [SIMD3<Float>] = []; pts.reserveCapacity(K)
            for k in 0..<K {
                let th = Float(k) / Float(K) * 2 * .pi
                let dir = n * cos(th) + b * sin(th)
                pts.append(centers[i] + dir * radii[i])
            }
            ring[i] = pts
        }
        let pr = color.x * alpha, pg = color.y * alpha, pb = color.z * alpha
        func push(_ p: SIMD3<Float>) {
            out.append(p.x); out.append(p.y); out.append(p.z)
            out.append(pr); out.append(pg); out.append(pb); out.append(alpha)
        }
        for i in 0..<(M - 1) {
            for k in 0..<K {
                let k2 = (k + 1) % K
                let a = ring[i][k], bb = ring[i][k2], cc = ring[i + 1][k], d = ring[i + 1][k2]
                push(a); push(cc); push(bb)
                push(bb); push(cc); push(d)
            }
        }
    }

    /// Append a cone (arrowhead): a fan of `sides` triangles from the apex to a base
    /// ring, `length` back along `-dir` from the `tip`.
    static func appendCone(_ out: inout [Float], tip: SIMD3<Float>, dir: SIMD3<Float>,
                           length: Float, radius: Float, color: SIMD3<Float>, alpha: Float) {
        guard length > 1e-5, radius > 1e-5 else { return }
        let t = simd_length(dir) > 1e-6 ? simd_normalize(dir) : SIMD3<Float>(0, 0, 1)
        let apex = tip + t * (length * 0.5)
        let baseC = tip - t * (length * 0.5)
        let n = CometArrow.perpendicular(to: t)
        let b = simd_normalize(simd_cross(t, n))
        let K = sides
        let pr = color.x * alpha, pg = color.y * alpha, pb = color.z * alpha
        func push(_ p: SIMD3<Float>) {
            out.append(p.x); out.append(p.y); out.append(p.z)
            out.append(pr); out.append(pg); out.append(pb); out.append(alpha)
        }
        for k in 0..<K {
            let th0 = Float(k) / Float(K) * 2 * .pi
            let th1 = Float(k + 1) / Float(K) * 2 * .pi
            let r0 = baseC + (n * cos(th0) + b * sin(th0)) * radius
            let r1 = baseC + (n * cos(th1) + b * sin(th1)) * radius
            push(apex); push(r0); push(r1)
        }
    }
}
