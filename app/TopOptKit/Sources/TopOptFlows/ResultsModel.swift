// ResultsModel.swift — the M7.8 results-screen logic, factored out of the SwiftUI
// view so it is verified headlessly (the M7 /app/ standard: tested logic here,
// device-QA pixels in ResultsScreen). It turns a finished `OptimizeOutcome` into
// the design's results presentation: the savings tabs, the recommended-orientation
// copy, the "Layer shear" readout, and the stress-overlay color ramp + shared
// scale. Matches the RESULTS section of docs/design/TopOpt.dc.html.
//
// Per DECISIONS.md 2026-07-11 (M7.8), print time is OMITTED in v1 — the design's
// orientation sheet shows Print time + Layer shear, but v1 keeps only Layer shear.
// The Metal rendering of the variant mesh / stress vertex-coloring / threshold
// morph is a separate follow-up; this file drives the chrome + the scrub state.

import Foundation
import simd
import TopOptKit
import TopOptDesign

/// Layer-shear risk for a variant's chosen orientation, classified from the
/// interlayer stress margin (safety factor: knocked-down yield ÷ max layer-plane
/// tension; larger is safer). The thresholds are a presentation heuristic (not a
/// physics gate — the physics gate is the accepted/rejected margin at 1.5×), so
/// they are named + tested here and may be tuned without touching the core.
public enum LayerShear: Equatable, Sendable {
    case low, moderate, high

    /// Design label ("Low ✓" renders the ✓ + green tint in the view when `isLow`).
    public var label: String {
        switch self {
        case .low: return "Low"
        case .moderate: return "Moderate"
        case .high: return "High"
        }
    }
    /// Whether interlayer failure is a low concern (the green, checkmarked state).
    public var isLow: Bool { self == .low }

    /// Classify from the interlayer margin. A non-finite margin means the layer
    /// planes carry ~no tension (unbounded safety) → Low.
    public static func classify(interlayerMargin m: Double) -> LayerShear {
        if !m.isFinite || m >= 2.0 { return .low }
        if m >= 1.25 { return .moderate }
        return .high
    }
}

/// A grid-indexed scalar field (the variant's per-voxel von Mises stress, MPa)
/// with the grid geometry needed to sample it at a mesh vertex. The index layout
/// matches the core `VoxelGrid::index` = (k*ny + j)*nx + i.
public struct StressField: Sendable {
    public let nx: Int
    public let ny: Int
    public let nz: Int
    public let origin: SIMD3<Float>   // grid minimum corner (world mm)
    public let spacing: Float         // voxel edge length (mm)
    public let values: [Float]        // size nx*ny*nz, MPa (may be empty)

    public init(nx: Int, ny: Int, nz: Int, origin: SIMD3<Float>, spacing: Float, values: [Float]) {
        self.nx = nx; self.ny = ny; self.nz = nz
        self.origin = origin; self.spacing = spacing; self.values = values
    }

    public var isEmpty: Bool { values.isEmpty || spacing <= 0 || nx <= 0 || ny <= 0 || nz <= 0 }

    /// Nearest-voxel value at world position `p` (0 when empty; indices clamp into
    /// range so a vertex exactly on the max face still reads the boundary voxel).
    public func value(at p: SIMD3<Float>) -> Float {
        guard !isEmpty else { return 0 }
        let i = clamp(Int(((p.x - origin.x) / spacing).rounded(.down)), nx)
        let j = clamp(Int(((p.y - origin.y) / spacing).rounded(.down)), ny)
        let k = clamp(Int(((p.z - origin.z) / spacing).rounded(.down)), nz)
        let idx = (k * ny + j) * nx + i
        return idx >= 0 && idx < values.count ? values[idx] : 0
    }

    private func clamp(_ v: Int, _ n: Int) -> Int { min(max(v, 0), n - 1) }

    /// The single highest-stress voxel (M7.viz.2 hot-spot callout): its value (MPa),
    /// the flat field index (argmax), and the world position of that voxel's center —
    /// the anchor the marker frames. Nil when the field is empty or carries no stress
    /// (all zero → nothing to call out). Ties resolve to the lowest index (stable).
    public func peak() -> (valueMPa: Float, index: Int, position: SIMD3<Float>)? {
        guard !isEmpty else { return nil }
        var bestIdx = -1
        var best: Float = 0
        for idx in values.indices where values[idx] > best {
            best = values[idx]; bestIdx = idx
        }
        guard bestIdx >= 0 else { return nil }   // every value <= 0 → no hot spot
        // Invert index = (k*ny + j)*nx + i. plane = nx*ny, so k = idx/plane,
        // rem = idx%plane, j = rem/nx, i = rem%nx.
        let plane = nx * ny
        let k = bestIdx / plane
        let rem = bestIdx % plane
        let j = rem / nx
        let i = rem % nx
        let center = origin + SIMD3<Float>(Float(i) + 0.5, Float(j) + 0.5, Float(k) + 0.5) * spacing
        return (best, bestIdx, center)
    }
}

/// A per-NODE displacement field (mm) from the FEA solve, exposed through the bridge
/// by M7.disp — the companion of `StressField` that the M7.viz.3 flex animation
/// displaces mesh vertices by. Unlike `StressField` (per-VOXEL), this is sampled at
/// grid NODES: `nx/ny/nz` are the VOXEL dims, so there are `(nx+1)*(ny+1)*(nz+1)`
/// nodes, node `(a,b,c)` at flat index `(c*(ny+1)+b)*(nx+1)+a` sits at world
/// `origin + (a,b,c)*spacing`, and its three components `[3n, 3n+1, 3n+2]` are
/// `(ux, uy, uz)`. This is NOT a physics simulation — the displacement is already
/// solved; this only samples it so the mesh can be drawn deflected.
public struct DisplacementField: Sendable {
    public let nx: Int      // VOXEL grid dims (nodes are nx+1 / ny+1 / nz+1 per axis)
    public let ny: Int
    public let nz: Int
    public let origin: SIMD3<Float>   // grid minimum corner (world mm)
    public let spacing: Float         // voxel edge length (mm)
    public let values: [Float]        // size 3*(nx+1)*(ny+1)*(nz+1), mm (may be empty)

    public init(nx: Int, ny: Int, nz: Int, origin: SIMD3<Float>, spacing: Float, values: [Float]) {
        self.nx = nx; self.ny = ny; self.nz = nz
        self.origin = origin; self.spacing = spacing; self.values = values
    }

    /// Number of grid nodes ((nx+1)·(ny+1)·(nz+1)); the field holds 3 per node.
    public var nodeCount: Int { (nx + 1) * (ny + 1) * (nz + 1) }

    public var isEmpty: Bool {
        values.isEmpty || spacing <= 0 || nx <= 0 || ny <= 0 || nz <= 0
            || values.count < 3 * nodeCount
    }

    /// Displacement at grid node `(a, b, c)` (voxel corner), `.zero` if the node is
    /// out of range or the field is empty/ragged. Unlike `displacement(at:)` (which
    /// rounds a world point to the nearest node), this indexes an exact node — the
    /// load-path strain gradient (M7.viz.4) needs a voxel's eight named corners.
    public func node(_ a: Int, _ b: Int, _ c: Int) -> SIMD3<Float> {
        guard !isEmpty, a >= 0, a <= nx, b >= 0, b <= ny, c >= 0, c <= nz else { return .zero }
        let n = (c * (ny + 1) + b) * (nx + 1) + a
        let base = 3 * n
        guard base >= 0, base + 2 < values.count else { return .zero }
        return SIMD3<Float>(values[base], values[base + 1], values[base + 2])
    }

    /// Nearest-node displacement at world position `p` (zero when empty / degenerate).
    /// Mesh vertices sit on printed-voxel corners, i.e. grid nodes (M7.disp handoff),
    /// so rounding to the nearest node lands on the exact node in practice.
    public func displacement(at p: SIMD3<Float>) -> SIMD3<Float> {
        guard !isEmpty else { return .zero }
        let a = clamp(Int(((p.x - origin.x) / spacing).rounded()), nx + 1)
        let b = clamp(Int(((p.y - origin.y) / spacing).rounded()), ny + 1)
        let c = clamp(Int(((p.z - origin.z) / spacing).rounded()), nz + 1)
        let n = (c * (ny + 1) + b) * (nx + 1) + a
        let base = 3 * n
        guard base >= 0, base + 2 < values.count else { return .zero }
        return SIMD3<Float>(values[base], values[base + 1], values[base + 2])
    }

    private func clamp(_ v: Int, _ n: Int) -> Int { min(max(v, 0), n - 1) }
}

/// Pure math for the M7.viz.3 flex animation: the user-adjustable exaggeration and
/// the rest→full→rest loop amplitude. Kept out of the renderer so it is verified
/// headlessly (the M7 /app/ standard); the Metal vertex displacement that consumes
/// it is device QA. The animation is a DRAWING of the already-solved FEA
/// displacement, not a new simulation.
public enum FlexAnimation {
    /// Exaggeration band the design calls for (50–100×). The default sits at the low
    /// end so the deflection reads on a phone screen without tearing the mesh apart.
    public static let minExaggeration: Float = 50
    public static let maxExaggeration: Float = 100
    public static let defaultExaggeration: Float = 60

    /// Clamp a user-chosen exaggeration into the [min, max] band.
    public static func clampExaggeration(_ v: Float) -> Float {
        min(maxExaggeration, max(minExaggeration, v))
    }

    /// Loop amplitude in [0, 1] for a phase in [0, 1): a raised cosine that is 0 at
    /// rest (phase 0), 1 at full deflection (phase 0.5), and back to 0 (phase 1) —
    /// rest → full → back, with zero slope at both turnarounds so the loop has no
    /// visible seam.
    public static func amplitude(phase: Double) -> Double {
        0.5 - 0.5 * cos(2 * Double.pi * phase)
    }

    /// The displaced position of a rest vertex: `base + exaggeration·amplitude·d`.
    /// This is exactly the math the Metal vertex shader applies (`flexScale =
    /// exaggeration·amplitude`); amplitude 0 → rest, amplitude 1 → full deflection.
    public static func displacedPosition(base: SIMD3<Float>, displacement d: SIMD3<Float>,
                                         exaggeration: Float, amplitude: Double) -> SIMD3<Float> {
        base + (exaggeration * Float(amplitude)) * d
    }
}

/// Pure math for the M7.viz.6 failure-load prediction ("push it till it breaks").
/// Kept out of the model + renderer so it is verified headlessly (the M7 /app/
/// standard). NO new physics: linear FEA means the von Mises field scales linearly
/// with the applied load, so the load that first reaches yield is a direct
/// derivation from ALREADY-COMPUTED data (peak von Mises + material yield + the
/// load the user applied). Nothing here solves, meshes, or calls the optimizer.
public enum FailureLoad {
    /// Gibson-Ashby knockdown exponent — MUST match the core's
    /// `minimize_plastic.cpp infill_margin_knockdown()` (`kKnockdownExponent`), so
    /// the infill-adjusted failure load here AGREES with the ladder's infill-aware
    /// acceptance gate (M7.infill-margin). Do NOT invent a different curve.
    public static let knockdownExponent: Double = 1.5
    /// The core's `kKnockdownFloor`: a degenerate (≤ 0%) infill never yields a
    /// non-positive factor, so the knockdown stays in (0, 1].
    public static let knockdownFloor: Double = 1e-3

    /// The multiplicative infill knockdown on strength (and therefore on the failure
    /// LOAD, which scales with strength): `f^1.5` with `f = infill% / 100`, pinned to
    /// EXACTLY 1.0 at ≥ 100% (solid) so a solid/unset project shows no adjustment.
    /// Byte-for-byte the core `infill_margin_knockdown` (which knocks down the
    /// acceptance MARGIN); strength ∝ margin·load⁻¹, so the same factor applies to
    /// the failure load. See `minimize_plastic.cpp` (M7.infill-margin).
    public static func infillKnockdown(percent: Double) -> Double {
        let f = percent / 100.0
        if f >= 1.0 { return 1.0 }
        if f <= 0.0 { return knockdownFloor }
        return Swift.max(pow(f, knockdownExponent), knockdownFloor)
    }

    /// The failure multiplier = material yield ÷ current peak von Mises: how many
    /// times the current load the part can carry before the worst point reaches
    /// yield. Nil (undefined) when the peak stress or the yield is not positive —
    /// there is no finite ratio to report (a load-free / no-material variant).
    public static func multiplier(peakMPa: Double, yieldMPa: Double) -> Double? {
        guard peakMPa > 0, yieldMPa > 0 else { return nil }
        return yieldMPa / peakMPa
    }

    /// The on-screen deflection exaggeration for a "push" scrub position, PROPORTIONAL
    /// to load (linear FEA): a push to `pushFactor`× the current load deflects
    /// `pushFactor`× as much, so mapping `pushFactor ∈ [1, multiplier]` linearly onto
    /// `[maxExaggeration/multiplier, maxExaggeration]` shows the real proportion while
    /// staying bounded — at failure (`pushFactor == multiplier`) the deflection reaches
    /// the legible `maxExaggeration`, and a lightly-loaded part (large multiplier)
    /// honestly barely moves at 1× (that's the "feels dead" case this feature answers).
    public static func pushExaggeration(pushFactor: Double, multiplier: Double) -> Float {
        guard multiplier > 0 else { return 0 }
        let frac = Swift.min(1, Swift.max(0, pushFactor / multiplier))
        return FlexAnimation.maxExaggeration * Float(frac)
    }
}

/// One accepted variant's presentation (a savings tab + its orientation/shear
/// readouts). Everything is precomputed from the outcome so it is `Equatable` and
/// directly assertable in tests.
public struct ResultVariantVM: Equatable, Sendable {
    public let index: Int
    /// Achieved physical volume fraction (0–1); savings is the complement.
    public let achievedVolumeFraction: Double
    /// Rounded percent of material saved, e.g. 30 for a 0.70 volume fraction.
    public let savingsPercent: Int
    /// Tab headline, e.g. "−30%" (U+2212 minus, matching the design).
    public let savingsLabel: String
    /// Printed mass in grams (spacing-aware, from the core).
    public let massGrams: Double
    /// Formatted mass, e.g. "199 g" / "1.24 kg".
    public let massLabel: String
    /// Support-material estimate for the chosen orientation (cm³).
    public let supportCm3: Double
    /// Formatted support, e.g. "3.8 cm³" or "minimal".
    public let supportLabel: String
    /// The chosen build orientation (M4.4 winning unit direction).
    public let orientation: SIMD3<Double>
    /// Tilt of the build direction away from vertical, folded into [0°, 90°]
    /// (a direction and its negation give the same layer planes).
    public let tiltDegrees: Int
    /// The recommended-orientation sentence (no print time — DECISIONS 2026-07-11).
    public let orientationSummary: String
    /// Layer-shear classification for this orientation.
    public let layerShear: LayerShear
    /// Max von Mises stress (MPa), for the shared stress-legend scale.
    public let maxStressMPa: Double
    /// Worst-case safety-factor margin (min of in-plane / interlayer).
    public let worstCaseMargin: Double
    /// M5.2b advisory min-feature data (report-only; never gates).
    public let minFeatureViolations: Int
    public let minFeatureWarning: String
    /// The app's recommendation — the LIGHTEST variant that still clears the safety
    /// margin for the loads (max plastic saved while safe). Default-selected.
    public let isRecommended: Bool

    /// The tab's sub-line, e.g. "199 g · selected" / "199 g · plastic" (design).
    public func subLabel(active: Bool) -> String {
        "\(massLabel) · \(active ? "selected" : "plastic")"
    }
}

/// The stress-overlay legend (M7.viz.1). States the material and the yield value
/// the heatmap is scaled to, so a viewer knows a color is keyed to the material
/// limit — not an arbitrary per-run data range. `scaledToYield` is false in the
/// no-material fallback, where the scale is the data range and the copy says so.
public struct StressLegend: Equatable, Sendable {
    /// The material the scale is keyed to (empty in the fallback).
    public let materialName: String
    /// The yield strength (MPa) the top of the scale (red) corresponds to (0 in the
    /// fallback).
    public let yieldStrengthMPa: Double
    /// Whether the scale is keyed to the material yield (vs. the data-range fallback).
    public let scaledToYield: Bool
    /// One-line caption naming the material + yield, e.g. "PLA · scaled to 55 MPa yield".
    public let caption: String
    /// Low end of the bar (safe): "0".
    public let minLabel: String
    /// High end of the bar (at/above yield → red): "55 MPa (yield)".
    public let maxLabel: String
}

/// The displayed variant's single worst-stress point (M7.viz.2 hot-spot callout) —
/// where the red zone actually peaks, so the user is not left hunting for it. Its
/// `margin` is the peak value ÷ the material yield (the fraction of the limit used
/// at the worst point: 1.0 = exactly at yield, > 1 = over). `position` is the world
/// center of the worst voxel, which the marker projects onto the stage.
public struct HotSpot: Equatable, Sendable {
    /// Peak von Mises stress on the displayed variant (MPa).
    public let valueMPa: Double
    /// The material yield (MPa) the margin is taken against (0 when unknown).
    public let yieldStrengthMPa: Double
    /// value ÷ yield — the fraction of the material limit reached at the worst point
    /// (0 when no yield is available: there is no limit to compare against).
    public let margin: Double
    /// World position of the worst voxel's center — the marker anchor.
    public let position: SIMD3<Float>
    /// The worst voxel's flat field index (== the von Mises field's argmax).
    public let fieldIndex: Int
    /// The peak value phrased for the callout, e.g. "24 MPa".
    public let valueLabel: String
    /// The margin phrased for the callout, e.g. "44% of yield" / "at/above yield"; in
    /// the no-material fallback it reads "peak stress" (no % — there is no limit).
    public let marginLabel: String
}

/// The M7.viz.6 failure-load prediction for the displayed variant: how much load it
/// carries before the worst point yields, and WHERE it fails first. A pure derivation
/// from already-computed data (peak von Mises + material yield + the applied load) —
/// linear FEA, no new solve. The `position`/`fieldIndex` are the SAME worst point the
/// M7.viz.2 hot spot finds (the marker reuses its styling).
///
/// HONESTY (M7.viz.6 + M7.params infill-aware): infill is FIXED per project
/// (lock-at-creation), so there is ONE honest failure load — the value for THIS
/// project's infill — not a swinging "solid vs infill" pair. The FEA still models
/// solid material (ARCHITECTURE §2); the Gibson-Ashby knockdown (`effectiveYield =
/// yield × f^1.5`, the SAME curve the M7.infill-margin ladder uses) is applied at the
/// display layer, so `multiplier = effectiveYield ÷ peak` and `failureLoadKg` reflect
/// the printed part. A solid (100 %) project has knockdown 1, so the number is
/// unchanged and the label drops the infill suffix.
public struct FailurePrediction: Equatable, Sendable {
    /// effectiveYield ÷ peak von Mises — how many times the current load the printed
    /// part carries before the worst point reaches its (infill-adjusted) yield.
    public let multiplier: Double
    /// The load the user applied (kgf; the sum of the load groups' weights) — the
    /// scalar the failure load scales from.
    public let appliedLoadKg: Double
    /// The failure load (kgf) for THIS project's infill: `multiplier × appliedLoadKg`.
    /// The single honest value shown everywhere.
    public let failureLoadKg: Double
    /// The display unit the labels are formatted in (the workspace kg/lbs toggle).
    public let unit: WeightUnit
    /// World position of the worst voxel's center — the failure marker anchor (== the
    /// M7.viz.2 hot spot).
    public let position: SIMD3<Float>
    /// The worst voxel's flat field index (== the von Mises field's argmax).
    public let fieldIndex: Int
    /// Peak von Mises the estimate is derived from (MPa).
    public let peakMPa: Double
    /// The material's solid yield (MPa), before the infill knockdown — kept for
    /// reference; `effectiveYieldMPa` is what the multiplier is actually measured on.
    public let yieldMPa: Double
    /// The printed part's effective yield (MPa): `yieldMPa × infillKnockdown`.
    public let effectiveYieldMPa: Double
    /// The project's fixed infill % (100 = solid).
    public let infillPercent: Int
    /// The Gibson-Ashby knockdown applied (1.0 when solid).
    public let infillKnockdown: Double
    /// The failure load phrased alone, e.g. "157 lb".
    public let valueLabel: String
    /// The headline, e.g. "Holds ~157 lb at 20% gyroid" (or "Holds ~340 lb" solid).
    public let headline: String
    /// The honesty caption, e.g. "At 20% gyroid infill · yields at the marker" (or
    /// "Solid-print estimate · yields at the marker" when solid).
    public let subtitle: String
}

/// The results screen's state + derived presentation. Constructed from a finished,
/// accepted `OptimizeOutcome` (the run screen only routes here when
/// `acceptedCount >= 1`, so `tabs` is never empty).
@MainActor
public final class ResultsModel: ObservableObject {
    /// Project name for the top chrome.
    public let projectName: String
    /// The run's material name (from materials.json), shown in the stress legend.
    public let materialName: String
    /// The material's yield strength (MPa) — the limit the stress heatmap is scaled
    /// to (M7.viz.1 "honest heatmap"). 0 when unknown (no material / legacy
    /// construction), in which case the scale falls back to the per-run data range.
    public let yieldStrengthMPa: Double
    /// The total load the user applied (kgf; the sum of the load-group weights) — the
    /// scalar the M7.viz.6 failure load scales from. 0 when no load case is declared
    /// (an STL / self-weight run), which suppresses the failure prediction (there is
    /// no user load to scale). It is app-declared data (ForceModel), threaded in from
    /// the workspace — not a core field.
    public let appliedLoadKg: Double
    /// The workspace's kg/lbs display unit, so the failure load reads in the user's
    /// current units (M7.viz.6 surfaces the prediction in the same toggle).
    public let loadUnit: WeightUnit
    /// The project's infill % (M7.params). Fixed per project (lock-at-creation), so
    /// EVERY displayed physics figure is knocked down to this infill consistently
    /// (`infillKnockdown` / `effectiveYieldStrengthMPa`). 100 means solid (knockdown 1).
    public let infillPercent: Int
    /// The project's infill pattern (M7.params), for the infill-aware labels
    /// (e.g. "Holds ~157 lb at 20% gyroid"). Purely descriptive — the knockdown math
    /// depends only on the infill %.
    public let infillPattern: String
    /// The Gibson-Ashby strength knockdown for this project's fixed infill (f^1.5;
    /// 1.0 when solid). The SAME factor the core applies at its acceptance gate
    /// (`minimize_plastic.cpp`), so the displayed physics agrees with the ladder. The
    /// FEA/stress field itself stays solid (ARCHITECTURE §2); this scales the DISPLAYED
    /// strength — the effective yield the part reaches at this infill — everywhere.
    public let infillKnockdown: Double

    /// The effective yield strength (MPa) of the PRINTED part at this project's infill:
    /// the material yield knocked down by `infillKnockdown`. This is the limit every
    /// displayed strength/margin figure is measured against — the stress scale, the
    /// hot-spot "% of yield", and the failure multiplier — so they all agree and are
    /// honest for the part that actually prints (M7.params infill-aware physics).
    public var effectiveYieldStrengthMPa: Double { yieldStrengthMPa * infillKnockdown }

    /// Whether this project prints at a sparse infill below solid (drives the
    /// infill-aware labels; a solid part shows no infill suffix).
    public var isSparseInfill: Bool { infillPercent < 100 }
    /// One tab per accepted variant, in ladder order (largest volume first, so
    /// savings ascend left→right as in the design). GROWS as variants stream in.
    @Published public private(set) var tabs: [ResultVariantVM] = []
    /// Shared stress scale (MPa) the overlay maps onto the color ramp. Keyed to the
    /// material YIELD (M7.viz.1) so a color means the same physical safety across
    /// variants and runs, not a per-run data range; falls back to the max von Mises
    /// over all tabs only when no material yield is available.
    public private(set) var stressScaleMaxMPa: Double = 0

    /// Selected tab. Defaults to (and, until the user picks, follows) the recommended
    /// lightest-safe variant.
    @Published public private(set) var selectedIndex: Int = 0
    /// Stress overlay toggle (colors the variant mesh by von Mises — Metal follow-up).
    @Published public var stressOn: Bool = false
    /// Flex animation toggle (M7.viz.3): displace the mesh by the FEA displacement
    /// field, looping rest→full→rest (or a static full-deflection frame under
    /// reduced-motion). Only meaningful when the selected variant `hasFlex`.
    @Published public var flexOn: Bool = false
    /// Flex loop position in [0, 1) — advanced by the view's timer while flexing;
    /// wraps. Reduced-motion ignores it (the frame is pinned to full deflection).
    @Published public private(set) var flexPhase: Double = 0
    /// User-adjustable exaggeration (50–100×; default tuned for phone legibility),
    /// clamped through `setFlexExaggeration`. Multiplies the solved displacement so
    /// the (sub-millimetre) deflection is visible.
    public private(set) var flexExaggeration: Float = FlexAnimation.defaultExaggeration
    /// Load-path overlay toggle (M7.viz.4): draw the dominant principal-stress
    /// direction as short segments over the variant, tracing how force travels from
    /// the loaded region to the anchors. An advanced-tier overlay (viz.5 gates
    /// tiers). Only meaningful when the selected variant `hasLoadPath`. The overlay
    /// is static, so it needs no reduced-motion special-case.
    @Published public var loadPathOn: Bool = false
    /// Load-path flow position in [0, 1) — advanced by the view's timer while the
    /// overlay is on, driving the traveling-dash animation (M7.viz.4: force visibly
    /// flowing from the loads toward the anchors). Wraps. Reduced-motion holds it at 0
    /// (a static overlay), so the animation is opt-out-safe.
    @Published public private(set) var loadPathPhase: Double = 0
    /// Failure-load surface toggle (M7.viz.6): reveals the predicted failure load, the
    /// failure marker (reusing the viz.2 hot-spot styling), and — when the variant has
    /// a displacement field — the "push" scrub. Only meaningful when the selected
    /// variant `hasFailurePrediction`.
    @Published public var failureOn: Bool = false
    /// The "push" scrub position (M7.viz.6): the load multiple the user is driving the
    /// part to, in [1, failure multiplier]. 1 = the current load; the multiplier =
    /// yield. Drives the flex animation at proportional exaggeration (`pushFlexScale`).
    @Published public private(set) var pushFactor: Double = 1
    /// Morph/threshold scrub position in [0, 1] (1 = fully formed variant).
    @Published public private(set) var playT: Double = 1
    /// Whether the morph is auto-playing (a UI timer advances `playT` in the view).
    @Published public private(set) var playing: Bool = false

    /// The accepted variants' raw geometry + fields (parallel to `tabs`), kept for
    /// the viewer to build the selected variant's mesh + sample its stress field.
    private var accepted: [OptimizeVariant] = []
    private var gridDim: (Int, Int, Int) = (0, 0, 0)
    private var gridOrigin: SIMD3<Float> = .zero
    private var spacing: Float = 0
    /// True once the user has manually picked a tab; until then the selection
    /// follows the recommendation as lighter variants stream in.
    private var userSelected = false

    public init(projectName: String, outcome: OptimizeOutcome,
                materialName: String = "", yieldStrengthMPa: Double = 0,
                appliedLoadKg: Double = 0, loadUnit: WeightUnit = .kg,
                infillPercent: Int = 100, infillPattern: String = "gyroid") {
        self.projectName = projectName
        self.materialName = materialName
        self.yieldStrengthMPa = max(0, yieldStrengthMPa)
        self.appliedLoadKg = max(0, appliedLoadKg)
        self.loadUnit = loadUnit
        self.infillPercent = infillPercent
        self.infillPattern = infillPattern
        self.infillKnockdown = FailureLoad.infillKnockdown(percent: Double(infillPercent))
        apply(outcome)
        selectedIndex = tabs.firstIndex(where: { $0.isRecommended }) ?? 0
    }

    /// Merge a newer (possibly larger) outcome — a streamed variant landing or the
    /// authoritative final outcome — preserving the user's tab pick / scrub / stress
    /// toggle. Until the user manually selects, the selection follows the (updated)
    /// recommendation so a freshly-arrived lighter variant becomes the default.
    public func update(from outcome: OptimizeOutcome) {
        apply(outcome)
        if userSelected {
            selectedIndex = min(selectedIndex, max(0, tabs.count - 1))
        } else {
            selectedIndex = tabs.firstIndex(where: { $0.isRecommended }) ?? selectedIndex
        }
    }

    /// Recompute the derived presentation from an outcome (does NOT touch selection).
    private func apply(_ outcome: OptimizeOutcome) {
        let acc = outcome.variants.filter { $0.accepted }
        accepted = acc
        gridDim = (outcome.gridNx, outcome.gridNy, outcome.gridNz)
        gridOrigin = SIMD3<Float>(outcome.gridOrigin)
        spacing = Float(outcome.spacing)
        tabs = ResultsModel.buildTabs(acc, voxelVolumeMM3: outcome.voxelVolumeMM3,
                                      knockdown: infillKnockdown)
        // M7.viz.1 "honest heatmap": key the shared stress scale to the MATERIAL
        // LIMIT (yield) so a color means the same physical safety everywhere — not
        // to the per-run data range. M7.params infill-aware: the limit is the
        // EFFECTIVE yield of the printed part at this project's fixed infill (yield ×
        // knockdown), so the same color, the hot-spot "% of yield", and the failure
        // multiplier all measure against the part that actually prints. Fall back to
        // the data-range max only when no material yield is available.
        stressScaleMaxMPa = effectiveYieldStrengthMPa > 0
            ? effectiveYieldStrengthMPa
            : (acc.map(\.maxStressMPa).max() ?? 0)
        keyframeCache = nil   // variant data changed → rebuild keyframes on demand
        flexCache = nil       // …and the per-vertex flex displacements
        loadPathCache = nil   // …and the derived load-path glyphs
        loadPathSegmentCache = nil
        failureCache = nil    // …and the failure-load prediction
        peakToRedCache = nil  // …and the flex peak-to-red color multiple
    }

    /// The currently selected variant (nil only for an empty outcome).
    public var selected: ResultVariantVM? {
        tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil
    }

    private var selectedVariant: OptimizeVariant? {
        accepted.indices.contains(selectedIndex) ? accepted[selectedIndex] : nil
    }

    /// The selected variant's isosurface for display (nil if it has no geometry).
    public var selectedMesh: ViewerMesh? {
        guard let v = selectedVariant, !v.meshVertices.isEmpty else { return nil }
        return ViewerMesh(vertices: v.meshVertices, indices: v.meshIndices, faceIDs: [])
    }

    /// The selected variant's stress field, tied to the run's grid geometry.
    public var selectedStressField: StressField? {
        guard let v = selectedVariant else { return nil }
        return StressField(nx: gridDim.0, ny: gridDim.1, nz: gridDim.2,
                           origin: gridOrigin, spacing: spacing, values: v.vonMisesField)
    }

    // MARK: - flex animation (M7.viz.3)

    /// The selected variant's per-node displacement field (M7.disp), tied to the
    /// run's grid geometry — the field the flex animation displaces vertices by.
    public var selectedDisplacementField: DisplacementField? {
        guard let v = selectedVariant else { return nil }
        return DisplacementField(nx: gridDim.0, ny: gridDim.1, nz: gridDim.2,
                                 origin: gridOrigin, spacing: spacing, values: v.displacementField)
    }

    /// Whether the selected variant carries a displacement field to flex (a
    /// cancelled/legacy variant has none, so the Flex control stays hidden).
    public var hasFlex: Bool {
        guard let f = selectedDisplacementField else { return false }
        return !f.isEmpty
    }

    private var flexCache: (index: Int, disp: [Float])?

    /// Toggle the flex animation. Turning it off resets the loop to rest so it
    /// restarts cleanly next time. Flex and the load-path overlay are mutually
    /// exclusive — flex moves the vertices while the load path is drawn at rest
    /// positions, so turning one on turns the other off.
    public func toggleFlex() {
        flexOn.toggle()
        if flexOn { loadPathOn = false; failureOn = false; pushFactor = 1 }
        if !flexOn { flexPhase = 0 }
    }

    /// Set the exaggeration factor, clamped to the design's 50–100× band.
    public func setFlexExaggeration(_ v: Float) {
        flexExaggeration = FlexAnimation.clampExaggeration(v)
    }

    /// Advance the flex loop by `dt` (phase units); wraps into [0, 1). No-op unless
    /// flexing (the view only calls this while `flexOn` and motion is allowed).
    public func advanceFlex(_ dt: Double) {
        guard flexOn else { return }
        var p = (flexPhase + dt).truncatingRemainder(dividingBy: 1)
        if p < 0 { p += 1 }
        flexPhase = p
    }

    /// Current loop amplitude in [0, 1]. Reduced-motion pins it at full deflection
    /// (a static frame, no loop, per the accessibility requirement); otherwise it
    /// follows the rest→full→rest phase. 0 when flex is off (rest / no displacement).
    public func flexAmplitude(reduceMotion: Bool) -> Double {
        guard flexOn else { return 0 }
        return reduceMotion ? 1 : FlexAnimation.amplitude(phase: flexPhase)
    }

    /// The GPU displacement scale for the current frame: `exaggeration · amplitude`.
    /// The Metal vertex shader adds `flexScale · displacement` to each rest vertex.
    public func flexScale(reduceMotion: Bool) -> Float {
        flexExaggeration * Float(flexAmplitude(reduceMotion: reduceMotion))
    }

    /// Per-flat-vertex displacement vectors (mm) for `mesh`, sampled from `field` at
    /// each flat vertex's rest position — the static buffer the viewer uploads once
    /// per selection; the shader scales it by `flexScale` each frame. Flattened xyz,
    /// aligned with `mesh.flat.positions`. Cached on `selectedIndex` (rebuilt when the
    /// variant data changes) so the O(N) sample runs once per variant, not per frame.
    public func flexDisplacements(for mesh: ViewerMesh, field: DisplacementField) -> [Float] {
        if let c = flexCache, c.index == selectedIndex { return c.disp }
        let positions = mesh.flat.positions
        let count = mesh.flat.vertexCount
        var out = [Float]()
        out.reserveCapacity(count * 3)
        for v in 0..<count {
            let p = SIMD3<Float>(positions[v * 3], positions[v * 3 + 1], positions[v * 3 + 2])
            let d = field.displacement(at: p)
            out.append(d.x); out.append(d.y); out.append(d.z)
        }
        flexCache = (selectedIndex, out)
        return out
    }

    // MARK: - load-path overlay (M7.viz.4)

    private var loadPathCache: (index: Int, path: LoadPath)?
    private var loadPathSegmentCache: (index: Int, verts: [Float])?

    /// Whether the selected variant can show a load path. It is derived from the FEA
    /// displacement field (strain → principal-stress direction), so it needs the same
    /// displacement field the flex animation does; a cancelled/legacy variant has
    /// none, so the Load-path control stays hidden.
    public var hasLoadPath: Bool { hasFlex }

    /// Toggle the load-path overlay. Mutually exclusive with flex (see `toggleFlex`).
    /// Resets the flow animation to the start so it restarts cleanly each time.
    public func toggleLoadPath() {
        loadPathOn.toggle()
        loadPathPhase = 0
        if loadPathOn { flexOn = false; flexPhase = 0; failureOn = false; pushFactor = 1 }
    }

    /// Advance the load-path flow animation by `dt` (phase units); wraps into [0, 1).
    /// No-op unless the overlay is on (the view only calls this while `loadPathOn` and
    /// motion is allowed), so reduced-motion simply never advances it → a static frame.
    public func advanceLoadPath(_ dt: Double) {
        guard loadPathOn else { return }
        var p = (loadPathPhase + dt).truncatingRemainder(dividingBy: 1)
        if p < 0 { p += 1 }
        loadPathPhase = p
    }

    /// The selected variant's derived load path (dominant principal-stress direction
    /// glyphs over the printed region), built once per selection and cached. Nil when
    /// the variant carries no displacement field.
    public var selectedLoadPath: LoadPath? {
        if let c = loadPathCache, c.index == selectedIndex { return c.path }
        guard let disp = selectedDisplacementField, !disp.isEmpty else { return nil }
        let path = LoadPathField.build(displacement: disp, stress: selectedStressField)
        loadPathCache = (selectedIndex, path)
        return path
    }

    /// The load-path overlay's line-segment vertex buffer: two vertices per glyph,
    /// each `[x, y, z, r, g, b, a]` (stride 7) — the world-space endpoints of the
    /// segment centred on the glyph, coloured by the glyph's von Mises stress on the
    /// SHARED scale (same ramp as the M7.viz.1 heatmap, so a hot path reads red).
    /// This is exactly the pos+rgba line layout the Metal ground/line pipeline draws.
    /// Cached on `selectedIndex`.
    public func loadPathSegments(for path: LoadPath) -> [Float] {
        if let c = loadPathSegmentCache, c.index == selectedIndex { return c.verts }
        var out = [Float]()
        out.reserveCapacity(path.glyphs.count * 2 * 7)
        let half = path.segmentLength * 0.5
        for g in path.glyphs {
            let frac = stressFraction(mpa: Double(g.stressMPa))
            let c = ResultsModel.stressColor(fraction: frac)
            let r = Float(c.r), gr = Float(c.g), b = Float(c.b)
            let p0 = g.position - half * g.direction
            let p1 = g.position + half * g.direction
            out.append(p0.x); out.append(p0.y); out.append(p0.z)
            out.append(r); out.append(gr); out.append(b); out.append(1)
            out.append(p1.x); out.append(p1.y); out.append(p1.z)
            out.append(r); out.append(gr); out.append(b); out.append(1)
        }
        loadPathSegmentCache = (selectedIndex, out)
        return out
    }

    // MARK: - failure-load prediction (M7.viz.6)

    private var failureCache: (index: Int, pred: FailurePrediction?)?

    /// The displayed variant's failure-load prediction (M7.viz.6). A pure derivation:
    /// `multiplier = yield / peak`, `failureLoad = multiplier × appliedLoad`, at the
    /// hot spot (reusing the viz.2 peak point). Nil when there is no user load to scale
    /// (`appliedLoadKg == 0` — an STL/self-weight run), no stress to peak, or no
    /// material yield to compare against. Cached per selection (the O(N) peak scan runs
    /// once per variant, not per push-scrub frame); the load/unit/infill are constant.
    public var failurePrediction: FailurePrediction? {
        if let c = failureCache, c.index == selectedIndex { return c.pred }
        let pred = computeFailurePrediction()
        failureCache = (selectedIndex, pred)
        return pred
    }

    private func computeFailurePrediction() -> FailurePrediction? {
        // Measure against the EFFECTIVE yield of the printed part at this project's
        // fixed infill (M7.params infill-aware): one honest failure load, not a
        // solid-vs-infill pair. Solid (knockdown 1) reduces to the plain yield/peak.
        guard appliedLoadKg > 0,
              let field = selectedStressField, let peak = field.peak(),
              let mult = FailureLoad.multiplier(peakMPa: Double(peak.valueMPa),
                                                yieldMPa: effectiveYieldStrengthMPa)
        else { return nil }
        let failKg = mult * appliedLoadKg
        let valueLbl = ResultsModel.loadLabel(kg: failKg, unit: loadUnit)
        let descriptor = ResultsModel.infillDescriptor(percent: infillPercent, pattern: infillPattern)
        return FailurePrediction(
            multiplier: mult,
            appliedLoadKg: appliedLoadKg,
            failureLoadKg: failKg,
            unit: loadUnit,
            position: peak.position,
            fieldIndex: peak.index,
            peakMPa: Double(peak.valueMPa),
            yieldMPa: yieldStrengthMPa,
            effectiveYieldMPa: effectiveYieldStrengthMPa,
            infillPercent: infillPercent,
            infillKnockdown: infillKnockdown,
            valueLabel: valueLbl,
            headline: descriptor.map { "Holds ~\(valueLbl) at \($0)" } ?? "Holds ~\(valueLbl)",
            subtitle: descriptor.map { "At \($0) infill · yields at the marker" }
                ?? "Solid-print estimate · yields at the marker")
    }

    /// The infill descriptor for a physics label, e.g. "20% gyroid", or nil when the
    /// project prints solid (100 %) — a solid part carries no infill suffix.
    static func infillDescriptor(percent: Int, pattern: String) -> String? {
        percent < 100 ? "\(percent)% \(pattern)" : nil
    }

    /// Whether the selected variant can show a failure prediction (drives the toggle).
    public var hasFailurePrediction: Bool { failurePrediction != nil }

    /// Whether the "push" scrub is available: the failure surface is on AND the variant
    /// carries a displacement field to drive the flex deflection. When there is no
    /// displacement field, the feature degrades gracefully to the number + marker only
    /// (no scrub), rather than failing.
    public var pushActive: Bool { failureOn && hasFlex && hasFailurePrediction }

    /// Toggle the failure-load surface. Mutually exclusive with flex/load-path (they
    /// drive the same viewer deflection/overlay channels); turning it off resets the
    /// push scrub to the current load (1×).
    public func toggleFailure() {
        failureOn.toggle()
        if failureOn { flexOn = false; loadPathOn = false; flexPhase = 0 }
        if !failureOn { pushFactor = 1 }
    }

    /// Set the push scrub, clamped to [1, failure multiplier] (no-op with no
    /// prediction). 1 = the current load; the multiplier = the load that yields.
    public func setPush(factor: Double) {
        guard let fp = failurePrediction else { return }
        pushFactor = min(fp.multiplier, max(1, factor))
    }

    /// The flex exaggeration for the current push position — proportional to load
    /// (linear FEA), reaching the legible max at failure. 0 with no prediction. This is
    /// a STATIC scrub (the position maps straight to a deflection), so it is
    /// reduced-motion-safe by construction — no loop.
    public func pushFlexScale() -> Float {
        guard hasFlex, let fp = failurePrediction else { return 0 }
        return FailureLoad.pushExaggeration(pushFactor: pushFactor, multiplier: fp.multiplier)
    }

    /// Whether the push scrub has reached (or passed) the failure multiplier — the
    /// part yields here, so the marker turns red / a "yields here" label shows.
    public var atFailure: Bool {
        guard let fp = failurePrediction else { return false }
        return pushFactor >= fp.multiplier - 1e-6
    }

    /// The live "push" scrub readout (M7.viz.6b): the current load in the user's units
    /// plus the current multiple, phrased so it reads naturally as the user drags —
    /// e.g. "1180 lb · 1.4× load", ramping to "1915 lb · 3.0× · YIELDS" at/above the
    /// failure multiplier. Pure (position → string), so it is headlessly assertable.
    public func pushReadout(prediction fp: FailurePrediction) -> String {
        let load = ResultsModel.loadLabel(kg: pushFactor * fp.appliedLoadKg, unit: fp.unit)
        let mult = String(format: "%.1f×", pushFactor)
        return atFailure ? "\(load) · \(mult) · YIELDS" : "\(load) · \(mult) load"
    }

    /// Format a kgf load in the given display unit (kg / lbs), matching the workspace
    /// weight readout (`ForceModel.formattedWeight`): < 10 → one decimal, ≥ 10 →
    /// rounded integer. Keeps the failure load in the user's current units.
    static func loadLabel(kg: Double, unit: WeightUnit) -> String {
        let v = unit == .kg ? kg : kg * ForceModel.kgToLb
        let num = v < 10 ? String(format: "%.1f", v) : String(Int(v.rounded()))
        return "\(num) \(unit.rawValue)"
    }

    // MARK: - optimization-history playback (keyframes)

    /// Whether the selected variant carries an optimization history to play back.
    public var hasHistory: Bool { !(selectedVariant?.keyframeMeshes.isEmpty ?? true) }

    private var keyframeCache: (index: Int, meshes: [ViewerMesh])?

    /// The selected variant's history keyframe meshes (~solid → optimized), built
    /// once per selection. An empty frame (material not yet formed early in a
    /// low-volume rung) becomes an empty ViewerMesh that renders nothing.
    public func keyframes() -> [ViewerMesh] {
        if let c = keyframeCache, c.index == selectedIndex { return c.meshes }
        let ms = (selectedVariant?.keyframeMeshes ?? []).map {
            ViewerMesh(vertices: $0.vertices, indices: $0.indices, faceIDs: [])
        }
        keyframeCache = (selectedIndex, ms)
        return ms
    }

    /// The keyframe mesh at the current scrub position (0 = first/~solid, 1 =
    /// optimized), or nil when there's no history (fall back to the final mesh).
    public var playbackMesh: ViewerMesh? {
        let ks = keyframes()
        guard !ks.isEmpty else { return nil }
        return ks[ResultsModel.keyframeIndex(playT: playT, count: ks.count)]
    }

    /// Which keyframe a scrub position maps to (nearest frame, clamped).
    public static func keyframeIndex(playT: Double, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let t = min(1, max(0, playT))
        return min(count - 1, max(0, Int((t * Double(count - 1)).rounded())))
    }

    /// Whether Play scrubs THROUGH the optimization-history keyframes (the "watch it
    /// carve out" morph) rather than the static / reveal-slice view. Pure so the
    /// branch is verified headlessly (the M7 /app/ standard); `ResultsScreen.showHistory`
    /// is exactly this call.
    ///
    /// THE FIX ("Stress chip breaks playback"): `stressOn` is deliberately NOT a factor.
    /// It used to suppress the morph (Stress on → the branch fell back to the
    /// slice-reveal viewer), so pressing Play with Stress on sliced instead of morphing.
    /// The morph and the stress overlay now coexist (the tints are sampled per keyframe).
    /// A deflection (flex loop / failure push) or the load-path overlay still shows the
    /// final formed mesh — they animate/annotate it — so they take precedence.
    public static func showsHistoryMorph(hasHistory: Bool, deflectionActive: Bool,
                                         loadPathActive: Bool) -> Bool {
        hasHistory && !deflectionActive && !loadPathActive
    }

    /// Per-flat-vertex stress colors (alpha 1) for `mesh`, sampled from `field`
    /// against the shared scale — the buffer the viewer uploads when stress is on.
    ///
    /// `multiplier` scales the sampled von Mises value before the color lookup so the
    /// heatmap tracks the motion (M7.viz coupling): linear FEA means the stress at a
    /// point scales with the applied load, so the flex loop (0 at rest → 1 at full
    /// deflection) and the failure "push" scrub (1× → the failure multiple) drive the
    /// SAME field warmer/cooler as the geometry moves. `multiplier` 1 is the solved
    /// field as-is (a static stress overlay). See `stressColorMultiplier`.
    public func stressTints(for mesh: ViewerMesh, field: StressField,
                            multiplier: Double = 1) -> [SIMD4<Float>] {
        let positions = mesh.flat.positions
        let count = mesh.flat.vertexCount
        var out = [SIMD4<Float>]()
        out.reserveCapacity(count)
        for v in 0..<count {
            let p = SIMD3<Float>(positions[v * 3], positions[v * 3 + 1], positions[v * 3 + 2])
            let frac = stressFraction(mpa: Double(field.value(at: p)) * multiplier)
            let c = ResultsModel.stressColor(fraction: frac)
            out.append(SIMD4<Float>(Float(c.r), Float(c.g), Float(c.b), 1))
        }
        return out
    }

    private var peakToRedCache: (index: Int, value: Double)?

    /// The load multiple that drives the displayed variant's PEAK stress to the TOP of
    /// the shared color scale (fraction 1 → red). When the scale is keyed to the
    /// material yield (M7.viz.1) this is exactly `yield / peak` — i.e. the SAME multiple
    /// the failure "push" reaches at the failure load — so the flex loop can flush to
    /// the identical red at full deflection that the push does. 1 when there is no
    /// field / no peak (nothing to warm). Cached per selection (the O(N) peak scan runs
    /// once per variant, not per flex-loop frame — `stressColorMultiplier` reads it each
    /// frame while flexing).
    public var peakToRedMultiplier: Double {
        if let c = peakToRedCache, c.index == selectedIndex { return c.value }
        let value: Double = {
            guard let field = selectedStressField, let peak = field.peak(),
                  peak.valueMPa > 0, stressScaleMaxMPa > 0 else { return 1 }
            return stressScaleMaxMPa / Double(peak.valueMPa)
        }()
        peakToRedCache = (selectedIndex, value)
        return value
    }

    /// The load multiple currently applied to the base von Mises field for coloring,
    /// so the stress heatmap moves WITH the geometry (M7.viz.2/3/6 coupling). Linear
    /// FEA: the displayed field = base field × this multiplier, recolored against the
    /// SAME yield scale.
    ///   • Failure "push" active → the push scrub `pushFactor` (1× → the failure
    ///     multiple): as the user drives toward failure the body flushes to red, and
    ///     at the multiple the peak voxel reaches exactly yield (fraction 1 → red).
    ///   • Flex loop active → the deflection `flexAmplitude` (0 at rest → 1 at full
    ///     deflection) SCALED by `peakToRedMultiplier`, so the body flushes blue → red →
    ///     blue as it wobbles — the SAME coupling the failure push uses (at full
    ///     deflection the peak voxel reaches the top of the scale, exactly like a push to
    ///     failure). Without this scale the flex loop only ever reached the solved 1×
    ///     field, which for a part comfortably below yield reads as a flat, unchanging
    ///     blue — the "flex doesn't recolor" bug. Reduced-motion pins amplitude 1 (the
    ///     static full-deflection frame shows the peak at red).
    ///   • Neither → 1 (the solved field as-is, a static stress overlay).
    public func stressColorMultiplier(reduceMotion: Bool) -> Double {
        if pushActive { return pushFactor }
        if flexOn && hasFlex { return flexAmplitude(reduceMotion: reduceMotion) * peakToRedMultiplier }
        return 1
    }

    // MARK: - Intents

    /// Select a tab. Resets the morph to fully-formed (design `pick` → playT 1).
    /// Marks the selection as user-chosen, so streaming variants no longer move it.
    public func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        userSelected = true
        selectedIndex = index
        playT = 1
        playing = false
        flexPhase = 0   // the new variant's flex loop starts from rest
        loadPathPhase = 0   // …and the load-path flow restarts
        pushFactor = 1  // …and the push scrub resets to the current load
    }

    public func toggleStress() { stressOn.toggle() }

    /// Scrub the morph; clamps to [0, 1] and pauses (a manual scrub stops playback).
    public func scrub(to t: Double) {
        playT = min(1, max(0, t))
        playing = false
    }

    /// Play/pause the morph. Starting from the end restarts from 0.
    public func togglePlay() {
        if !playing && playT >= 1 { playT = 0 }
        playing.toggle()
    }

    /// Advance the morph by `dt` in [0,1] units (called by the view's timer while
    /// `playing`); stops at 1.
    public func advance(_ dt: Double) {
        guard playing else { return }
        playT = min(1, playT + dt)
        if playT >= 1 { playing = false }
    }

    // MARK: - Stress overlay color ramp

    /// A von Mises value (MPa) mapped to [0, 1] against the shared scale.
    public func stressFraction(mpa: Double) -> Double {
        stressScaleMaxMPa > 0 ? min(1, max(0, mpa / stressScaleMaxMPa)) : 0
    }

    /// The legend for the stress overlay (M7.viz.1): names the material and the yield
    /// value the scale is keyed to (green ≈ comfortably below yield → red = at/above
    /// yield). In the no-material fallback it is honest that the scale is relative.
    public var stressLegend: StressLegend {
        // M7.params infill-aware: the scale is keyed to the printed part's EFFECTIVE
        // yield (yield × knockdown), so red means "at the limit of the part that
        // actually prints." A sparse infill annotates the caption (e.g. "at 20%
        // gyroid"); solid is unchanged.
        let effective = effectiveYieldStrengthMPa
        let scaled = effective > 0
        let yieldText = ResultsModel.mpaLabel(effective)
        let name = materialName.isEmpty ? "Material" : materialName
        let infill = ResultsModel.infillDescriptor(percent: infillPercent, pattern: infillPattern)
        let caption: String
        if scaled {
            let base = "\(name) · scaled to \(yieldText) yield"
            caption = infill.map { "\(base) at \($0)" } ?? base
        } else {
            caption = "Relative scale (no material limit)"
        }
        return StressLegend(
            materialName: materialName,
            yieldStrengthMPa: effective,
            scaledToYield: scaled,
            caption: caption,
            minLabel: "0",
            maxLabel: scaled ? "\(yieldText) (yield)" : "peak")
    }

    /// Format a stress value in MPa for the legend, e.g. "55 MPa" (yields are whole
    /// MPa in materials.json).
    static func mpaLabel(_ v: Double) -> String { String(format: "%.0f MPa", v) }

    /// The displayed variant's hot spot (M7.viz.2): the single highest-stress point,
    /// its value, and its margin (value ÷ yield). Nil when the selected variant has
    /// no stress field or carries no stress (nothing to call out). Uses the SAME
    /// yield the M7.viz.1 scale is keyed to.
    public var hotSpot: HotSpot? {
        guard let field = selectedStressField, let peak = field.peak() else { return nil }
        let value = Double(peak.valueMPa)
        // M7.params infill-aware: the "% of yield" is measured against the printed
        // part's EFFECTIVE yield (yield × knockdown), so it agrees with the failure
        // multiplier and the stress scale. Solid (knockdown 1) is the plain fraction.
        let y = effectiveYieldStrengthMPa
        let frac = y > 0 ? value / y : 0
        return HotSpot(
            valueMPa: value,
            yieldStrengthMPa: y,
            margin: frac,
            position: peak.position,
            fieldIndex: peak.index,
            valueLabel: ResultsModel.mpaLabel(value),
            marginLabel: ResultsModel.hotSpotMarginLabel(fractionOfYield: frac, hasYield: y > 0))
    }

    /// Phrase the hot spot's margin (value ÷ yield). Below yield → "N% of yield"; at
    /// or above the limit → the honest "at/above yield (N%)"; no material limit → a
    /// plain "peak stress" (there is no yield to compare against).
    static func hotSpotMarginLabel(fractionOfYield f: Double, hasYield: Bool) -> String {
        guard hasYield else { return "peak stress" }
        let pct = Int((f * 100).rounded())
        return f >= 1 ? "at/above yield (\(pct)%)" : "\(pct)% of yield"
    }

    /// The design's stress gradient (the conic legend on the Stress toggle):
    /// blue → cyan → green → yellow → red, evenly spaced. `fraction` is clamped.
    public static func stressColor(fraction: Double) -> RGBA {
        // #1c3caa, #00aadc, #3cbe6e, #fadc3c, #ff4632 (0–255 components).
        let stops: [(Double, Double, Double)] = [
            (28, 60, 170), (0, 170, 220), (60, 190, 110), (250, 220, 60), (255, 70, 50),
        ]
        let x = min(1, max(0, fraction)) * Double(stops.count - 1)
        let i = min(stops.count - 2, Int(x))
        let t = x - Double(i)
        let a = stops[i], b = stops[i + 1]
        return RGBA(a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }

    // MARK: - Builders (pure)

    /// - Parameter knockdown: the Gibson-Ashby infill knockdown (1.0 solid). The
    ///   core reports SOLID margins (it applies the knockdown only at its acceptance
    ///   gate — minimize_plastic.cpp), so the DISPLAYED strength/margin readouts
    ///   (worst-case margin, layer-shear classification) are knocked down here to the
    ///   printed part's infill, consistently with the failure load + hot spot.
    static func buildTabs(_ variants: [OptimizeVariant], voxelVolumeMM3: Double,
                          knockdown: Double = 1) -> [ResultVariantVM] {
        // Variants arrive heaviest-first (ladder order); the LAST accepted rung is
        // the lightest safe one — the recommendation.
        let recommendedIndex = variants.count - 1
        return variants.enumerated().map { i, v in
            let savings = 1 - v.achievedVolumeFraction
            let pct = Int((savings * 100).rounded())
            let cm3 = Double(v.supportVolumeVoxels) * voxelVolumeMM3 / 1000.0
            let supportLabel = cm3 <= 0.05 ? "minimal" : String(format: "%.1f cm³", cm3)
            let tilt = tiltFromVertical(v.orientation)
            return ResultVariantVM(
                index: i,
                achievedVolumeFraction: v.achievedVolumeFraction,
                savingsPercent: pct,
                savingsLabel: "\u{2212}\(pct)%",
                massGrams: v.massGrams,
                massLabel: massLabel(v.massGrams),
                supportCm3: cm3,
                supportLabel: supportLabel,
                orientation: v.orientation,
                tiltDegrees: tilt,
                orientationSummary: orientationSummary(tiltDegrees: tilt, supportCm3: cm3, supportLabel: supportLabel),
                layerShear: LayerShear.classify(interlayerMargin: v.interlayerMargin * knockdown),
                maxStressMPa: v.maxStressMPa,
                worstCaseMargin: v.worstCaseMargin * knockdown,
                minFeatureViolations: v.minFeatureViolations,
                minFeatureWarning: v.minFeatureWarning,
                isRecommended: i == recommendedIndex)
        }
    }

    /// Angle (whole degrees) of a build direction away from vertical (+Z), folded
    /// into [0, 90] since a direction and its negation define the same layer planes.
    static func tiltFromVertical(_ d: SIMD3<Double>) -> Int {
        let len = simd_length(d)
        guard len > 1e-9 else { return 0 }
        let a = acos(min(1, max(-1, d.z / len))) * 180 / Double.pi
        return Int(min(a, 180 - a).rounded())
    }

    static func massLabel(_ g: Double) -> String {
        if g >= 1000 { return String(format: "%.2f kg", g / 1000) }
        if g >= 10 { return String(format: "%.0f g", g) }
        return String(format: "%.1f g", g)
    }

    /// The recommended-orientation sentence — tilt + support, NO print time
    /// (DECISIONS 2026-07-11 chose (b) omit).
    static func orientationSummary(tiltDegrees tilt: Int, supportCm3 cm3: Double, supportLabel: String) -> String {
        let base = tilt <= 6
            ? "Print upright — load paths align with the layer direction."
            : "Tilt \(tilt)° from vertical — load paths align with the layer direction."
        let support = cm3 <= 0.05 ? "Minimal supports needed." : "Est. \(supportLabel) support under overhangs."
        return base + " " + support
    }
}
