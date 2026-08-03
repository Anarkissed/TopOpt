// SmoothingVariantSession.swift — what the smoothing page is working on, and the
// LOAD CASE it re-certifies under (handoff 2026-08-02-smoothing-page).
//
// BAR AE3, AND THE REASON FOR IT. Re-certification must run under the load case
// the variant was OPTIMIZED under — not the project's current editable state. The
// user may have moved an anchor, changed a force, or swapped a material since the
// run finished; certifying a smoothed variant against that is certifying it
// against a part that never existed. PR 261's lesson is sharper still: a selector
// resolved against the wrong geometry does not fail loudly, it silently tags
// NOTHING, and the run reports a margin computed under no load at all.
//
// So the load case is READ OUT OF THE RETAINED JOB DOCUMENT that PR 274 keeps
// beside every variant, by the pure parser below. `SmoothRecertLoadCase` has no
// initialiser that takes a ProjectModel, a ForceModel or a SelectionModel — there
// is nowhere for the current editable state to enter. That is the structural half
// of AE3; the test is the other half.
//
// Everything here is pure value types and pure rules, so the whole surface is
// headlessly testable (the /app/ verification standard).

import Foundation
import simd
import TopOptKit

// MARK: - the load case, read out of the retained job

/// The physics inputs a re-certification needs, resolved from the EXACT job
/// document the variant was produced by.
///
/// The parse is deliberately strict about the things that decide a verdict
/// (material, resolution, anchors, load groups) and forgiving about the rest: a
/// key this build has never heard of is simply not read, never a parse failure,
/// because the retained document may have been written by a newer worker.
public struct SmoothRecertLoadCase: Equatable, Sendable {
    public let material: String
    public let resolution: Int
    public let anchorFaceIDs: [Int]
    public let loadGroups: [TopOptKit.LoadGroupSpec]
    /// `loads.build_dir` — which way is DOWN in service (core negates it into
    /// gravity). Not the plate normal.
    public let buildDirection: SIMD3<Double>
    public let infillPercent: Int
    /// Keep-clear bores / mating pads / protected faces the run declared, as the
    /// freeze primitives the smoother holds bit-identical.
    public let freeze: [TopOptKit.FreezeRegionSpec]
    /// Face ids the run declared as protected. Frozen too, but resolved from the
    /// model's own B-rep by the bridge (they have no app-side geometry here).
    public let protectedFaceIDs: [Int]

    public enum ParseError: Error, CustomStringConvertible, Equatable {
        case notJSON
        case noLoadCase
        case missing(String)

        public var description: String {
            switch self {
            case .notJSON:
                return "the retained job document is not readable JSON"
            case .noLoadCase:
                return "the retained job has no declared load case — it was a "
                     + "self-weight run, and there is no traction to re-certify under"
            case .missing(let k):
                return "the retained job is missing \"\(k)\", which the "
                     + "re-certification cannot be run without"
            }
        }
    }

    /// THE ONLY WAY TO BUILD ONE. Parses the retained job document — the bytes PR
    /// 274 kept beside the variant.
    public static func fromRetainedJob(_ data: Data) throws -> SmoothRecertLoadCase {
        guard let job = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any] else { throw ParseError.notJSON }
        guard let material = job["material"] as? String, !material.isEmpty else {
            throw ParseError.missing("material")
        }
        guard let resolution = (job["resolution"] as? NSNumber)?.intValue,
              resolution > 0 else { throw ParseError.missing("resolution") }
        guard let loads = job["loads"] as? [String: Any] else {
            throw ParseError.noLoadCase
        }

        let anchors = (loads["anchor_face_ids"] as? [Any] ?? [])
            .compactMap { ($0 as? NSNumber)?.intValue }
        var groups: [TopOptKit.LoadGroupSpec] = []
        for g in (loads["groups"] as? [[String: Any]] ?? []) {
            let ids = (g["face_ids"] as? [Any] ?? [])
                .compactMap { ($0 as? NSNumber)?.intValue }
            let f = (g["force"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
            guard f.count == 3 else { continue }
            groups.append(TopOptKit.LoadGroupSpec(faceIDs: ids,
                                                  force: SIMD3(f[0], f[1], f[2])))
        }
        if anchors.isEmpty || groups.isEmpty { throw ParseError.noLoadCase }

        let bd = (loads["build_dir"] as? [Any] ?? [])
            .compactMap { ($0 as? NSNumber)?.doubleValue }
        let buildDirection = bd.count == 3 ? SIMD3(bd[0], bd[1], bd[2])
                                           : SIMD3<Double>(0, 0, 1)
        let infill = (loads["infill_percent"] as? NSNumber)?.intValue ?? -1

        // Keep-clear regions: only the MANUAL ones carry geometry in the document.
        // A face-sourced clearance names a face id the bridge re-resolves from the
        // model's own B-rep, exactly as the run did — the geometry is not
        // re-authored here, which is the same rule PR 274 applied to lattice
        // regions on a variant.
        var freeze: [TopOptKit.FreezeRegionSpec] = []
        for c in (loads["clearances"] as? [[String: Any]] ?? []) {
            guard let geo = c["geometry"] as? [String: Any] else { continue }
            let kind = (c["kind"] as? String) ?? "bolt"
            func vec(_ key: String) -> SIMD3<Double>? {
                guard let a = (geo[key] as? [Any])?
                        .compactMap({ ($0 as? NSNumber)?.doubleValue }), a.count == 3
                else { return nil }
                return SIMD3(a[0], a[1], a[2])
            }
            func num(_ key: String) -> Double { (geo[key] as? NSNumber)?.doubleValue ?? 0 }
            if kind == "face" {
                guard let o = vec("origin"), let n = vec("normal") else { continue }
                freeze.append(.face(origin: o, normal: n,
                                    halfUMM: num("half_u_mm"),
                                    halfWMM: num("half_w_mm")))
            } else {
                guard let p = vec("axis_point"), let d = vec("axis_dir") else { continue }
                freeze.append(.bolt(axisPoint: p, axisDir: d,
                                    radiusMM: num("radius_mm"),
                                    halfLengthMM: num("half_length_mm")))
            }
        }
        let protections = (loads["face_protections"] as? [Any] ?? [])
            .compactMap { ($0 as? NSNumber)?.intValue }

        return SmoothRecertLoadCase(
            material: material, resolution: resolution, anchorFaceIDs: anchors,
            loadGroups: groups, buildDirection: buildDirection,
            infillPercent: infill, freeze: freeze, protectedFaceIDs: protections)
    }

    /// The anchor + load + protected faces, all of which the smoother freezes. The
    /// bridge resolves each from the model's own B-rep — the same predicates the
    /// run used — so the clamp and the traction stay attached to bit-identical
    /// solid across the re-voxelization.
    public var structurallyFrozenFaceIDs: [Int] {
        anchorFaceIDs + loadGroups.flatMap { $0.faceIDs } + protectedFaceIDs
    }

    /// A one-line attribution the page shows above the receipt, so WHICH load case
    /// produced these numbers is stated rather than assumed.
    public var attribution: String {
        let n = loadGroups.reduce(0) { $0 + $1.faceIDs.count }
        return "re-certified under the run's own load case · "
             + "\(anchorFaceIDs.count) anchor face\(anchorFaceIDs.count == 1 ? "" : "s") · "
             + "\(loadGroups.count) load group\(loadGroups.count == 1 ? "" : "s") "
             + "over \(n) face\(n == 1 ? "" : "s") · \(material) · \(resolution)³"
    }
}

// MARK: - which variant the smoothing page is working on

/// Why a finished variant cannot be smoothed. Each case names a real, checkable
/// condition — never a generic "unavailable".
public enum SmoothUnavailable: Equatable, Sendable {
    /// The run kept no job document (an on-device run, or one that predates the
    /// retention PR 274 added), so there is no load case to re-certify under and
    /// the project's current state is NOT an acceptable substitute.
    case noRetainedJob
    /// THE RUN WAS SOLVED ON THIS DEVICE. Distinct from `noRetainedJob` on purpose
    /// (task 2026-08-03-variant-entry-gating-and-retention): the bridge writes no
    /// job document at all, so "re-run it on a Mac worker" is the actual fix — and
    /// a user who DID run it on a worker must never be told that. Which of the two
    /// they are looking at is decided by the run's own recorded machine, and the
    /// machine is shown beside the reason.
    case computedOnDevice
    /// The retained job declared no load case at all (a self-weight run). Under
    /// self-weight a lighter part carries less of its own weight, so smoothing can
    /// only ever RAISE the margin — the receipt would be real but vacuous, and the
    /// page says so rather than staging a reassuring number.
    case selfWeightRun
    /// THE PIPELINE ORDER (AE8's reverse). Smoothing a latticed export would round
    /// the STRUTS, which is not what anyone means by smoothing a part.
    case alreadyLatticed
    /// The variant has no exported geometry to smooth (a cancelled rung).
    case noGeometry
    /// The model file the load case's faces are defined on is gone.
    case modelFileMissing
    /// CORE COULD NOT READ THE VARIANT BACK (round 2, bar S2). The page's mesh is
    /// core's own import of the file the page wrote — that is what makes the
    /// protected-surface map and the brush the same mesh by construction. If that
    /// import fails there is no page mesh at all, and the honest answer is to say
    /// so here rather than open a page whose brush is inert for a reason it
    /// cannot name.
    case meshUnreadable(String)

    public var reason: String {
        switch self {
        case .noRetainedJob:
            return "this run finished before results kept their job document, so "
                 + "there’s no load case to re-certify a smoothed shape under — "
                 + "re-run it to smooth its variants"
        case .computedOnDevice:
            return "this run was solved on this device, which doesn’t write the job "
                 + "document a re-certification needs — re-run it on a Mac worker "
                 + "to smooth its variants"
        case .selfWeightRun:
            return "this run had no declared load — under self-weight, smoothing "
                 + "only ever raises the margin, so the receipt would tell you nothing"
        case .alreadyLatticed:
            return "this run generated a lattice — smoothing it would round the "
                 + "struts. Smooth first, then lattice the smoothed variant"
        case .noGeometry:
            return "this rung produced no geometry to smooth"
        case .modelFileMissing:
            return "the model file is missing — the load case’s faces are defined on it"
        case .meshUnreadable(let why):
            return "this variant’s mesh could not be read back for smoothing: \(why)"
        }
    }
}

/// The identity and the geometry of the variant a smoothing page was opened from.
///
/// Like `LatticeVariantContext`, the MESH TRAVELS WITH THE IDENTITY: a label
/// naming a variant over a viewport showing something else is exactly the
/// dishonesty this type exists to prevent.
public struct SmoothVariantContext: Equatable {
    public let runName: String
    public let variantIndex: Int
    public let requestedVolumeFraction: Double
    public let massGrams: Double
    /// The OPTIMIZER's remembered margin for this variant. Shown ONLY as
    /// provenance ("the run reported…"), NEVER as the before-side of the receipt —
    /// AE2 requires both sides to be measured by analyze_fixed_design.
    public let reportedMargin: Double
    public let accepted: Bool

    /// THE PAGE'S ONE MESH (round 2, bar S2) — core's own import of the file the
    /// page wrote. The stage draws it, the brush paints it, `smooth_freeze_mask`
    /// masks it and the smoother moves it, because all four read that same file.
    ///
    /// It is deliberately NOT `OptimizeVariant.meshVertices`: on a LAN run that
    /// buffer is a triangle soup with 6x core's vertex count, which is exactly
    /// the mismatch this page refused to paint through.
    public let pageMesh: SmoothPageMesh

    /// The page's geometry, flattened as the results screen draws it. Derived
    /// from `pageMesh` so there is one definition and no second buffer to drift.
    public var meshVertices: [Float] { pageMesh.vertices }
    public var meshIndices: [Int32] { pageMesh.indices }

    /// The load case the variant was optimized under, read out of the retained job.
    public let loadCase: SmoothRecertLoadCase?
    /// Why smoothing is unavailable, when it is.
    public let unavailable: SmoothUnavailable?
    /// The part file the load case's face ids are defined on.
    public let modelPath: String

    public init(runName: String, variantIndex: Int,
                requestedVolumeFraction: Double, massGrams: Double,
                reportedMargin: Double, accepted: Bool,
                pageMesh: SmoothPageMesh,
                loadCase: SmoothRecertLoadCase?,
                unavailable: SmoothUnavailable?, modelPath: String) {
        self.runName = runName
        self.variantIndex = variantIndex
        self.requestedVolumeFraction = requestedVolumeFraction
        self.massGrams = massGrams
        self.reportedMargin = reportedMargin
        self.accepted = accepted
        self.pageMesh = pageMesh
        self.loadCase = loadCase
        self.unavailable = unavailable
        self.modelPath = modelPath
    }

    /// The request for this page's protected-surface map, or nil when there is no
    /// load case to resolve it against. Routed through `pageMesh` so the mesh path
    /// it names is the page mesh's own — bar S2's "by construction".
    public var freezeMaskRequest: SmoothFreezeMaskRequest? {
        loadCase.map { pageMesh.freezeMaskRequest(modelPath: modelPath, loadCase: $0) }
    }

    public var title: String {
        let pct = Int((requestedVolumeFraction * 100).rounded())
        let mass = massGrams > 0 ? String(format: " · %.1f g", massGrams) : ""
        return "Variant \(variantIndex + 1) · \(pct)%\(mass)"
    }

    public var subtitle: String {
        "from “\(runName)” · the run reported margin "
            + String(format: "%.2f", reportedMargin)
    }

    public var canSmooth: Bool { loadCase != nil && unavailable == nil }
    public var vertexCount: Int { meshVertices.count / 3 }
}

// MARK: - entry availability (AE8, both directions)

/// Whether the smoothing page may be entered for a given finished variant, and
/// whether a smoothed variant may go on to the lattice page.
///
/// THE PIPELINE ORDER IS SMOOTH-THEN-LATTICE, and it is enforced HERE rather than
/// left to the two pages to agree about:
///   * a variant from a run that generated a lattice may NOT be smoothed;
///   * a smoothed variant MAY be sent to the lattice page, and the lattice is then
///     generated on the SMOOTHED geometry.
public enum SmoothPageEntry {

    /// Decide entry for a variant. `latticed` is the run's own record of whether
    /// it generated a lattice (`OptimizeOutcome.latticeReport != nil`) — the run's
    /// fact, not the project's current lattice settings.
    ///
    /// `solvedOnDevice` separates the two ways a job document can be absent (see
    /// `SmoothUnavailable.computedOnDevice`). It defaults to false so every
    /// pre-existing caller and test keeps its exact previous verdict.
    public static func availability(hasGeometry: Bool, latticed: Bool,
                                    retainedJob: Data?,
                                    modelPath: String?,
                                    solvedOnDevice: Bool = false) -> SmoothUnavailable? {
        if !hasGeometry { return .noGeometry }
        if latticed { return .alreadyLatticed }
        guard let path = modelPath, !path.isEmpty else { return .modelFileMissing }
        _ = path
        guard let job = retainedJob else {
            return solvedOnDevice ? .computedOnDevice : .noRetainedJob
        }
        do {
            _ = try SmoothRecertLoadCase.fromRetainedJob(job)
            return nil
        } catch SmoothRecertLoadCase.ParseError.noLoadCase {
            return .selfWeightRun
        } catch {
            return .noRetainedJob
        }
    }

    /// Build the context for a variant, resolving its load case from the retained
    /// job. Never reads the project's current editable state — there is no
    /// parameter through which it could.
    ///
    /// `pageMesh` is core's own import of the file the page wrote (bar S2). It is
    /// the ONLY geometry this function accepts: there is no parameter through
    /// which the run's own streamed buffer could reach the page, which is what
    /// stops the page from ever holding two meshes again.
    ///
    /// `meshUnreadable` is the caller's report that the import failed. It is
    /// checked FIRST, because every later verdict would be about a mesh that was
    /// never read.
    public static func context(runName: String, variantIndex: Int,
                               requestedVolumeFraction: Double, massGrams: Double,
                               reportedMargin: Double, accepted: Bool,
                               pageMesh: SmoothPageMesh,
                               latticed: Bool, retainedJob: Data?,
                               modelPath: String?,
                               meshUnreadable: String? = nil) -> SmoothVariantContext {
        let why: SmoothUnavailable?
        if let e = meshUnreadable {
            why = .meshUnreadable(e)
        } else {
            why = availability(hasGeometry: !pageMesh.isEmpty,
                               latticed: latticed, retainedJob: retainedJob,
                               modelPath: modelPath)
        }
        let lc: SmoothRecertLoadCase? = why == nil
            ? retainedJob.flatMap { try? SmoothRecertLoadCase.fromRetainedJob($0) }
            : nil
        return SmoothVariantContext(
            runName: runName, variantIndex: variantIndex,
            requestedVolumeFraction: requestedVolumeFraction, massGrams: massGrams,
            reportedMargin: reportedMargin, accepted: accepted,
            pageMesh: pageMesh,
            loadCase: lc, unavailable: why, modelPath: modelPath ?? "")
    }

    /// THE HANDOFF TO THE LATTICE PAGE (AE8, forward). Returns the geometry the
    /// lattice page must work on: the SMOOTHED mesh when smoothing was kept, the
    /// original otherwise. Never a blend, and never the original under a label
    /// that says smoothed.
    public static func latticeGeometry(original: (vertices: [Float], indices: [Int32]),
                                       kept: SmoothKeptResult?)
        -> (vertices: [Float], indices: [Int32], smoothed: Bool) {
        guard let k = kept else {
            return (original.vertices, original.indices, false)
        }
        return (k.meshVertices, k.meshIndices, true)
    }
}

/// The smoothing a user chose to KEEP: the smoothed geometry plus the receipt
/// that certified it. This is what travels onward to the lattice page and to
/// export — geometry and its verdict together, never one without the other.
// MARK: - WHICH RUNG A SMOOTHING BELONGS TO (task
//         2026-08-03-variant-postprocessing-concurrency, requirement 3)

/// THE DEFECT THIS EXISTS FOR. A ladder takes hours, and a user can now work on
/// rung 1 while rung 4 is still solving. So they can smooth rung 1, watch rung 3
/// arrive, and ship rung 3 — with a smoothed shape on screen that was computed
/// from a DIFFERENT design and certified under a different margin. A smoothed
/// variant must never silently become the basis for a later rung's work.
///
/// The rule is PR 260's, deliberately: an Equatable FINGERPRINT of everything that
/// determines the result, recorded when it is computed and compared against the
/// current one — same inputs ⇒ fresh, any change ⇒ stale — surfaced through the
/// SAME `LatticePageBanner` shape (`.smoothingStale`). No second staleness concept.
public struct SmoothingRungFingerprint: Equatable, Sendable {
    /// The rung's position in the run's ladder — what the UI calls it.
    public let variantIndex: Int
    /// The rung's ladder target, the key every artifact is indexed by.
    public let requestedVolumeFraction: Double
    /// Core's hash over that rung's DENSITY FIELD (`design_fingerprint`), read from
    /// the retained container. This is what makes the identity a DESIGN rather than
    /// a position: a later run whose rung 1 lands at the same volume fraction is a
    /// different design and hashes differently. nil when no container covers the
    /// rung — then the index + fraction are the whole identity, which is honest
    /// rather than pretending to a hash we do not have.
    public let designFingerprint: UInt64?

    public init(variantIndex: Int, requestedVolumeFraction: Double,
                designFingerprint: UInt64? = nil) {
        self.variantIndex = variantIndex
        self.requestedVolumeFraction = requestedVolumeFraction
        self.designFingerprint = designFingerprint
    }

    /// How the UI names this rung. One phrasing, so the banner, the card and the
    /// receipt cannot drift.
    public var rungLabel: String {
        String(format: "rung %d (%.0f%% volume)", variantIndex + 1,
               requestedVolumeFraction * 100)
    }
}

/// The staleness verdict for a kept smoothing, against the variant on screen.
public enum SmoothingStaleness {

    /// nil ⇒ the smoothing describes the variant currently shown. Non-nil ⇒ it was
    /// made from a different rung, and the banner says WHICH.
    ///
    /// `kept` is the fingerprint recorded when the smoothing was computed; `current`
    /// is the variant the page is showing now.
    public static func banner(kept: SmoothingRungFingerprint?,
                              current: SmoothingRungFingerprint?)
        -> LatticePageBanner? {
        guard let kept, let current, kept != current else { return nil }
        return LatticePageBanner(
            kind: .smoothingStale,
            title: "Smoothing is from \(kept.rungLabel)",
            body: "You are looking at \(current.rungLabel). This smoothed shape was "
                + "computed from \(kept.rungLabel) and certified under that rung's "
                + "own margin — it does not describe the variant on screen. Smooth "
                + "this rung to get a result for it.",
            actionLabel: "Smooth this rung", showsProgress: false)
    }

    /// Whether a kept smoothing may be presented as the CURRENT geometry. The
    /// inverse of the banner, given its own name because that is the question every
    /// call site is actually asking, and a `banner == nil` check reads as a UI
    /// question rather than a correctness one.
    public static func isCurrent(kept: SmoothingRungFingerprint?,
                                 current: SmoothingRungFingerprint?) -> Bool {
        banner(kept: kept, current: current) == nil
    }
}

public struct SmoothKeptResult: Equatable, Sendable {
    public let meshVertices: [Float]
    public let meshIndices: [Int32]
    /// The path of the smoothed mesh core wrote.
    public let meshPath: String
    /// The certification of THIS geometry.
    public let certification: SmoothCertification
    /// Per-region strengths, for the record.
    public let regionSummary: [String]
    /// WHICH RUNG THIS WAS MADE FROM (task
    /// 2026-08-03-variant-postprocessing-concurrency, requirement 3). Recorded at
    /// KEEP time, so the identity travels with the geometry rather than being
    /// re-derived later from whatever happens to be selected.
    public let rung: SmoothingRungFingerprint?

    public init(meshVertices: [Float], meshIndices: [Int32], meshPath: String,
                certification: SmoothCertification, regionSummary: [String],
                rung: SmoothingRungFingerprint? = nil) {
        self.meshVertices = meshVertices
        self.meshIndices = meshIndices
        self.meshPath = meshPath
        self.certification = certification
        self.regionSummary = regionSummary
        self.rung = rung
    }
}
