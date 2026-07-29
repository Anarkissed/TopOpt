// PrintParams.swift — the M7.params print-parameters the user captures for a
// project (docs/design/PrintParams_TopOpt.dc.html, the PRINT PARAMETERS sheet).
//
// These are the FDM slicer inputs the user commits to: wall loops, top/bottom
// shell layers, infill % (+ pattern) and layer height. They are USER OVERRIDES of
// the values the M5.1 rule engine (core `recommend_settings`, settings/rules.json)
// would recommend — the sheet always shows concrete values, so committing them
// replaces the recommendation for this project rather than tweaking it per-field.
//
// SCOPE of this type (M7.params):
//   * Captured on the sheet, PERSISTED on the project (ProjectSnapshot, the
//     persist-b/c pattern) so they survive relaunch.
//   * `infillPercent` is additionally threaded through the bridge to the core
//     (RunRequest → BridgeLoadCase) so the M7.infill-margin ladder knockdown can
//     consume it — it is the one field that feeds the optimizer.
//   * `layerHeightMM` is CAPTURED BUT NOT WIRED: the M5.1 engine's `SlicerSettings`
//     has no layer-height field, so there is nothing to override with it yet. It is
//     kept on the project for the future slicer/report surface (see `slicerOverride`,
//     which deliberately omits it).
// The walls / top / bottom / pattern overrides have no in-app consumer yet (the
// app never surfaces recommended settings); they are captured + persisted here and
// consumed when a settings/report/export surface lands (M7.9). See the handoff.

import Foundation

/// The user's print parameters for a project — the M7.params capture, and the
/// USER OVERRIDE of the M5.1 recommended slicer settings.
public struct PrintParams: Equatable, Sendable, Codable {
    /// Nozzle layer height (mm). Captured for the future slicer/report surface;
    /// not wired into the current settings engine (it has no layer-height field).
    public var layerHeightMM: Double
    /// Perimeter wall loops (the M5.1 `walls` override).
    public var wallLoops: Int
    /// Solid top shell layers (the M5.1 `top_layers` override).
    public var topLayers: Int
    /// Solid bottom shell layers (the M5.1 `bottom_layers` override).
    public var bottomLayers: Int
    /// Infill density, 0–100 % (the M5.1 `infill_percent` override). Also threaded
    /// through the bridge for the M7.infill-margin ladder knockdown.
    public var infillPercent: Int
    /// Infill pattern name (the M5.1 `infill_pattern` override).
    public var infillPattern: String
    /// Extrusion line width (mm) of the single OUTER wall loop — the width of one
    /// deposited bead, a slicer setting (typically 1.0–1.2× the nozzle), NOT the nozzle
    /// diameter. Bambu Studio / OrcaSlicer expose the outer perimeter's width separately
    /// from the inner loops, so the solid wall ring the slicer lays down is
    /// `outer + (wallLoops - 1) · inner`. Threaded through BOTH front-ends for the
    /// width-aware knockdown's wall-ring term (handoff line-width-plumbing).
    public var wallLineWidthOuterMM: Double
    /// Extrusion line width (mm) of the INNER wall loops (see `wallLineWidthOuterMM`).
    /// A bead width, not the nozzle diameter. This is the core's historical single
    /// `wall_line_width_mm`.
    public var wallLineWidthInnerMM: Double

    public init(layerHeightMM: Double, wallLoops: Int, topLayers: Int,
                bottomLayers: Int, infillPercent: Int, infillPattern: String,
                wallLineWidthOuterMM: Double = PrintParams.fdmDefault.wallLineWidthOuterMM,
                wallLineWidthInnerMM: Double = PrintParams.fdmDefault.wallLineWidthInnerMM) {
        self.layerHeightMM = layerHeightMM
        self.wallLoops = wallLoops
        self.topLayers = topLayers
        self.bottomLayers = bottomLayers
        self.infillPercent = infillPercent
        self.infillPattern = infillPattern
        self.wallLineWidthOuterMM = wallLineWidthOuterMM
        self.wallLineWidthInnerMM = wallLineWidthInnerMM
    }

    // MARK: - Codable (back-compat, N4)

    private enum CodingKeys: String, CodingKey {
        case layerHeightMM, wallLoops, topLayers, bottomLayers, infillPercent, infillPattern
        case wallLineWidthOuterMM, wallLineWidthInnerMM
    }

    /// A project saved BEFORE the line-width fields existed (its JSON carries the six
    /// original keys but neither width) decodes with the two widths defaulted to the FDM
    /// starting point, so an old project loads instead of failing to decode (N4). The
    /// synthesized decoder would throw on the missing keys; this restores the same
    /// "missing → default" tolerance the whole-struct-optional `printParams?` already
    /// gives a pre-M7.params snapshot.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layerHeightMM = try c.decode(Double.self, forKey: .layerHeightMM)
        wallLoops = try c.decode(Int.self, forKey: .wallLoops)
        topLayers = try c.decode(Int.self, forKey: .topLayers)
        bottomLayers = try c.decode(Int.self, forKey: .bottomLayers)
        infillPercent = try c.decode(Int.self, forKey: .infillPercent)
        infillPattern = try c.decode(String.self, forKey: .infillPattern)
        wallLineWidthOuterMM = try c.decodeIfPresent(Double.self, forKey: .wallLineWidthOuterMM)
            ?? PrintParams.fdmDefault.wallLineWidthOuterMM
        wallLineWidthInnerMM = try c.decodeIfPresent(Double.self, forKey: .wallLineWidthInnerMM)
            ?? PrintParams.fdmDefault.wallLineWidthInnerMM
    }

    /// FDM-sensible defaults (a typical desktop-FDM starting point: 0.2 mm layers,
    /// 3 walls, 4 top / 4 bottom shells, 20 % gyroid infill). The sheet seeds from
    /// this and the "Default" button resets to it.
    ///
    /// Line-width defaults assume a 0.4 mm nozzle and follow the Bambu Studio /
    /// OrcaSlicer 0.4-nozzle system profile: a 0.42 mm OUTER wall (a hair narrower for
    /// surface quality) and a 0.45 mm INNER wall. 0.45 mm is also the core's historical
    /// `wall_line_width_mm` and the value coupons 191/192 were measured at, so the inner
    /// term is continuous with the calibrated knockdown. These are BEAD widths, not the
    /// nozzle diameter.
    public static let fdmDefault = PrintParams(
        layerHeightMM: 0.2, wallLoops: 3, topLayers: 4,
        bottomLayers: 4, infillPercent: 20, infillPattern: "gyroid",
        wallLineWidthOuterMM: 0.42, wallLineWidthInnerMM: 0.45)

    /// The infill-pattern options the sheet offers (design PRINT PARAMETERS sheet:
    /// 6 patterns). `gyroid` is the default and the core rules.json's FDM pattern.
    public static let patternOptions = [
        "gyroid", "grid", "cubic", "triangles", "honeycomb", "lines",
    ]

    // MARK: - Field bounds + step increments

    /// The sane FDM bounds for each numeric field, shared by the on-close `clamped()`
    /// and every − / + stepper so the two can never drift apart. Layer height
    /// 0.04–1.0 mm; walls 0–10; top/bottom shells 0–15; infill 0–100 %.
    public static let layerHeightRange: ClosedRange<Double> = 0.04...1.0
    public static let wallLoopsRange: ClosedRange<Int> = 0...10
    public static let shellLayersRange: ClosedRange<Int> = 0...15
    public static let infillRange: ClosedRange<Int> = 0...100
    /// Wall extrusion line width bounds (mm). A bead is ~0.6–2.0× the nozzle, and
    /// nozzles run ~0.2–1.0 mm, so 0.1–2.0 mm covers every realistic FDM profile while
    /// staying inside the core schema's (0, 100] guard. Shared by outer and inner.
    public static let lineWidthRange: ClosedRange<Double> = 0.1...2.0

    /// The nudge each field's − / + stepper applies: layer height and line width by
    /// 0.02 mm, the wall / shell counts and infill % by 1.
    public static let layerHeightStep: Double = 0.02
    public static let lineWidthStep: Double = 0.02

    // MARK: - Validation

    /// Sane FDM bounds, applied when the user edits a field (numeric inputs let a
    /// user type anything). A pattern outside `patternOptions` falls back to the
    /// default. Bounds come from the shared ranges so the steppers agree with this.
    public func clamped() -> PrintParams {
        PrintParams(
            layerHeightMM: layerHeightMM.isFinite ? Self.clamp(layerHeightMM, Self.layerHeightRange) : PrintParams.fdmDefault.layerHeightMM,
            wallLoops: Self.clamp(wallLoops, Self.wallLoopsRange),
            topLayers: Self.clamp(topLayers, Self.shellLayersRange),
            bottomLayers: Self.clamp(bottomLayers, Self.shellLayersRange),
            infillPercent: Self.clamp(infillPercent, Self.infillRange),
            infillPattern: PrintParams.patternOptions.contains(infillPattern) ? infillPattern : PrintParams.fdmDefault.infillPattern,
            wallLineWidthOuterMM: wallLineWidthOuterMM.isFinite ? Self.clamp(wallLineWidthOuterMM, Self.lineWidthRange) : PrintParams.fdmDefault.wallLineWidthOuterMM,
            wallLineWidthInnerMM: wallLineWidthInnerMM.isFinite ? Self.clamp(wallLineWidthInnerMM, Self.lineWidthRange) : PrintParams.fdmDefault.wallLineWidthInnerMM)
    }

    private static func clamp<V: Comparable>(_ v: V, _ range: ClosedRange<V>) -> V {
        Swift.min(Swift.max(v, range.lowerBound), range.upperBound)
    }

    /// Infill after stepping by `delta` %, already clamped to the valid 0–100 range.
    /// The sheet's − / + steppers use this so a step never leaves the range (the
    /// free-type field is still clamped globally on sheet close, per `clamped()`).
    public func steppingInfill(by delta: Int) -> Int {
        Self.clamp(infillPercent + delta, Self.infillRange)
    }

    /// Layer height after nudging by `steps` × 0.02 mm, clamped to 0.04–1.0 mm and
    /// rounded to a clean 2-dp mm value (so repeated steps don't accumulate float
    /// drift). Used by the sheet's layer-height − / + steppers.
    public func steppingLayerHeight(by steps: Int) -> Double {
        let nudged = layerHeightMM + Double(steps) * Self.layerHeightStep
        let clamped = Self.clamp(nudged, Self.layerHeightRange)
        return (clamped * 100).rounded() / 100
    }

    /// Wall loops after stepping by `delta`, clamped to 0–10 (the − / + steppers).
    public func steppingWallLoops(by delta: Int) -> Int {
        Self.clamp(wallLoops + delta, Self.wallLoopsRange)
    }

    /// Top shell layers after stepping by `delta`, clamped to 0–15.
    public func steppingTopLayers(by delta: Int) -> Int {
        Self.clamp(topLayers + delta, Self.shellLayersRange)
    }

    /// Bottom shell layers after stepping by `delta`, clamped to 0–15.
    public func steppingBottomLayers(by delta: Int) -> Int {
        Self.clamp(bottomLayers + delta, Self.shellLayersRange)
    }

    /// Outer wall line width after nudging by `steps` × 0.02 mm, clamped to 0.1–2.0 mm
    /// and rounded to a clean 2-dp mm value (no float drift under repeated steps).
    public func steppingOuterLineWidth(by steps: Int) -> Double {
        Self.steppedWidth(wallLineWidthOuterMM, by: steps)
    }

    /// Inner wall line width after nudging by `steps` × 0.02 mm, clamped to 0.1–2.0 mm.
    public func steppingInnerLineWidth(by steps: Int) -> Double {
        Self.steppedWidth(wallLineWidthInnerMM, by: steps)
    }

    private static func steppedWidth(_ w: Double, by steps: Int) -> Double {
        let nudged = w + Double(steps) * lineWidthStep
        let clamped = clamp(nudged, lineWidthRange)
        return (clamped * 100).rounded() / 100
    }

    /// Infill pinned to the 0–100 slider track. The tap-to-edit field can briefly
    /// hold an out-of-range value before the on-close clamp, and a SwiftUI `Slider`
    /// value outside its bounds is undefined — so the infill slider reads this.
    public var infillSliderValue: Double {
        Double(min(max(infillPercent, 0), 100))
    }

    // MARK: - Settings override

    /// The user overrides projected onto the M5.1 engine's FDM field set — i.e. the
    /// slicer settings this project should carry, overriding what `recommend_settings`
    /// would return. Layer height is intentionally absent (the engine has no such
    /// field; it is captured but not wired, per M7.params scope). This is the payload
    /// a settings/report/export surface consumes; today only `infillPercent` also
    /// reaches the core, through the bridge (M7.infill-margin).
    public var slicerOverride: SlicerOverride {
        SlicerOverride(walls: wallLoops, topLayers: topLayers, bottomLayers: bottomLayers,
                       infillPercent: infillPercent, infillPattern: infillPattern)
    }
}

/// The FDM slicer fields the M5.1 rule engine (core `SlicerSettings`) produces and
/// that the user's `PrintParams` override. A plain value type mirroring the engine's
/// FDM output so the override contract is expressible + testable in /app/ without a
/// core change. Layer height is not part of the engine's output, so it is not here.
public struct SlicerOverride: Equatable, Sendable, Codable {
    public var walls: Int
    public var topLayers: Int
    public var bottomLayers: Int
    public var infillPercent: Int
    public var infillPattern: String

    public init(walls: Int, topLayers: Int, bottomLayers: Int,
                infillPercent: Int, infillPattern: String) {
        self.walls = walls
        self.topLayers = topLayers
        self.bottomLayers = bottomLayers
        self.infillPercent = infillPercent
        self.infillPattern = infillPattern
    }
}
