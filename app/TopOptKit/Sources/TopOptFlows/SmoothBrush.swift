// SmoothBrush.swift — LOCAL smoothing strength (handoff 2026-08-02-smoothing-page).
//
// THE MAINTAINER'S STATED REASON for wanting this page: "smoothing to not be on
// the entire model and only on parts that need it." So strength stops being one
// global knob. A stroke paints triangles into a REGION; a region carries its own
// strength; the union becomes the per-vertex weight vector core's constrained
// smoother multiplies each Taubin pass by. There is no second smoothing path —
// this feeds PR 200's machinery, and an unpainted vertex comes back bit-identical
// because core copies a zero-weight vertex verbatim (the same branch a frozen
// vertex takes).
//
// FROZEN MEANS FROZEN, AND THE BRUSH IS NOT AN EXCEPTION. The freeze mask is a
// GEOMETRIC fact computed by core from the resolved clearance predicates (bolt
// bores, mating pads, anchor and load faces, Protect groups) — the app never
// re-derives it. Three layers keep it:
//
//   1. `paint` REFUSES a frozen vertex. It is not added to the region, so the
//      user sees the brush decline instead of appearing to work.
//   2. `vertexWeights` writes 0 at every frozen index unconditionally, whatever
//      the region assignments say.
//   3. core tests `frozen[v]` FIRST in the update and copies the vertex verbatim.
//
// That is exclusion at the geometry level at every layer. Nothing here smooths a
// protected vertex and puts it back afterwards.
//
// A pure value type — no SwiftUI, no GPU, no bridge — so painting, per-region
// strength, undo/redo and the weight derivation are all unit-tested headlessly
// (the /app/ verification standard). The gesture layer feeds it triangle indices
// exactly as `PaintModel` is fed today.

import Foundation
import simd
import TopOptDesign

// MARK: - the freeze mask (a geometric fact, never an app opinion)

/// The per-vertex freeze mask core computed for this mesh, plus the tolerance it
/// used. Built ONLY from `TopOptKit.smoothFreezeMask`, which calls core's own
/// `compute_freeze_mask` on the same resolved regions the smoother will apply —
/// so what the brush refuses and what the smoother protects are one answer.
///
/// `unavailable` is the honest empty state: before the mask has been fetched the
/// brush must not paint at all, because it cannot yet know what it would touch.
public struct SmoothFreezeMask: Equatable, Sendable {
    /// `frozen[v]` — one entry per mesh vertex.
    public let frozen: [Bool]
    /// The tolerance core used (mm): 0.75 × the analysis grid spacing.
    public let toleranceMM: Double
    /// THE MESH FILE core computed this mask from (round 2, bar S3). A vertex
    /// count is a weak identity — two different meshes can share one. The path
    /// is what the mask is actually ABOUT, so the brush compares it too.
    /// Empty means "not stated", which matches a brush that states none.
    public let meshPath: String

    public init(frozen: [Bool], toleranceMM: Double, meshPath: String = "") {
        self.frozen = frozen
        self.toleranceMM = toleranceMM
        self.meshPath = meshPath
    }

    /// The mask for a mesh whose freeze regions have not been resolved yet. NOT
    /// "nothing is frozen" — `paintable` is false, so the brush is inert.
    public static let unavailable = SmoothFreezeMask(frozen: [], toleranceMM: 0)

    public var isAvailable: Bool { !frozen.isEmpty }
    public var frozenCount: Int { frozen.reduce(0) { $0 + ($1 ? 1 : 0) } }
    public var vertexCount: Int { frozen.count }

    /// Whether vertex `v` may be painted. An out-of-range index and an
    /// unavailable mask both answer NO — the brush never paints into the unknown.
    public func paintable(_ v: Int) -> Bool {
        guard v >= 0, v < frozen.count else { return false }
        return !frozen[v]
    }
}

// MARK: - the brush's own tools (round 2, bar L4)

/// Paint / erase / orbit, and the brush disc's size.
///
/// WHY THIS EXISTS. Round 1 shipped the page with NO brush tools of its own: the
/// on/off toggle, the eraser and the size stepper all lived in the TO page's
/// paint drawer, so the smoothing page could only be USED with the workspace
/// chrome left on screen underneath it. That is the mechanical reason it was an
/// overlay rather than a page — hiding the chrome would have disarmed the brush.
/// Moving the tools onto the page is therefore the precondition for bar L1, not
/// a cosmetic tidy.
///
/// A pure value, so the mode rules are unit-tested headlessly like the rest of
/// the brush.
public struct SmoothBrushTools: Equatable, Sendable {

    public enum Mode: String, Sendable, CaseIterable, Identifiable {
        /// One-finger drag adds triangles to the active region.
        case paint
        /// One-finger drag removes triangles from their region.
        case erase
        /// One-finger drag orbits the part instead of painting — the way to
        /// LOOK at what you brushed. Without it the page would have no
        /// single-finger orbit at all, since the brush claims that gesture.
        case orbit

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .paint: return "Paint"
            case .erase: return "Erase"
            case .orbit: return "Orbit"
            }
        }
        public var icon: String {
            switch self {
            case .paint: return "paintbrush.pointed.fill"
            case .erase: return "eraser.fill"
            case .orbit: return "rotate.3d"
            }
        }
    }

    public var mode: Mode
    /// The brush disc radius in screen points — the same units and the same
    /// bounds the TO page's paint drawer used, so the gesture feels identical.
    public var radiusPoints: Double

    public static let minRadius: Double = 12
    public static let maxRadius: Double = 64
    public static let radiusStep: Double = 6

    public init(mode: Mode = .paint, radiusPoints: Double = 26) {
        self.mode = mode
        self.radiusPoints = min(max(radiusPoints, Self.minRadius), Self.maxRadius)
    }

    /// Whether a one-finger drag paints at all (false in `.orbit`).
    public var paints: Bool { mode != .orbit }
    /// Whether a painting drag REMOVES rather than adds.
    public var erases: Bool { mode == .erase }

    public mutating func grow() {
        radiusPoints = min(radiusPoints + Self.radiusStep, Self.maxRadius)
    }
    public mutating func shrink() {
        radiusPoints = max(radiusPoints - Self.radiusStep, Self.minRadius)
    }
    public var canGrow: Bool { radiusPoints < Self.maxRadius }
    public var canShrink: Bool { radiusPoints > Self.minRadius }
}

// MARK: - one painted region

/// A region of the variant's surface with its OWN smoothing strength. Auto-named
/// and colour-coded from the same palette the selection groups use, so a third
/// visual language is not invented for a third page.
public struct SmoothRegion: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// User-editable label, auto-seeded "Region A", "Region B", …
    public var name: String
    /// Palette slot in `DS.Color.groupPalette`.
    public var colorIndex: Int
    /// This region's own strength ∈ [0, 1]. 0 = painted but inert (the region is
    /// still listed, so "I turned this one off" is a visible, reversible state).
    public var strength: Double

    public init(id: UUID = UUID(), name: String, colorIndex: Int,
                strength: Double) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.strength = min(max(strength, 0), 1)
    }

    public var color: RGBA {
        let palette = DS.Color.groupPalette
        return palette[((colorIndex % palette.count) + palette.count) % palette.count]
    }
}

/// One reversible brush edit: which triangles changed region, from what to what.
/// Both ends are stored, so an edit is exactly invertible — the same shape
/// `PaintEdit` uses, for the same reason.
public struct SmoothBrushEdit: Equatable, Sendable {
    public struct Change: Equatable, Sendable {
        public var triangle: Int32
        public var from: UUID?
        public var to: UUID?
        public init(triangle: Int32, from: UUID?, to: UUID?) {
            self.triangle = triangle
            self.from = from
            self.to = to
        }
    }
    public var changes: [Change]
    public var isEmpty: Bool { changes.isEmpty }
    public init(changes: [Change] = []) { self.changes = changes }
}

// MARK: - the brush state machine

public struct SmoothBrushModel: Equatable, Sendable {

    /// Add triangles to the active region, or erase them back to unpainted.
    public enum Mode: String, Sendable { case add, erase }

    /// The regions, in creation order (the panel's row order).
    public private(set) var regions: [SmoothRegion] = []
    /// The region new strokes paint into.
    public private(set) var activeRegionID: UUID?
    /// triangle index → owning region. A triangle absent from this map is
    /// unpainted, and every one of its vertices gets weight 0.
    public private(set) var assignments: [Int32: UUID] = [:]

    /// The mesh's triangle corner indices (flattened, 3 per triangle) — how a
    /// painted TRIANGLE becomes painted VERTICES. Held so weight derivation is a
    /// pure function of this value.
    public let indices: [Int32]
    /// The mesh's vertex count.
    public let vertexCount: Int
    /// Core's freeze mask for this mesh.
    public let freeze: SmoothFreezeMask
    /// The file the painted mesh was read from — stamped by
    /// `SmoothPageMesh.brush(freeze:)`, empty when none was stated. Compared
    /// against the mask's own path, so "same count, different mesh" is caught
    /// rather than painted (round 2, bar S3).
    public let meshPath: String

    private var nextColor: Int = 0

    public init(indices: [Int32], vertexCount: Int, freeze: SmoothFreezeMask,
                meshPath: String = "") {
        self.indices = indices
        self.vertexCount = vertexCount
        self.freeze = freeze
        self.meshPath = meshPath
    }

    public var isEmpty: Bool { assignments.isEmpty }
    public var activeRegion: SmoothRegion? { regions.first { $0.id == activeRegionID } }

    /// Whether the mask and the painted mesh are the SAME mesh. Two conditions,
    /// because a vertex count is a weak identity:
    ///
    ///   * the counts agree — one weight per vertex, or the vector core consumes
    ///     is not even the right length;
    ///   * and, when both sides state a file, they state the SAME file. Round 2's
    ///     measurement is why: the on-device path's mesh matched core's on COUNT
    ///     AND on order, while the LAN path's differed 6:1. A count check alone
    ///     would pass a same-size mesh from a different variant and paint the
    ///     wrong vertices in silence, which is worse than refusing.
    ///
    /// Either side leaving its path empty means "not stated" and does not fail
    /// the check — the mask carries a path only when core told us one.
    public var meshesAgree: Bool {
        guard freeze.isAvailable, freeze.vertexCount == vertexCount else { return false }
        if meshPath.isEmpty || freeze.meshPath.isEmpty { return true }
        return meshPath == freeze.meshPath
    }

    /// The brush can only be used once core has told us what is frozen. Until
    /// then every paint call is a no-op and the page says why.
    public var canPaint: Bool { meshesAgree }

    /// The one-line reason the brush is inert, or nil when it is usable.
    public var unusableReason: String? {
        if meshesAgree { return nil }
        if !freeze.isAvailable {
            return "Working out which surfaces are protected — the brush unlocks "
                 + "once the bores, mating faces and anchors are resolved."
        }
        if freeze.vertexCount != vertexCount {
            return "The protected-surface map describes a different mesh "
                 + "(\(freeze.vertexCount) vertices vs \(vertexCount)) — refusing to "
                 + "paint rather than guess which vertices it means."
        }
        return "The protected-surface map was computed for a different file "
             + "(\(freeze.meshPath) vs \(meshPath)) — the vertex counts match, "
             + "but matching counts are not the same vertices, so this refuses "
             + "rather than guess."
    }

    // MARK: - regions

    @discardableResult
    public mutating func addRegion(strength: Double = 0.35) -> UUID {
        let palette = DS.Color.groupPalette
        let letter = Character(UnicodeScalar(UInt8(65 + (regions.count % 26))))
        let r = SmoothRegion(name: "Region \(letter)",
                             colorIndex: nextColor % palette.count,
                             strength: strength)
        nextColor += 1
        regions.append(r)
        activeRegionID = r.id
        return r.id
    }

    public mutating func setActive(_ id: UUID) {
        if regions.contains(where: { $0.id == id }) { activeRegionID = id }
    }

    public mutating func rename(_ id: UUID, to name: String) {
        guard let i = regions.firstIndex(where: { $0.id == id }) else { return }
        regions[i].name = name
    }

    /// Set one region's strength. Clamped to [0,1]; unknown id is a no-op. This is
    /// the "inspectable and reversible" half of local strength — nothing is baked
    /// into the painted set, so a strength change never re-paints anything.
    public mutating func setStrength(_ id: UUID, _ strength: Double) {
        guard let i = regions.firstIndex(where: { $0.id == id }) else { return }
        regions[i].strength = min(max(strength, 0), 1)
    }

    /// Remove a region and unpaint its triangles.
    public mutating func removeRegion(_ id: UUID) {
        guard regions.contains(where: { $0.id == id }) else { return }
        regions.removeAll { $0.id == id }
        assignments = assignments.filter { $0.value != id }
        if activeRegionID == id { activeRegionID = regions.last?.id }
    }

    /// Triangle count currently painted into `id`.
    public func triangleCount(_ id: UUID) -> Int {
        assignments.reduce(0) { $0 + ($1.value == id ? 1 : 0) }
    }

    // MARK: - painting

    /// The vertices of triangle `t`, or nil if the index is out of range.
    private func corners(_ t: Int32) -> (Int, Int, Int)? {
        let base = Int(t) * 3
        guard t >= 0, base + 2 < indices.count else { return nil }
        return (Int(indices[base]), Int(indices[base + 1]), Int(indices[base + 2]))
    }

    /// A triangle may be painted only if it has at least one vertex the brush is
    /// allowed to move. A triangle whose every corner is frozen is REFUSED — the
    /// stroke does not take, so the frozen region reads as untouchable rather than
    /// as painted-but-secretly-ignored.
    public func paintable(triangle t: Int32) -> Bool {
        guard canPaint, let (a, b, c) = corners(t) else { return false }
        return freeze.paintable(a) || freeze.paintable(b) || freeze.paintable(c)
    }

    /// Apply one stroke and return its exact inverse-able edit.
    ///
    /// - `.add`: every PAINTABLE triangle joins `into` (defaulting to the active
    ///   region, creating one if there is none). Triangles that are entirely
    ///   inside a frozen region are dropped — layer 1 of the freeze guarantee.
    /// - `.erase`: every painted triangle in the stroke becomes unpainted.
    ///
    /// Triangles are de-duplicated and processed in ascending order, and a
    /// triangle already at its destination contributes no change — so the edit is
    /// minimal and deterministic, and re-painting a stroke is a no-op.
    @discardableResult
    public mutating func paint(_ mode: Mode, triangles: [Int32],
                               into region: UUID? = nil) -> SmoothBrushEdit {
        guard canPaint else { return SmoothBrushEdit() }
        var target: UUID? = region ?? activeRegionID
        if mode == .add, target == nil { target = addRegion() }
        if mode == .add, let t = target, !regions.contains(where: { $0.id == t }) {
            return SmoothBrushEdit()
        }

        var changes: [SmoothBrushEdit.Change] = []
        for t in Array(Set(triangles)).sorted() {
            let old = assignments[t]
            switch mode {
            case .add:
                guard let dest = target, paintable(triangle: t), old != dest else { continue }
                changes.append(.init(triangle: t, from: old, to: dest))
                assignments[t] = dest
            case .erase:
                guard old != nil else { continue }
                changes.append(.init(triangle: t, from: old, to: nil))
                assignments[t] = nil
            }
        }
        return SmoothBrushEdit(changes: changes)
    }

    public mutating func undo(_ edit: SmoothBrushEdit) {
        for c in edit.changes { assignments[c.triangle] = c.from }
    }

    public mutating func redo(_ edit: SmoothBrushEdit) {
        for c in edit.changes { assignments[c.triangle] = c.to }
    }

    /// Unpaint everything, keeping the regions and their strengths (the "start the
    /// strokes over" affordance, distinct from discarding the whole smoothing).
    public mutating func clearStrokes() { assignments.removeAll() }

    // MARK: - the weight vector core consumes

    /// The per-vertex weight vector for `TopOptKit.smoothBrushAndRecertifyLoadCase`
    /// — one entry per mesh vertex, each in [0,1].
    ///
    /// A vertex takes the STRONGEST strength among the regions whose triangles
    /// touch it. Max, not sum and not last-writer: two overlapping strokes must
    /// give a deterministic answer that never exceeds either region's own stated
    /// strength, and "the strongest thing I asked for here" is the reading a user
    /// can predict from the panel.
    ///
    /// A FROZEN VERTEX IS ALWAYS 0, whatever the assignments say — layer 2. (Layer
    /// 1 already stopped it being painted; layer 3 is core's own first-test branch.
    /// The redundancy is the point: no single edit can undo the guarantee.)
    public func vertexWeights() -> [Double] {
        var w = [Double](repeating: 0, count: vertexCount)
        guard canPaint else { return w }
        var strengthByRegion: [UUID: Double] = [:]
        for r in regions { strengthByRegion[r.id] = r.strength }
        for (t, id) in assignments {
            guard let s = strengthByRegion[id], s > 0, let (a, b, c) = corners(t)
            else { continue }
            for v in [a, b, c] where v >= 0 && v < w.count {
                if s > w[v] { w[v] = s }
            }
        }
        for v in 0..<w.count where freeze.frozen[v] { w[v] = 0 }
        return w
    }

    /// The strongest region strength that will actually be applied — what the page
    /// passes as the uniform `strength` knob, so the product `strength · weight[v]`
    /// reproduces each region's own strength exactly at its strongest vertices.
    public var maxStrength: Double {
        var m = 0.0
        for r in regions where triangleCount(r.id) > 0 {
            if r.strength > m { m = r.strength }
        }
        return m
    }

    /// The weight vector rescaled so `maxStrength · normalizedWeights()[v]` equals
    /// the weight the user asked for. Core multiplies the pass factor by
    /// `strength · w[v]`, so the page sends `maxStrength` and these.
    public func normalizedWeights() -> [Double] {
        let m = maxStrength
        guard m > 0 else { return [Double](repeating: 0, count: vertexCount) }
        return vertexWeights().map { $0 / m }
    }

    /// Whether there is anything to smooth: at least one region with a positive
    /// strength and at least one painted triangle.
    public var hasEffect: Bool { maxStrength > 0 && !assignments.isEmpty }

    // MARK: - inspectability (item 3: "must be inspectable and reversible")

    /// A per-region readout: how much surface it covers and at what strength.
    public struct RegionSummary: Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let strength: Double
        public let triangles: Int
        public let vertices: Int
        /// Vertices the stroke touched that are FROZEN, and so contribute nothing.
        /// Surfaced rather than hidden: a user who painted over a bolt circle must
        /// be told the brush stopped at it, not left to infer it from the result.
        public let frozenTouched: Int
        public var inert: Bool { strength <= 0 || vertices == 0 }
    }

    /// The per-vertex tint the stage paints the variant with, so the brush is
    /// VISIBLE — a brush whose strokes you cannot see is not a brush.
    ///
    /// It rides the viewer's existing per-vertex tint channel (the same one the
    /// lattice density proxy uses), so this costs no new GPU buffer and no new
    /// renderer path. Three states, and the third is the point:
    ///
    ///   * unpainted  → clear (the mesh's own shading shows through);
    ///   * painted    → the region's colour, opacity rising with its strength, so
    ///     "this bit is at 0.2 and that bit is at 0.9" is legible at a glance;
    ///   * FROZEN     → a flat locked tint, drawn WHATEVER the strokes say. The
    ///     user can see what the brush will refuse BEFORE trying to paint it,
    ///     rather than discovering it from a footnote afterwards.
    public func vertexTints(frozenTint: SIMD4<Float> =
                                SIMD4<Float>(0.42, 0.85, 0.55, 0.34)) -> [SIMD4<Float>] {
        var out = [SIMD4<Float>](repeating: .zero, count: vertexCount)
        guard meshesAgree else { return out }
        var colorByRegion: [UUID: (RGBA, Double)] = [:]
        for r in regions { colorByRegion[r.id] = (r.color, r.strength) }
        for (t, id) in assignments {
            guard let (c, s) = colorByRegion[id], let (a, b, d) = corners(t) else { continue }
            // Opacity floors at 0.20 so a strength-0 region is still visibly
            // painted — "I brushed here and turned it off" is a state the user
            // must be able to see, not an invisible one.
            let alpha = Float(0.20 + 0.60 * min(max(s, 0), 1))
            for v in [a, b, d] where v >= 0 && v < out.count {
                if alpha > out[v].w {
                    out[v] = SIMD4<Float>(Float(c.r), Float(c.g), Float(c.b), alpha)
                }
            }
        }
        for v in 0..<out.count where freeze.frozen[v] { out[v] = frozenTint }
        return out
    }

    public func summaries() -> [RegionSummary] {
        regions.map { r in
            var verts = Set<Int>()
            var frozenTouched = Set<Int>()
            for (t, id) in assignments where id == r.id {
                guard let (a, b, c) = corners(t) else { continue }
                for v in [a, b, c] {
                    guard v >= 0, v < vertexCount else { continue }
                    if freeze.isAvailable, v < freeze.frozen.count, freeze.frozen[v] {
                        frozenTouched.insert(v)
                    } else {
                        verts.insert(v)
                    }
                }
            }
            return RegionSummary(id: r.id, name: r.name, strength: r.strength,
                                 triangles: triangleCount(r.id),
                                 vertices: verts.count,
                                 frozenTouched: frozenTouched.count)
        }
    }
}
