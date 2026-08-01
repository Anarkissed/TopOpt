// LatticeVariantSession.swift — "lattice THIS variant" (task
// 2026-08-02-lattice-a-variant).
//
// THE DEFECT THIS FILE EXISTS FOR. The lattice page could already be opened from
// a finished variant, but opening it only borrowed that variant's stress field as
// a grading demand. The working model never changed, so Optimize on that page
// re-ran the WHOLE LADDER from the ORIGINAL part, merely graded by a previous
// run's field — the surprising behaviour behind a button that did not say so.
//
// Everything here is pure value types and pure rules so the whole surface is
// headlessly testable (the /app/ verification standard): which variant a page is
// working on, whether the artifacts needed to re-lattice it actually survive,
// which of the two genuinely-different actions a button offers, and what may be
// authored against a variant's geometry.

import Foundation
import simd
import TopOptKit

// MARK: - the retained artifacts (the storage gap, closed)

/// The two artifacts a re-lattice needs that a run did NOT used to keep:
///
///   * `designBin` — the run's `design.bin`: each variant's own DENSITY FIELD.
///     A run persisted the iso-surface MESH and the result FIELDS but never the
///     DESIGN, so the only surviving record of a variant was a triangle soup —
///     which is why "export the STL and re-import it" was the workaround, and
///     why it could not work (a re-voxelized iso-surface is a DIFFERENT design).
///   * `jobJSON` — the EXACT job document that was submitted. Not the project's
///     current editable state: the user may have moved an anchor since. The
///     load case must be the one the variant was optimized under, and the only
///     way to be sure of that is to keep it rather than re-derive it. PR 261's
///     lesson — a selector resolved against the wrong geometry silently tags
///     nothing — is exactly why re-authoring is not an option.
///
/// Both are captured at run time and persisted beside the outcome. A run that
/// produced neither (see `unavailableReason`) makes the re-lattice action
/// honestly UNAVAILABLE rather than quietly falling back to a fresh ladder.
public struct RelatticeArtifacts: Equatable, Sendable {
    public let jobJSON: Data
    public let designBin: Data

    public init(jobJSON: Data, designBin: Data) {
        self.jobJSON = jobJSON
        self.designBin = designBin
    }
}

/// Why a run cannot be re-latticed. Each case names a real, checkable condition —
/// never a generic "unavailable".
public enum RelatticeUnavailable: Equatable, Sendable {
    /// The run happened on this device through the bridge, which has no job
    /// document and writes no design container.
    case computedOnDevice
    /// The run predates the design container (an older worker, or a project
    /// restored from a blob written before this feature existed).
    case runPredatesDesignStore
    /// The worker served no design.bin for this job.
    case designNotTransferred

    public var reason: String {
        switch self {
        case .computedOnDevice:
            return "this run was solved on this device, which doesn’t write the design file a re-lattice needs — re-run it on a Mac worker to lattice its variants"
        case .runPredatesDesignStore:
            return "this run finished before results kept their design file — re-run it to lattice its variants"
        case .designNotTransferred:
            return "the Mac worker didn’t send this run’s design file — re-run it to lattice its variants"
        }
    }
}

// MARK: - which variant a lattice page is working on

/// The identity and the geometry of the variant a lattice page was opened from.
///
/// BAR Z9: this is what the viewport must render and what every authoring action
/// must resolve against. A label naming the variant over a viewport showing the
/// ORIGINAL part is exactly the dishonesty this type exists to prevent, so the
/// mesh travels WITH the identity rather than being looked up separately.
public struct LatticeVariantContext: Equatable {
    /// The run this variant belongs to (the project name, as the field
    /// provenance already records it).
    public let runName: String
    /// Its index in the results list — what the variants page shows.
    public let variantIndex: Int
    /// Its ladder rung. THE JOIN KEY: this is what the job's `variant` block
    /// names, and what the stored design container is keyed by.
    public let requestedVolumeFraction: Double
    public let massGrams: Double
    public let worstCaseMargin: Double
    public let accepted: Bool

    /// THE VARIANT'S OWN GEOMETRY (bar Z9). Flattened xyz vertices + triangle
    /// corner indices, exactly as the results screen draws them.
    public let meshVertices: [Float]
    public let meshIndices: [Int32]

    /// The variant's own von Mises field — Auto density with NO simulation
    /// (bar Z4, app side).
    public let field: LatticeDemandField

    /// The artifacts a re-lattice needs, when the run kept them.
    public let artifacts: RelatticeArtifacts?
    /// Why not, when it did not.
    public let unavailable: RelatticeUnavailable?

    public init(runName: String, variantIndex: Int,
                requestedVolumeFraction: Double, massGrams: Double,
                worstCaseMargin: Double, accepted: Bool,
                meshVertices: [Float], meshIndices: [Int32],
                field: LatticeDemandField,
                artifacts: RelatticeArtifacts?,
                unavailable: RelatticeUnavailable?) {
        self.runName = runName
        self.variantIndex = variantIndex
        self.requestedVolumeFraction = requestedVolumeFraction
        self.massGrams = massGrams
        self.worstCaseMargin = worstCaseMargin
        self.accepted = accepted
        self.meshVertices = meshVertices
        self.meshIndices = meshIndices
        self.field = field
        self.artifacts = artifacts
        self.unavailable = unavailable
    }

    /// "Variant 2 · 60% · 41.2 g" — the identity line the page shows so WHICH
    /// variant is being worked on is never in doubt (bar Z7/Z9).
    public var title: String {
        let pct = Int((requestedVolumeFraction * 100).rounded())
        let mass = massGrams > 0 ? String(format: " · %.1f g", massGrams) : ""
        return "Variant \(variantIndex + 1) · \(pct)%\(mass)"
    }

    /// The full attribution, including the run it came from.
    public var subtitle: String {
        "from “\(runName)” · margin " + String(format: "%.2f", worstCaseMargin)
    }

    /// Whether this variant can actually be re-latticed.
    public var canRelattice: Bool { artifacts != nil }
}

// MARK: - the two actions (bar Z7)

/// What a lattice page's action row offers.
///
/// BAR Z7: from a variant these are TWO genuinely different jobs, and the page
/// must never present one button that silently does the surprising one.
///
///   * `.relattice` — lattice THIS variant. No optimization ladder runs; the
///     stored design is re-certified, graded from its own field, latticed and
///     exported. Minutes.
///   * `.optimize`  — run the WHOLE ladder again from the original part, with
///     lattice settings applied to whatever it produces. This is the pre-existing
///     behaviour, and it keeps existing when it is what the user wants — but it
///     is now labelled as what it is.
///
/// From the workspace entry (no variant) there is only `.optimize`, exactly as
/// before, and this type's output is the pre-existing single-button surface.
public struct LatticePageActions: Equatable, Sendable {
    public struct Action: Equatable, Sendable {
        public let label: String
        public let sub: String
        public let enabled: Bool
        /// True for the action a plain tap should land on.
        public let primary: Bool
    }

    /// Lattice the finished variant. nil when the page was not opened from one.
    public let relattice: Action?
    /// Run the ladder from the original part.
    public let optimize: Action

    public static func compute(variant: LatticeVariantContext?,
                               optimizeSurface: LatticeOptimizeSurface,
                               running: Bool) -> LatticePageActions {
        guard let v = variant else {
            // No variant: the pre-existing single Optimize button, verbatim.
            return LatticePageActions(
                relattice: nil,
                optimize: Action(label: optimizeSurface.label,
                                 sub: optimizeSurface.sub,
                                 enabled: optimizeSurface.enabled, primary: true))
        }
        let pct = Int((v.requestedVolumeFraction * 100).rounded())
        let re: Action
        if running {
            re = Action(label: "Lattice this variant",
                        sub: "a job is already running", enabled: false,
                        primary: true)
        } else if let why = v.unavailable {
            re = Action(label: "Lattice this variant", sub: why.reason,
                        enabled: false, primary: true)
        } else {
            re = Action(
                label: "Lattice this variant",
                sub: "certifies and exports variant \(v.variantIndex + 1) (\(pct)%) — no ladder re-runs",
                enabled: true, primary: true)
        }
        // The ladder action keeps its own gate and reason, and gains the clause
        // that makes it distinguishable at a glance: it does NOT lattice this
        // variant, it starts over.
        let opt = Action(
            label: "Optimize from scratch",
            sub: "re-runs the whole ladder from the original part · " +
                 optimizeSurface.sub,
            enabled: optimizeSurface.enabled && !running, primary: false)
        return LatticePageActions(relattice: re, optimize: opt)
    }
}

// MARK: - what may be authored against a variant (bar Z11)

/// Authoring rules for a lattice page opened from a finished variant.
///
/// BAR Z11: a variant mesh has NO clean pseudo-faces. It is a marching-cubes
/// iso-surface of a topology-optimized field — the same segmentation limitation
/// behind tap-overselect, the clearance heuristic and the gravity-face problem.
/// Tapping it cannot produce a face id that means anything, and re-using the
/// ORIGINAL model's face ids would resolve a selector against geometry the
/// variant no longer has: PR 261's silent-tags-nothing failure, exactly.
///
/// So on a variant, authoring is by EXPLICIT GEOMETRY PREDICATE — the bolt
/// cylinder / bounded slab shape `resolve_clearance_manual` already carries and
/// core's `lattice.regions` accepts verbatim. Face TAPPING is off, and the page
/// says why instead of accepting taps that would land nowhere.
public struct LatticeVariantAuthoring: Equatable, Sendable {
    /// May the user tap the viewport to select a face?
    public let faceTapEnabled: Bool
    /// May the user place primitives (bolt cylinders / face slabs)?
    public let primitivePlacementEnabled: Bool
    /// The one-line explanation the page shows when tapping is off. Empty when
    /// tapping is on.
    public let note: String

    public static func compute(variant: LatticeVariantContext?)
        -> LatticeVariantAuthoring {
        guard variant != nil else {
            return LatticeVariantAuthoring(faceTapEnabled: true,
                                           primitivePlacementEnabled: true,
                                           note: "")
        }
        return LatticeVariantAuthoring(
            faceTapEnabled: false,
            primitivePlacementEnabled: true,
            note: "This is an optimized variant — it has no selectable faces. "
                + "Place a region to say where lattice goes; it lands on this "
                + "variant’s geometry.")
    }
}

// MARK: - region emission against a variant

public extension LatticeRegionEmission {
    /// The emission for a page working on a VARIANT.
    ///
    /// Only explicit geometry predicates are emitted (bar Z11): every entry
    /// comes from a placed primitive, whose cylinder/slab is model-space
    /// geometry the core resolves directly against the variant's voxels. Faces
    /// carried over from the setup page are NOT synthesised here — their
    /// geometry describes the ORIGINAL part's surface, which this design no
    /// longer has, and emitting them would place regions the user has never
    /// seen against the geometry they will actually affect. They are COUNTED so
    /// the page can say so.
    static func variantRegions(
        groups: [SelectionGroup],
        roles: [UUID: LatticeGroupRole],
        primitives: (UUID) -> [(prim: ManualPrimitive, depthMM: Double)],
        includePrimitives: [(prim: ManualPrimitive, depthMM: Double)]) -> Result {
        var out: [LatticeRegionSpec] = []
        var skipped = 0
        for (p, d) in includePrimitives {
            if let s = spec(for: p, role: .include, depthMM: d) { out.append(s) }
        }
        for g in groups {
            guard let role = roles[g.id] else { continue }
            for (p, d) in primitives(g.id) {
                if let s = spec(for: p, role: role, depthMM: d) { out.append(s) }
            }
            skipped += g.faces.count
        }
        return Result(regions: out, skippedFaces: skipped)
    }
}
