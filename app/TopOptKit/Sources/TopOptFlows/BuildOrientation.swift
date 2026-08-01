import Foundation
import simd

/// THE SECOND QUESTION (handoff 2026-08-01-build-direction-separation).
///
/// The app has always asked "which way is down in service" — that is the gravity
/// direction widget. It has never asked "which way is up on the printer", and the
/// pipeline simply assumed the answer was the opposite of the first. Those are
/// different questions. On the V5 hook's own load case that assumption lands on
/// the WORST of 26 orientations, and at resolution 48 it turns a part that passes
/// its strength check into one that fails it.
///
/// This model is the second question, stored separately, plus the ranking the
/// core hands back so the user can see WHY one way up beats another.
///
/// *** IT NEVER AUTO-APPLIES. *** The ranking is a recommendation. The verdict
/// shown anywhere in the app is the verdict of the orientation that was actually
/// certified. When the recommendation would gate differently, the app says so in
/// both directions and the user chooses; certifying against an orientation the
/// user did not pick is precisely the "the number describes a different object
/// than the file" failure this project has spent weeks eliminating.
public struct BuildOrientation: Codable, Equatable, Sendable {

    /// The declared build-plate normal in MODEL space, or nil when the user has
    /// not chosen one. nil is the DEFAULT and means "assume it from gravity",
    /// which is what the pipeline did before this existed — so a project that
    /// never touches this control produces the identical job.
    ///
    /// Optional + only-encoded-when-set, so a project saved before this change
    /// decodes with nil and the on-disk format is byte-identical when unused.
    public var plateUp: SIMD3<Float>?

    /// Ask the core for the ranking on the next run. Costs 0.1-0.4% of the
    /// certification solve it rides on (PR 266), so the app leaves it ON: the
    /// user who has NOT chosen an orientation is exactly the one it helps most.
    public var wantsRanking: Bool = true

    public init(plateUp: SIMD3<Float>? = nil, wantsRanking: Bool = true) {
        self.plateUp = plateUp
        self.wantsRanking = wantsRanking
    }

    /// THE ONE RESOLVER, app-side — the mirror of the core's
    /// `resolve_build_direction`. Explicit wins verbatim; unset falls back to
    /// `-gravity`, and to +Z when gravity is unset too (matching the loadcase
    /// builder's own +Z default). Every app path that needs a build direction
    /// must ask THIS, never re-derive it, for the same reason the core has one
    /// resolver: three derivations drift, and each looks self-consistent.
    public func resolved(gravity: SIMD3<Float>?) -> SIMD3<Float> {
        if let up = plateUp, up != .zero { return simd_normalize(up) }
        if let g = gravity, g != .zero { return simd_normalize(-g) }
        return SIMD3<Float>(0, 0, 1)
    }

    /// True when no plate normal was declared and the direction above is an
    /// inference. The UI must SAY so rather than presenting a guess as a choice.
    public var isInferredFromGravity: Bool { plateUp == nil || plateUp == .zero }

    // MARK: - the six named axes

    /// The candidate orientations the control offers. PR 266 measured every
    /// criterion's optimum, in all three of its cases, at one of these six — the
    /// off-axis candidates and the flat-face normals earned nothing, and the
    /// strut interlayer margin strictly vetoes off-axis. The core still RANKS all
    /// 26 sphere directions; the control offers the six that can win.
    public static let axes: [(label: String, dir: SIMD3<Float>)] = [
        ("+X", SIMD3(1, 0, 0)), ("−X", SIMD3(-1, 0, 0)),
        ("+Y", SIMD3(0, 1, 0)), ("−Y", SIMD3(0, -1, 0)),
        ("+Z", SIMD3(0, 0, 1)), ("−Z", SIMD3(0, 0, -1)),
    ]

    /// A short human label for a direction ("+Z", or the raw components off-axis).
    public static func label(_ v: SIMD3<Float>) -> String {
        for a in axes where simd_dot(simd_normalize(v), a.dir) > 0.999_9 { return a.label }
        let n = simd_normalize(v)
        return String(format: "(%.2f, %.2f, %.2f)", n.x, n.y, n.z)
    }

    public static func label(_ v: SIMD3<Double>) -> String {
        label(SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z)))
    }
}

// MARK: - the ranking the core hands back

/// One candidate orientation's SIX criteria, kept SEPARATE. PR 266's S3 measured
/// that they genuinely disagree — the strut-angle criterion wants a tilted
/// orientation while every other criterion wants a cube axis — and that a single
/// weighted score would launder that trade-off into one number that hides where
/// the disagreement is. So the UI shows the columns, never a total.
public struct OrientationCandidate: Codable, Equatable, Sendable, Identifiable {
    public var id: String { BuildOrientation.label(buildDirection) }

    public let buildDirection: SIMD3<Double>
    public let onCubeAxis: Bool
    public let isAsBuilt: Bool
    public let isRecommended: Bool

    /// S-a — support-requiring voxels. Lower is better; 0 means the part rests
    /// on the plate with no overhang the printer cannot bridge.
    public let supportVoxels: Int
    /// S-b — the macro interlayer margin, the term that actually moves with
    /// orientation (the in-plane term does not).
    public let macroInterlayerMargin: Double
    /// The gate's own number and verdict AT this orientation. REPORTED, never
    /// applied: this is what makes "as built REJECTED, as recommended ACCEPTED"
    /// a measured statement instead of a guess.
    public let marginEffective: Double
    public let wouldBeAccepted: Bool
    /// S-c — the strut in-plane margin. Present only for a latticed part, and
    /// INVARIANT in build direction by construction (PR 266's S2 self-check).
    public let strutInPlaneMargin: Double?
    /// S-d — the strut interlayer margin. Identical on all six cube axes; only
    /// ever WORSE off-axis, so it can veto a tilt but never argue for one.
    public let strutInterlayerMargin: Double?
    /// S-e — the fraction of lattice strut length lying within 10° of the plate.
    /// This is the criterion that DISAGREES with the others.
    public let horizontalStrutFraction: Double?
    /// S-f — printability in the build frame.
    public let minFeatureViolations: Int
    public let buildHeightLayers: Int
    public let firstLayerFootprintVoxels: Int
}

/// The decoded `build_orientation.json` receipt.
public struct OrientationRanking: Codable, Equatable, Sendable {
    public let asBuilt: SIMD3<Double>
    /// "declared" or "assumed_from_gravity" — the honesty half. A fallback that
    /// is not reported is a lie by omission (PR 266's S5).
    public let asBuiltWasAssumed: Bool
    public let asBuiltAccepted: Bool
    public let recommended: SIMD3<Double>
    public let recommendedAccepted: Bool
    public let recommendationDiffers: Bool
    /// *** The one the UI must never bury: the recommendation would gate
    /// differently from what was built. ***
    public let verdictWouldChange: Bool
    /// The core's own pre-composed sentence, so the app cannot phrase it
    /// differently from the receipt on disk.
    public let statement: String

    // MARK: - the orientation was CHOSEN (handoff 2026-08-01-bake-build-orientation)

    /// *** THE ORIENTATION WAS CHOSEN FOR THE USER, AND THE EXPORTED GEOMETRY
    /// WAS ROTATED ONTO IT. *** Only ever true when the user declared none. When
    /// this is set the UI MUST say so before it says anything else: PR 271's
    /// rule was "a recommendation never SILENTLY changes a verdict", and the
    /// word carrying it was *silently*. Applying a choice the user did not make
    /// and not saying so is the same failure wearing a helpful face.
    public let autoApplied: Bool
    /// What the run WOULD have used — the documented `-gravity` fallback — with
    /// its measured verdict. The counterfactual, not an adjective.
    public let asInferred: SIMD3<Double>?
    public let asInferredAccepted: Bool
    /// The chosen orientation gates DIFFERENTLY from the assumed one.
    public let autoApplyChangedVerdict: Bool
    /// *** The part PASSES because of the chosen orientation: printed the way
    /// the run would otherwise have assumed, it FAILS. *** The single most
    /// important sentence this app can show about a run, when it is true.
    public let autoApplyRescued: Bool
    /// The gate CONSTRAINED the choice: the unconstrained six-criteria
    /// recommendation would have failed, so the best PASSING orientation was
    /// applied instead. Shown so the trade-off is visible rather than resolved
    /// in silence.
    public let autoApplyConstrainedByGate: Bool
    /// The exported mesh was rotated so the certified build direction is +Z in
    /// the file. Every `SIMD3` on this type stays in the MODEL frame; this flag
    /// is what tells the UI there are two frames and which one it is showing.
    public let exportBaked: Bool

    public let candidates: [OrientationCandidate]
    /// PR 266's S2 invariants, checked in production. False here means the
    /// wiring is wrong and the columns below should not be trusted.
    public let strutInPlaneInvariant: Bool
    public let cubeAxesStrutInterlayerIdentical: Bool
    public let sweepSeconds: Double

    /// The six cube axes, in the control's order, for the ranking table. The
    /// core scores all 26 sphere directions; the table shows the ones a user can
    /// actually choose, plus the as-built row if it is off-axis.
    public var tableRows: [OrientationCandidate] {
        let axes = candidates.filter { $0.onCubeAxis }
        let offAxisAsBuilt = candidates.filter { $0.isAsBuilt && !$0.onCubeAxis }
        return offAxisAsBuilt + axes
    }

    /// WHERE the criteria disagree — the columns whose best candidate is not the
    /// recommended one. This is PR 266's S3 "does the compromise ATTAIN each
    /// optimum" report, and it is what the UI shows instead of a single score.
    public var dissentingCriteria: [String] {
        var out: [String] = []
        func best(_ key: (OrientationCandidate) -> Double?, lowerIsBetter: Bool) -> Double? {
            let vs = candidates.compactMap(key)
            return lowerIsBetter ? vs.min() : vs.max()
        }
        guard let rec = candidates.first(where: { $0.isRecommended }) else { return out }
        if let b = best({ Double($0.supportVoxels) }, lowerIsBetter: true),
           Double(rec.supportVoxels) != b { out.append("support material") }
        if let b = best({ $0.macroInterlayerMargin }, lowerIsBetter: false),
           rec.macroInterlayerMargin != b { out.append("interlayer strength") }
        if let b = best({ $0.strutInterlayerMargin }, lowerIsBetter: false),
           let v = rec.strutInterlayerMargin, v != b { out.append("lattice strut strength") }
        if let b = best({ $0.horizontalStrutFraction }, lowerIsBetter: true),
           let v = rec.horizontalStrutFraction, v != b { out.append("flat lattice struts") }
        if let b = best({ Double($0.buildHeightLayers) }, lowerIsBetter: true),
           Double(rec.buildHeightLayers) != b { out.append("print height") }
        return out
    }

    /// Decode the core's `build_orientation.json`. Returns nil for anything it
    /// does not recognise — a receipt the app cannot read is shown as absent,
    /// never as a half-parsed ranking.
    public static func decode(_ data: Data) -> OrientationRanking? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let built = root["as_built"] as? [String: Any],
              let rec = root["recommended"] as? [String: Any],
              let rows = root["candidates"] as? [[String: Any]]
        else { return nil }

        func vec(_ any: Any?) -> SIMD3<Double>? {
            guard let a = any as? [Any], a.count == 3 else { return nil }
            let d = a.compactMap { ($0 as? NSNumber)?.doubleValue }
            return d.count == 3 ? SIMD3(d[0], d[1], d[2]) : nil
        }
        guard let bDir = vec(built["build_direction"]), let rDir = vec(rec["build_direction"])
        else { return nil }

        let checks = root["self_checks"] as? [String: Any] ?? [:]
        // The auto-apply block, present only when the orientation was CHOSEN.
        // Absent on every PR 271 receipt, which decodes with autoApplied false
        // and every field below inert — so an old document still reads.
        let auto = root["auto_applied"] as? [String: Any]
        let inferredBlock = auto?["as_inferred"] as? [String: Any]
        let candidates: [OrientationCandidate] = rows.compactMap { r in
            guard let d = vec(r["build_direction"]) else { return nil }
            func num(_ k: String) -> Double? { (r[k] as? NSNumber)?.doubleValue }
            func int(_ k: String) -> Int { (r[k] as? NSNumber)?.intValue ?? 0 }
            func flag(_ k: String) -> Bool { (r[k] as? NSNumber)?.boolValue ?? false }
            return OrientationCandidate(
                buildDirection: d,
                onCubeAxis: flag("on_cube_axis"),
                isAsBuilt: flag("is_as_built"),
                isRecommended: flag("is_recommended"),
                supportVoxels: int("support_voxels"),
                macroInterlayerMargin: num("macro_interlayer_margin") ?? 0,
                marginEffective: num("margin_effective") ?? 0,
                wouldBeAccepted: flag("would_be_accepted"),
                strutInPlaneMargin: num("strut_in_plane_margin"),
                strutInterlayerMargin: num("strut_interlayer_margin"),
                horizontalStrutFraction: num("horizontal_strut_length_fraction"),
                minFeatureViolations: int("min_feature_violations"),
                buildHeightLayers: int("build_height_layers"),
                firstLayerFootprintVoxels: int("first_layer_footprint_voxels"))
        }
        guard !candidates.isEmpty else { return nil }

        return OrientationRanking(
            asBuilt: bDir,
            asBuiltWasAssumed: (built["source"] as? String) == "assumed_from_gravity",
            asBuiltAccepted: (built["verdict"] as? String) == "ACCEPTED",
            recommended: rDir,
            recommendedAccepted: (rec["verdict"] as? String) == "ACCEPTED",
            recommendationDiffers: (rec["differs_from_as_built"] as? NSNumber)?.boolValue ?? false,
            verdictWouldChange: (root["verdict_would_change"] as? NSNumber)?.boolValue ?? false,
            statement: (root["statement"] as? String) ?? "",
            autoApplied: (auto?["chosen"] as? NSNumber)?.boolValue ?? false,
            asInferred: vec(inferredBlock?["build_direction"]),
            asInferredAccepted: (inferredBlock?["verdict"] as? String) == "ACCEPTED",
            autoApplyChangedVerdict:
                (auto?["changed_verdict"] as? NSNumber)?.boolValue ?? false,
            autoApplyRescued: (auto?["rescued"] as? NSNumber)?.boolValue ?? false,
            autoApplyConstrainedByGate:
                (auto?["constrained_by_gate"] as? NSNumber)?.boolValue ?? false,
            exportBaked: ((root["export_frame"] as? [String: Any])?["baked"]
                as? NSNumber)?.boolValue ?? false,
            candidates: candidates,
            strutInPlaneInvariant: (checks["strut_in_plane_invariant"] as? NSNumber)?.boolValue ?? true,
            cubeAxesStrutInterlayerIdentical:
                (checks["cube_axes_strut_interlayer_identical"] as? NSNumber)?.boolValue ?? true,
            sweepSeconds: (root["sweep_seconds"] as? NSNumber)?.doubleValue ?? 0)
    }
}
