// LatticeSettings.swift — the persisted lattice-mode settings for a project, and
// the runtime-bounded control envelope (handoff 2026-07-29-lattice-mode-ui).
//
// THE ONE RULE THIS FILE ENFORCES: the lattice controls are bounded by what CORE
// says is certifiable, read at runtime. `LatticeSettings` stores only the user's
// RAW choices — the mode toggle, the topology, the cell size, the density range, the
// region. It authors NO certifiable-band or cell-size LIMIT. Every bound is applied
// by `LatticeBounds.compute`, which takes the core-read `TopOptKit.LatticeLimits`
// (the density band + the cells-per-member ceiling) plus local geometry and the
// user's own print settings, and returns the effective values TOGETHER WITH a plain
// reason for each clamp. So the moment core widens its band, the controls widen; and
// a greyed / pinned control always says why (the two ★ bars).

import Foundation
import simd
import TopOptKit

/// The boundary treatment — a THREE-WAY choice mapping 1:1 onto the core job
/// schema's `lattice.skin` field, so "skin without rim" is UNREPRESENTABLE (bar
/// B7): core's diagrid skin is BUILT ON the rim (anchored landings + rim loops +
/// collar tori, handoff 2026-07-29-lattice-boundary-finish), and this enum has no
/// case that could ask for faces without the border.
public enum LatticeBoundaryTreatment: String, Codable, CaseIterable, Equatable, Sendable {
    /// Lattice to the edge — no rim, no skin (`skin: "none"`).
    case none
    /// Closed border only — rim loops + collar tori on protected bores (`skin: "rim"`).
    case rim
    /// Rim + woven face skin — the anchored diagrid (`skin: "diagrid"`).
    case fullSkin

    /// The exact core job-schema value (`job.lattice.skin`).
    public var jobSkinValue: String {
        switch self {
        case .none: return "none"
        case .rim: return "rim"
        case .fullSkin: return "diagrid"
        }
    }
}

/// The LATTICE ROLE a selection group can carry (round-2 item L22): "lattice
/// here" (include) or "no lattice here" (exclude). This is an ATTRIBUTE on a
/// TO-page group (the KeepClearAffix precedent) — the group itself stays in the
/// ONE `SelectionModel`; the role never copies or moves it. Maps 1:1 onto the
/// core job schema's `lattice.regions[].role` (job.cpp — PR 256).
public enum LatticeGroupRole: String, Codable, Equatable, Sendable {
    case include   // "lattice here" — material stays, LATTICED
    case exclude   // "no lattice here" — material stays, SOLID
}

/// One `lattice.regions` entry, exactly the wire shape core's job.cpp accepts
/// (role ∈ include|exclude, kind ∈ bolt|face, geometry with every extent > 0).
/// Values are model-space mm, the same frame as a manual clearance.
public struct LatticeRegionSpec: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case bolt, face }
    public let role: LatticeGroupRole
    public let kind: Kind
    // bolt: cylinder about axis_point + t·axis_dir, t ∈ [−half_length, +half_length]
    public var axisPoint: SIMD3<Double> = .zero
    public var axisDir: SIMD3<Double> = .zero
    public var radiusMM: Double = 0
    public var halfLengthMM: Double = 0
    // face: slab origin + s·normal, s ∈ [0, depth], clipped to 2·half_u × 2·half_w
    public var origin: SIMD3<Double> = .zero
    public var normal: SIMD3<Double> = .zero
    public var halfUMM: Double = 0
    public var halfWMM: Double = 0
    public var depthMM: Double = 0
    /// ★ The B-rep face this region was spawned from (task 2026-08-12 §0a), or
    /// nil for a hand-placed primitive. Emitted as the job's `face_id` so CORE
    /// can check the depth tie: a face that is both protected and latticed must
    /// carry ONE depth, and core refuses the job when it carries two.
    public var faceID: Int? = nil

    public init(role: LatticeGroupRole, kind: Kind) {
        self.role = role
        self.kind = kind
    }

    /// Core rejects zero-extent regions ("a zero-extent region marks nothing") and
    /// zero directions — mirror that check so the app never emits a refusable entry.
    public var isValid: Bool {
        switch kind {
        case .bolt:
            return radiusMM > 0 && halfLengthMM > 0 && simd_length(axisDir) > 1e-9
        case .face:
            return halfUMM > 0 && halfWMM > 0 && depthMM > 0 && simd_length(normal) > 1e-9
        }
    }
}

/// How the lattice density is chosen. `uniform` is the shipped run path (fills at
/// the range's clamped dense end). `auto` grades the PREVIEW from a real von Mises
/// field (a solid-part sim or a finished variant's own field) — it is OFFERED only
/// when such a field exists — and, since task lattice-page-core-hookup stage 4,
/// it RIDES the optimize job: the run carries a `grading` block and core grades
/// each accepted variant from that variant's OWN final stress field (the receipt
/// records the provenance). Bar B6 stands: auto still never silently means
/// uniform — a graded job carries NO uniform cell/radius at all.
public enum LatticeDensityMode: String, Codable, Equatable, Sendable {
    case uniform
    case auto
}

/// How the CELL SIZE is chosen (handoff 2026-08-01-lattice-cell-size-sweep, bar R6).
/// `fixed` is the shipped legacy path: one user-typed cell, byte-identical job. `auto`
/// hands the choice to core — it uses its OWN printability floor for the topology at
/// the user's extrusion width, so the app states that number rather than inventing one.
/// `swept` gives core a min…max window to grade the cell across (coarse where the
/// stress is low, fine where it is high), both ends still bounded by core's floor.
/// `fit` (task 2026-08-07-cell-mode-fit-and-swept-floor) derives the cell PER
/// DECLARED REGION from that region's own thickness — core has carried it since
/// PR 302 and the device had no way to select it.
public enum LatticeCellSizeMode: String, Codable, Equatable, Sendable {
    case auto
    case fixed
    case swept
    case fit
}

/// The lattice block the run carries — the exact fields the core job schema's
/// `lattice` object accepts (topology / cell_mm / strut_radius_mm / emit_stl /
/// emit_3mf / skin / min_extrudable_width_mm), plus the density facts the run
/// report echoes. Present on a RunRequest
/// ONLY when lattice mode is on AND the settings are runnable-as-certified; absent ⇒
/// the job is byte-identical to a non-lattice run (BAR U1). The worker generates a
/// UNIFORM lattice at `strutRadiusMM` (the shipped generator has no grading law yet).
public struct LatticeSpec: Equatable, Sendable {
    /// A core-certifiable topology name (`"octet"`), matching the job schema.
    public let topologyID: String
    public let cellMM: Double
    /// The uniform strut radius (mm) the worker generates at — the topology's grading
    /// law evaluated at `generateRelativeDensity`.
    public let strutRadiusMM: Double
    /// The single density the uniform build fills at (the range's clamped dense end),
    /// echoed in the report so the receipt names what was generated.
    public let generateRelativeDensity: Double
    /// The previewed density range (both clamped to the core band), echoed in the report.
    public let minRelativeDensity: Double
    public let maxRelativeDensity: Double
    public let emitSTL: Bool
    public let emit3MF: Bool
    /// True iff a region scopes this lattice (vs the whole part) — a legacy include
    /// primitive or any `regions` entry. Carried for the run report's honesty note;
    /// the regions themselves ride `regions` below (`lattice.regions`, PR 256).
    public let regionScoped: Bool
    /// The boundary treatment's core job value (`job.lattice.skin`): "none" | "rim" |
    /// "diagrid" (handoff 2026-07-29-lattice-boundary-finish).
    public let skin: String
    /// The user's outer extrusion line width (mm), arming core's OWN skin
    /// printability clamp (`lattice_skin_min_radius_mm`). nil ⇒ the key is omitted
    /// and core uses its default.
    public let minExtrudableWidthMM: Double?
    /// GRADED run (task lattice-page-core-hookup stage 4: core's `run_job` now
    /// honours a `grading` block, grading each accepted variant from that
    /// variant's OWN final stress field). When true the job carries the lattice
    /// block WITHOUT cell_mm/strut_radius_mm (the schema REJECTS uniform geometry
    /// alongside grading) plus a top-level `grading` block — `cellMM` is then the
    /// grading TARGET cell (core raises it to the printability floor) and
    /// `strutRadiusMM`/`generateRelativeDensity` are 0 (the run derives them; a
    /// uniform number here would be the fabrication bar B6 forbids).
    public let graded: Bool
    /// The include/exclude regions the job carries (`lattice.regions`, PR 256's
    /// schema — round-2: the app now EMITS them; the old "core's schema carries no
    /// region yet" copy was stale). Empty ⇒ the key is omitted ⇒ byte-identical to
    /// a pre-regions job.
    public let regions: [LatticeRegionSpec]
    /// The EFFECTIVE cell-size mode this job carries, as the job schema names it:
    /// "fixed" | "auto" | "swept". Only a GRADED job can carry anything but "fixed"
    /// (core chooses/sweeps the cell inside its grading pass), so `runSpec` resolves
    /// a non-graded run to "fixed" — the spec never claims a mode the job can't emit.
    public let cellSizeMode: String
    /// The sweep window (mm), meaningful only when `cellSizeMode == "swept"`.
    public let cellMinMM: Double
    public let cellMaxMM: Double

    // ── SUB-FLOOR RETENTION (task 2026-08-05-lattice-retention-app-control) ─────
    // The four `grading` keys core has carried with no way for the device to ask.
    // ALL DEFAULT OFF / ABSENT, so a spec built from untouched controls serializes
    // to exactly the dictionary this app produced before (bar R1). Every one is
    // already gated against the LINKED core's schema by `runSpec` — a spec never
    // carries a key core would refuse, because `reject_unknown_keys` kills the
    // whole job over one.

    /// Keep lattice in members below the cells-per-member floor where the region
    /// measures as carrying almost no load (`retain_subfloor_in_unloaded_regions`).
    public let retainSubfloorInUnloadedRegions: Bool
    /// The stress-fraction ceiling, ONLY when the user moved it off core's own
    /// number. nil ⇒ the key is omitted ⇒ core takes its constant at call time.
    /// Echoing core's default back as if the app owned it would make the app the
    /// author of a number it merely read.
    public let subfloorStressFraction: Double?
    /// Evaluate the retention predicate per declared region rather than over the
    /// union (`subfloor_per_region`). Core's schema gates this on retention being
    /// armed, and so does `runSpec`.
    public let subfloorPerRegion: Bool
    /// Ask for the per-region cell/voxel report in the graded lattice receipt
    /// (`report_region_cells`). Decision-free: it changes no mask, cell, density
    /// or verdict.
    public let reportRegionCells: Bool

    /// ★ `lattice.require_lattice_void_reaches_exterior` — ALWAYS EMITTED, in
    /// both directions (task 2026-08-06-arm-projection-and-void-check).
    ///
    /// Unlike the four retention flags above, this key is NOT omitted when it
    /// is at its default. Core defaults it to TRUE, so omitting it would run the
    /// same way — but the receipt could not tell "the user asked for this" from
    /// "nobody said anything", and this is the switch that can REFUSE A RUN.
    /// When a rung stops, the record has to say whether the rule was asked for.
    ///
    /// It also rides in the `lattice` block rather than `grading`, so it is NOT
    /// covered by the grading-schema capability probe and must be written at
    /// BOTH emission sites by hand — `RemoteRun.buildJobJSON` and
    /// `RelatticeJobBuilder.build`. That duplication is asserted against in
    /// DefaultArmingTests rather than trusted.
    public let requireVoidReachesExterior: Bool

    public init(topologyID: String, cellMM: Double, strutRadiusMM: Double,
                generateRelativeDensity: Double, minRelativeDensity: Double,
                maxRelativeDensity: Double, emitSTL: Bool = true, emit3MF: Bool = false,
                regionScoped: Bool = false,
                skin: String = LatticeBoundaryTreatment.rim.jobSkinValue,
                minExtrudableWidthMM: Double? = nil,
                graded: Bool = false,
                regions: [LatticeRegionSpec] = [],
                cellSizeMode: String = LatticeCellSizeMode.fixed.rawValue,
                cellMinMM: Double = 0, cellMaxMM: Double = 0,
                retainSubfloorInUnloadedRegions: Bool = false,
                subfloorStressFraction: Double? = nil,
                subfloorPerRegion: Bool = false,
                reportRegionCells: Bool = false,
                requireVoidReachesExterior: Bool = true) {
        self.requireVoidReachesExterior = requireVoidReachesExterior
        self.cellSizeMode = cellSizeMode
        self.cellMinMM = cellMinMM
        self.cellMaxMM = cellMaxMM
        self.retainSubfloorInUnloadedRegions = retainSubfloorInUnloadedRegions
        self.subfloorStressFraction = subfloorStressFraction
        self.subfloorPerRegion = subfloorPerRegion
        self.reportRegionCells = reportRegionCells
        self.topologyID = topologyID
        self.cellMM = cellMM
        self.strutRadiusMM = strutRadiusMM
        self.generateRelativeDensity = generateRelativeDensity
        self.minRelativeDensity = minRelativeDensity
        self.maxRelativeDensity = maxRelativeDensity
        self.emitSTL = emitSTL
        self.emit3MF = emit3MF
        self.regionScoped = regionScoped
        self.skin = skin
        self.minExtrudableWidthMM = minExtrudableWidthMM
        self.graded = graded
        self.regions = regions
    }

    /// THE `grading` BLOCK, BUILT ONCE (task 2026-08-05-lattice-retention-app-control).
    ///
    /// `RemoteRunner` (optimize) and `RelatticeJobBuilder` (re-lattice) used to build
    /// this dictionary independently, with the same keys written out twice. That is
    /// two chances to drift, and dropping the posture on the re-lattice path is the
    /// same class of bug as the ladder-position-in-a-fraction-shaped-key failure that
    /// killed every re-lattice in 48 ms. So there is one builder and both call it —
    /// a one-sided edit is no longer expressible.
    ///
    /// Returns nil for a non-graded spec: core's schema REJECTS a grading block's
    /// keys alongside a uniform cell, and retention lives inside grading, so a
    /// uniform run has nowhere to carry it.
    func gradingDictionary() -> [String: Any]? {
        guard graded else { return nil }
        var grading: [String: Any] = [
            "topology": topologyID,
            // Required by the grading schema: the printability floor's input.
            "min_extrudable_width_mm": minExtrudableWidthMM ?? 0,
        ]
        // Cell-size mode (handoff 2026-08-01-lattice-cell-size-sweep, bar R6).
        // Core does NOT merely ignore a stated cell in auto/swept: `job.cpp`
        // REFUSES `cell_mm` alongside either mode ("a target cell alongside a
        // ladder is a CONFLICT, not a hint"), and refuses the ladder keys outside
        // swept. So the three shapes are exclusive, mirrored exactly:
        //   fixed  → cell_mm, no mode key   (an absent cell_mode IS "fixed")
        //   auto   → cell_mode only         (core picks from its own floor)
        //   swept  → cell_mode + min + max  (no cell_mm)
        //   fit    → cell_mode only         (core derives one cell per region)
        switch cellSizeMode {
        case LatticeCellSizeMode.auto.rawValue,
             LatticeCellSizeMode.fit.rawValue:
            grading["cell_mode"] = cellSizeMode
        case LatticeCellSizeMode.swept.rawValue:
            grading["cell_mode"] = cellSizeMode
            grading["cell_min_mm"] = cellMinMM
            grading["cell_max_mm"] = cellMaxMM
        default:
            grading["cell_mm"] = cellMM
        }
        // SUB-FLOOR RETENTION. Every key below is ABSENT unless the user armed it
        // AND the linked core accepts it (`LatticeSettings.resolvedSubfloor`), so a
        // job built from untouched controls is byte-identical to the one this app
        // produced before (bar R1) — and no key core would refuse can be written
        // here, because `reject_unknown_keys` kills the whole job over one.
        if retainSubfloorInUnloadedRegions {
            grading["retain_subfloor_in_unloaded_regions"] = true
            // Only when the user MOVED it. Absent means core takes its own constant
            // at call time, which is a different document from one restating it.
            if let f = subfloorStressFraction { grading["subfloor_stress_fraction"] = f }
            // Core's schema gates this on retention being armed; `resolvedSubfloor`
            // already enforces it, and nesting it here makes the rule structural.
            if subfloorPerRegion { grading["subfloor_per_region"] = true }
        }
        // Decision-free and independent of retention: it feeds no mask, cell,
        // density or verdict — it only adds the per-region rows to the receipt.
        if reportRegionCells { grading["report_region_cells"] = true }
        return grading
    }
}

/// The user's lattice-mode settings on a project. A pure value type: Codable (round-
/// trips through the project snapshot and rides the existing undo slice) and Equatable
/// (part of the run-request identity, so an edit re-enables Optimize). OFF by default
/// ⇒ byte-identical to a non-lattice project (BAR U1).
public struct LatticeSettings: Codable, Equatable, Sendable {
    /// LATTICE MODE. Off (the default) ⇒ no lattice block reaches the job and the
    /// proxy is inert — the project produces exactly today's job.
    public var enabled: Bool
    /// The chosen topology's stable id (`LatticeType.id`, e.g. "octet"). The picker
    /// previews any of `LatticeType.family`; only a core-certifiable topology
    /// (`TopOptKit.latticeCertifiableTopologies`) reaches a run — the rest are
    /// preview-only, and the UI says so.
    public var topologyID: String
    /// Cell size (mm). Freely edited by the user; its certifiable CEILING (cells per
    /// member) is read from core at use, never stored here. The starting value is the
    /// print-tested octet cell reused from the proxy default — a start, not a limit.
    public var cellMM: Double
    /// How the cell size is chosen (bar R6). `.fixed` is the DEFAULT — the shipped
    /// legacy path, so an untouched project emits exactly today's job.
    public var cellSizeMode: LatticeCellSizeMode
    /// The sweep window's ends (mm), used only in `.swept`. Stored as the user's raw
    /// pick; the lower end is clamped to CORE's printability floor at use
    /// (`LatticeBounds.cellFloorMM`), never to a number written here.
    public var cellMinMM: Double
    public var cellMaxMM: Double
    /// The density RANGE the lattice grades between (relative density, dimensionless).
    /// Stored as the user's raw pick; CLAMPED to the core band [rhoMin, rhoMax] at use
    /// (`LatticeBounds`). The neutral open defaults (0…1) carry no band number.
    public var minRelativeDensity: Double
    public var maxRelativeDensity: Double
    /// The lattice-INCLUDE region primitives ("Material, latticed"), reusing the
    /// manual-primitive value type + gizmo (bolt = cylinder region, face = slab
    /// region). Empty ⇒ the whole solid part. Since round-2 these EMIT as
    /// `lattice.regions` role=include entries (PR 256's schema); new region
    /// primitives are added through the unified Selections library instead, so this
    /// is the LEGACY store (kept for old snapshots + the region gizmo plumbing).
    public var includePrimitives: [ManualPrimitive]
    /// Boundary treatment (three-way; maps 1:1 onto `job.lattice.skin`, bar B7).
    public var boundary: LatticeBoundaryTreatment
    /// Density mode (uniform run fill vs field-graded preview, bar B6).
    public var densityMode: LatticeDensityMode
    /// Faces painted "Material, latticed" (lattice-include). Preview-scope legacy
    /// store (the unified library's group roles are the carrier now). The EXCLUDE
    /// paint role deliberately does NOT live here: it drives the existing protect
    /// affix (`loads.face_protections`, FrozenSolid) so there is ONE protect concept.
    public var paintedIncludeFaces: [Int]
    /// LATTICE ROLES on the TO page's selection groups (round-2 L22), keyed by
    /// `SelectionGroup.id`. An attribute over the ONE `SelectionModel` — never a
    /// second group store: the groups themselves stay in `ProjectModel.selection`,
    /// and an entry whose group is gone is inert (lookup by id finds nothing).
    /// Empty by default ⇒ absent from old snapshots ⇒ they decode unchanged.
    public var groupRoles: [UUID: LatticeGroupRole]
    /// Depth (mm) a face-role lattice region reaches into the part — the
    /// `depth_mm` the emitted `lattice.regions` face entries carry (round-2),
    /// and the legacy painted-include preview depth. Since the depth redesign
    /// this is the FALLBACK: the per-group depth below is what the user drags.
    public var paintDepthMM: Double

    /// ★ THE ONE NUMBER, PER GROUP (task 2026-08-12 §0a). How far the user
    /// dragged that group's lattice primitive out from its face, in mm. It is
    /// BOTH the lattice region depth and — when the group is also protected —
    /// the protection depth. Absent ⇒ `paintDepthMM`, so every existing
    /// snapshot decodes to exactly the depth it had. Read only through
    /// `LatticeSlabDepth`, never directly at a call site.
    public var groupDepthMM: [UUID: Double]

    // ── SUB-FLOOR RETENTION, the user's raw choices (task
    // 2026-08-05-lattice-retention-app-control). All OFF / absent by default, so
    // an untouched project emits exactly today's job (bar R1), and absent from
    // every older snapshot so those projects decode unchanged.

    /// "Keep the lattice where the part is too thin to certify it."
    public var retainSubfloorInUnloadedRegions: Bool
    /// The stress-fraction ceiling ONLY when the user typed one. nil ⇒ core's own
    /// number, and the key is not sent at all.
    public var subfloorStressFraction: Double?
    /// Decide region by region rather than over the union of them.
    public var subfloorPerRegion: Bool
    /// Ask the run for the per-region breakdown in its receipt.
    public var reportRegionCells: Bool

    /// ★ THE ENCLOSED-VOID RULE — the OFF control (task
    /// 2026-08-06-arm-projection-and-void-check, S2c). DEFAULT TRUE, matching
    /// core's own `lattice.require_lattice_void_reaches_exterior`.
    ///
    /// ON  — a lattice cell whose pore space cannot reach the outside of the
    ///       part REFUSES that rung, naming how many cells, where, in which
    ///       declared region, and how much volume is trapped.
    /// OFF — the run exports the sealed cavity, as it did before. Whatever ends
    ///       up inside it — powder, resin, support — can never come out.
    ///
    /// ★ THIS ONE REFUSES RUNS, unlike every other switch in this struct, which
    /// is why it is worth being able to turn off: a job that succeeded
    /// yesterday can stop today, and the maintainer needs a way to get the part
    /// out while he decides what to do about it.
    public var requireVoidReachesExterior: Bool

    /// ★ THE PER-REGION LATTICE DENSITY (task 2026-08-13-lattice-as-a-material,
    /// §7a), keyed by `SelectionGroup.id` exactly as `groupRoles` is — an
    /// attribute over the ONE `SelectionModel`, never a second group store.
    ///
    /// A DECLARED region carrying a fixed relative density is MODE 1; the
    /// optimiser choosing a graded density field over the region is MODE 2. They
    /// are one mechanism — a fixed density IS a constant density field — so this
    /// is one control with two settings and not two features:
    ///
    ///   ABSENT (the default)  AUTO. The optimiser picks the density, graded, and
    ///                         it is bounded by core's own certifiable band, so
    ///                         ★ AUTO CAN NEVER PRODUCE A REFUSAL — there is
    ///                         always an admissible density in the band for it to
    ///                         choose. That is the lattice-page redesign §4 rule,
    ///                         and it is the reason Auto is the default here.
    ///   PRESENT               the user's fixed relative density f. 1.0 means
    ///                         SOLID and emits no lattice at all, byte-identically
    ///                         to not declaring the region (core's own C0 rule,
    ///                         `kLatticeSolidAt`).
    ///
    /// Empty by default ⇒ absent from every older snapshot ⇒ those projects decode
    /// unchanged (bar R1).
    public var frozenRegionDensity: [UUID: Double]

    /// The FIRST include primitive — the legacy single-region accessor the existing
    /// gizmo plumbing (`placeLatticeRegion` / `moveLatticeRegion` / proxy scoping)
    /// reads and writes. One source of truth: this is a view over
    /// `includePrimitives`, never a second stored value.
    public var region: ManualPrimitive? {
        get { includePrimitives.first }
        set {
            if let v = newValue {
                if includePrimitives.isEmpty { includePrimitives = [v] }
                else { includePrimitives[0] = v }
            } else if !includePrimitives.isEmpty {
                includePrimitives.removeFirst()
            }
        }
    }

    public init(enabled: Bool = false, topologyID: String = LatticeType.octet.id,
                cellMM: Double = LatticeSettings.defaultCellMM,
                cellSizeMode: LatticeCellSizeMode = .auto,
                cellMinMM: Double = LatticeSettings.defaultCellMinMM,
                cellMaxMM: Double = LatticeSettings.defaultCellMaxMM,
                minRelativeDensity: Double = 0, maxRelativeDensity: Double = 1,
                region: ManualPrimitive? = nil,
                includePrimitives: [ManualPrimitive] = [],
                // THE DEFAULT IS THE ONE THAT CAN ACTUALLY EMIT (task
                // 2026-08-03-variant-postprocessing-fix, defect 4). It was `.rim`,
                // which on an optimized part is provably zero geometry — see
                // `LatticeCoreCapability.rimEmitsNothingOnVoxelParts`. Core's own job
                // schema has always defaulted to "diagrid" (`job.hpp`); the app was
                // the one overriding it with the choice that does nothing.
                boundary: LatticeBoundaryTreatment = .fullSkin,
                // ★ §4b (task 2026-08-12) — AUTO IS THE DEFAULT. A user who sets
                // his faces and presses Auto on everything must get a lattice
                // with no further questions. The DECODE fallbacks below stay
                // `.uniform` / `.fixed` on purpose: those describe what an OLD
                // snapshot actually had, and a default must never rewrite
                // history (the `boundary` precedent).
                densityMode: LatticeDensityMode = .auto,
                paintedIncludeFaces: [Int] = [],
                paintDepthMM: Double = 4,
                groupRoles: [UUID: LatticeGroupRole] = [:],
                groupDepthMM: [UUID: Double] = [:],
                retainSubfloorInUnloadedRegions: Bool = false,
                subfloorStressFraction: Double? = nil,
                subfloorPerRegion: Bool = false,
                reportRegionCells: Bool = false,
                // Defaults ON, like core. Every other flag here defaults OFF
                // because it adds behaviour; this one defaults ON because the
                // maintainer armed the rule.
                requireVoidReachesExterior: Bool = true,
                frozenRegionDensity: [UUID: Double] = [:]) {
        self.frozenRegionDensity = frozenRegionDensity
        self.retainSubfloorInUnloadedRegions = retainSubfloorInUnloadedRegions
        self.subfloorStressFraction = subfloorStressFraction
        self.subfloorPerRegion = subfloorPerRegion
        self.reportRegionCells = reportRegionCells
        self.requireVoidReachesExterior = requireVoidReachesExterior
        self.enabled = enabled
        self.topologyID = topologyID
        self.cellMM = cellMM
        self.cellSizeMode = cellSizeMode
        self.cellMinMM = cellMinMM
        self.cellMaxMM = cellMaxMM
        self.minRelativeDensity = minRelativeDensity
        self.maxRelativeDensity = maxRelativeDensity
        self.includePrimitives = includePrimitives
        self.boundary = boundary
        self.densityMode = densityMode
        self.paintedIncludeFaces = paintedIncludeFaces
        self.paintDepthMM = paintDepthMM
        self.groupRoles = groupRoles
        self.groupDepthMM = groupDepthMM
        if let r = region, includePrimitives.isEmpty { self.includePrimitives = [r] }
    }

    // Codable by hand: every field newer than the first shipped snapshot decodes
    // with `decodeIfPresent` + its default, so PRE-EXISTING project snapshots (which
    // stored `region`, not `includePrimitives`) still decode — the legacy `region`
    // key migrates into the list (LatticeModeTests.testPreLatticeSnapshotStillDecodes
    // guards the older layer of the same rule).
    private enum CodingKeys: String, CodingKey {
        case enabled, topologyID, cellMM, minRelativeDensity, maxRelativeDensity
        case region                     // legacy single-region snapshots
        case includePrimitives, boundary, densityMode, paintedIncludeFaces, paintDepthMM
        case groupRoles
        case groupDepthMM        // the ONE dragged depth per group (task 2026-08-12 §0a)
        case cellSizeMode, cellMinMM, cellMaxMM   // cell-size sweep (bar R6)
        // sub-floor retention (task 2026-08-05-lattice-retention-app-control)
        case retainSubfloorInUnloadedRegions, subfloorStressFraction
        case subfloorPerRegion, reportRegionCells
        // the enclosed-void rule's OFF control
        // (task 2026-08-06-arm-projection-and-void-check)
        case requireVoidReachesExterior
        // the per-region lattice density (task 2026-08-13-lattice-as-a-material)
        case frozenRegionDensity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        topologyID = try c.decodeIfPresent(String.self, forKey: .topologyID) ?? LatticeType.octet.id
        cellMM = try c.decodeIfPresent(Double.self, forKey: .cellMM) ?? LatticeSettings.defaultCellMM
        // Absent from every pre-R6 snapshot ⇒ `.fixed` ⇒ those projects keep emitting
        // exactly the job they emitted before (bar R1).
        cellSizeMode = try c.decodeIfPresent(LatticeCellSizeMode.self, forKey: .cellSizeMode) ?? .fixed
        cellMinMM = try c.decodeIfPresent(Double.self, forKey: .cellMinMM) ?? LatticeSettings.defaultCellMinMM
        cellMaxMM = try c.decodeIfPresent(Double.self, forKey: .cellMaxMM) ?? LatticeSettings.defaultCellMaxMM
        minRelativeDensity = try c.decodeIfPresent(Double.self, forKey: .minRelativeDensity) ?? 0
        maxRelativeDensity = try c.decodeIfPresent(Double.self, forKey: .maxRelativeDensity) ?? 1
        if let list = try c.decodeIfPresent([ManualPrimitive].self, forKey: .includePrimitives) {
            includePrimitives = list
        } else if let legacy = try c.decodeIfPresent(ManualPrimitive.self, forKey: .region) {
            includePrimitives = [legacy]
        } else {
            includePrimitives = []
        }
        // A snapshot with no `boundary` key was written when the default WAS `.rim`,
        // so `.rim` is the faithful restore of what that project actually had — the
        // decode fallback describes HISTORY and does not follow the new default
        // (task 2026-08-03-variant-postprocessing-fix). Such a project opens with
        // the "this emits nothing" warning showing, which is the honest outcome.
        boundary = try c.decodeIfPresent(LatticeBoundaryTreatment.self, forKey: .boundary) ?? .rim
        densityMode = try c.decodeIfPresent(LatticeDensityMode.self, forKey: .densityMode) ?? .uniform
        paintedIncludeFaces = try c.decodeIfPresent([Int].self, forKey: .paintedIncludeFaces) ?? []
        paintDepthMM = try c.decodeIfPresent(Double.self, forKey: .paintDepthMM) ?? 4
        groupRoles = try c.decodeIfPresent([UUID: LatticeGroupRole].self, forKey: .groupRoles) ?? [:]
        // Absent from every pre-task snapshot ⇒ empty ⇒ every group falls back to
        // `paintDepthMM`, which is exactly the depth those projects emitted.
        groupDepthMM = try c.decodeIfPresent([UUID: Double].self, forKey: .groupDepthMM) ?? [:]
        // Absent from every snapshot older than this task, and the default is
        // AUTO for every region, so an old project decodes to exactly what it
        // always meant (bar R1).
        frozenRegionDensity =
            try c.decodeIfPresent([UUID: Double].self, forKey: .frozenRegionDensity) ?? [:]
        // Absent from every snapshot written before this task ⇒ off / core's own
        // number ⇒ those projects keep emitting exactly the job they emitted.
        retainSubfloorInUnloadedRegions = try c.decodeIfPresent(
            Bool.self, forKey: .retainSubfloorInUnloadedRegions) ?? false
        subfloorStressFraction = try c.decodeIfPresent(
            Double.self, forKey: .subfloorStressFraction)
        subfloorPerRegion = try c.decodeIfPresent(Bool.self, forKey: .subfloorPerRegion) ?? false
        reportRegionCells = try c.decodeIfPresent(Bool.self, forKey: .reportRegionCells) ?? false
        // ★ nil → TRUE, and the asymmetry with the four lines above is the point.
        // Those decode to "off" because absent meant off when they were written.
        // This rule is ARMED BY DEFAULT now, so a project saved before this
        // field existed must reopen ARMED — decoding it to false would opt every
        // existing project out of a rule the maintainer turned on, silently.
        requireVoidReachesExterior = try c.decodeIfPresent(
            Bool.self, forKey: .requireVoidReachesExterior) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(topologyID, forKey: .topologyID)
        try c.encode(cellMM, forKey: .cellMM)
        try c.encode(cellSizeMode, forKey: .cellSizeMode)
        try c.encode(cellMinMM, forKey: .cellMinMM)
        try c.encode(cellMaxMM, forKey: .cellMaxMM)
        try c.encode(minRelativeDensity, forKey: .minRelativeDensity)
        try c.encode(maxRelativeDensity, forKey: .maxRelativeDensity)
        try c.encode(includePrimitives, forKey: .includePrimitives)
        try c.encode(boundary, forKey: .boundary)
        try c.encode(densityMode, forKey: .densityMode)
        try c.encode(paintedIncludeFaces, forKey: .paintedIncludeFaces)
        try c.encode(paintDepthMM, forKey: .paintDepthMM)
        try c.encode(groupRoles, forKey: .groupRoles)
        try c.encode(groupDepthMM, forKey: .groupDepthMM)
        try c.encode(frozenRegionDensity, forKey: .frozenRegionDensity)
        try c.encode(retainSubfloorInUnloadedRegions,
                     forKey: .retainSubfloorInUnloadedRegions)
        // encodeIfPresent: "the user has not moved it" must round-trip as ABSENT,
        // not as core's number written into the project — the whole point of the
        // nil is that the app never becomes the author of that constant.
        try c.encodeIfPresent(subfloorStressFraction, forKey: .subfloorStressFraction)
        try c.encode(subfloorPerRegion, forKey: .subfloorPerRegion)
        try c.encode(reportRegionCells, forKey: .reportRegionCells)
        try c.encode(requireVoidReachesExterior, forKey: .requireVoidReachesExterior)
    }

    /// The starting cell size (mm): the octet cell PR-201 print-tested, reused from the
    /// viewer proxy's own default so the preview is continuous. A default START value
    /// the user edits — deliberately NOT a certifiable limit (limits come from core).
    public static let defaultCellMM: Double = LatticeProxyParams().cellMM

    /// Starting ends of the SWEPT window (mm). Like `defaultCellMM` these are START
    /// values the user edits, not limits: the real lower bound is core's printability
    /// floor, applied by `LatticeBounds.compute` (`cellFloorMM`).
    public static let defaultCellMinMM: Double = 4
    public static let defaultCellMaxMM: Double = 8

    /// The resolved topology (never nil — an unknown id falls back to octet, matching
    /// `LatticeType.named`).
    public var lattice: LatticeType { LatticeType.named(topologyID) }

    /// A member-width estimate (mm) for the cells-per-member readout, taken from the
    /// region's smallest cross-section: a bolt's diameter, a face slab's smallest
    /// in-plane span. nil ⇒ no region (whole part) — the readout is then omitted rather
    /// than a part-bbox width faked as a member width. This only drives an ADVISORY
    /// readout today (core certifies no cells-per-member ceiling yet), never a run gate.
    public var regionMemberMM: Double? {
        guard let r = region else { return nil }
        switch r.kind {
        case .bolt: return max(0, 2 * r.radiusMM)
        case .face: return max(0, 2 * Swift.min(r.halfUMM, r.halfWMM))
        }
    }

    /// The lattice block to put on the run, or nil when the settings must NOT lattice
    /// this build — mode off, a preview-only topology, or a cell over a real core
    /// ceiling. nil ⇒ the job omits the lattice block ⇒ byte-identical to today (U1).
    /// `limits` is read from core; `memberMM`/`lineWidthMM` are the local geometry and
    /// print facts (only affect the advisory readouts today, since core exposes no cell
    /// ceiling yet). The generated uniform strut radius is the topology's grading law at
    /// the range's clamped dense end.
    /// SUB-FLOOR RETENTION, resolved against BOTH gates before it can ride a job
    /// (task 2026-08-05-lattice-retention-app-control):
    ///
    ///   * CORE'S SCHEMA GATE — `subfloor_stress_fraction` and
    ///     `subfloor_per_region` are refused by core unless retention is armed
    ///     ("a job that means one thing and says another"), so retention off
    ///     zeroes both here rather than shipping a document core will reject.
    ///   * THE CAPABILITY GATE — a key the linked core does not accept is never
    ///     emitted, because `reject_unknown_keys` fails the WHOLE job over one.
    ///   * ★ THE FIT EXCLUSION (task 2026-08-07-cell-mode-fit-and-swept-floor) —
    ///     `grade_lattice` THROWS on `cell_mode: "fit"` alongside retention
    ///     (core/src/simp/grading.cpp:66-70), deliberately: fit already derives a
    ///     cell per region and already reports what it emitted below the accuracy
    ///     floor, with its own accounting, so running both leaves two mechanisms
    ///     deciding the same voxel with two receipts. The job that pairs them is
    ///     therefore NOT EXPRESSIBLE from here — `cellMode` is the mode the SPEC
    ///     will carry, not the stored setting, so a swept snapshot that `runSpec`
    ///     resolved down to fixed cannot smuggle the pair through either.
    ///
    /// Returns the four values a `LatticeSpec` carries.
    func resolvedSubfloor(capability: LatticeRetentionCapability,
                          cellMode: LatticeCellSizeMode)
        -> (retain: Bool, fraction: Double?, perRegion: Bool, regionCells: Bool) {
        let retain = retainSubfloorInUnloadedRegions && capability.retention
            && cellMode != .fit
        // Sent ONLY when the user moved it off core's own number: nil means
        // "core takes its own constant at call time", which is a different job
        // document from one that states the same value.
        let fraction = (retain && capability.stressFraction)
            ? subfloorStressFraction : nil
        let perRegion = retain && subfloorPerRegion && capability.perRegion
        // Decision-free and independent of retention — but still capability-gated.
        let regionCells = reportRegionCells && capability.regionCells
        return (retain, fraction, perRegion, regionCells)
    }

    public func runSpec(limits: TopOptKit.LatticeLimits, generatable: Bool,
                        memberMM: Double = 0,
                        lineWidthMM: Double = 0, emitSTL: Bool = true,
                        emit3MF: Bool = false,
                        regions: [LatticeRegionSpec] = [],
                        capability: LatticeRetentionCapability = .fromCore,
                        cellModes: LatticeCellModeCapability = .fromCore)
        -> LatticeSpec? {
        guard enabled else { return nil }
        let b = LatticeBounds.compute(settings: self, limits: limits,
                                      generatable: generatable,
                                      memberMM: memberMM, lineWidthMM: lineWidthMM)
        guard b.runnableAsCertified else { return nil }
        // AUTO density (task lattice-page-core-hookup stage 4): core's run_job now
        // grades each accepted variant from that variant's OWN final stress field,
        // so the job ships a GRADED spec — a `grading` block, never a uniform
        // fill (bar B6 intact: auto still never silently means uniform). Core's
        // grading schema REQUIRES the stated minimum extrudable width (its
        // printability floor), so without a line width the spec stays nil and
        // Optimize is gated with that reason.
        // ★ §4c AND BAR B6, RECONCILED (task 2026-08-12). I briefly made this fall
        // through to the UNIFORM spec so Auto — now the DEFAULT — could never
        // produce "no lattice at all". `LatticePageTests
        // .testStaleFieldIsFlaggedAndAutoNeverSilentlyUniform` refused it, and it
        // was right to: B6 is an explicit decision that auto must never become
        // uniform behind the user's back, and a `graded: false` flag is not the
        // same as a refusal the page states.
        //
        // §4c is about a region that cannot be CERTIFIED — there Auto takes the
        // buildable cell and reports the region out of regime (see
        // LatticeFaceCardDerivation). A missing strut line width is a missing
        // INPUT, not an uncertifiable region: nil here, and the page names the
        // reason. In production the width always exists — PrintParams derives it
        // by rule from the wall beads — which is pinned below.
        if densityMode == .auto {
            guard lineWidthMM > 0 else { return nil }
            // Cell-size mode (bar R6). Only the GRADED job can carry a mode other than
            // fixed, and both sweep ends are pushed up onto CORE's printability floor —
            // the app never states a cell core would refuse.
            let floor = b.cellFloorMM ?? 0
            let lo = Swift.max(cellMinMM, floor)
            let hi = Swift.max(cellMaxMM, lo)
            // Core refuses a non-positive ladder end, so a snapshot carrying one falls
            // back to the fixed cell rather than shipping a job the schema rejects.
            // FIT falls back the same way when the LINKED core does not carry the
            // value: an unknown cell_mode kills the whole job at validation, exactly
            // as an unknown grading key does, so a project snapshot saved against a
            // newer core degrades to the fixed cell instead of dying at the worker.
            var mode: LatticeCellSizeMode = (cellSizeMode == .swept && !(lo > 0))
                ? .fixed : cellSizeMode
            if mode == .fit && !cellModes.fit { mode = .fixed }
            // ★ FIT DERIVES FROM A DECLARED REGION, so core REFUSES the mode on a job
            // that declares none (job.cpp: "a job that declares none states no
            // requirement to fit"). Caught by this task's own schema test, which
            // handed the emitted bytes to core's parser rather than checking a key
            // list — a job.json that dies at validation is not a degraded run, it is
            // no run. The page says so on the control; this is the structural half.
            if mode == .fit && !regions.contains(where: { $0.role == .include }) {
                mode = .fixed
            }
            // Sub-floor retention rides the GRADED path only — the keys live in the
            // `grading` block, and a uniform lattice job has no grading block at
            // all, so there is nothing for core to read there. The control says so.
            // `mode` (not `cellSizeMode`) carries the fit exclusion, so a spec that
            // fell back to fixed can still arm retention.
            let sub = resolvedSubfloor(capability: capability, cellMode: mode)
            return LatticeSpec(topologyID: topologyID, cellMM: cellMM, strutRadiusMM: 0,
                               generateRelativeDensity: 0,
                               minRelativeDensity: b.densityLo,
                               maxRelativeDensity: b.densityHi,
                               emitSTL: emitSTL, emit3MF: emit3MF,
                               regionScoped: region != nil || !regions.isEmpty,
                               skin: boundary.jobSkinValue,
                               minExtrudableWidthMM: lineWidthMM,
                               graded: true,
                               regions: regions,
                               cellSizeMode: mode.rawValue,
                               cellMinMM: lo, cellMaxMM: hi,
                               retainSubfloorInUnloadedRegions: sub.retain,
                               subfloorStressFraction: sub.fraction,
                               subfloorPerRegion: sub.perRegion,
                               reportRegionCells: sub.regionCells,
                               // NOT capability-gated: this key lives in the
                               // `lattice` block, not `grading`, and it has been
                               // in core's schema since PR 305. The retention
                               // keys need the probe because they were added to
                               // `grading` after some cores were built.
                               requireVoidReachesExterior: requireVoidReachesExterior)
        }
        let genRho = b.generateRelativeDensity
        let radius = lattice.strutRadiusMM(relativeDensity: genRho, cellMM: cellMM)
        guard radius > 0 else { return nil }
        return LatticeSpec(topologyID: topologyID, cellMM: cellMM, strutRadiusMM: radius,
                           generateRelativeDensity: genRho,
                           minRelativeDensity: b.densityLo, maxRelativeDensity: b.densityHi,
                           emitSTL: emitSTL, emit3MF: emit3MF,
                           regionScoped: region != nil || !regions.isEmpty,
                           skin: boundary.jobSkinValue,
                           minExtrudableWidthMM: lineWidthMM > 0 ? lineWidthMM : nil,
                           regions: regions,
                           // The UNIFORM path carries it too. The enclosed-void
                           // rule is about the lattice's pore space, which a
                           // uniform lattice has exactly as much of as a graded
                           // one — carrying it on only one path would make the
                           // rule silently depend on the density mode.
                           requireVoidReachesExterior: requireVoidReachesExterior)
    }

    /// Convenience: read the certifiable limits AND the generatable set from core
    /// for this topology, then build the run spec. `topology` is accepted
    /// (defaulting to `topologyID`) so a caller can be explicit; it must match
    /// `topologyID`. Used by `AppModel.makeRunRequest`.
    public func runSpec(topology: String? = nil, memberMM: Double = 0,
                        lineWidthMM: Double = 0, emitSTL: Bool = true,
                        emit3MF: Bool = false,
                        regions: [LatticeRegionSpec] = [],
                        capability: LatticeRetentionCapability = .fromCore,
                        cellModes: LatticeCellModeCapability = .fromCore)
        -> LatticeSpec? {
        let id = topology ?? topologyID
        let limits = TopOptKit.latticeLimits(topology: id)
        let generatable = TopOptKit.latticeGeneratableTopologies.contains(id)
        return runSpec(limits: limits, generatable: generatable, memberMM: memberMM,
                       lineWidthMM: lineWidthMM, emitSTL: emitSTL, emit3MF: emit3MF,
                       regions: regions, capability: capability,
                       cellModes: cellModes)
    }

    /// The proxy grading parameters for the current settings, with the density range
    /// already clamped to the core band, so the viewer proxy (requirement 5) shows the
    /// SAME numbers the run would use. `limits` is read from core.
    public func proxyParams(limits: TopOptKit.LatticeLimits) -> LatticeProxyParams {
        let b = LatticeBounds.compute(settings: self, limits: limits)
        return LatticeProxyParams(latticeID: topologyID, cellMM: cellMM,
                                  minRelativeDensity: b.densityLo,
                                  maxRelativeDensity: b.densityHi,
                                  gamma: 1,
                                  uniformRelativeDensity: 0.5 * (b.densityLo + b.densityHi))
    }
}

/// THE CELL-SIZE CONTROL'S ENVELOPE, as a pure value (task
/// 2026-08-05-lattice-retention-app-control, S3).
///
/// *** WHY THIS MOVED OUT OF THE VIEW. *** The audit this task ran asked a simple
/// question — can the user type the cell size a pre-flight refusal names? — and the
/// answer lived in two `private` functions on a SwiftUI view, where no test could
/// reach it. It could not. Two independent reasons, both here now where they can be
/// pinned:
///
///   * TYPED INPUT WAS QUANTIZED TO HALF A MILLIMETRE. `1.2` became `1.0`.
///   * THE LOWER BOUND WAS CORE'S rho_min PRINTABILITY FLOOR — 4.93 mm at the
///     maintainer's own 0.45 mm line width, four times the value the refusal names.
///     Core itself refuses no such cell (`lattice "cell_mm" must be > 0`,
///     job.cpp:851; a graded target is RAISED, never refused). The app was the only
///     thing in the way.
public enum LatticeCellEntry {
    /// The slider's top end — a UI convenience, unchanged.
    public static let sliderMaxMM: Double = 20
    /// The start of range when core has no number to give (no line width, or a
    /// topology it carries no tensor for). Explicitly not a certifiable limit.
    public static let fallbackFloorMM: Double = 2
    /// The floor of last resort. A cell has to be a positive length; below this
    /// the control is not expressing a lattice, it is expressing a typo.
    public static let hardFloorMM: Double = 0.05

    /// The control's real lower bound: the DENSEST-end printability floor when core
    /// gives one, else the old fallback. Never core's rho_min floor, which describes
    /// one end of the band rather than what the printer can make.
    public static func entryFloorMM(_ b: LatticeBounds?) -> Double {
        if let d = b?.cellFloorDensestMM { return d }
        return Swift.min(b?.cellFloorMM ?? fallbackFloorMM, fallbackFloorMM)
    }

    public static func range(_ b: LatticeBounds?) -> ClosedRange<Double> {
        let lo = Swift.max(hardFloorMM,
                           Swift.min(entryFloorMM(b), sliderMaxMM - 0.5))
        return lo...sliderMaxMM
    }

    /// DRAGGING quantizes to a half-millimetre — the shipped feel, unchanged.
    public static func dragged(_ v: Double, _ b: LatticeBounds?) -> Double {
        let r = range(b)
        return Swift.min(r.upperBound, Swift.max(r.lowerBound, (v * 2).rounded() / 2))
    }

    /// TYPING is EXACT to two decimals — what the refusals quote, and what the
    /// number pad already accepts.
    public static func typed(_ v: Double, _ b: LatticeBounds?) -> Double {
        let r = range(b)
        return Swift.min(r.upperBound,
                         Swift.max(r.lowerBound, (v * 100).rounded() / 100))
    }

    /// A cell size as text. Two decimals when the value needs them — a cell typed
    /// from a refusal ("1.17 mm") must not read back as "1.2 mm", or the number on
    /// screen is not the number in the job.
    public static func text(_ v: Double) -> String {
        let oneDP = (v * 10).rounded() / 10
        return abs(v - oneDP) < 5e-4
            ? String(format: "%.1f mm", v)
            : String(format: "%.2f mm", v)
    }
}

/// The runtime-computed, core-bounded envelope for the lattice controls, plus the
/// PLAIN reason each bound is where it is. Pure and headlessly unit-tested: it takes
/// the settings, the core-read `limits`, the region/part member width and the user's
/// own extrusion line width, and returns the effective values and reasons. It AUTHORS
/// NO band or cell number — the band + cell ceiling come from `limits` (from core),
/// and the strut printability floor comes from the user's line width. That is the
/// whole point: nothing here to hardcode, so the UI widens when core widens.
public struct LatticeBounds: Equatable, Sendable {
    // --- density band -------------------------------------------------------
    /// Effective (clamped-to-band) low / high grading density.
    public let densityLo: Double
    public let densityHi: Double
    /// The core band edges, for labels ("certifiable 15–59%").
    public let bandLo: Double
    public let bandHi: Double
    /// Non-nil iff that end was moved onto the band — the reason to show under it.
    public let densityLoReason: String?
    public let densityHiReason: String?

    // --- topology -----------------------------------------------------------
    /// True iff core carries a homogenized tensor for the chosen topology (runnable).
    public let certifiable: Bool
    /// Non-nil iff the chosen topology is preview-only (why a run won't lattice it).
    public let topologyReason: String?
    /// True iff core's GEOMETRY GENERATOR can emit the chosen topology
    /// (`TopOptKit.latticeGeneratableTopologies`) — INDEPENDENT of `certifiable`:
    /// core certifies seven topologies but generates only octet today (bar B0).
    public let generatable: Bool
    /// Non-nil iff the topology certifies but cannot be generated (why a run
    /// can't lattice it even though the band displays).
    public let generatableReason: String?

    // --- cell size ----------------------------------------------------------
    /// The certifiable cell CEILING (mm) for the current member width, or nil when core
    /// does not yet certify a cells-per-member value (then the readout is ADVISORY).
    public let cellCeilingMM: Double?
    /// The cell-size FLOOR (mm) — core's printability floor for this topology at the
    /// user's own extrusion width (`TopOptKit.latticeCellBounds`), i.e. the smallest
    /// cell whose thinnest certifiable strut still prints. nil ⇒ no line width is
    /// known (or core carries no tensor for the topology), and the control then falls
    /// back to its own start value rather than inventing a floor. This is the LOWER
    /// bound of the cell-size control, the partner of `cellCeilingMM` above, and the
    /// cell core picks in AUTO mode (bar R6).
    public let cellFloorMM: Double?
    /// THE OTHER FLOOR — the one the refusals name (task
    /// 2026-08-05-lattice-retention-app-control, S3).
    ///
    /// `cellFloorMM` above is core's `lattice_cell_printability_floor_mm`, and that
    /// number is evaluated at the band's LIGHTEST density: it is the smallest cell
    /// at which even a rho_min lattice still prints. Nothing forces a user to
    /// lattice at the lightest density, and the concurrent cell-size-adaptation work
    /// establishes the same point from the other side — the "23 mm member" the
    /// maintainer was told he needed was that same rho_min-conditional figure, and
    /// at the density a member can actually carry the arithmetic gives 5.47 mm.
    ///
    /// This is the DENSEST-end partner: the smallest cell whose strut at core's
    /// band-TOP density still reaches one extrusion line width. Below it no cell
    /// prints at any density; between it and `cellFloorMM` a cell prints at the
    /// dense end only, which is exactly the range a pre-flight refusal tells the
    /// user to type in ("this region admits cells from 1.09 mm"). Using the LIGHT
    /// floor as the control's hard bound made those numbers unenterable — a refusal
    /// naming a value the user could not type.
    ///
    /// READ FROM CORE, not derived here (`TopOptKit.latticeCellBounds`), because the
    /// app's own octet strut law disagrees with core's by a factor of 1.4: derived in
    /// Swift this came out 1.64 mm at a 0.45 mm bead where core's arithmetic gives
    /// 1.17. A bound that disagrees with the refusal quoting it is no better than the
    /// bound it replaced. nil ⇒ no line width, or core carries no strut-diameter law
    /// for the topology.
    public let cellFloorDensestMM: Double?
    /// How many cells span the governing member at the current cell size (the readout).
    public let cellsAcrossMember: Double
    /// True iff `cellMM` exceeds a real (non-advisory) ceiling — a genuine clamp.
    public let cellOverCeiling: Bool
    /// The reason for the cell ceiling: the real "too few cells" message, or the
    /// advisory "not yet certified by core" note.
    public let cellReason: String?

    // --- strut printability (from the user's OWN line width) ----------------
    /// The strut radius (mm) the densest end produces at this cell — the thing that
    /// must be printable. From the topology's exact grading law r = L·√(ρ/K).
    public let strutRadiusMM: Double
    /// One extrusion line width (mm) — the printability floor for a strut radius. From
    /// the user's print settings, not a hardcoded number.
    public let strutFloorMM: Double
    public let strutTooThin: Bool
    public let strutReason: String?

    private static func pct(_ x: Double) -> String {
        "\(Int((x * 100).rounded()))%"
    }
    private static func mm(_ x: Double) -> String {
        String(format: "%.1f mm", x)
    }

    /// Compute the bounded envelope + reasons.
    /// - Parameters:
    ///   - settings: the user's raw choices.
    ///   - limits: the core-read certifiable limits for `settings.topologyID`.
    ///   - memberMM: the governing (thinnest) member width the lattice must span, in
    ///     mm — from the region if one is set, else a part-scale estimate. Pass 0 when
    ///     unknown (the cells-per-member readout is then omitted).
    ///   - lineWidthMM: the STRUT extrusion line width (mm) — the strut printability
    ///     floor, `PrintParams.strutLineWidthMM`. It was the OUTER WALL bead until
    ///     2026-08-06; a strut is a lone unsupported extrusion, not a wall loop, so it
    ///     carries its own width now (task strut-line-width-field). Pass 0 to skip the
    ///     strut-printability check.
    public static func compute(settings: LatticeSettings,
                               limits: TopOptKit.LatticeLimits,
                               generatable: Bool = true,
                               memberMM: Double = 0,
                               lineWidthMM: Double = 0) -> LatticeBounds {
        let topo = settings.lattice
        // Display name for the reasons. LatticeType.named falls back to octet for
        // ids it has no geometry for (kelvin/rhombic), which would put the WRONG
        // name in a reason string — resolve the name independently.
        let name = LatticeType.displayName(forID: settings.topologyID)

        // Density: clamp the user's range into the core band. When core does not
        // certify this topology the band is degenerate (0…0); we then leave the range
        // as the user set it (preview-only) and pin nothing — the topology reason
        // carries the honesty instead of a bogus density clamp.
        let bandLo = limits.rhoMin
        let bandHi = limits.rhoMax
        var lo = max(0.0, min(1.0, settings.minRelativeDensity))
        var hi = max(lo, min(1.0, settings.maxRelativeDensity))
        var loReason: String? = nil
        var hiReason: String? = nil
        if limits.certifiable && bandHi > bandLo {
            if lo < bandLo { lo = bandLo; loReason = "below the certifiable density range (≥ \(pct(bandLo)))" }
            if hi > bandHi { hi = bandHi; hiReason = "above the certifiable density range (≤ \(pct(bandHi)))" }
            if hi < lo { hi = lo }
        }

        // Topology. Certifiability and generatability are INDEPENDENT properties
        // (bar B0): the first is whether core carries a tensor (band displays), the
        // second is whether core's geometry generator can emit it (a run exists).
        let topoReason: String? = limits.certifiable
            ? nil
            : "\(name) is preview-only — not yet certifiable, so a run won't lattice it"
        let genReason: String? = generatable
            ? nil
            : "\(name) certifies, but core has no geometry generator for it yet — a run can't lattice it"

        // Cell size ceiling from cells-per-member. minCellsPerMember == 0 ⇒ core has
        // not certified a ceiling yet ⇒ ADVISORY (readout only, no clamp).
        let cells = memberMM > 0 ? LatticeDensityProxy.cellsAcrossMember(memberMM: memberMM, cellMM: settings.cellMM) : 0
        var ceiling: Double? = nil
        var overCeiling = false
        var cellReason: String? = nil
        if limits.minCellsPerMember > 0 && memberMM > 0 {
            let c = memberMM / limits.minCellsPerMember
            ceiling = c
            if settings.cellMM > c + 1e-9 {
                overCeiling = true
                cellReason = "too few cells across this member to certify — need ≥ \(String(format: "%g", limits.minCellsPerMember)) across \(mm(memberMM)), so cell ≤ \(mm(c))"
            }
        } else if memberMM > 0 {
            cellReason = "cells-per-member ceiling not yet certified by core — shown as a guide, not a limit"
        }

        // Cell FLOOR — core's printability floor for this topology at the user's own
        // line width, read through the bridge (bar R6). Never computed here: the app
        // hardcodes no cell number, so a core re-measurement moves the control. Only
        // meaningful with a line width AND a topology core carries a tensor for.
        var cellFloor: Double? = nil
        var cellFloorDensest: Double? = nil
        // `certifiable` is the honest gate: core's floor is derived from the topology's
        // certifiable band, so a preview-only topology has no floor to state (the bridge
        // returns a band-of-zero number there rather than refusing).
        if lineWidthMM > 0 && limits.certifiable {
            let cb = TopOptKit.latticeCellBounds(topology: settings.topologyID,
                                                 minExtrudableWidthMM: lineWidthMM)
            if cb.valid && cb.printabilityFloorMM > 0 { cellFloor = cb.printabilityFloorMM }
            if cb.valid && cb.printabilityFloorDensestMM > 0 {
                cellFloorDensest = cb.printabilityFloorDensestMM
            }
        }
        // A cell UNDER the floor is its own honest clamp — but never overwrite the
        // ceiling's message, which is the harder failure. Which floor it is under
        // decides what actually happens, and they are different outcomes: under the
        // LIGHT floor a graded run has its target raised by core and a uniform run
        // builds the cell as typed; under the DENSE floor nothing prints at all.
        if cellReason == nil, let d = cellFloorDensest, settings.cellMM < d - 1e-9 {
            cellReason = "no lattice prints at \(mm(settings.cellMM)) at this line "
                       + "width — even at the densest certifiable \(name) the struts "
                       + "come out thinner than one bead. Cell ≥ \(mm(d))."
        } else if cellReason == nil, let f = cellFloor, settings.cellMM < f - 1e-9 {
            cellReason = "below core's printability floor for \(name) at this line "
                       + "width (\(mm(f))), which is measured at the LIGHTEST "
                       + "certifiable density. A graded run has its cell raised to "
                       + "that number; a uniform run builds the cell you typed, and "
                       + "its struts print because it fills at the dense end."
        }

        // Strut printability from the user's own STRUT line width (not a wall bead —
        // see the parameter doc). The densest grading end
        // makes the thinnest… no: the densest end makes the THICKEST strut; the
        // printability risk is at the SPARSE end, so check the low density's radius.
        let strutR = topo.strutRadiusMM(relativeDensity: lo, cellMM: settings.cellMM)
        let floor = lineWidthMM > 0 ? 0.5 * lineWidthMM : 0
        let tooThin = floor > 0 && strutR < floor - 1e-9
        let strutReason: String? = tooThin
            ? "struts reach \(String(format: "%.2f mm", strutR)) at the sparse end — thinner than one extrusion width (\(mm(lineWidthMM))), too thin to print"
            : nil

        return LatticeBounds(
            densityLo: lo, densityHi: hi, bandLo: bandLo, bandHi: bandHi,
            densityLoReason: loReason, densityHiReason: hiReason,
            certifiable: limits.certifiable, topologyReason: topoReason,
            generatable: generatable, generatableReason: genReason,
            cellCeilingMM: ceiling, cellFloorMM: cellFloor,
            cellFloorDensestMM: cellFloorDensest,
            cellsAcrossMember: cells, cellOverCeiling: overCeiling,
            cellReason: cellReason,
            strutRadiusMM: strutR, strutFloorMM: floor, strutTooThin: tooThin,
            strutReason: strutReason)
    }

    /// Whether the current settings are safe to RUN as a certified lattice: a
    /// certifiable topology, density inside the band (always true after the clamp), and
    /// the cell within any REAL cells-per-member ceiling core certifies. Strut thinness
    /// is NOT a run gate: the shipped generator fills UNIFORMLY at the dense end of the
    /// range (`generateRelativeDensity`), whose struts are the thickest and always
    /// printable — `strutTooThin` is a sparse-end preview advisory only. A false here is
    /// why the job omits the lattice block; the reasons above say which condition failed.
    public var runnableAsCertified: Bool {
        certifiable && generatable && !cellOverCeiling
    }

    /// The single relative density the RUN generates at. The shipped generator is
    /// UNIFORM (the grading law is held for the certifiable band, handoff
    /// lattice-generation-production), so the build fills at the range's DENSE end — the
    /// conservative choice, never sparser (hence weaker) than the previewed range. When
    /// graded generation lands this becomes the range itself.
    public var generateRelativeDensity: Double { densityHi }
}
