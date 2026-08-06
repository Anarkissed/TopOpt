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
/// ── THE TWO CONTROLS, AND WHAT EACH ONE DECIDES (task 2026-08-05, bars D1/D2)
///
/// ROUND 3 REPLACED ORBIT WITH `pencilOnly`, READING AN EARLIER NOTE OF THE
/// MAINTAINER'S AS AN EITHER/OR. It is not one. His rule, stated precisely:
///
///   * `pencilOnly` OFF → the brush claims the one-finger drag, so an EXPLICIT
///     ORBIT MODE IS REQUIRED: without it there is no way to turn the part
///     around with a finger at all.
///   * `pencilOnly` ON  → a finger cannot brush and the pencil can only brush,
///     so a one-finger drag ALREADY always orbits. A third tab here would be a
///     control that does nothing new, which is clutter.
///
/// So orbit's PRESENCE is conditional on `pencilOnly` being off (`availableModes`),
/// and turning `pencilOnly` on while in orbit falls back to paint rather than
/// leaving a dead mode selected (`setPencilOnly`).
///
/// TWO QUESTIONS, TWO PROPERTIES — this is the D1 defect stated as a rule.
/// Round 3 left the page's master gate reading a property called `paints` that
/// silently meant "a FINGER paints", so checking "Pencil only" disarmed the
/// gesture entirely and the pencil never painted either. A finger-only property
/// must never decide whether the gesture EXISTS. They are now separate names:
///
///   * `armed` — does the brush claim a drag at all? MODE decides. Never contact.
///   * `paints(from:)` — may THIS contact paint? `pencilOnly` decides, and only
///     for the finger; a pencil always may while the brush is armed.
///
/// The invariant both rounds existed to guarantee — that a one-finger drag
/// always has SOME way to turn the part around — holds through both paths now:
/// `pencilOnly` ON lets the finger fall through to the camera gestures, and
/// `pencilOnly` OFF offers the Orbit mode that releases the drag.
public struct SmoothBrushTools: Equatable, Sendable {

    public enum Mode: String, Sendable, CaseIterable, Identifiable {
        /// A painting drag deepens the smoothing under the brush.
        case paint
        /// A painting drag clears it back to unsmoothed.
        case erase
        /// The brush is PARKED: a drag turns the part around instead of
        /// painting, with either contact. Offered only while `pencilOnly` is
        /// off, because that is the only state in which the brush would
        /// otherwise own the one-finger drag.
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
        /// Whether a drag in this mode marks the surface at all.
        public var marks: Bool { self != .orbit }
    }

    /// Which kind of contact a drag came from. The page's gesture layer mounts a
    /// separate recognizer per kind, so this is reported rather than guessed.
    public enum Input: String, Sendable, CaseIterable {
        case finger, pencil
    }

    public var mode: Mode
    /// The brush disc radius in screen points — the same units and the same
    /// bounds the TO page's paint drawer used, so the gesture feels identical.
    public var radiusPoints: Double
    /// ONLY THE PENCIL PAINTS (bar U2). A finger drag then orbits, always, with
    /// no mode to switch.
    public var pencilOnly: Bool

    public static let minRadius: Double = 12
    public static let maxRadius: Double = 64
    public static let radiusStep: Double = 6

    public init(mode: Mode = .paint, radiusPoints: Double = 26,
                pencilOnly: Bool = false) {
        // Orbit is not offered while `pencilOnly` is on, so it cannot be the
        // state a value STARTS in either — normalised here so there is no
        // reachable way to hold a mode the page would not draw a tab for.
        self.mode = (pencilOnly && mode == .orbit) ? .paint : mode
        self.radiusPoints = min(max(radiusPoints, Self.minRadius), Self.maxRadius)
        self.pencilOnly = pencilOnly
    }

    /// The modes the page offers RIGHT NOW (bar D2). Orbit only while the finger
    /// would otherwise be claimed by the brush.
    public var availableModes: [Mode] { Self.modes(pencilOnly: pencilOnly) }

    public static func modes(pencilOnly: Bool) -> [Mode] {
        pencilOnly ? [.paint, .erase] : Mode.allCases
    }

    /// Set "Pencil only", falling back OUT of orbit when it is turned on — a
    /// selected mode with no tab is a dead control, and the page would otherwise
    /// sit in it with nothing on screen to leave it by.
    public mutating func setPencilOnly(_ on: Bool) {
        pencilOnly = on
        if on, mode == .orbit { mode = .paint }
    }

    /// WHETHER THE BRUSH CLAIMS A DRAG AT ALL. The MODE decides this and nothing
    /// else — see the type comment: a contact-kind property here is the D1 defect.
    public var armed: Bool { mode.marks }

    /// Whether a drag from `input` paints. A pencil always may while the brush is
    /// armed; a finger may only when it has not been released to the camera.
    public func paints(from input: Input) -> Bool {
        guard armed else { return false }
        switch input {
        case .pencil: return true
        case .finger: return !pencilOnly
        }
    }

    /// Whether a ONE-FINGER drag paints. RENAMED from `paints` (task 2026-08-05):
    /// a property called `paints` that silently meant "a finger paints" is how it
    /// came to be read as "the brush is armed" at the page's master gate, which
    /// killed the pencil too. The name now says which contact it is about, so the
    /// same mistake cannot be written by accident.
    public var fingerPaints: Bool { paints(from: .finger) }
    /// Whether a painting drag REMOVES rather than adds.
    public var erases: Bool { mode == .erase }
    /// Whether a one-finger drag turns the part around — the property the page
    /// exists to guarantee is always reachable.
    public var fingerOrbits: Bool { !paints(from: .finger) }

    public mutating func grow() {
        radiusPoints = min(radiusPoints + Self.radiusStep, Self.maxRadius)
    }
    public mutating func shrink() {
        radiusPoints = max(radiusPoints - Self.radiusStep, Self.minRadius)
    }
    public var canGrow: Bool { radiusPoints < Self.maxRadius }
    public var canShrink: Bool { radiusPoints > Self.minRadius }
}

// MARK: - who may paint, and where a drag goes (task 2026-08-05, bar D1)

/// ONE DECISION, READ BY EVERY SITE THAT ROUTES A DRAG.
///
/// THE DEFECT THIS EXISTS TO MAKE UNWRITABLE. Round 2 armed the viewer's brush
/// gesture from one property; round 3 added `brushRequiresPencil` as a second,
/// correct admission mechanism at the recognizer — and left the first one
/// reading a finger-only value. Two mechanisms decided the same thing, the
/// stricter one won, and checking a box called "Pencil only" turned off painting
/// entirely, the pencil included. The maintainer lost a night to it.
///
/// So the question is asked ONCE here and the answer is passed down. The
/// workspace builds this value; the view's inputs carry its two fields; the
/// recognizers route through `route(_:touches:)`. There is no second place to
/// disagree with.
public struct BrushGesture: Equatable, Sendable {
    /// Does the brush claim a drag at all? Off ⇒ every contact is the camera's.
    public let armed: Bool
    /// Is the brush withholding the FINGER (the pencil is never withheld)?
    public let requiresPencil: Bool

    public init(armed: Bool, requiresPencil: Bool) {
        self.armed = armed
        self.requiresPencil = requiresPencil
    }

    /// The smoothing page: the brush is armed unless the user parked it in
    /// Orbit, and WHICH contact may paint is `pencilOnly`'s business alone.
    public static func smoothingPage(_ tools: SmoothBrushTools) -> BrushGesture {
        BrushGesture(armed: tools.armed, requiresPencil: tools.pencilOnly)
    }

    /// The TO page's paint drawer — unchanged behaviour: armed by its own toggle,
    /// and it never withholds the finger.
    public static func workspacePaint(active: Bool) -> BrushGesture {
        BrushGesture(armed: active, requiresPencil: false)
    }

    /// The brush is off everywhere else.
    public static let off = BrushGesture(armed: false, requiresPencil: false)

    /// May a drag from `input` paint?
    public func admits(_ input: SmoothBrushTools.Input) -> Bool {
        guard armed else { return false }
        switch input {
        case .pencil: return true
        case .finger: return !requiresPencil
        }
    }

    /// Where a drag goes.
    public enum Route: String, Equatable, Sendable {
        /// Into the brush.
        case paint
        /// To the camera's orbit.
        case orbit
        /// To the camera's pan (two fingers, brush not claiming the drag).
        case pan
    }

    /// Route a drag of `touches` contacts of kind `input`.
    ///
    /// The rules, unchanged from what the recognizers did before this value
    /// existed — one finger paints while the brush admits it, two fingers orbit
    /// so the camera stays drivable mid-stroke, and a contact the brush does not
    /// admit falls through to the ordinary camera gestures (two fingers pan, one
    /// orbits). What changed is that they are stated once.
    public func route(_ input: SmoothBrushTools.Input, touches: Int) -> Route {
        if admits(input) {
            // A pencil is always exactly one contact; a finger drag with a second
            // finger down is the user reaching for the camera mid-stroke.
            if input == .pencil || touches <= 1 { return .paint }
            return .orbit
        }
        return touches >= 2 ? .pan : .orbit
    }

    /// Whether a drag from `input` is being REFUSED — the brush is armed and this
    /// contact still cannot paint. The page says so at the moment it happens
    /// rather than leaving grey buttons downstream to imply it.
    public func refuses(_ input: SmoothBrushTools.Input) -> Bool {
        armed && !admits(input)
    }
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

    /// THE STRENGTH LADDER (bar U1). The maintainer's instruction was to take the
    /// region concept out of the UI entirely — no region list, no per-region
    /// strength slider — and let the model itself be the interface: "TINT THE
    /// MODEL where painted — darker tint = more smoothing".
    ///
    /// That only works if strength has somewhere to come from once the slider is
    /// gone, and there is exactly one input left: the brush. So brushing an area
    /// AGAIN deepens it, one rung per stroke, the way every sculpting tool
    /// behaves. The tint darkens with the rung, so how hard an area is being
    /// smoothed is legible from the part rather than from a list beside it.
    ///
    /// THE REGION MODEL IS KEPT, INTERNALLY, exactly as the task allows — one
    /// region per rung, created on first use. That is not a leftover: every
    /// downstream seam (`vertexWeights`, `maxStrength`, `normalizedWeights`, the
    /// receipt's region lines) is already written against regions and is
    /// unchanged by this, so the freeze guarantee — bar B2, PR 279's AE1 — passes
    /// through untouched code.
    public static let levels: [Double] = [0.25, 0.50, 0.75, 1.00]

    /// rung index (1-based) → the region backing it.
    private var levelRegion: [Int: UUID] = [:]
    /// Triangles already deepened during the CURRENT stroke. A drag emits many
    /// samples over the same triangles, so without this one gesture would run
    /// straight to the top rung. One stroke, one rung.
    private var strokeTouched: Set<Int32> = []

    public init(indices: [Int32], vertexCount: Int, freeze: SmoothFreezeMask,
                meshPath: String = "") {
        self.indices = indices
        self.vertexCount = vertexCount
        self.freeze = freeze
        self.meshPath = meshPath
    }

    // MARK: - the ladder

    /// Which rung triangle `t` sits on: 0 = unpainted, 1…`levels.count`.
    public func level(of t: Int32) -> Int {
        guard let id = assignments[t] else { return 0 }
        for (rung, rid) in levelRegion where rid == id { return rung }
        return 0
    }

    /// The strongest rung any triangle currently sits on — what the panel's own
    /// readout reports, since there is no list to read it off any more.
    public var deepestLevel: Int {
        assignments.keys.reduce(0) { max($0, level(of: $1)) }
    }

    /// The region backing `rung`, created on first use so an untouched brush
    /// still reports no regions at all.
    private mutating func region(forLevel rung: Int) -> UUID {
        if let id = levelRegion[rung] { return id }
        let clamped = min(max(rung, 1), Self.levels.count)
        let id = addRegion(strength: Self.levels[clamped - 1])
        regions[regions.count - 1].name = "Level \(clamped)"
        levelRegion[rung] = id
        return id
    }

    /// A new stroke begins: the per-gesture dedup resets, so this drag may deepen
    /// each triangle it covers once.
    public mutating func beginStroke() { strokeTouched.removeAll() }
    /// The stroke ends. Separate from `beginStroke` so a cancelled gesture and a
    /// completed one leave the same state.
    public mutating func endStroke() { strokeTouched.removeAll() }

    /// THE PAGE'S ONE PAINTING ENTRY POINT (bar U1). Deepen (or clear) every
    /// covered triangle, and return the exactly-invertible edit.
    ///
    /// `.paint` moves each triangle up one rung, capped at the top, and at most
    /// once per stroke. `.erase` clears it outright — the maintainer asked for a
    /// paint/erase toggle, not a rung-by-rung undo, and "take the smoothing off
    /// here" is what erase means everywhere else in the app.
    ///
    /// Frozen triangles are refused here exactly as they are by `paint` — this
    /// routes THROUGH it rather than round it, so layer 1 of the freeze guarantee
    /// is the same code.
    @discardableResult
    public mutating func brush(_ mode: SmoothBrushTools.Mode,
                               triangles: [Int32]) -> SmoothBrushEdit {
        // `.orbit` is a parked brush, not a stroke. The gesture layer already
        // routes it to the camera, so this is the second layer: a mode that does
        // not mark the surface can never mark it from here either.
        guard mode.marks, canPaint else { return SmoothBrushEdit() }
        if mode == .erase {
            return paint(.erase, triangles: triangles)
        }
        var changes: [SmoothBrushEdit.Change] = []
        for t in Array(Set(triangles)).sorted() {
            guard !strokeTouched.contains(t), paintable(triangle: t) else { continue }
            strokeTouched.insert(t)
            let next = min(level(of: t) + 1, Self.levels.count)
            let dest = region(forLevel: next)
            let old = assignments[t]
            guard old != dest else { continue }
            changes.append(.init(triangle: t, from: old, to: dest))
            assignments[t] = dest
        }
        return SmoothBrushEdit(changes: changes)
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
    ///
    /// Also closes any stroke in flight: a clear that left the per-gesture set
    /// behind would make the NEXT stroke over the same triangles a no-op, which
    /// reads as a dead brush.
    public mutating func clearStrokes() {
        assignments.removeAll()
        strokeTouched.removeAll()
    }

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
    /// ORANGE, 10% PER PASS, LAYERING (task 2026-08-05, bar D4 — the maintainer's
    /// own specification).
    ///
    /// One hue, and the OPACITY is the readout: a first pass lays 10% orange, a
    /// second pass over the same area adds another 10%, and so on, so how hard an
    /// area has been worked is legible from the part itself. Round 3 encoded the
    /// same fact half in opacity and half in VALUE (the tint darkened toward
    /// black); his instruction is opacity, so the hue and the value are now
    /// constant and only `w` moves.
    ///
    /// THE CAP IS THE LADDER'S CAP, and that is the whole justification: strength
    /// stops climbing at `levels.count` passes (the top rung is 1.00 — there is
    /// no more smoothing to ask for), so the tint stops there too at
    /// `0.10 × levels.count`. A tint that kept darkening past the point where the
    /// result stopped changing would be the page lying about what a pass did.
    ///
    /// ERASE CLEARS IT OUTRIGHT — the accumulated passes go with the assignment,
    /// exactly as erase clears the smoothing itself (round 3's rule: erase is
    /// "take the smoothing off here", not a rung-by-rung undo).
    public static let paintTint = SIMD3<Float>(1.00, 0.48, 0.10)
    /// Opacity added per pass.
    public static let tintPerPass: Float = 0.10

    /// The tint for a triangle sitting on `rung` (0 = unpainted).
    public static func tint(forRung rung: Int) -> SIMD4<Float> {
        guard rung > 0 else { return .zero }
        let capped = min(rung, levels.count)
        return SIMD4<Float>(paintTint.x, paintTint.y, paintTint.z,
                            tintPerPass * Float(capped))
    }

    /// The FROZEN tint — a flat locked green, drawn whatever the strokes say, so
    /// what the brush will refuse is visible before it is tried.
    public static let frozenTintDefault = SIMD4<Float>(0.42, 0.85, 0.55, 0.34)

    /// The per-MESH-VERTEX tint. Kept because the weight/freeze reasoning is all
    /// per mesh vertex — but note that this is NOT what the viewer consumes; see
    /// `viewerTints`, and the header comment there for why that mattered.
    public func vertexTints(frozenTint: SIMD4<Float> = frozenTintDefault)
        -> [SIMD4<Float>] {
        var out = [SIMD4<Float>](repeating: .zero, count: vertexCount)
        guard meshesAgree else { return out }
        for t in assignments.keys {
            let c = Self.tint(forRung: level(of: t))
            guard c.w > 0, let (a, b, d) = corners(t) else { continue }
            for v in [a, b, d] where v >= 0 && v < out.count {
                if c.w > out[v].w { out[v] = c }
            }
        }
        for v in 0..<out.count where freeze.frozen[v] { out[v] = frozenTint }
        return out
    }

    /// THE TINT THE VIEWER ACTUALLY DRAWS — one entry per FLAT (unshared) render
    /// vertex, three per triangle, in triangle order.
    ///
    /// WHY THIS EXISTS, AND WHY THE TINT HAD NEVER APPEARED ON DEVICE. The stage
    /// consumes tints through `MetalMeshView`'s per-vertex channel, and the
    /// renderer draws the FLAT buffer: `ViewerMesh.flat.vertexCount` is
    /// `3 × triangleCount`, not the welded vertex count. `Renderer.setStressTints`
    /// (MetalMeshView.swift:1380) requires exactly that length and RETURNS
    /// SILENTLY otherwise — and the smoothing page was handing it
    /// `vertexTints()`, one entry per WELDED vertex. On the maintainer's bracket
    /// those two numbers differ by about 6:1, so every upload was dropped on the
    /// floor and no stroke he ever painted could have tinted anything.
    ///
    /// Per-flat-vertex is also the RIGHT unit for this brush: a stroke paints
    /// TRIANGLES, so an unshared buffer paints exactly the triangles that were
    /// brushed, with no bleed across a shared corner into an unpainted neighbour.
    /// Frozen vertices still win over a stroke, as they do everywhere else.
    public func viewerTints(frozenTint: SIMD4<Float> = frozenTintDefault)
        -> [SIMD4<Float>] {
        var out = [SIMD4<Float>](repeating: .zero, count: indices.count)
        guard meshesAgree else { return out }
        for i in stride(from: 0, to: indices.count, by: 3) {
            let t = Int32(i / 3)
            let c = Self.tint(forRung: level(of: t))
            for k in 0..<3 {
                let v = Int(indices[i + k])
                let frozen = v >= 0 && v < freeze.frozen.count && freeze.frozen[v]
                out[i + k] = frozen ? frozenTint : c
            }
        }
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
