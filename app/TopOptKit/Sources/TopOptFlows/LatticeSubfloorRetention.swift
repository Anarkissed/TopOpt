// LatticeSubfloorRetention.swift — the app's side of sub-floor lattice retention
// and the per-region receipt (task 2026-08-05-lattice-retention-app-control).
//
// THE DEFECT THIS FILE EXISTS FOR. Core has been able to KEEP a lattice in
// material too thin to certify since PR 295 — `grading.retain_subfloor_in_
// unloaded_regions`, parsed at core/src/cli/job.cpp:1079, consumed at
// run_job.cpp:1983. The device has never been able to ask for it. The grading
// dictionary the app assembles emitted exactly six keys (topology,
// min_extrudable_width_mm, cell_mode, cell_min_mm, cell_max_mm, cell_mm), so
// `subfloor_retention.requested` came back false on every forecast the app has
// ever run — which made the branch at LatticeForecast.swift:202, the one that
// explains retention to the user, unreachable code on the device path.
//
// The app was rendering the receipt of a thing it could not request.
//
// THREE PIECES LIVE HERE, and none of them is a mirror of a core number:
//
//   1. LatticeRetentionCapability — WHICH grading keys the linked core accepts,
//      asked of core's own parser at runtime, never mirrored in Swift.
//   2. LatticeRetentionControl — the control's copy and, before the run, the
//      EXPOSURE: how much material this would lattice without a certificate.
//   3. LatticeRegionCellReceipt — core's per-region report, read back and turned
//      into lines, with "this region got nothing" said BY NAME and first.

import Foundation
import TopOptKit

// MARK: - 1 · what the LINKED core accepts

/// The four grading keys this feature needs, and whether the core the app is
/// built against accepts each one.
///
/// *** WHY THIS IS PROBED AND NOT DECLARED. *** `reject_unknown_keys` fails the
/// WHOLE job on one unrecognised grading key — so emitting a key an older core
/// does not know is not a degraded run, it is a job that dies at schema
/// validation in milliseconds, which is exactly how every re-lattice of a growth
/// variant died before task 2026-08-04-variant-volume-fraction-mismatch. And a
/// hardcoded "core supports this" boolean is the failure `LatticeCoreCapability`
/// carries its own scar for: PR 284 wrote one, PR 285 made it false the same
/// evening, and the app spent two PRs quoting a core rule that no longer existed.
///
/// So the app asks core's parser (`TopOptKit.gradingSchemaAccepts`), which hands
/// `topopt::parse_job` a document carrying the key and reads whether the schema
/// refused it by name. Two of these four keys (`subfloor_per_region`,
/// `report_region_cells`) arrive with the concurrent cell-size-adaptation work;
/// when that core lands and the maintainer rebuilds, they light up with no app
/// change and no constant to remember to flip.
public struct LatticeRetentionCapability: Equatable, Sendable {
    /// The switch itself: keep lattice in members below the cells-per-member floor.
    public let retention: Bool
    /// The stress-fraction ceiling override (schema-gated on `retention`).
    public let stressFraction: Bool
    /// Evaluate the retention predicate PER REGION rather than over the union.
    public let perRegion: Bool
    /// Emit the per-region cell/voxel report into the graded lattice receipt.
    public let regionCells: Bool
    /// False ⇒ the probe could not prove itself on this build and every answer
    /// above is a conservative false. Surfaced, never silently swallowed.
    public let probeReliable: Bool

    public init(retention: Bool, stressFraction: Bool, perRegion: Bool,
                regionCells: Bool, probeReliable: Bool) {
        self.retention = retention
        self.stressFraction = stressFraction
        self.perRegion = perRegion
        self.regionCells = regionCells
        self.probeReliable = probeReliable
    }

    // The key names, in one place, exactly as core's grading schema spells them.
    public static let retentionKey = "retain_subfloor_in_unloaded_regions"
    public static let stressFractionKey = "subfloor_stress_fraction"
    public static let perRegionKey = "subfloor_per_region"
    public static let regionCellsKey = "report_region_cells"

    /// Nothing available — the value a job builder falls back to when it cannot
    /// ask, and the one tests use to pin the "controls untouched" path.
    public static let none = LatticeRetentionCapability(
        retention: false, stressFraction: false, perRegion: false,
        regionCells: false, probeReliable: false)

    /// Everything available — the shape of a core that carries all four keys.
    /// Tests drive the serializer with this so the emission is proven WITHOUT
    /// depending on which core happens to be vendored.
    public static let all = LatticeRetentionCapability(
        retention: true, stressFraction: true, perRegion: true,
        regionCells: true, probeReliable: true)

    /// Read from the linked core, once. `static let` is lazy in Swift, so the four
    /// parses happen on first use and never again.
    public static let fromCore: LatticeRetentionCapability = {
        let reliable = TopOptKit.gradingSchemaProbeIsReliable
        return LatticeRetentionCapability(
            retention: TopOptKit.gradingSchemaAccepts(key: retentionKey),
            stressFraction: TopOptKit.gradingSchemaAccepts(key: stressFractionKey),
            perRegion: TopOptKit.gradingSchemaAccepts(key: perRegionKey),
            regionCells: TopOptKit.gradingSchemaAccepts(key: regionCellsKey),
            probeReliable: reliable)
    }()

    /// Core's OWN default stress-fraction ceiling — the number
    /// `subfloor_stress_fraction` overrides. Read from core, never authored here:
    /// the app shows it, and omits the key entirely when the user has not moved
    /// off it, so core takes its own constant at call time.
    public static var coreStressFractionDefault: Double {
        TopOptKit.latticeSubfloorStressFractionDefault
    }

    /// Why a dependent control is unavailable, in the user's terms. nil ⇒ offered.
    public func unavailableReason(forPerRegion: Bool = false,
                                  forRegionCells: Bool = false) -> String? {
        let have = forRegionCells ? regionCells : (forPerRegion ? perRegion : retention)
        if have { return nil }
        if !probeReliable {
            return "The app couldn’t ask this core what it accepts, so it won’t "
                 + "send a setting that might stop the job before it starts."
        }
        return "The core on your Mac doesn’t take this setting yet — rebuild core "
             + "and this appears on its own."
    }
}

// MARK: - 1b · which cell_mode VALUES the linked core accepts

/// Whether the core the app is built against takes `"cell_mode": "fit"` (task
/// 2026-08-07-cell-mode-fit-and-swept-floor).
///
/// *** WHY A SECOND PROBE AND NOT `gradingSchemaAccepts`. *** That one asks about a
/// grading KEY, and `cell_mode` has been an accepted key since the cell-size sweep
/// landed. What grew afterwards is the SET OF VALUES it takes — "fit" arrived with
/// PR 302 — and a core that predates it does not ignore the value, it fails the whole
/// job with `grading "cell_mode" must be "fixed", "auto" or "swept"`. Same fatal
/// shape as an unknown key, different question, so it needs its own probe rather than
/// a hardcoded "core has this now" that is right on the day it is written.
public struct LatticeCellModeCapability: Equatable, Sendable {
    /// True iff the linked core's schema accepts `"cell_mode": "fit"`.
    public let fit: Bool
    /// False ⇒ the probe could not prove itself on this build (the same two-sided
    /// control `LatticeRetentionCapability` uses), so `fit` is a conservative false.
    public let probeReliable: Bool

    public init(fit: Bool, probeReliable: Bool) {
        self.fit = fit
        self.probeReliable = probeReliable
    }

    /// Nothing available — what a builder falls back to when it cannot ask.
    public static let none = LatticeCellModeCapability(fit: false,
                                                       probeReliable: false)
    /// Everything available. Tests drive the serializer with this so the emission is
    /// proven WITHOUT depending on which core happens to be vendored.
    public static let all = LatticeCellModeCapability(fit: true,
                                                      probeReliable: true)

    /// Read from the linked core, once (`static let` is lazy in Swift).
    public static let fromCore: LatticeCellModeCapability = {
        LatticeCellModeCapability(
            fit: TopOptKit.gradingSchemaAcceptsCellMode(
                LatticeCellSizeMode.fit.rawValue),
            probeReliable: TopOptKit.gradingSchemaProbeIsReliable)
    }()

    /// Why the control is unavailable, in the user's terms. nil ⇒ offered.
    public var unavailableReason: String? {
        if fit { return nil }
        if !probeReliable {
            return "The app couldn’t ask this core what it accepts, so it won’t "
                 + "send a setting that might stop the job before it starts."
        }
        return "The core on your Mac doesn’t take this setting yet — rebuild core "
             + "and this appears on its own."
    }
}

// MARK: - 2 · the control, its copy, and the exposure

/// The lattice page's retention control as a pure value: whether it is offered,
/// what it says, and — before any run — how much material it would lattice
/// without a certificate.
///
/// Every sentence here says WHAT CHANGES. The words "advanced", "expert" and
/// "unsafe" are deliberately absent: a user who is told a setting is "advanced"
/// learns nothing about their part.
public struct LatticeRetentionControl: Equatable, Sendable {
    /// The switch's title.
    public let title: String
    /// The one paragraph under it — what turning it on does.
    public let body: String
    /// True iff the switch can be operated at all.
    public let enabled: Bool
    /// Why not, when it cannot. nil ⇒ operable.
    public let disabledReason: String?
    /// The exposure, once a forecast for the current settings exists. nil ⇒ no
    /// forecast yet (the page says it is checking) or nothing is below the floor.
    public let exposure: String?
    /// True iff `exposure` describes material that WOULD be retained — the line is
    /// drawn as a warning rather than as information.
    public let exposureIsLive: Bool
    /// The stress-ceiling row's value text ("core’s 20%" / "12%").
    public let ceilingText: String
    /// Whether the ceiling row is shown at all (retention armed AND core takes it).
    public let showsCeiling: Bool

    public static let titleText = "Keep the lattice where the part is too thin to certify it"

    /// `belowFloorVoxels` / `regionVoxels` come from core's own pre-flight
    /// forecast (`subfloor_retention.voxels_below_floor` and `region_voxels`) — the
    /// app counts nothing itself. `ceilingFraction` is nil while the user is on
    /// core's own number.
    public static func compute(armed: Bool,
                               graded: Bool,
                               capability: LatticeRetentionCapability,
                               belowFloorVoxels: Int?,
                               regionVoxels: Int?,
                               ceilingFraction: Double?,
                               coreCeilingFraction: Double,
                               cellMode: LatticeCellSizeMode = .fixed)
        -> LatticeRetentionControl {
        let body =
            "This region’s members are thinner than a certified lattice needs. "
          + "Turn this on and the lattice is built anyway — the strength "
          + "certificate will not cover it, and the part is stamped out of regime."
        // Retention lives in the `grading` block, and a uniform lattice job has no
        // grading block at all, so there is nothing for core to read. Said as the
        // fact it is rather than greying the row in silence.
        var disabled: String? = nil
        if !graded {
            disabled = "Set Density mode to Auto — retention is part of the grading "
                     + "law, and a uniform lattice run carries no grading block for "
                     + "it to ride."
        } else if cellMode == .fit {
            // ★ THE FIT EXCLUSION, IN HIS TERMS. From where he sits these two solve
            // the same problem — "my regions are too thin, lattice them anyway" — so
            // the copy says WHICH TO USE WHEN rather than only that they conflict.
            // Core THROWS on the pair (grading.cpp:66-70) and the app must not let
            // him author that job.
            disabled = "Cell size is set to Per region, which already fits a cell to "
                     + "each region and reports what it emitted below the floor. "
                     + "Use Per region when your regions differ in thickness; use "
                     + "this switch when one cell has to serve them all. Only one "
                     + "of the two can decide a given piece of material, so core "
                     + "refuses a run that asks for both."
        } else if let why = capability.unavailableReason() {
            disabled = why
        }
        var exposure: String? = nil
        var live = false
        if let below = belowFloorVoxels, below > 0 {
            let of = regionVoxels ?? 0
            let pct = of > 0 ? Double(below) / Double(of) * 100 : 0
            let share = of > 0
                ? String(format: " — %.1f%% of the %@ voxels this lattice covers",
                         pct, fmt(of))
                : ""
            if armed {
                live = true
                exposure = "Up to \(fmt(below)) voxels\(share) would be latticed "
                    + "with no certificate over them. It is an upper bound: they are "
                    + "kept only where the region’s own peak stress measures at or "
                    + "under the ceiling below, and the run reports which."
            } else {
                exposure = "\(fmt(below)) voxels here\(share) are below the "
                    + "cells-across floor and will stay SOLID. Turning this on is "
                    + "what would lattice them."
            }
        } else if belowFloorVoxels == 0 {
            exposure = "Nothing in this lattice is below the cells-across floor, so "
                     + "this setting would change nothing on these settings."
        }
        let ceilingText = ceilingFraction
            .map { String(format: "%.0f%%", $0 * 100) }
            ?? String(format: "core’s %.0f%%", coreCeilingFraction * 100)
        return LatticeRetentionControl(
            title: titleText, body: body,
            enabled: disabled == nil, disabledReason: disabled,
            exposure: exposure, exposureIsLive: live,
            ceilingText: ceilingText,
            showsCeiling: armed && disabled == nil && capability.stressFraction)
    }

    private static func fmt(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

// MARK: - 3 · the per-region receipt, read back

/// One row of core's per-region report (`grading.regions[]` in the graded lattice
/// receipt, written when the job carried `grading.report_region_cells`).
///
/// ★ THE NUMBER THAT WOULD HAVE SAVED A NIGHT is `latticedVoxels == 0` on a named
/// region. The maintainer's overnight run emitted 1131 lattice cells into material
/// he never declared, and no file could tell him which of his seven regions got
/// what. This row is that file, read onto his screen.
public struct LatticeRegionCellRow: Equatable, Sendable {
    /// 1-based declaration order; 0 is core's anonymous row for "no include
    /// regions declared, here is the whole candidate set".
    public let regionID: Int
    public let candidateVoxels: Int
    public let latticedVoxels: Int
    public let solidVoxels: Int
    /// nil where core wrote `null` — the member is THICKER than the distance
    /// transform's cap, not thin and not unmeasured.
    public let minMemberWidthMM: Double?
    public let maxMemberWidthMM: Double?
    /// This region's peak von Mises over the PART's peak, measured on the
    /// variant's own field. Reported whether or not retention was armed.
    public let stressFraction: Double
    /// One of core's five: certified / out_of_regime / solid_load / no_pair /
    /// no_candidates.
    public let verdict: String
    public let exposureFraction: Double
    /// The nozzle at or under which this region's thinnest member would become
    /// latticeable. 0 when the region already lattices.
    public let nozzleNeededMM: Double
    /// Whether core found any (cell, density) pair that CERTIFIES the thinnest
    /// member here. ★ This is not "can it be latticed" — see `why`.
    public let feasibleAtThinnest: Bool
    /// The finest printable cell at the thinnest member (mm) — the number core's
    /// own refusal text tells the user to type into the cell-size control.
    public let minPrintableCellAtThinnestMM: Double
    /// The member width this region would need to clear the accuracy floor.
    public let memberWidthNeededMM: Double

    // ── WHAT THE LAW ACTUALLY DID HERE (review P2) ────────────────────────────
    // Joined by `region_id` from the OTHER per-region block in the same receipt,
    // `grading.subfloor_retention.regions[]` (core/src/cli/run_job.cpp), which core
    // has emitted since PR 295 whenever retention is armed. Without it a row can say
    // what the GEOMETRY allows but not what the RUN decided, and those are different
    // questions with different remedies.

    /// True iff this run armed sub-floor retention at all.
    public let retentionArmed: Bool
    /// The ceiling the region's stress had to come in under, as core reported it.
    public let retentionCeiling: Double
    /// Did THIS region measure as unloaded enough to keep sub-floor material?
    /// nil ⇒ retention was not armed, so the question was never asked.
    public let regionQualified: Bool?
    /// How many of this region's voxels were below the cells-per-member floor.
    public let belowFloorVoxels: Int
    /// How many of them the law actually kept as lattice.
    public let retainedVoxels: Int
    /// True iff the whole run blew the aggregate exposure cap, in which case
    /// NOTHING was retained anywhere and no region's own verdict is why.
    public let overBudget: Bool

    public init(regionID: Int, candidateVoxels: Int, latticedVoxels: Int,
                solidVoxels: Int, minMemberWidthMM: Double?,
                maxMemberWidthMM: Double?, stressFraction: Double,
                verdict: String, exposureFraction: Double,
                nozzleNeededMM: Double, feasibleAtThinnest: Bool,
                minPrintableCellAtThinnestMM: Double,
                memberWidthNeededMM: Double,
                retentionArmed: Bool = false, retentionCeiling: Double = 0,
                regionQualified: Bool? = nil, belowFloorVoxels: Int = 0,
                retainedVoxels: Int = 0, overBudget: Bool = false) {
        self.regionID = regionID
        self.candidateVoxels = candidateVoxels
        self.latticedVoxels = latticedVoxels
        self.solidVoxels = solidVoxels
        self.minMemberWidthMM = minMemberWidthMM
        self.maxMemberWidthMM = maxMemberWidthMM
        self.stressFraction = stressFraction
        self.verdict = verdict
        self.exposureFraction = exposureFraction
        self.nozzleNeededMM = nozzleNeededMM
        self.feasibleAtThinnest = feasibleAtThinnest
        self.minPrintableCellAtThinnestMM = minPrintableCellAtThinnestMM
        self.memberWidthNeededMM = memberWidthNeededMM
        self.retentionArmed = retentionArmed
        self.retentionCeiling = retentionCeiling
        self.regionQualified = regionQualified
        self.belowFloorVoxels = belowFloorVoxels
        self.retainedVoxels = retainedVoxels
        self.overBudget = overBudget
    }

    /// The member's span in cells at core's own finest printable cell — the same
    /// division core does (`cells_per_member_at_finest`, lattice.cpp), over two
    /// numbers this receipt already carries. nil when either is missing.
    public var cellsPerMemberAtFinest: Double? {
        guard let w = minMemberWidthMM, minPrintableCellAtThinnestMM > 0 else {
            return nil
        }
        return w / minPrintableCellAtThinnestMM
    }

    /// ★ CAN THIS MEMBER BE BUILT AT ALL, as opposed to CERTIFIED?
    ///
    /// Core carries TWO floors and its own header says so in as many words: the
    /// ACCURACY floor (5 cells), below which the homogenized tensor stops describing
    /// the member and the certificate goes out of regime — and the PERCOLATION floor
    /// (1 cell), below which there is no connected strut network and the generator
    /// emits debris. "A pipeline that refuses both with one message is collapsing two
    /// verdicts that need different answers", and this row's `no_pair` message was
    /// doing exactly that.
    ///
    /// `percolationFloor` is read from core (`latticeCellBounds`), never authored.
    /// nil ⇒ core states no percolation floor, so the question cannot be answered
    /// and the copy does not pretend to.
    public func buildableAtFinestCell(percolationFloor: Double?) -> Bool? {
        guard let n = percolationFloor, n > 0, let c = cellsPerMemberAtFinest else {
            return nil
        }
        return c >= n
    }

    /// Got nothing at all — the headline case.
    public var receivedNothing: Bool { latticedVoxels == 0 }

    /// The row's name on screen. `label` is the app's own name for that region
    /// (the selection group's, in the SAME order the job emitted include entries);
    /// absent ⇒ the ordinal, which is still an identity core and the app agree on.
    public func name(label: String?) -> String {
        if regionID == 0 { return "The whole part (no include regions declared)" }
        if let l = label, !l.isEmpty { return "\(l) (region \(regionID))" }
        return "Region \(regionID)"
    }

    /// WHY, in the user's words — core's verdict expanded with core's own numbers.
    ///
    /// *** EVERY BRANCH HERE NAMES THE REASON THE CODE ACTED ON, NOT A REASON THAT
    /// SOUNDS RIGHT. *** Three of the five originally did not (review P2), and one of
    /// them — "no cell size works here" — was contradicted by another row in the same
    /// receipt: two regions with the SAME 4.00 mm members, one told nothing could be
    /// latticed there and the other latticed in full. Nothing geometric separates
    /// them. `at_thinnest.feasible` is a pure function of (member width, nozzle), so
    /// identical members give identical feasibility; what actually differed was
    /// whether the RETENTION PREDICATE kept the material —
    /// `retain_subfloor && region_qualified(e) && !over_budget`, at
    /// `core/src/simp/grading.cpp:367` and `:502`, where `qualified` is
    /// `stress_fraction <= ceiling` (`grading.cpp:205`). A stress measurement, never
    /// a thickness one.
    ///
    /// `percolationFloor` comes from core (`latticeCellBounds`); pass nil and the
    /// buildable-vs-certifiable sentence is omitted rather than guessed.
    public func why(percolationFloor: Double?) -> String {
        switch verdict {
        case "no_candidates":
            // MEASURED: candidate_voxels == 0 (run_job.cpp:2298). That is "no voxel
            // carrying this region's id reached the lattice pass" — which the
            // optimizer leaving the space empty would cause, but so would an exclude
            // region covering it, or the region sitting outside the solved area. The
            // old copy asserted one of those three as fact.
            return "No material reached the lattice pass under this region — nothing "
                 + "carrying its id was a candidate. Either the optimizer left the "
                 + "space empty, an exclude region covers it, or it falls outside "
                 + "the solved area."
        case "no_pair":
            // MEASURED: latticed == 0 AND at_thinnest.feasible == false
            // (run_job.cpp:2323). `feasible` is the CERTIFIABILITY test — no cell is
            // both printable at this nozzle and coarse enough for 5 cells to span the
            // member. It says nothing about whether a lattice can be BUILT here.
            var s = "No cell size can CERTIFY this member: nothing is both printable "
                  + "at your nozzle and coarse enough for the homogenized model to "
                  + "describe it."
            switch buildableAtFinestCell(percolationFloor: percolationFloor) {
            case .some(true):
                // Buildable and uncertifiable — the regime retention exists for.
                s += String(format:
                    " It CAN still be built: at core's finest printable cell "
                  + "(%.2f mm) this member spans %.1f cells, above the %g cell the "
                  + "struts need to connect. That lattice would print and its certificate "
                  + "would be out of regime — which is what the “keep the lattice "
                  + "where the part is too thin to certify it” switch is for.",
                    minPrintableCellAtThinnestMM,
                    cellsPerMemberAtFinest ?? 0, percolationFloor ?? 0)
            case .some(false):
                s += String(format:
                    " It cannot be built either: at core's finest printable cell "
                  + "(%.2f mm) this member spans only %.1f cells, below the %g cell the "
                  + "struts need to connect, so the generator would emit loose "
                  + "fragments rather than a lattice.",
                    minPrintableCellAtThinnestMM,
                    cellsPerMemberAtFinest ?? 0, percolationFloor ?? 0)
            case nil:
                break
            }
            if memberWidthNeededMM > 0 {
                s += String(format: " To CERTIFY it the member would need %.2f mm.",
                            memberWidthNeededMM)
            }
            if nozzleNeededMM > 0 {
                s += String(format: " A nozzle of %.2f mm or finer would also do it.",
                            nozzleNeededMM)
            }
            return s + retentionClause
        case "solid_load":
            // MEASURED: latticed == 0 with a feasible pair (run_job.cpp:2331). Core's
            // own comment calls the load-carrying fallback an inference on this path
            // ("On this path that is the load-carrying fallback"), so state the
            // measurement and the inference apart. The old copy asserted "it is
            // carrying load" as fact.
            return String(format:
                "Kept solid, and NOT because it is too thin — the geometry here "
              + "admits a certified cell. Its peak stress measures %.0f%% of the "
              + "part's peak; on this path what remains is the demand-driven "
              + "fallback keeping it solid.", stressFraction * 100) + retentionClause
        case "out_of_regime":
            // MEASURED: latticed > 0, run-level retained > 0, and this region's
            // stress <= ceiling (run_job.cpp:2334). ★ `exposure_fraction` is
            // `gf.subfloor_retained_fraction_of_part` — the WHOLE RUN's retained
            // share, written onto every out-of-regime row. The old copy read as if
            // it were this region's own share of the part.
            var s = "Latticed, and the certificate does NOT cover it: this is the "
                  + "sub-floor material you asked to keep."
            if retainedVoxels > 0 {
                s += " \(Self.fmt(retainedVoxels)) voxels here were kept below the "
                   + "floor."
            }
            s += String(format:
                " Across the whole run, %.2f%% of the printed part is sub-floor "
              + "lattice. Cell size never enters the certification maths, so the "
              + "margin reads the same whether that lattice is fine or badly wrong.",
                exposureFraction * 100)
            return s
        case "certified":
            // MEASURED: latticed > 0 and it did not qualify as retained sub-floor.
            // A `certified` row can still hold solid voxels, so do not claim the
            // whole region latticed — the counts line beside this says which.
            return "The lattice here is inside the certified regime."
        default:
            return verdict.isEmpty ? "No verdict reported." : verdict
        }
    }

    /// What the RUN decided about keeping sub-floor material here — the half a
    /// geometry verdict cannot answer, read from `grading.subfloor_retention`.
    private var retentionClause: String {
        guard belowFloorVoxels > 0 else { return "" }
        if !retentionArmed {
            return " \(Self.fmt(belowFloorVoxels)) voxels here are below the "
                 + "cells-across floor and stayed solid because retention was off."
        }
        if overBudget {
            return " Retention was on, but the run’s TOTAL sub-floor material "
                 + "exceeded the aggregate exposure cap, so nothing was kept "
                 + "anywhere — not this region’s doing."
        }
        if regionQualified == false {
            return String(format:
                " Retention was on and this region did NOT qualify: its peak stress "
              + "measures %.1f%% of the part's peak, above the %.0f%% ceiling, so "
              + "its %@ below-floor voxels stayed solid. Raising the ceiling above "
              + "%.1f%% would keep them.",
                stressFraction * 100, retentionCeiling * 100,
                Self.fmt(belowFloorVoxels), stressFraction * 100)
        }
        return ""
    }

    /// The one-line counts.
    public func countsLine() -> String {
        var s = "\(Self.fmt(latticedVoxels)) of \(Self.fmt(candidateVoxels)) voxels "
              + "latticed · \(Self.fmt(solidVoxels)) left solid"
        if let lo = minMemberWidthMM {
            let hi = maxMemberWidthMM
            s += hi.map { String(format: " · members %.2f–%.2f mm", lo, $0) }
                ?? String(format: " · members from %.2f mm", lo)
        }
        return s
    }

    static func fmt(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

/// The whole per-region report, read off the graded lattice receipt.
public struct LatticeRegionCellReceipt: Equatable, Sendable {
    public let rows: [LatticeRegionCellRow]

    public init(rows: [LatticeRegionCellRow]) { self.rows = rows }

    /// Read `grading.regions[]` out of a variant's lattice receipt. nil when the
    /// job did not ask for it (or the worker's core predates it) — never an empty
    /// report presented as "every region got something".
    public static func parse(_ data: Data) -> LatticeRegionCellReceipt? {
        guard let root = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any],
              let grading = root["grading"] as? [String: Any],
              let list = grading["regions"] as? [[String: Any]],
              !list.isEmpty
        else { return nil }
        // ── THE OTHER PER-REGION BLOCK IN THE SAME FILE (review P2). Core has
        // emitted `grading.subfloor_retention.regions[]` since PR 295 whenever
        // retention is armed — region_id, the MEASURED stress fraction, whether that
        // region qualified, how many voxels were below the floor and how many were
        // kept. Joined by region_id, it is what lets a row say what the RUN decided
        // rather than only what the GEOMETRY allows. Absent (retention off, or an
        // older core) ⇒ every field stays at its "never asked" default.
        let sub = grading["subfloor_retention"] as? [String: Any] ?? [:]
        let armed = sub["armed"] as? Bool ?? false
        let ceiling = sub["stress_fraction_ceiling"] as? Double ?? 0
        let overBudget = sub["over_budget"] as? Bool ?? false
        var byID: [Int: [String: Any]] = [:]
        for r in (sub["regions"] as? [[String: Any]] ?? []) {
            if let id = r["region_id"] as? Int { byID[id] = r }
        }
        let rows = list.map { r -> LatticeRegionCellRow in
            let width = r["member_width_mm"] as? [String: Any] ?? [:]
            let thin = r["at_thinnest_member"] as? [String: Any] ?? [:]
            let id = r["region_id"] as? Int ?? 0
            let s = byID[id]
            return LatticeRegionCellRow(
                regionID: id,
                candidateVoxels: r["candidate_voxels"] as? Int ?? 0,
                latticedVoxels: r["latticed_voxels"] as? Int ?? 0,
                solidVoxels: r["solid_voxels"] as? Int ?? 0,
                // `null` is core's honest encoding of "thicker than the distance
                // transform's cap" — kept as nil, never flattened to 0, which a
                // reader would take for a vanishingly thin member.
                minMemberWidthMM: width["min"] as? Double,
                maxMemberWidthMM: width["max"] as? Double,
                stressFraction: r["stress_fraction"] as? Double ?? 0,
                verdict: r["verdict"] as? String ?? "",
                exposureFraction: r["exposure_fraction"] as? Double ?? 0,
                nozzleNeededMM: r["nozzle_needed_mm"] as? Double ?? 0,
                feasibleAtThinnest: thin["feasible"] as? Bool ?? false,
                minPrintableCellAtThinnestMM:
                    thin["min_printable_cell_mm"] as? Double ?? 0,
                memberWidthNeededMM: thin["min_member_width_mm"] as? Double ?? 0,
                retentionArmed: armed,
                retentionCeiling: ceiling,
                // nil, not false: with retention off the question was never asked,
                // and "did not qualify" would be a verdict nothing reached.
                regionQualified: armed ? (s?["qualified"] as? Bool) : nil,
                belowFloorVoxels: s?["below_floor_voxels"] as? Int ?? 0,
                retainedVoxels: s?["retained_voxels"] as? Int ?? 0,
                overBudget: overBudget)
        }
        return LatticeRegionCellReceipt(rows: rows)
    }

    /// Regions that received NO lattice at all, in declaration order.
    public var emptyRegions: [LatticeRegionCellRow] { rows.filter { $0.receivedNothing } }

    /// THE HEADLINE, and it leads with the empty regions BY NAME. `labels` is the
    /// app's own name per region id (1-based include order); pass what you have.
    public func headline(labels: [Int: String] = [:]) -> String {
        let empty = emptyRegions
        guard !empty.isEmpty else {
            return rows.count == 1
                ? "The one region core reported all received lattice."
                : "All \(rows.count) regions received lattice."
        }
        let names = empty.map { $0.name(label: labels[$0.regionID]) }
        if names.count == rows.count {
            return "NONE of your regions received any lattice: "
                 + names.joined(separator: ", ") + "."
        }
        return "\(names.count) of \(rows.count) regions received NO lattice: "
             + names.joined(separator: ", ") + "."
    }

    /// One block of lines per region, empty regions FIRST — the order a user
    /// scanning for what went wrong needs, not declaration order.
    ///
    /// `percolationFloor` is core's own (`latticeCellBounds`), and it is what lets a
    /// row separate "cannot be certified" from "cannot be built". Omit it and that
    /// sentence is left out rather than guessed.
    public func lines(labels: [Int: String] = [:],
                      percolationFloor: Double? = nil) -> [String] {
        let ordered = emptyRegions + rows.filter { !$0.receivedNothing }
        return ordered.map { r in
            "\(r.name(label: labels[r.regionID])): \(r.countsLine()). "
                + r.why(percolationFloor: percolationFloor)
        }
    }

    /// WHAT CORE DOES AND DOES NOT COUNT HERE, said rather than implied. The
    /// report is per-VOXEL and graded-path only; per-region EMITTED CELL counts
    /// and the uniform path are not in core yet (the concurrent cell-size work
    /// flags this as its own largest remaining gap). Claiming "cells" for a voxel
    /// count would be exactly the relabelling this project keeps getting bitten by.
    public static let scopeNote =
        "Counted in VOXELS, not emitted cells, and only on a graded (Auto density) "
      + "run — that is what core measures per region today. A uniform lattice run "
      + "still has no per-region breakdown."
}
