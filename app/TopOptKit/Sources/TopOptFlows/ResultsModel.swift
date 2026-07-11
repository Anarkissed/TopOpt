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

/// The results screen's state + derived presentation. Constructed from a finished,
/// accepted `OptimizeOutcome` (the run screen only routes here when
/// `acceptedCount >= 1`, so `tabs` is never empty).
@MainActor
public final class ResultsModel: ObservableObject {
    /// Project name for the top chrome.
    public let projectName: String
    /// One tab per accepted variant, in ladder order (largest volume first, so
    /// savings ascend left→right as in the design). GROWS as variants stream in.
    @Published public private(set) var tabs: [ResultVariantVM] = []
    /// Shared stress scale across variants: the max von Mises over all tabs, so the
    /// overlay legend is comparable between variants (ARCHITECTURE V-gate spirit /
    /// design "shared scale").
    public private(set) var stressScaleMaxMPa: Double = 0

    /// Selected tab. Defaults to (and, until the user picks, follows) the recommended
    /// lightest-safe variant.
    @Published public private(set) var selectedIndex: Int = 0
    /// Stress overlay toggle (colors the variant mesh by von Mises — Metal follow-up).
    @Published public var stressOn: Bool = false
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

    public init(projectName: String, outcome: OptimizeOutcome) {
        self.projectName = projectName
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
        tabs = ResultsModel.buildTabs(acc, voxelVolumeMM3: outcome.voxelVolumeMM3)
        stressScaleMaxMPa = acc.map(\.maxStressMPa).max() ?? 0
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

    /// Per-flat-vertex stress colors (alpha 1) for `mesh`, sampled from `field`
    /// against the shared scale — the buffer the viewer uploads when stress is on.
    public func stressTints(for mesh: ViewerMesh, field: StressField) -> [SIMD4<Float>] {
        let positions = mesh.flat.positions
        let count = mesh.flat.vertexCount
        var out = [SIMD4<Float>]()
        out.reserveCapacity(count)
        for v in 0..<count {
            let p = SIMD3<Float>(positions[v * 3], positions[v * 3 + 1], positions[v * 3 + 2])
            let frac = stressFraction(mpa: Double(field.value(at: p)))
            let c = ResultsModel.stressColor(fraction: frac)
            out.append(SIMD4<Float>(Float(c.r), Float(c.g), Float(c.b), 1))
        }
        return out
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

    static func buildTabs(_ variants: [OptimizeVariant], voxelVolumeMM3: Double) -> [ResultVariantVM] {
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
                layerShear: LayerShear.classify(interlayerMargin: v.interlayerMargin),
                maxStressMPa: v.maxStressMPa,
                worstCaseMargin: v.worstCaseMargin,
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
