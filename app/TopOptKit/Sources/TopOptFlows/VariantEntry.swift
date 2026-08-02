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
    /// A job is already running.
    public let runInFlight: Bool
    /// The app RE-ATTACHED to this run rather than submitting it, so it no longer
    /// holds the document it sent and can never retain one for these results.
    public let reattached: Bool

    public init(hasGeometry: Bool, machine: SolvingMachine, retainedJob: Data?,
                retainedDesign: Data?, runGeneratedLattice: Bool,
                modelPath: String?, workerSelected: Bool, runInFlight: Bool,
                reattached: Bool = false) {
        self.hasGeometry = hasGeometry
        self.machine = machine
        self.retainedJob = retainedJob
        self.retainedDesign = retainedDesign
        self.runGeneratedLattice = runGeneratedLattice
        self.modelPath = modelPath
        self.workerSelected = workerSelected
        self.runInFlight = runInFlight
        self.reattached = reattached
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

    /// A job is already running — checked first for both entries, because it makes
    /// every other reason moot and is the least interesting thing to read.
    static let runningReason = "a job is already running"

    // MARK: smoothing

    /// Why smoothing is blocked, or nil. The reasons are `SmoothUnavailable`'s own
    /// — the page and the button say the same sentence because they read the same
    /// enum, not because two strings were kept in step by hand.
    public static func smoothingBlocks(_ f: VariantEntryFacts) -> [String] {
        var out: [String] = []
        if f.runInFlight { out.append(runningReason) }
        if let why = SmoothPageEntry.availability(
            hasGeometry: f.hasGeometry, latticed: f.runGeneratedLattice,
            retainedJob: f.artifacts?.jobJSON, modelPath: f.modelPath,
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
            else { out.append(.runPredatesDesignStore) }
        } else if f.jobFacts.declaresDesignBox {
            // Only meaningful once there IS a retained job to read it from.
            out.append(.designBoxRun)
        }
        if f.modelPath?.isEmpty ?? true { out.append(.modelFileMissing) }
        if !f.workerSelected { out.append(.noWorkerSelected) }
        var reasons = out.map { $0.reason }
        if f.runInFlight { reasons.insert(runningReason, at: 0) }
        return reasons
    }

    public static func lattice(_ f: VariantEntryFacts) -> VariantEntryVerdict {
        verdict(label: "Lattice", blocks: latticeBlocks(f))
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

/// WHY THE DESIGN-BOX BLOCK EXISTS, AND WHEN IT MUST GO.
///
/// The app refuses a lattice-under-design-box configuration because the CORE
/// refuses it: `run_job.cpp` throws on both the optimize+lattice pre-flight and in
/// `lattice_variant_job`, because the certification load case cannot be
/// reconstructed on a domain-expanded grid. This is a MIRROR of a core rule, not
/// an app policy — so it is stated in one place, with the core's own words, and a
/// test reads `core/src/cli/run_job.cpp` and fails the moment core stops refusing.
/// When the concurrent design-box-recertification task lands the capability, that
/// test goes red and this constant is what changes.
public enum LatticeCoreCapability {
    /// The core still refuses lattice work on a design-box run.
    public static let designBoxRefused = true

    /// The distinctive phrase the core refusal carries, as the source-reading test
    /// looks for it.
    public static let designBoxRefusalPhrase =
        "lattice certification does not support a design box"

    /// The sentence the app shows when the CURRENT setup is a lattice run with a
    /// design box — the configuration the maintainer built on the lattice page and
    /// only discovered was impossible when Optimize came back refused.
    public static let liveConflictReason =
        "a lattice run can’t use a design box — the certification load case can’t "
        + "be rebuilt on the expanded grid, so the job is refused. Turn off the "
        + "design box, or turn off lattice mode"

    /// Whether the CURRENT project setup would be refused. Live state on purpose:
    /// this gates a job built from live state, unlike the variant entries above,
    /// which gate work on a run that already happened.
    public static func liveConflict(latticeEnabled: Bool,
                                    designBoxActive: Bool) -> String? {
        guard designBoxRefused, latticeEnabled, designBoxActive else { return nil }
        return liveConflictReason
    }
}
