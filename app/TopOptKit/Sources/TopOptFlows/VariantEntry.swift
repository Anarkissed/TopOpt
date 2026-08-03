// VariantEntry.swift — GATE AT THE ENTRY POINT, NOT AFTER (task
// 2026-08-03-variant-entry-gating-and-retention, bar AJ2).
//
// THE DEFECT THIS FILE EXISTS FOR. Tapping "Smooth" on a finished variant opened
// the smoothing page. The page laid out what smoothing buys you, said it was
// working out which surfaces are protected, listed the user's selections — and
// THEN threw a modal saying this variant can't be smoothed at all. Every fact
// behind that refusal was known before the page opened. The lattice page's own
// bottom bar already had the right shape: a DISABLED button carrying the reason.
//
// So both entries are decided HERE, from facts that are checkable without
// entering either page, and each blocking precondition carries its own sentence.
// A generic "not available" is not an outcome this type can produce.
//
// WHERE THE FACTS COME FROM (bar AJ4). Everything that decides a verdict is read
// from THE RUN'S OWN RECORD — its outcome and the job document PR 274 retained
// beside it — never from the project's current, editable setup. `Facts` has no
// initialiser that takes a ProjectModel, a ForceModel, a SelectionModel or a
// DesignBoxModel, so live state has nowhere to enter. That matters most for the
// design box: the question "was this run solved on an expanded domain?" is a
// question about the run, and answering it from the workspace's current box would
// both disable a perfectly latticeable variant (box added since) and invite a
// refused job (box removed since — the maintainer's exact sequence).
//
// Pure value types and pure rules, so the whole surface is headlessly testable.

import Foundation
import TopOptKit

// MARK: - what the retained job says about itself

/// The facts a gate needs out of the retained job document, parsed once.
///
/// Deliberately tiny and deliberately TOLERANT: an unreadable or unknown-shaped
/// document is not a parse failure, it is simply a document that does not declare
/// a design box. The strict parse that a re-certification depends on lives in
/// `SmoothRecertLoadCase`; this one only answers the entry questions.
public struct RetainedJobFacts: Equatable, Sendable {
    /// `design_box` is present in the document — core's `has_design_box`, read
    /// from the same key `job.cpp` parses.
    public let declaresDesignBox: Bool

    public init(declaresDesignBox: Bool) {
        self.declaresDesignBox = declaresDesignBox
    }

    public static func parse(_ data: Data?) -> RetainedJobFacts {
        guard let data,
              let job = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return RetainedJobFacts(declaresDesignBox: false) }
        return RetainedJobFacts(declaresDesignBox: job["design_box"] is [String: Any])
    }
}

// MARK: - the facts an entry gate decides on

/// Everything the two entry gates need, and NOTHING that could come from the
/// project's current setup (bar AJ4).
public struct VariantEntryFacts: Equatable {
    /// The variant has exported geometry (a cancelled/severed rung has none).
    public let hasGeometry: Bool
    /// Which machine solved the run — the fact that separates "solved here, so
    /// there is no job document" from "solved on a worker, but before retention".
    public let machine: SolvingMachine
    /// The job document the run was submitted with, retained beside the results.
    public let retainedJob: Data?
    /// That run's `design.bin`.
    public let retainedDesign: Data?
    /// The RUN's own record of whether it generated a lattice.
    public let runGeneratedLattice: Bool
    /// The part file the retained load case's face ids are defined on.
    public let modelPath: String?
    /// A Mac worker is selected in Compute.
    public let workerSelected: Bool
    /// The rung this variant targeted — the key the re-lattice job selects the
    /// stored design by, so it is also the key that decides whether the retained
    /// container actually covers this variant (task
    /// 2026-08-03-variant-postprocessing-fix).
    public let requestedVolumeFraction: Double
    /// A job is already running.
    public let runInFlight: Bool
    /// The app RE-ATTACHED to this run rather than submitting it, so it no longer
    /// holds the document it sent and can never retain one for these results.
    public let reattached: Bool

    public init(hasGeometry: Bool, machine: SolvingMachine, retainedJob: Data?,
                retainedDesign: Data?, runGeneratedLattice: Bool,
                modelPath: String?, workerSelected: Bool, runInFlight: Bool,
                reattached: Bool = false,
                requestedVolumeFraction: Double = 0) {
        self.hasGeometry = hasGeometry
        self.machine = machine
        self.retainedJob = retainedJob
        self.retainedDesign = retainedDesign
        self.runGeneratedLattice = runGeneratedLattice
        self.modelPath = modelPath
        self.workerSelected = workerSelected
        self.runInFlight = runInFlight
        self.reattached = reattached
        self.requestedVolumeFraction = requestedVolumeFraction
    }

    /// The retained artifacts, when BOTH survive — the same all-or-nothing rule
    /// `ProjectStore.loadRelatticeArtifacts` applies, restated here so a gate can
    /// never be built on half of them.
    public var artifacts: RelatticeArtifacts? {
        guard let j = retainedJob, let d = retainedDesign, !j.isEmpty, !d.isEmpty
        else { return nil }
        return RelatticeArtifacts(jobJSON: j, designBin: d)
    }

    public var jobFacts: RetainedJobFacts { .parse(retainedJob) }

    /// The retained job document, treating EMPTY as absent — the same rule
    /// `artifacts` applies to both halves. A zero-byte document is not a load case.
    public var retainedJobIfPresent: Data? {
        guard let j = retainedJob, !j.isEmpty else { return nil }
        return j
    }

    /// Whether the retained container holds a design for THIS rung. nil ⇒ there is
    /// no readable container to ask (the caller has already decided that case).
    public var designCoversThisVariant: Bool? {
        guard let d = retainedDesign, !d.isEmpty,
              let index = DesignContainerIndex.parse(d) else { return nil }
        return index.holds(requestedVolumeFraction: requestedVolumeFraction)
    }
}

// MARK: - the verdict

/// Whether an entry control may be tapped, and — when it may not — WHY, in the
/// words the refusal itself uses.
///
/// There is no "disabled with no reason" state: `blocked` is either nil (enabled)
/// or a sentence. That is the whole point of the type.
public struct VariantEntryVerdict: Equatable, Sendable {
    /// The action's own label ("Smooth", "Lattice").
    public let label: String
    public let enabled: Bool
    /// The one-line reason, shown under the disabled control. nil ⇒ enabled.
    public let reason: String?
    /// Every blocking condition, not just the first — so a run that is blocked
    /// three ways can be reported honestly in a receipt or a test.
    public let allReasons: [String]

    public init(label: String, enabled: Bool, reason: String?, allReasons: [String]) {
        self.label = label
        self.enabled = enabled
        self.reason = reason
        self.allReasons = allReasons
    }

    /// The accessibility sentence: "Smooth, unavailable: <reason>".
    public var accessibilityLabel: String {
        guard let r = reason else { return label }
        return "\(label), unavailable: \(r)"
    }
}

// MARK: - the gates

/// The ONE place that decides whether a finished variant may be taken into the
/// smoothing page or the lattice page.
public enum VariantEntry {

    /// A job is already running.
    ///
    /// NO LONGER A BLOCK ON EITHER ENTRY (task
    /// 2026-08-03-variant-postprocessing-concurrency). It used to be the FIRST
    /// reason on both, which meant a four-hour ladder made every variant it had
    /// already produced untouchable for the rest of the run — the user watched a
    /// progress bar and could do nothing with work that was already finished.
    ///
    /// Two facts made that wrong. SMOOTHING is an on-device computation: the bridge
    /// calls `topopt::analyze_fixed_design` in-process (bridge.cpp:975 / :1297,
    /// driven by `SmoothingModel.live`), so on the maintainer's setup — iPad app,
    /// Mac worker — it runs on a different computer entirely and cannot contend
    /// with the ladder at all. And lattice SETUP — topology, cell size, regions,
    /// boundary — is pure configuration: zero compute, nothing to contend with.
    ///
    /// What DOES belong to the Mac is dispatching a lattice generation, and that is
    /// gated separately (`latticeActionWaits`) — it queues, and says so, rather
    /// than racing a second CLI job onto a busy worker.
    static let runningReason = "a job is already running"

    /// The sentence the LATTICE ACTION shows while the worker is busy. The page is
    /// fully usable; only the button that dispatches work waits.
    ///
    /// WORDED FOR WHAT ACTUALLY HAPPENS. The worker HAS a real queue
    /// (`max_concurrency 1`), but the app holds ONE run slot — `RunModel.start`
    /// returns immediately while a run is in flight — so nothing is queued ON the
    /// worker; the generation simply starts when the ladder ends. Saying "this
    /// will queue behind it" would describe a worker-side queue the app does not
    /// create. Making it a genuine one needs a second run slot in the app, which is
    /// stated in the handoff rather than implied here.
    public static let latticeQueuedReason =
        "the Mac is still solving this run — set the lattice up now; generating it "
        + "starts when the run finishes"

    // MARK: smoothing

    /// Why smoothing is blocked, or nil. The reasons are `SmoothUnavailable`'s own
    /// — the page and the button say the same sentence because they read the same
    /// enum, not because two strings were kept in step by hand.
    public static func smoothingBlocks(_ f: VariantEntryFacts) -> [String] {
        var out: [String] = []
        // `f.runInFlight` is deliberately NOT a block here — see `runningReason`.
        // Smoothing runs on THIS device, in-process; the ladder runs on the Mac.
        // THE JOB DOCUMENT ALONE (task 2026-08-03-variant-postprocessing-fix).
        // Smoothing re-certifies under the run's LOAD CASE; it never opens
        // design.bin. Reading the both-halves `artifacts` here meant a run whose
        // design container did not arrive — a run killed mid-ladder, a worker that
        // served no design — reported "there's no load case to re-certify a smoothed
        // shape under" while holding the load case. Two different artifacts, two
        // different verdicts.
        if let why = SmoothPageEntry.availability(
            hasGeometry: f.hasGeometry, latticed: f.runGeneratedLattice,
            retainedJob: f.retainedJobIfPresent, modelPath: f.modelPath,
            solvedOnDevice: f.machine.isThisDevice) {
            out.append(why.reason)
        }
        return out
    }

    public static func smoothing(_ f: VariantEntryFacts) -> VariantEntryVerdict {
        verdict(label: "Smooth", blocks: smoothingBlocks(f))
    }

    // MARK: lattice

    /// Why latticing THIS variant is blocked, or nil. Order is deliberate: the
    /// conditions that cannot be fixed at all come before the ones the user can
    /// act on, so the first (displayed) reason is the truest one.
    public static func latticeBlocks(_ f: VariantEntryFacts) -> [String] {
        var out: [RelatticeUnavailable] = []
        if !f.hasGeometry { out.append(.noGeometry) }
        if f.artifacts == nil {
            if f.machine.isThisDevice { out.append(.computedOnDevice) }
            else if f.reattached { out.append(.jobDocumentNotRecorded) }
            // THE JOB IS HERE, THE DESIGN IS NOT (task
            // 2026-08-03-variant-postprocessing-fix). Since the job document is
            // retained at submit, this is now a state a CURRENT run can be in, and
            // it has always had its own sentence — `designNotTransferred` simply had
            // no producer, so such a run borrowed "finished before results kept
            // their design file", which says the build is old when the build is
            // fine and the transfer is what did not happen.
            else if f.retainedJobIfPresent != nil { out.append(.designNotTransferred) }
            else { out.append(.runPredatesDesignStore) }
        } else if f.designCoversThisVariant == false {
            // THE CONTAINER IS HERE BUT THIS RUNG IS NOT IN IT (task
            // 2026-08-03-variant-postprocessing-fix). The design is fetched after
            // every streamed variant, so it normally covers exactly what is on
            // screen; a fetch that failed at a later rung leaves a container that
            // does not, and core would refuse this variant by name. Say it first.
            out.append(.variantNotInDesign)
        } else if LatticeCoreCapability.designBoxRefused,
                  f.jobFacts.declaresDesignBox {
            // Only meaningful once there IS a retained job to read it from — and
            // only while CORE actually refuses it. Before the device-failure task
            // this branch did not consult the capability at all, so the constant
            // `LatticeCoreCapability.designBoxRefused` documented a remedy ("drop
            // it when core stops refusing") that would have changed nothing a user
            // can see. The mirror now genuinely mirrors.
            out.append(.designBoxRun)
        }
        if f.modelPath?.isEmpty ?? true { out.append(.modelFileMissing) }
        if !f.workerSelected { out.append(.noWorkerSelected) }
        // `f.runInFlight` no longer inserts a block: the lattice page is SETUP, and
        // setup is free. The dispatching action reads `latticeActionWaits` instead.
        return out.map { $0.reason }
    }

    public static func lattice(_ f: VariantEntryFacts) -> VariantEntryVerdict {
        verdict(label: "Lattice", blocks: latticeBlocks(f))
    }

    /// WHY THE LATTICE **ACTION** WAITS, or nil (task
    /// 2026-08-03-variant-postprocessing-concurrency, requirement 4).
    ///
    /// Generating a lattice is the Mac's work, and the worker runs one job at a
    /// time. So while the ladder is going the action does not RACE it — the app
    /// never dispatches a second CLI job at a busy worker — and it does not
    /// silently refuse either. It queues, and the button says which it is doing.
    ///
    /// Separate from `latticeBlocks` on purpose: a BLOCK is a fact about the
    /// variant that will not change by waiting, and this one changes the moment
    /// the ladder ends.
    public static func latticeActionWaits(_ f: VariantEntryFacts) -> String? {
        f.runInFlight ? latticeQueuedReason : nil
    }

    private static func verdict(label: String, blocks: [String]) -> VariantEntryVerdict {
        VariantEntryVerdict(label: label, enabled: blocks.isEmpty,
                            reason: blocks.first, allReasons: blocks)
    }
}

// MARK: - the one remaining way a finished run is retired (bar 4)

/// WHEN RESULTS ARE INVALIDATED, THE USER IS TOLD AND CONFIRMS.
///
/// After this task, nothing else retires a finished run: editing the setup never
/// touches it, and a run that produces nothing puts it back (`RunModel`'s
/// preserved outcome). The single remaining path is a NEW run that succeeds —
/// which is the user's own Optimize, but which still costs them hours of finished
/// work in one tap. So it is stated, with the count and the mass, and confirmed.
///
/// Pure, so the copy and the trigger are tested without a view.
public struct ResultsReplacementPrompt: Equatable, Sendable, Identifiable {
    public var id: String { message }
    /// "Optimizing again replaces the 3 variants this project already has…"
    public let message: String
    public let variantCount: Int

    /// nil ⇒ nothing to lose, so no prompt: the run starts as it always did.
    public static func forNewRun(existing: OptimizeOutcome?) -> ResultsReplacementPrompt? {
        let accepted = existing?.variants.filter { $0.accepted } ?? []
        guard !accepted.isEmpty else { return nil }
        let n = accepted.count
        let masses = accepted.compactMap { $0.massGrams > 0 ? $0.massGrams : nil }
        let lightest = masses.min()
        let mass = lightest.map { String(format: " (lightest %.1f g)", $0) } ?? ""
        return ResultsReplacementPrompt(
            message: "Optimizing again replaces the \(n) variant\(n == 1 ? "" : "s") "
                   + "this project already has\(mass). They can’t be brought back.",
            variantCount: n)
    }
}

// MARK: - the core capability this gate mirrors

/// WHAT CORE ACTUALLY REFUSES TODAY, AND THE ONE PLACE THE APP SAYS IT.
///
/// THE FAILURE THIS TYPE NOW CARRIES THE SCAR OF (task
/// 2026-08-03-retention-designbox-device-failure). PR 284 wrote this mirror while
/// core still threw "lattice certification does not support a design box" from
/// both the optimize+lattice pre-flight and `lattice_variant_job`, and armed a
/// source-reading test to go red the day core dropped it. PR 285 dropped it the
/// same evening. The test DID go red — and nobody saw, because CI is `core-linux`
/// only and has never built the app package. So the app spent both PRs telling the
/// maintainer "the core refuses to lattice it" about a core, in that same binary,
/// that certifies it happily.
///
/// Core's remaining rule is much narrower, and it is about GRADING, not the design
/// box: a graded plan picks its cell set before the added-material policy runs, so
/// a graded design-box run could emit struts into cells the certificate calls
/// solid (`run_job.cpp`, both the run_job pre-flight and `lattice_variant_job`).
/// UNIFORM lattice under a design box is supported and tested — that is exactly
/// what PR 285 built.
public enum LatticeCoreCapability {
    /// Does core still refuse ALL lattice work on a design-box run? It does not —
    /// PR 285 removed the blanket refusal (`resolve_design_domain` now does the
    /// remap the refusal was standing in for). Kept as the switch the variant
    /// entry gate consults, so a future core that re-refuses is one edit away.
    public static let designBoxRefused = false

    /// The blanket refusal's distinctive phrase. Core must NO LONGER carry it; the
    /// source-reading test asserts that, so a revert in core turns the app red
    /// instead of silently making this constant a lie again.
    public static let designBoxRefusalPhrase =
        "lattice certification does not support a design box"

    /// The refusal core DOES still carry, as the source-reading test looks for it.
    /// A RAW string: the test greps `run_job.cpp`'s SOURCE TEXT, where the quotes
    /// around the two JSON keys are C++ escapes and appear as backslash-quote.
    public static let gradedDesignBoxRefusalPhrase =
        #"a \"grading\" block is not yet supported together with a \"design_box\""#

    /// The sentence the app shows when the CURRENT setup is a GRADED lattice run
    /// with a design box — the one configuration core still refuses.
    public static let liveConflictReason =
        "a graded lattice can’t use a design box — the grading law picks its cells "
        + "before the added-material policy runs, so the job is refused. Switch "
        + "density to uniform, or turn off the design box"

    /// Whether the CURRENT project setup would be refused. Live state on purpose:
    /// this gates a job built from live state, unlike the variant entries above,
    /// which gate work on a run that already happened.
    ///
    /// `graded` is REQUIRED rather than defaulted: it is the fact that decides the
    /// verdict, and a default would let a caller inherit the wrong answer in
    /// silence — which is the shape of the failure this whole type is a scar of.
    public static func liveConflict(latticeEnabled: Bool,
                                    designBoxActive: Bool,
                                    graded: Bool) -> String? {
        guard latticeEnabled, designBoxActive, graded else { return nil }
        return liveConflictReason
    }

    // MARK: "Rim only" on a voxel-derived part (task
    //       2026-08-03-variant-postprocessing-fix, defect 4)

    /// CAN "RIM ONLY" EVER PRODUCE GEOMETRY ON AN OPTIMIZED PART? No — and the
    /// reason is structural, not statistical.
    ///
    /// Core emits rim geometry from exactly two places, and both need an ANALYTIC
    /// PLANE face on the `LatticeBoundary`: `emit_rim_line` dresses a plane–plane
    /// edge, and `emit_rim_torus` dresses a plane–collar-bore pair
    /// (`lattice_gen.cpp`'s skin pass walks `faces()` and matches those two shapes).
    ///
    /// A Plane face enters a boundary through `LatticeBoundary::add_half_space` (or
    /// `add_box`, which is six of them). In the whole of `core/src`, NOTHING calls
    /// either — the only callers are two test harnesses. The production builder,
    /// `run_job.cpp`'s `lattice_boundary_for`, adds a VOXEL BASE (no face), keep-outs
    /// (a Bore face for a bolt, nothing for a slab) and include/exclude regions
    /// (no faces at all).
    ///
    /// So on every run the app can produce, `faces()` holds bores or nothing, no
    /// plane–plane or plane–bore pair exists, and rim output is identically zero.
    /// The maintainer's three receipts say `rim_elements: 0` because zero is the
    /// only value that line can take — and "Rim only" was the app's DEFAULT.
    ///
    /// PR 250 built the rim to dress ANALYTIC plane/bore pairs, which is what it
    /// does; PR 253 added the freeform diagrid precisely because a voxel-derived
    /// surface owns no analytic face. The defect is that the app kept offering — and
    /// defaulting to — the one of the three choices that cannot apply.
    public static let rimEmitsNothingOnVoxelParts = true

    /// The sentence the app shows when "Rim only" is chosen. It states the fact and
    /// the remedy, and it is shown BEFORE the run, not in a receipt afterwards.
    public static let rimOnlyProducesNothingReason =
        "“Rim only” dresses the edges where flat faces meet, and an optimized part "
        + "has none — its surface comes from the voxel grid. On this part it emits "
        + "nothing at all: choose Full skin for a woven surface, or None to say so "
        + "deliberately"

    /// nil ⇒ the boundary choice can produce geometry on this part. Non-nil ⇒ it
    /// provably cannot, with the reason.
    ///
    /// `voxelDerived` is the honest input: a lattice run over an OPTIMIZED design
    /// (every run the app makes) is voxel-derived. It is a parameter rather than an
    /// assumption so that the day core dresses analytic faces on this path, one
    /// caller changes rather than this rule being quietly wrong.
    public static func boundaryProducesNothing(skinJobValue: String,
                                               voxelDerived: Bool) -> String? {
        guard rimEmitsNothingOnVoxelParts, voxelDerived, skinJobValue == "rim"
        else { return nil }
        return rimOnlyProducesNothingReason
    }
}
