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
/// THE TWO HALVES ARRIVE AT DIFFERENT TIMES, AND ONLY ONE OF THEM IS NEEDED FOR
/// SMOOTHING (task 2026-08-03-variant-postprocessing-fix). The job document
/// exists the instant the run is submitted; `design.bin` exists only once the
/// solver has produced a variant. Treating them as one all-or-nothing pair meant a
/// run whose design never arrived reported that it had kept NOTHING — and the
/// smoothing entry, which needs only the load case, was greyed out with it.
///
/// So `designBin` may be EMPTY: that is a pair which can re-certify a smoothed
/// shape but cannot lattice a variant, and the two entry gates say exactly that.
/// `VariantEntryFacts.artifacts` is the accessor that enforces "both halves" where
/// both halves are genuinely required.
public struct RelatticeArtifacts: Equatable, Sendable {
    public let jobJSON: Data
    public let designBin: Data

    public init(jobJSON: Data, designBin: Data) {
        self.jobJSON = jobJSON
        self.designBin = designBin
    }

    /// The half that exists at SUBMIT time. Smoothing needs only this.
    public static func jobOnly(_ jobJSON: Data) -> RelatticeArtifacts {
        RelatticeArtifacts(jobJSON: jobJSON, designBin: Data())
    }

    /// Whether the design container came too — i.e. whether a variant of this run
    /// can be latticed, not merely smoothed.
    public var hasDesign: Bool { !designBin.isEmpty }
}

// MARK: - what a retained design.bin actually contains

/// THE VOLUME FRACTIONS A RETAINED `design.bin` HOLDS BLOCKS FOR.
///
/// WHY THIS EXISTS. The container is now published by core after EVERY variant and
/// fetched by the app after every variant, so it normally covers exactly the
/// variants on screen. "Normally" is not a gate. A fetch that fails at rung 3
/// leaves a two-block container beside three visible variants, and "Lattice" on
/// the third would be enabled right up until core refused it with *"no stored
/// design at volume fraction 0.38"* — the late refusal this whole gating surface
/// exists to remove. So the app reads the container's own index and checks.
///
/// It parses the HEADER and each block's PROLOGUE only (`design_store.hpp`
/// v1: little-endian throughout), striding over the density payload rather than
/// copying it — a 50 MB container is indexed without materialising a single field.
public struct DesignContainerIndex: Equatable, Sendable {
    /// `requested_volume_fraction` of every block, in file order.
    public let requestedVolumeFractions: [Double]
    /// Each block's `fingerprint` — core's hash over that rung's DENSITY FIELD
    /// (`design_fingerprint`, design_store.cpp). Parallel to the array above.
    ///
    /// This is the identity of a DESIGN, not of a position: two rungs at the same
    /// volume fraction from different runs hash differently. That is what lets a
    /// smoothing say which design it was made from and go stale when that is no
    /// longer the design on screen (task
    /// 2026-08-03-variant-postprocessing-concurrency, requirement 3), and it is the
    /// same number PR 274's Z3 uses to tie "the certified object" to "the exported
    /// one".
    public let fingerprints: [UInt64]

    public init(requestedVolumeFractions: [Double], fingerprints: [UInt64] = []) {
        self.requestedVolumeFractions = requestedVolumeFractions
        self.fingerprints = fingerprints
    }

    /// The design fingerprint for a rung, or nil when the container has no block
    /// for it. nil is never "0" — an absent design is not a design that hashes to
    /// zero.
    public func fingerprint(forRequestedVolumeFraction vf: Double) -> UInt64? {
        guard let i = requestedVolumeFractions.firstIndex(where: { $0 == vf }),
              i < fingerprints.count else { return nil }
        return fingerprints[i]
    }

    /// The format version this reader understands (`kDesignFormatVersion`).
    static let formatVersion: UInt8 = 1
    /// Bytes before the first block: version(1) + pad(3) + nx,ny,nz(3×4)
    /// + origin(3×8) + spacing(8) + count(4) + pad(4).
    static let headerBytes = 1 + 3 + 12 + 24 + 8 + 4 + 4
    /// Bytes of one block BEFORE its density array: requested_vf, achieved_vf,
    /// margin_worst, margin_effective, max_stress (5×8) + accepted, iterations
    /// (2×4) + build_dir (3×8) + auto_applied, baked (2×4) + fingerprint(8)
    /// + count(8).
    static let blockPrologueBytes = 40 + 8 + 24 + 8 + 8 + 8

    /// nil when the bytes are not a container this build can read — never a
    /// half-parsed answer, and never a crash on a truncated file.
    public static func parse(_ data: Data) -> DesignContainerIndex? {
        func u8(_ at: Int) -> UInt8? {
            guard at >= 0, at < data.count else { return nil }
            return data[data.startIndex + at]
        }
        // The format is fixed little-endian and every Apple target is
        // little-endian, so an unaligned load IS the decode.
        func le<T>(_ at: Int, _ type: T.Type) -> T? {
            guard at >= 0, at + MemoryLayout<T>.size <= data.count else { return nil }
            return data.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: at, as: T.self)
            }
        }
        guard u8(0) == formatVersion,
              let count = le(16 + 24 + 8, Int32.self), count >= 0
        else { return nil }
        var fractions: [Double] = []
        var prints: [UInt64] = []
        var at = headerBytes
        for _ in 0..<Int(count) {
            guard let vf = le(at, Double.self),
                  // fingerprint sits immediately before the density count (u64,
                  // then i64) — see `blockPrologueBytes`.
                  let fp = le(at + blockPrologueBytes - 16, UInt64.self),
                  let densityCount = le(at + blockPrologueBytes - 8, Int64.self),
                  densityCount >= 0
            else { return nil }
            fractions.append(vf)
            prints.append(fp)
            let next = at + blockPrologueBytes + Int(densityCount) * 8
            guard next <= data.count else { return nil }
            at = next
        }
        return DesignContainerIndex(requestedVolumeFractions: fractions,
                                    fingerprints: prints)
    }

    /// Whether a block for this rung is present. The re-lattice job selects by
    /// VOLUME FRACTION (`RelatticeRunner`, `job.variant.volume_fraction`), and
    /// core matches it exactly, so this comparison is the same one core makes.
    public func holds(requestedVolumeFraction vf: Double) -> Bool {
        requestedVolumeFractions.contains { $0 == vf }
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
    /// The app RE-ATTACHED to this run after a relaunch, so it no longer holds the
    /// document it submitted. Rebuilding one from the current project state is the
    /// re-authored load case this whole path exists to avoid, so it is refused
    /// rather than approximated.
    case jobDocumentNotRecorded
    /// The rung produced no geometry (a cancelled / severed rung), so there is no
    /// variant to lattice at all.
    case noGeometry
    /// THE RUN USED A DESIGN BOX. Core refuses lattice certification under domain
    /// expansion — the certification load case cannot be reconstructed on the
    /// expanded grid (`run_job.cpp`, both the optimize+lattice pre-flight and
    /// `lattice_variant_job`). Read from the RETAINED job, not the project's
    /// current design-box state: the question is what the run DID, not what the
    /// workspace is set to now.
    case designBoxRun
    /// No Mac worker is selected. The certification solves run where the core
    /// runs, and the on-device bridge has no lattice path at all.
    case noWorkerSelected
    /// The model file the retained load case's faces are defined on is gone.
    case modelFileMissing
    /// The run kept a design container, but it holds no block for THIS rung — the
    /// design fetch that would have added it failed while later variants kept
    /// streaming. Core selects the stored design by volume fraction and would
    /// refuse this one by name; the button says so instead.
    case variantNotInDesign

    public var reason: String {
        switch self {
        case .computedOnDevice:
            return "this run was solved on this device, which doesn’t write the design file a re-lattice needs — re-run it on a Mac worker to lattice its variants"
        case .runPredatesDesignStore:
            return "this run finished before results kept their design file — re-run it to lattice its variants"
        case .designNotTransferred:
            return "the Mac worker didn’t send this run’s design file — re-run it to lattice its variants"
        case .jobDocumentNotRecorded:
            return "this app reconnected to the run after a restart, so it no longer has the job it sent — re-run it to lattice its variants"
        case .noGeometry:
            return "this rung produced no geometry to lattice"
        case .designBoxRun:
            return "this run used a design box — the certification load case can’t be rebuilt on the expanded grid, so the core refuses to lattice it. Re-run it without a design box to lattice its variants"
        case .noWorkerSelected:
            return "latticing a variant runs on a Mac worker — pick one in Compute first"
        case .modelFileMissing:
            return "the model file is missing — the run’s load case is defined on it"
        case .variantNotInDesign:
            return "this run’s design file arrived without this rung in it, so there’s nothing to lattice here — a later variant’s design didn’t reach this device. Re-run it to lattice this variant"
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
    /// Its ladder rung — what the results screen labels it and what names its
    /// exported mesh file. A POSITION IN A LADDER, not a description of the
    /// design: on a growth ladder it is 1.55 / 1.25 / 1.10 (see below).
    public let requestedVolumeFraction: Double
    /// THE VARIANT'S OWN ACHIEVED VOLUME FRACTION (task
    /// 2026-08-04-variant-volume-fraction-mismatch, bar A3) — what this design
    /// actually came out at, from THIS variant's own record. Travels with the
    /// re-lattice job and is CHECKED by core against the stored design, so the
    /// number the page shows and the number the design achieved cannot drift.
    public let achievedVolumeFraction: Double
    /// THE DESIGN'S IDENTITY — core's `design_fingerprint` for this rung, read
    /// from the retained container's own index. This is what the re-lattice job
    /// selects by.
    ///
    /// *** WHY NOT THE RUNG. *** The job used to name the variant by
    /// `variant.volume_fraction`, which core validates as a FRACTION — bounded to
    /// (0, 1]. A growth ladder's rungs are part-relative and exceed 1, so every
    /// re-lattice of a growth variant died at schema validation in ~48 ms with
    /// *"variant.volume_fraction must be in (0, 1]"*, on a number (1.1) that was
    /// the correct join key. The bound was right; carrying a ladder position in a
    /// field shaped like a fraction was not. nil ⇒ the container held no
    /// fingerprint for this rung, and the entry gate already refuses.
    public let designFingerprint: UInt64?
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
                requestedVolumeFraction: Double,
                achievedVolumeFraction: Double = 0,
                designFingerprint: UInt64? = nil,
                massGrams: Double,
                worstCaseMargin: Double, accepted: Bool,
                meshVertices: [Float], meshIndices: [Int32],
                field: LatticeDemandField,
                artifacts: RelatticeArtifacts?,
                unavailable: RelatticeUnavailable?) {
        self.runName = runName
        self.variantIndex = variantIndex
        self.requestedVolumeFraction = requestedVolumeFraction
        self.achievedVolumeFraction = achievedVolumeFraction
        self.designFingerprint = designFingerprint
        self.massGrams = massGrams
        self.worstCaseMargin = worstCaseMargin
        self.accepted = accepted
        self.meshVertices = meshVertices
        self.meshIndices = meshIndices
        self.field = field
        self.artifacts = artifacts
        self.unavailable = unavailable
    }

    /// THE ONE PLACE A CONTEXT IS BUILT FROM A FINISHED VARIANT (task
    /// 2026-08-04-variant-volume-fraction-mismatch, bar L2).
    ///
    /// The page used to assemble this inline in the view, which is why the number
    /// it attached to a job could be a rung while the number it showed the user
    /// was a fraction and nothing could see both at once. Every field that
    /// describes the DESIGN now comes from `variant` and from the retained
    /// container, in one pure function a test can drive end to end — because "the
    /// value type was right but the call site passed something else" is how this
    /// defect shipped in the first place.
    public static func from(variant v: OptimizeVariant,
                            runName: String,
                            variantIndex: Int,
                            field: LatticeDemandField,
                            artifacts: RelatticeArtifacts?,
                            unavailable: RelatticeUnavailable?)
        -> LatticeVariantContext {
        let index = artifacts.flatMap { DesignContainerIndex.parse($0.designBin) }
        return LatticeVariantContext(
            runName: runName, variantIndex: variantIndex,
            requestedVolumeFraction: v.requestedVolumeFraction,
            achievedVolumeFraction: v.achievedVolumeFraction,
            designFingerprint: index?.fingerprint(
                forRequestedVolumeFraction: v.requestedVolumeFraction),
            massGrams: v.massGrams, worstCaseMargin: v.worstCaseMargin,
            accepted: v.accepted,
            meshVertices: v.meshVertices, meshIndices: v.meshIndices,
            field: field, artifacts: artifacts, unavailable: unavailable)
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
        /// ★ ruling 4 (item 6): refused for want of an include wall — greyed, and its tap takes
        /// him to where walls are marked instead of doing nothing.
        public var marksWalls: Bool = false
    }

    /// Lattice the finished variant. nil when the page was not opened from one.
    public let relattice: Action?
    /// Run the ladder from the original part.
    public let optimize: Action

    /// `forecast` is the PRE-FLIGHT FORECAST of the `lattice_variant` job this
    /// page's primary button submits (task 2026-08-03-variant-postprocessing-fix,
    /// bar F3). It belongs on THIS action and no other: it was computed from this
    /// variant's stored design under these settings, which is exactly what
    /// "Lattice this variant" runs and exactly what "Optimize from scratch" does
    /// not. Absent ⇒ the button says what it always said.
    public static func compute(variant: LatticeVariantContext?,
                               optimizeSurface: LatticeOptimizeSurface,
                               running: Bool,
                               forecast: LatticeForecast? = nil,
                               // ★ ruling (c) (2026-09-30): why this variant's job may not be
                               // written (`ProjectModel.variantLatticeJobRefusal()`); nil ⇒ it may.
                               jobRefusal: String? = nil) -> LatticePageActions {
        guard let v = variant else {
            // No variant: the pre-existing single Optimize button, verbatim.
            return LatticePageActions(
                relattice: nil,
                optimize: Action(label: optimizeSurface.label,
                                 sub: optimizeSurface.sub,
                                 enabled: optimizeSurface.enabled, primary: true,
                                 marksWalls: optimizeSurface.marksWalls))
        }
        let pct = Int((v.requestedVolumeFraction * 100).rounded())
        let re: Action
        if running {
            // THE ACTION WAITS; THE PAGE DOES NOT (task
            // 2026-08-03-variant-postprocessing-concurrency, requirement 4).
            // Generating a lattice is the Mac's work and the worker runs one job at
            // a time, so this never dispatches a second CLI job at a busy worker.
            // Everything else on this page — topology, cell size, regions, boundary
            // — is configuration, costs nothing, and stays live. "a job is already
            // running" said the page was closed; this says what is actually true.
            re = Action(label: "Lattice this variant",
                        sub: VariantEntry.latticeQueuedReason, enabled: false,
                        primary: true)
        } else if let why = v.unavailable {
            re = Action(label: "Lattice this variant", sub: why.reason,
                        enabled: false, primary: true)
        } else if let why = jobRefusal {
            // ★ RULING (c): zero include walls ⇒ no job — core would lattice the WHOLE variant.
            // Disabled with the stage's words; after `unavailable` (setting walls cannot fix a
            // run that kept no design), before the forecast (none is asked for).
            re = Action(label: "Lattice this variant", sub: why,
                        enabled: false, primary: true,
                        marksWalls: LatticeJobIncludeGate.opensWallMarking(why))
        } else if let f = forecast, f.regionVoxels > 0, f.wouldLatticeVoxels == 0 {
            // NOTHING WOULD BE LATTICED (task
            // 2026-08-04-variant-volume-fraction-mismatch, bar B3 / L3). This is
            // NOT the partial-lattice case below, and it is not a matter of taste:
            // a run from here produces a file with zero struts in it, which the
            // app then reported as *"filled at 0% density … strut radius
            // 0.00–0.65 mm"* and called a build. Core now refuses it outright; the
            // button refuses it FIRST, so the refusal costs no Mac time.
            //
            // The remedy rides the button, because by this point core has
            // EVALUATED one (including the extrusion-width remedy this task
            // added, which is the one that unlocks the maintainer's parts).
            let remedy = f.adviceLines().first
            re = Action(
                label: "Lattice this variant",
                sub: remedy.map { "\(f.headline) \($0)" } ?? f.headline,
                enabled: false, primary: true)
        } else if let f = forecast, f.isRefused {
            // THE REFUSAL, BEFORE THE RUN IS SPENT (bars F4 / P3). A configuration
            // that turns most of its region solid is not a lattice, and the
            // maintainer learned that from a receipt after an hour of Mac time.
            // It is said HERE, on the button that would spend the next one, with
            // the measured remedy where core found one.
            //
            // It WARNS rather than disables, deliberately: a partial lattice can be
            // exactly what someone wants, and the brief asks for this to be SAID,
            // not forbidden. What must never happen again is that it is silent.
            let remedy = f.adviceLines().first
            re = Action(
                label: "Lattice this variant",
                sub: remedy.map { "\(f.headline) \($0)" } ?? f.headline,
                enabled: true, primary: true)
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
            enabled: optimizeSurface.enabled && !running, primary: false,
            marksWalls: optimizeSurface.marksWalls && !running)
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
/// says why instead of accepting taps that would land nowhere. Face walls marked on the
/// PART travel to the variant's job as the stage's full prisms, face_id included as
/// provenance (the face-prism route, 2026-09-29; ruling a, 2026-09-30: core's variant path
/// imports the ORIGINAL part, where the id is real).
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
            // ★ RULING (e) (maintainer, 2026-09-30): ONE sentence on the tap refusal, his words.
            // (Placing a region is still offered by the page's header chip.)
            note: Self.variantTapRefusal)
    }

    /// ★ Ruling (e), in the house style (ruling 5, 2026-09-30: a curly ’ and "optimized" — "His
    /// rule was mine to phrase; the house style wins").
    public static let variantTapRefusal =
        "You can’t pick faces on an optimized result — the walls you marked on the part carry over."
}

// MARK: - region emission against a variant
//
// ★ RETIRED (2026-09-29, the face-prism route): a variant's job no longer has an emission of
// its own. It carries the stage's walls as their explicit prisms (see
// `ProjectModel.variantLatticeJobRegions`), so the primitives-only emission is gone.

/// ★★ THE VARIANT'S FACE-WALL LINE (ruling V1, 2026-09-29; the face-prism route, same day;
/// wording accepted 2026-09-30, ruling f). A variant's job carries every face wall the stage's
/// job carries, each as its prism, so a wall is left out only where the stage leaves it out
/// too: a marked face with no shape to lattice (the emission's `skippedFaces`), or a face
/// region the run cannot consume — a cut sector — NAMED (`skippedRegionNames`, ruling g).
/// Check sizes, the forecast and the re-lattice each say so in THIS one line, never a silent
/// result, and say nothing when every wall is carried. The sentence is the stage banner's
/// (`LatticeWallsWithoutShape`), so the two cannot drift.
public enum LatticeVariantFaceWalls {
    /// The line when any marked face or face region was left out; nil otherwise.
    public static func line(withoutShape n: Int, regions: [String] = []) -> String? {
        LatticeWallsWithoutShape.text(faces: n, regions: regions, ending: .leftOut)
    }
    /// A re-lattice result stored by the V1 build — its job carried placed shapes only, and its
    /// count was every face wall — keeps a line that is still TRUE of that result, instead of
    /// losing its notice when the key changed.
    public static func legacyLine(leftOut n: Int) -> String? {
        guard n > 0 else { return nil }
        return "Made before face walls reached variants: "
            + (n == 1 ? "1 face wall was" : "\(n) face walls were") + " left out."
    }
}

// MARK: - nothing set to lattice (ruling c)

/// ★★ RULING (c) (maintainer, 2026-09-30): a variant job with zero include walls refuses, in the
/// stage's words — never lattice the whole variant silently. Core lattices the WHOLE printed set
/// when a job declares no include region (run_job.cpp's candidate set; J6 of the face-prism
/// proof), and `RelatticeJobBuilder` writes an exclude-only or empty `lattice.regions` without
/// complaint, so the refusal is the app's, read from the EMITTED regions: a legacy include
/// primitive is an include wall; a marked face with no shape, a cut sector, a Solid/Off wall
/// is not.
///
/// ★★ RULING 4 (maintainer, 2026-09-30): ONE definition of "has an include wall", shared by the
/// stage, a variant and Optimize — `hasIncludeWall` is the only place the question is asked of a
/// region list (pinned by `LatticeIncludeGateTests`):
/// - the stage: an exclude-only project greys "Lattice" with the reason it already shows;
/// - Optimize: with lattice on and no include wall it is refused on the button, before the run
///   starts, in the same words — never lattice every variant whole;
/// - wherever "nothing set to lattice" shows, one tap takes him to where walls are marked
///   (`opensWallMarking`) — navigation only, never a wall made for him.
public enum LatticeJobIncludeGate {
    /// The stage's own words (`WorkspacePlaceholder.latticeThisSummary`) — one home.
    public static let latticeModeOff = "lattice mode is off"
    public static let nothingSetToLattice = "nothing set to lattice"
    /// ★ THE definition: an emitted region list lattices something only through an include wall.
    /// Core lattices the WHOLE printed set when a job declares none.
    public static func hasIncludeWall(_ regions: [LatticeRegionSpec]) -> Bool {
        regions.contains { $0.role == .include }
    }
    /// Why the job may not be written; nil when it may. Lattice off first, as the stage says it.
    public static func refusal(latticeEnabled: Bool, hasIncludeWall: Bool) -> String? {
        guard latticeEnabled else { return latticeModeOff }
        return hasIncludeWall ? nil : nothingSetToLattice
    }
    public static func refusal(latticeEnabled: Bool, regions: [LatticeRegionSpec]) -> String? {
        refusal(latticeEnabled: latticeEnabled, hasIncludeWall: hasIncludeWall(regions))
    }
    /// ★ ruling 4 (item 5): why Optimize may not start. Lattice OFF is no refusal — the run is
    /// topology only; lattice ON with no include wall is, in the same words.
    public static func optimizeRefusal(latticeEnabled: Bool, regions: [LatticeRegionSpec]) -> String? {
        latticeEnabled && !hasIncludeWall(regions) ? nothingSetToLattice : nil
    }
    /// ★ ruling 4 (item 6): the refusal a wall fixes — wherever it shows, one tap takes him to
    /// where walls are marked. Every other refusal is said without a tap.
    public static func opensWallMarking(_ refusal: String?) -> Bool {
        refusal == nothingSetToLattice
    }
}

// MARK: - a retained run core refuses (ruling 3)

/// ★★ RULING 3 (maintainer, 2026-09-30): an old retained run froze a wall at another depth than
/// the wall has today — core's depth tie refuses the variant's job before any solve. The app asks
/// core's OWN parser (never re-deriving the tie) and says it in his words. This only turns core's
/// message into that sentence: it reads core's numbers, never computes a verdict.
public enum LatticeVariantProtectionTie {
    public struct Mismatch: Equatable, Sendable {
        /// The RUN face id core names.
        public let faceID: Int
        /// Core's two numbers, in mm.
        public let protectionMM: Double
        public let wallMM: Double
    }
    /// Core's refusal text (job.cpp's depth tie: "face N is BOTH protected and a lattice region, at
    /// two different depths: the protection is X mm and the lattice region is Y mm. …") → its
    /// numbers; nil for any other message.
    public static func parse(coreError: String) -> Mismatch? {
        let pattern = #"face (\d+) is BOTH protected and a lattice region, at two different depths: the protection is ([0-9.]+) mm and the lattice region is ([0-9.]+) mm"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: coreError, range: NSRange(coreError.startIndex..., in: coreError)),
              let f = Range(m.range(at: 1), in: coreError), let x = Range(m.range(at: 2), in: coreError),
              let y = Range(m.range(at: 3), in: coreError),
              let face = Int(coreError[f]), let prot = Double(coreError[x]), let wall = Double(coreError[y])
        else { return nil }
        return Mismatch(faceID: face, protectionMM: prot, wallMM: wall)
    }
    /// A depth as a person writes it: 5, 12.5 — core's value rounded to 0.01 mm.
    public static func mm(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        return r == r.rounded() ? String(format: "%.0f", r) : String(format: "%g", r)
    }
    /// His sentence. `setToMM` is the depth to set the wall to — core's protection, less the wall's
    /// own in-plane expand when it has one (its slab reaches depth + expand).
    public static func sentence(_ m: Mismatch, wallName: String, setToMM: Double) -> String {
        "This result was optimized with a \(mm(m.protectionMM)) mm protected skin under \(wallName), "
            + "but the wall is \(mm(m.wallMM)) mm deep. Optimize again with this wall, "
            + "or set the wall to \(mm(setToMM)) mm."
    }
    /// Any OTHER refusal of a variant document is said in core's own words, less its file prefix.
    public static func coreWords(_ coreError: String) -> String {
        coreError.hasPrefix("job.json: ") ? String(coreError.dropFirst("job.json: ".count)) : coreError
    }
}

