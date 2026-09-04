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
    /// ★★ A SOLID OUTER SHELL OVER THE LATTICE (maintainer, 2026-08-19: "It might
    /// be worth adding a 'Covered' finish? For anyone who doesn't care about
    /// seeing the lattice?").
    ///
    /// ★ IT IS A DIFFERENT AXIS FROM THE OTHER THREE, AND CORE ALREADY HAS IT.
    /// `skin` is what happens at the lattice's BOUNDARY (none / rim / diagrid);
    /// `outer_finish` is what the OUTER SURFACE is (shell / skin / shell+skin) —
    /// core/src/cli/job.cpp:1433. A solid cover is `outer_finish: "shell"`, and
    /// the app has never sent that field at all, so this exposes a capability
    /// rather than inventing one.
    ///
    /// ★ AND IT IS WHAT THE WITHDRAWN "SKIN" CUT ACTUALLY BUILT — the lattice
    /// eroded by the printed wall ring, leaving a solid slab. Right geometry,
    /// wrong name. It moves here where it is honest.
    case covered

    /// ★★ THIS IS NOT A SOLID WALL, AND THE FIRST CUT MADE IT ONE (maintainer,
    /// 2026-08-19: "The skin is incorrect. It's adding a FULL skin back onto the
    /// lattice. There is no point in doing that. The skin is supposed to be like
    /// it is in the settings: a covering across all edges/corners. Meanwhile, rim
    /// is supposed to be around only the outside edges").
    ///
    /// ★ WHAT THE TWO TREATMENTS ACTUALLY ARE, as the wizard's own sample block
    /// draws them and as core builds them:
    ///
    ///   rim ....... thickened struts along the region's boundary EDGES only —
    ///               a frame around the block, faces left open.
    ///   fullSkin .. that rim PLUS a woven DIAGRID across the faces — a surface
    ///               LATTICE, still open, not a slab.
    ///
    /// ★ THE FIRST CUT READ "skin" AS "solid offset shell" and returned the
    /// printed wall ring as a thickness to erode the lattice by. That produced a
    /// solid wall over the struts, which is not what core makes, not what the
    /// sample block shows, and hides the very thing the preview exists to show.
    /// It is withdrawn rather than left in as an approximation: a preview that
    /// draws a slab where the run builds a diagrid is a confident wrong answer.
    ///
    /// Returning 0 means the preview does not yet DRAW either treatment — an
    /// honest absence. The plumbing that carries the choice to the bake stays, so
    /// the diagrid and the rim have somewhere to land.
    /// ★ ONLY `covered` HAS A THICKNESS. `rim` and `fullSkin` are LATTICE
    /// geometry — a frame of edge struts, and a diagrid woven across the faces —
    /// and neither is an offset the preview can express by eroding, which is what
    /// made the first cut wrong. They return 0 and are drawn by D1.
    ///
    /// The number for `covered` is the ring the slicer lays down,
    /// `PrintParams.wallRingMM`: a cover thinner than the printer's own walls
    /// would promise a part the machine cannot make.
    public func faceSkinMM(wallRingMM: Double) -> Double {
        self == .covered ? Swift.max(0, wallRingMM) : 0
    }

    /// ★ THE PREVIEW'S DRESSING LEVEL: 0 none · 1 rim (edges only) · 2 diagrid
    /// (the whole boundary). `covered` dresses nothing — it is a solid wall over
    /// the lattice, drawn by the skin field, not a heavier strut.
    public var previewDressingLevel: Float {
        switch self {
        case .none, .covered: return 0
        case .rim: return 1
        case .fullSkin: return 2
        }
    }

    /// ★ `job.lattice.outer_finish` — "shell" for a cover, nil otherwise so every
    /// pre-existing job stays byte-identical. Core refuses "skin"/"shell+skin"
    /// unless `skin == "diagrid"` (job.cpp:1438), so only the unambiguous value
    /// is ever emitted here.
    public var jobOuterFinish: String? { self == .covered ? "shell" : nil }

    /// The exact core job-schema value (`job.lattice.skin`).
    public var jobSkinValue: String {
        switch self {
        case .none: return "none"
        case .rim: return "rim"
        case .fullSkin: return "diagrid"
        // ★ A COVER IS AN OUTER FINISH, NOT A BOUNDARY TREATMENT — the lattice
        // underneath still runs to the edge, so `skin` stays "none" and
        // `jobOuterFinish` carries the cover.
        case .covered: return "none"
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
/// ★★★ THE GRADING OPTIONS (his request, 2026-08-25: "add two new settings for
/// the grading options"). How the CELL is allowed to vary inside a region —
/// STEPPED algorithm only; Default's dyadic ladder is untouched by his ruling.
///
///   full      everything shipped so far: the cells grade to fit the face's
///             shape near the outline AND the density follows the stress field
///             where one governs.
///   fitShape  "Grade to fit Shape" — the cells grade near the outline only;
///             the density is ONE number everywhere (the dial, or Auto).
///   none      "No grade" — one cell, one density; the per-face Cell size is
///             the dial. (The per-spot material rule still applies — a cell
///             never exceeds its own wall; that is sizing, not grading.)
public enum LatticeGradingMode: String, Equatable, Sendable, Codable {
    /// Stress + shape — the density follows the solve AND the cells fit the outline.
    case full
    /// Shape only — the cells fit the outline; one density everywhere.
    case fitShape
    /// ★ Stress only (his 2026-08-25 restructure): the density follows the solve,
    /// the cell stays one size. No shape band applies.
    case stressOnly
    /// No grade at all — one cell, one density.
    case none

    /// Does this mode grade the CELL to the face's outline? Only these two offer
    /// the shape band.
    public var fitsShape: Bool { self == .full || self == .fitShape }
    /// Does the SOLVE decide the density here?
    public var followsStress: Bool { self == .full || self == .stressOnly }
}

/// ★ HOW THE FIT-SHAPE GRADE STEPS DOWN — his "either stepped or default
/// (dyadic) options": stepped admits every integer divisor (S/2, S/3, S/4 …),
/// dyadic halves (S/2, S/4, S/8) so every graded cell shares nodes with its
/// parent.
public enum LatticeGradeStepStyle: String, Equatable, Sendable, Codable {
    case stepped, dyadic
}

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
    /// ★★ THE FACE'S REAL OUTLINE, in the plane's (u, v) mm relative to `origin`
    /// — see `LatticeFaceOutline` for the measurement that made this necessary.
    /// EMPTY means "no outline was available", and then the region is the
    /// rectangle `halfUMM`×`halfWMM` exactly as it always was, which is what a
    /// bolt, a hand-placed primitive and every pre-outline project get.
    public var outlineLoops: [[SIMD2<Double>]] = []
    /// ★ THE IN-PLANE REACH, kept as its own number instead of being folded into
    /// the half-extents. Against an OUTLINE the expand is Minkowski dilation by a
    /// ball — `signedDistance <= inPlaneOffsetMM` — which is precisely what
    /// `FaceOffsetShell.dilated` does to the primitive on screen. Folding it into
    /// halfU/halfW could only ever grow a rectangle.
    public var inPlaneOffsetMM: Double = 0
    /// ★ The B-rep face this region was spawned from (task 2026-08-12 §0a), or
    /// nil for a hand-placed primitive. Emitted as the job's `face_id` so CORE
    /// can check the depth tie: a face that is both protected and latticed must
    /// carry ONE depth, and core refuses the job when it carries two.
    public var faceID: Int? = nil
    /// ★ The density the user DIALLED for this region (task
    /// 2026-08-16-per-sector-density-override), or nil for auto. Emitted as the
    /// job's `relative_density`; absent when nil, so a job with no override is
    /// byte-identical to a pre-task one. Never set on an exclude region.
    public var relativeDensity: Double? = nil

    public init(role: LatticeGroupRole, kind: Kind) {
        self.role = role
        self.kind = kind
    }

    /// ★ THE ONE WIRE ENCODER for a lattice region (task
    /// 2026-08-16-per-sector-density-override). There were TWO hand-copied
    /// copies of this dictionary — RemoteRunner's optimize job and
    /// RelatticeRunner's re-lattice job — and they had ALREADY diverged: the
    /// re-lattice copy dropped `face_id`. Adding a third field to both by hand is
    /// exactly the one-sided edit RelatticeRunner's own header says it collapsed
    /// the grading dictionary to prevent. So both now call this.
    ///
    /// The `face_id` divergence is closed as a side effect and is provably inert:
    /// the re-lattice path's regions come from `variantRegions`, which emits only
    /// from manual primitives and never sets `faceID`, so the key was nil there
    /// and stays absent. Its bytes do not move.
    public var wireDictionary: [String: Any] {
        // ★★ THE OUTLINE GOES ON THE WIRE, and core now reads it. The first
        // attempt was withdrawn because `topopt-cli` rejected the key outright
        // ("unknown key \"in_plane_offset_mm\""); core's schema accepts
        // `outline_uv` as of this change, and `region_contains` tests it.
        //
        // ★ THE HALF-EXTENTS STAY, and are still required: they are the outline's
        // BOUNDING BOX, which core uses as the cheap reject before the polygon
        // test. A genuinely rectangular face omits the outline and behaves exactly
        // as it always did.
        //
        // ★ AND THE (u, w) FRAME IS CORE'S — see `LatticeRegionMask.basis`. The
        // app moved onto core's `plane_basis` order rather than negating here,
        // because a conversion at the boundary is a second place for the sign to
        // be wrong.
        var faceGeometry: [String: Any] = [
            "origin": [origin.x, origin.y, origin.z],
            "normal": [normal.x, normal.y, normal.z],
            "half_u_mm": halfUMM,
            "half_w_mm": halfWMM,
            "depth_mm": depthMM,
        ]
        if !outlineLoops.isEmpty {
            faceGeometry["outline_uv"] = outlineLoops.map { loop in
                loop.map { [$0.x, $0.y] }
            }
        }
        let geometry: [String: Any] = kind == .face
            ? faceGeometry
            : [
                "axis_point": [axisPoint.x, axisPoint.y, axisPoint.z],
                "axis_dir": [axisDir.x, axisDir.y, axisDir.z],
                "radius_mm": radiusMM,
                "half_length_mm": halfLengthMM,
            ]
        var entry: [String: Any] = ["role": role.rawValue, "kind": kind.rawValue,
                                    "geometry": geometry]
        // The face this region was spawned from (task 2026-08-12 §0a) — core uses
        // it to refuse a job whose protection depth and lattice depth for the same
        // face disagree.
        if let fid = faceID { entry["face_id"] = fid }
        // The DIALLED density. Absent means AUTO means core derives, so a project
        // that never touched it produces the identical job (bar R1).
        if let rho = relativeDensity { entry["relative_density"] = rho }
        return entry
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
/// ★ THREE MODES, NOT FOUR (task 2026-08-15-lattice-and-face-ui §8).
///
///     AUTO        density derived from the FEA        ← the default, unchanged
///     UNIFORM     one density everywhere              ← unchanged
///     PER REGION  each region states its own          ← NEW
///
/// ★ "SWEPT" IS NOT ONE OF THEM and never was: the only `swept` in this file is
/// `LatticeCellSizeMode.swept`, which belongs to CELL SIZE and only to cell size.
/// §8(a) asked for a swept DENSITY option to be removed if one existed anywhere in
/// code or copy — none does, and this comment is the record of that check.
///
/// ★ `perRegion` IS "NOT AUTO" EVERYWHERE. Every existing site tests `== .auto`,
/// so a per-region job takes the ungraded path exactly as `uniform` does; the
/// per-region numbers are captured by the UI and, until PR 331's per-sector
/// density override lands in core, NOT consumed by the run. That gap is asserted
/// in `FrozenRegionAsMaterialTests` and surfaced on the row — never silent.
public enum LatticeDensityMode: String, Codable, Equatable, Sendable {
    case uniform
    /// ★★ RENAMED FROM `auto` (maintainer, 2026-08-17: "If Density's 'auto' is
    /// meant to be 'Sim' I think it should change names. However, if there is a
    /// way to automate *without* using an FEA sim, then keep the 'Auto'").
    ///
    /// ★ THERE IS NO SUCH WAY, WHICH IS WHY THE NAME CHANGED RATHER THAN GAINING
    /// AN ASTERISK. This mode is the ONLY thing that puts a `grading` block in
    /// the job (`LatticeSpec.gradingDictionary` returns nil unless `graded`), and
    /// core's grading law is a map FROM a per-voxel demand field — the von Mises
    /// field an FEA produces. With no field there is nothing to grade by, so
    /// "automatic" here has never meant anything except "simulated". The old
    /// name described the interaction ("I don't have to type a number") and hid
    /// the mechanism ("a finite-element solve decides it"), which is the half
    /// that matters when you are deciding whether to trust the result.
    case sim
    /// ★ §8 — each region states its own density. Reveals PR 334's conditional
    /// drawer row (`LatticeRegionDrawer.make(perRegionDensity:)`), which is the
    /// whole of the wiring that mode was built for and could not reach.
    case perRegion

    /// ★ Two words at most (R14).
    public var title: String {
        switch self {
        case .sim: return "Sim"
        case .uniform: return "Uniform"
        case .perRegion: return "Per region"
        }
    }

    /// ★ WHETHER THIS MODE NEEDS A STRESS FIELD. One property, so every gate —
    /// the settings sheet, the solve trigger, the preview — asks the same
    /// question instead of each testing `== .sim` in its own words.
    public var needsSimulation: Bool { self == .sim }

    // ★ EVERY PROJECT ON DISK SAYS "auto", AND MUST KEEP OPENING. The rename is
    // a LABEL change, not a data migration: a stored `"auto"` decodes to `.sim`,
    // which is the same mode it always was. Encoding writes the new spelling, so
    // a project re-saved once stops carrying the old word — but nothing forces
    // that, and a project never re-saved still opens forever.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "auto" { self = .sim; return }
        guard let v = LatticeDensityMode(rawValue: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "unknown density mode \(raw)"))
        }
        self = v
    }
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
/// ★★ HOW AUTO CHANGES THE CELL FROM PLACE TO PLACE (maintainer, 2026-08-20: "If
/// 'Auto' is selected for cell size, a secondary question needs to become visible:
/// 1. Stepped 2. Default Grade 3. Organic Grade").
///
/// ★★★ ALL THREE ARE NOW WIRED (maintainer, 2026-08-21: "Please connect the Stepped
/// and Organic algos"). This enum IS core's `LatticeAlgorithm`, in the app's words:
///
///     stepped      -> "stepped"   one cell per declared region, taken VERBATIM
///     defaultGrade -> "doubled"   the dyadic ladder — THE DEFAULT
///     organicGrade -> "organic"   struts traced along the stress field
///
/// ★ THE PREVIOUS DOCTRINE HERE IS SUPERSEDED, NOT DELETED, AND THIS RECORDS WHY. It
/// said the other two were "not wired yet" and gave two reasons: stepped needs a rule
/// for what happens at an unshared seam, and organic needs cells off the ladder that
/// stop being cubic. BOTH REASONS WERE TRUE AND BOTH ARE NOW ANSWERED IN CORE, not
/// argued away here:
///
///   * `stepped` does not pretend the seam is fine — core COUNTS the floating strut
///     ends it produces (`LatticeSteppedStats::floating_ends`) and puts them on the
///     receipt. Measured on main: 4 of 5 abutting region pairs come out mechanically
///     disconnected. That is a number the user gets to see, not a silent reject.
///   * `organic` is exactly why the AESTHETIC mode exists. A traced lattice is
///     anisotropic by construction, so `run_job` REFUSES it under a structural claim
///     rather than certifying against a cubic tensor that does not describe it. The
///     old note's "one cubic tensor per topology" is that refusal, now enforced by
///     core and surfaced at the picker (`LatticeSettings.algorithmRefusalReason`).
///
/// So the availability rule below is no longer a hard-coded "not yet": it ASKS CORE.
public enum LatticeCellTransition: String, Codable, Hashable, Sendable, CaseIterable {
    case stepped
    case defaultGrade
    case organicGrade

    public var title: String {
        switch self {
        case .stepped: return "Stepped"
        case .defaultGrade: return "Default Grade"
        case .organicGrade: return "Organic Grade"
        }
    }

    /// ★★ CORE'S OWN ALGORITHM NAME. The one place the two vocabularies meet, so a
    /// picker built on this enum and a job built on that string cannot drift.
    public var coreAlgorithm: String {
        switch self {
        case .stepped:      return "stepped"
        case .defaultGrade: return "doubled"
        case .organicGrade: return "organic"
        }
    }

    /// nil ⇒ available. ★ ASKED OF CORE, never hard-coded: an algorithm core does not
    /// know is unavailable, and the reason names what is missing rather than promising
    /// a date. Replaces the old "not wired yet" pair — see the type's note for why both
    /// of those reasons are now answered in core.
    public var unavailableReason: String? {
        guard !TopOptKit.latticeAlgorithmIsKnown(coreAlgorithm) else { return nil }
        return "This build's core does not carry the \(title.lowercased()) algorithm."
    }

    public var body: String {
        switch self {
        case .stepped:
            return "One cell size per region, changing abruptly at the boundary."
        case .defaultGrade:
            return "Cell sizes double and halve on core's ladder, so coarse and fine "
                 + "cells meet at shared nodes."
        case .organicGrade:
            return "Cell size varies continuously with the stress."
        }
    }
}

/// ★★★ ORGANIC'S BOUNDARY FINISH — core's `organic_boundary_finish`, as its own name.
///
/// ★ A FINISH IS A LOOK, NOT A REPAIR (his ruling, and core honours it): the finish
/// runs LAST and the structural core of all three is byte-identical. So this changes
/// what the edge looks like and never what the lattice IS.
///
/// ★ `skin` IS THE DEFAULT AND IT IS THE SHARP ONE. It drops the shell, so every
/// clipped strut end becomes a cantilever unless the net-skin picks it up. That is
/// core's default, not a choice this app makes, and it is restated here only so the
/// picker can show it — the key is still written only when the user has moved it.
public enum LatticeOrganicFinish: String, Codable, Equatable, Sendable, CaseIterable {
    case clean, rim, skin

    /// Exactly core's spelling. One source for the picker and the job document, so
    /// they cannot drift.
    public var jobValue: String { rawValue }

    public var title: String {
        switch self {
        case .clean: return "Clean"
        case .rim:   return "Rim"
        case .skin:  return "Skin"
        }
    }
}

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

    /// ★ `job.lattice.outer_finish` — "shell" when the user picked **Covered**,
    /// nil otherwise so every job that does not use it is BYTE-IDENTICAL to the
    /// one before the option existed. See `LatticeBoundaryTreatment.covered`.
    public var outerFinish: String? = nil
    /// ★★ CORE'S `LatticeAlgorithm`, as its own name — "" means NOT STATED, so no key
    /// is written and core resolves it to doubled. A `var` with an empty default so
    /// every existing `LatticeSpec(...)` call is unchanged and produces the same job.
    public var algorithm: String = ""

    // ★ ORGANIC's seven keys, carried the same way `algorithm` is: plain `var`s with
    // core's own defaults, so every existing `LatticeSpec(...)` call site is unchanged
    // and produces the same job document. `gradingDictionary()` decides what is
    // actually written; nothing here is emitted merely by being set.
    public var organicGrowth: Bool = false
    public var organicStrutWidthMM: Double = 0
    public var organicOverhangDeg: Double = 0
    public var organicBoundaryFinish: String = LatticeOrganicFinish.skin.jobValue
    public var organicShapeFit: Bool = false
    public var organicShapeFitOnly: Bool = false
    public var organicScale: Double = 1
    /// The user's pick among certification's separations (0 ⇒ none; Fit lets core choose).
    public var organicPickedSeparationMM: Double = 0
    /// ★ THE LAYER HEIGHT THIS JOB WILL CARRY, for the growth precondition only.
    /// `organic_growth` is a SCHEMA REFUSAL without a stated `loads.layer_height_mm`,
    /// so the key is not written unless one is really there — the job document is the
    /// last place that rule can be enforced, and enforcing it only in the UI would let
    /// any other caller build a job that dies at parse.
    public var layerHeightMM: Double = 0
    /// The stage's Structural/Aesthetic choice, mirrored for the job's `intent`.
    /// Core refuses ORGANIC unless the job states `"intent": "aesthetic"` itself
    /// (run_job.cpp `refuse_organic_structural`), and no other algorithm reads it
    /// here, so an untouched project still emits byte-identically.
    public var stageMode: LatticeStageMode? = nil

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
        // ★★ THE ALGORITHM, ONLY WHEN STATED. An absent key is core's "not stated" and
        // resolves to doubled, so an untouched project's job is byte-identical to one
        // built before the selector existed. A name core does not know is never
        // written: `reject_unknown_keys` would kill the whole job over it, and a
        // job that dies after the solve is the worst place to learn about a typo.
        if TopOptKit.latticeAlgorithmIsKnown(algorithm) {
            grading["algorithm"] = algorithm
        }
        // ══════════════════════════════════════════════════════════════════════
        // ORGANIC — the seven keys, each written only when ALL of these hold.
        //
        // ★★★ NOTE FOR ANYONE LOOKING FOR A TOPOLOGY SWITCH: there isn't one.
        // Organic is chosen by `grading.algorithm`, NOT by `grading.topology` —
        // core SCHEMA-REFUSES any topology but "octet" (job.cpp ~1509), so an
        // organic run still says octet and that is correct, not a leftover.
        //
        //   1. THE USER CHOSE ORGANIC. Core refuses each of these keys under any
        //      other algorithm ("only allowed with algorithm organic"), so one of
        //      them beside octet kills the whole job after the solve.
        //   2. THE LINKED CORE KNOWS THE KEY. Runs use `reject_unknown_keys`, and
        //      this app is built against cores carrying three of these seven and
        //      cores carrying all seven. The probe is the only honest test.
        //   3. THE USER MOVED IT off core's own default. Restating a default is a
        //      DIFFERENT DOCUMENT from omitting it, and bar U1 is that an untouched
        //      project emits byte-identically to before organic existed.
        if algorithm == "organic" {
            func put(_ key: String, _ value: Any) {
                guard TopOptKit.gradingSchemaAccepts(key: key) else { return }
                grading[key] = value
            }
            if organicStrutWidthMM > 0 { put("organic_strut_width_mm", organicStrutWidthMM) }
            if organicOverhangDeg > 0 {
                // ★ TRACE ONLY — grown clamps to a compile-time 30 deg that no job key
                // reaches, so writing it under growth states a number core will ignore.
                if !organicGrowth { put("organic_overhang_angle_deg", organicOverhangDeg) }
            }
            if organicBoundaryFinish != LatticeOrganicFinish.skin.jobValue {
                put("organic_boundary_finish", organicBoundaryFinish)
            }
            if organicShapeFit { put("organic_shape_fit", true) }
            if organicShapeFitOnly { put("organic_shape_fit_only", true) }
            // ★ INTENT, STATED. Core refuses organic unless the job SAYS
            // "intent": "aesthetic" (run_job.cpp `refuse_organic_structural`): the
            // traced lattice is anisotropic and the certification library holds one
            // CUBIC tensor per topology, so a structural density would be certified
            // against a material this lattice is not. The stage's own word travels —
            // "aesthetic" runs; "structural" is refused by core with core's reason,
            // never quietly upgraded here. Measured on-device 2026-09-02: without
            // this key the organic run died at core's validation ("this job says
            // nothing").
            if let m = stageMode { put("intent", m == .structural ? "structural" : "aesthetic") }
            if organicScale != 1 { put("organic_scale", organicScale) }
            // ★ The user's pick among certification's separations (maintainer,
            // 2026-09-03). `put` refuses it until core's schema accepts the key, so a
            // pick is stored and shown but never sent to a core that would refuse.
            if organicPickedSeparationMM > 0 { put("organic_separation_mm", organicPickedSeparationMM) }
            // ★★★ GROWTH NEEDS A STATED LAYER HEIGHT — a SCHEMA REFUSAL since the
            // PR 353 amendment, not a fallback. Without one core would substitute half
            // a voxel (0.85 mm on the M2's 1.705 mm grid, roughly four times a real
            // layer) and compute the whole printability argument in the wrong
            // discretisation. So the key is simply not written without one, and the UI
            // disables the control and says why (`organicGrowthRefusalReason`).
            if organicGrowth, layerHeightMM > 0 { put("organic_growth", true) }
        }
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
    /// ★★★ WHICH QUESTION THIS LATTICE ANSWERS — asked ONCE, on entering the stage,
    /// and never editable afterwards (`LatticeStageMode`). nil ⇒ not yet chosen, which
    /// is what makes the modal appear; it is deliberately NOT defaulted, because a
    /// default would silently pick which claim the receipt makes.
    public var stageMode: LatticeStageMode?

    /// ★★★ WHICH KIND OF LATTICE IS LAID DOWN — core's `LatticeAlgorithm`, as its own
    /// name string. ORTHOGONAL to `cellSizeMode`: that says how the cell is CHOSEN,
    /// this says what is built.
    ///
    ///   "doubled" — the dyadic ladder. Cells of different size meet at SHARED NODES.
    ///   "stepped" — one cell per declared region, verbatim, NO transition handling;
    ///               abutting regions do not share nodes and core COUNTS the floating
    ///               strut ends rather than pretending otherwise.
    ///   "organic" — struts traced along the stress field.
    ///
    /// ★ EMPTY IS THE DEFAULT AND IT IS NOT "doubled". An empty string means NOT
    /// STATED: no `algorithm` key is written, so a job from untouched controls stays
    /// byte-identical to one built before the selector existed (bar U1). Core resolves
    /// an absent key to doubled itself.
    public var algorithm: String = ""

    /// ★★ THE ALGORITHM THE RUN WILL ACTUALLY USE, with "not stated" resolved — for
    /// display and for the preview, never for the job (which must keep the key absent).
    /// Falls back to core's first name rather than a Swift literal "doubled".
    public var resolvedAlgorithm: String {
        TopOptKit.latticeAlgorithmIsKnown(algorithm)
            ? algorithm : (TopOptKit.latticeAlgorithmNames.first ?? "doubled")
    }

    /// ★★★ WHY A CHOICE MAY BE REFUSED, in core's terms — nil when the pair is fine.
    ///
    /// `run_job` REFUSES organic under a structural claim: a traced lattice is
    /// anisotropic by construction and the certification library carries exactly one
    /// CUBIC tensor per topology, so there is nothing for the claim to be checked
    /// against. Surfacing it HERE means the user is told at the picker instead of by a
    /// job that dies after the solve — and the permission is core's answer, not a Swift
    /// `== "organic"`.
    public var algorithmRefusalReason: String? {
        guard TopOptKit.latticeAlgorithmIsKnown(algorithm) else { return nil }
        guard stageMode == .structural else { return nil }
        guard !TopOptKit.latticeAlgorithmAllowsStructural(algorithm) else { return nil }
        return "\(algorithm.capitalized) traces struts along the stress field, so the "
             + "lattice is anisotropic by construction — the certification library "
             + "holds one cubic stiffness per topology and there is nothing for a "
             + "strength claim to be checked against. It needs the Aesthetic mode."
    }

    /// Cell size (mm). Freely edited by the user; its certifiable CEILING (cells per
    /// member) is read from core at use, never stored here. The starting value is the
    /// print-tested octet cell reused from the proxy default — a start, not a limit.
    public var cellMM: Double
    /// How the cell size is chosen (bar R6). `.fixed` is the DEFAULT — the shipped
    /// legacy path, so an untouched project emits exactly today's job.
    /// How Auto varies the cell across the part — see `LatticeCellTransition`.
    /// Meaningful only when `cellSizeMode == .auto`; the other modes carry their own
    /// answer (Fit is per region, Swept is the ladder over the user's window).
    ///
    /// ★★★ COMPUTED OVER `algorithm`, NOT A SECOND STORED FIELD (2026-08-24). It was
    /// stored, and NOT in `CodingKeys` — so it decoded to `.defaultGrade` on every
    /// project load while `algorithm` decoded to what the user chose. The settings
    /// page then stamped `algorithm = cellTransition.coreAlgorithm` on save, and a
    /// project saved with "stepped" quietly became "doubled" the first time its
    /// settings page was SAVED after a relaunch — measured live: project.json said
    /// `algorithm = stepped`, the running guard said `algo='doubled'`. One value with
    /// two homes is how they drifted; now the algorithm string is the one home, and
    /// the picker state is a reading of it. `""` (not stated) reads as
    /// `.defaultGrade`, which is exactly how core resolves an unstated algorithm.
    public var cellTransition: LatticeCellTransition {
        get {
            LatticeCellTransition.allCases.first { $0.coreAlgorithm == algorithm }
                ?? .defaultGrade
        }
        set { algorithm = newValue.coreAlgorithm }
    }
    // ══════════════════════════════════════════════════════════════════════════
    // ORGANIC — the seven `organic_*` job keys.
    //
    // ★★★ EVERY ONE IS GATED TWICE and the gates are NOT the same question:
    //   1. the user chose organic  (`isOrganic`) — core REFUSES an organic_* key
    //      under any other algorithm (job.cpp: "only allowed with algorithm organic"),
    //      so emitting one beside octet kills the whole job;
    //   2. the LINKED core knows the key (`TopOptKit.gradingSchemaAccepts`) — runs use
    //      `reject_unknown_keys`, and this app is built against cores that carry three
    //      of these seven and cores that carry all seven.
    // Both live in `gradingBlock`, never here: this struct stores the user's raw pick
    // and nothing else, the same rule `cellSizeMode` follows.
    //
    // ★ NOT EXPOSED, DELIBERATELY. `OrganicParams` internals that no job key reaches —
    // test_ratio, seed_ratio, connect_ratio, step_ratio, thin_ratio, min_length_ratio,
    // families, max_curves, max_steps_per_curve, resolution_floor_voxels,
    // anchor_at_region_boundary, rho_min/rho_max. The UI must not invent them.

    /// ★★★ TRACED (false) vs GROWN (true) — core's `organic_growth`.
    ///
    /// ★ A DIFFERENT ARCHITECTURE, NOT A PARAMETER. Traced curves follow the stress
    /// field; grown ones are laid down in LAYER ORDER and refuse any step whose
    /// underside is unsupported. They share a name and nothing else.
    ///
    /// ★ AND IT HAS A HARD PRECONDITION — see `organicGrowthRefusalReason`. Growth asks
    /// its support question one layer at a time, so core SCHEMA-REFUSES it without a
    /// stated `loads.layer_height_mm` rather than substituting half a voxel (0.85 mm on
    /// the M2's 1.705 mm grid — about four times a real layer, which would compute the
    /// entire printability argument in the wrong discretisation).
    public var organicGrowth: Bool = false
    /// Strut width (mm). 0 ⇒ DERIVE from the density band and cell, which is core's
    /// own default; core refuses a stated value that is not > 0.
    public var organicStrutWidthMM: Double = 0
    /// Overhang limit, degrees, [0, 90].
    /// ★ TRACE ONLY. Grown clamps to a compile-time 30 deg that no job key reaches, so
    /// this control is DEAD in grown mode — see `organicOverhangIsLive`.
    public var organicOverhangDeg: Double = 0
    /// The edge treatment — see `LatticeOrganicFinish`. Core's default is `.skin`.
    public var organicBoundaryFinish: LatticeOrganicFinish = .skin
    /// Pull cells toward the region boundary.
    public var organicShapeFit: Bool = false
    /// Shape fit WITHOUT the stress grading.
    public var organicShapeFitOnly: Bool = false
    /// Uniform scale on the derived spacing.
    public var organicScale: Double = 1.0
    /// ★ THE SEPARATIONS CERTIFICATION FOUND (maintainer, 2026-09-03): after a run,
    /// core's receipt lists the separations that certified (`fitting_separations_mm`,
    /// D2); they are stored here so Settings can show them as the factored choices,
    /// and the pop-up can offer them. Empty until a run's receipt carries them.
    public var organicFittingSeparationsMM: [Double] = []
    /// The user's pick among those (0 ⇒ none picked; core chooses under Fit). Travels
    /// as `organic_separation_mm` the day core's schema accepts that key — gated in
    /// `gradingDictionary()` like every organic key, never sent to a core that refuses.
    public var organicPickedSeparationMM: Double = 0

    /// Is organic the chosen algorithm? Asked of the RESOLVED name, so "not stated"
    /// (which core resolves to doubled) is correctly not organic.
    public var isOrganic: Bool { resolvedAlgorithm == "organic" }

    /// ★★★ WHY GROWTH IS UNAVAILABLE — nil when it can be offered.
    ///
    /// The layer height travels in the job's `loads` block and is always written, so
    /// "stated" means a real number: a 0 reaches core as a stated zero and growth's
    /// support question has no discretisation to ask in. The UI disables the control
    /// and shows this, rather than letting the user arm a job that dies at parse.
    public func organicGrowthRefusalReason(layerHeightMM: Double) -> String? {
        Self.organicGrowthRefusalReason(layerHeightMM: layerHeightMM)
    }
    /// The same answer with no settings in hand — the wizard asks it of a draft.
    public static func organicGrowthRefusalReason(layerHeightMM: Double) -> String? {
        if !TopOptKit.gradingSchemaAccepts(key: "organic_growth") {
            return "This build's core does not carry the grown organic lattice."
        }
        if !(layerHeightMM > 0) {
            return "Grown organic lays the lattice down one printed layer at a time, "
                 + "so it needs the layer height. Set it in Print Parameters."
        }
        return nil
    }

    /// ★ IS THE OVERHANG CONTROL LIVE? Grown clamps to a compile-time constant no job
    /// key reaches, so offering the slider there is a dead knob.
    public var organicOverhangIsLive: Bool { isOrganic && !organicGrowth }

    public static let defaultShapeFitBandCells: Double = 1
    public var cellSizeMode: LatticeCellSizeMode
    /// The sweep window's ends (mm), used only in `.swept`. Stored as the user's raw
    /// pick; the lower end is clamped to CORE's printability floor at use
    /// (`LatticeBounds.cellFloorMM`), never to a number written here.
    public var cellMinMM: Double
    public var cellMaxMM: Double
    /// ★★★ HOW WIDE THE SHAPE-FIT GRADE IS, IN CELLS (his request, 2026-08-23: *"under
    /// the grading selection, include a slider/numeric input that sets a rim band that
    /// lets the user change how much of a gradient there is to fit the shape"*).
    ///
    /// The lattice already subdivides wherever a cell will not FIT inside the face's
    /// outline — that part is geometry and is not negotiable. This is the band on TOP of
    /// it: within `shapeFitBandMM` cells of the outline the lattice steps down a
    /// further level, so the grade reads as deliberate rather than only where the
    /// geometry forces it.
    ///
    /// MILLIMETRES in from the outline. 0 ⇒ fit only, no extra band (the strict
    /// geometric answer).
    public var shapeFitBandMM: Double
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
    /// ★ THE OUTER SURFACE UNDER ORGANIC — "the shape to fit does not include an
    /// outline and is ONLY lattice" (maintainer, 2026-09-03). Core's default
    /// `outer_finish` is a SOLID SHELL, which is an outline, so an organic job writes
    /// the bare surface ("skin") unless the user picked Covered. A bare surface is
    /// only schema-legal with `skin: "diagrid"` (job.cpp: "the diagrid IS the outer
    /// finish that replaces or dresses the shell"); on the organic path core never
    /// hands that skin spec to the generator (run_job.cpp: `generate_organic_lattice(
    /// *organic, w, &boundary, …)` takes no `skin`), so the key unlocks the bare
    /// surface and draws nothing — the organic surface is `organic_boundary_finish`
    /// alone, and the wizard sets that to "clean". Non-organic jobs: byte-identical.
    public var jobOuterFinishResolved: String? {
        isOrganic ? (boundary == .covered ? "shell" : "skin") : boundary.jobOuterFinish
    }
    public var jobSkinResolved: String { isOrganic ? "diagrid" : boundary.jobSkinValue }
    public var boundary: LatticeBoundaryTreatment
    /// Density mode (uniform run fill vs field-graded preview, bar B6).
    public var densityMode: LatticeDensityMode

    // ─────────────────────────────────────────────────────────────────────
    // ★★ THE SIM MASTER SWITCH (maintainer, 2026-08-17)

    /// ★ HIS SPEC: "Add a dark glass on/off check with a 'Simulate Stresses' at
    /// the top of the 'Lattice Settings' modal (above the 'type') … The idea is
    /// that if the SIM option is selected, you can offer any variable for the AI
    /// to use, but can set some values yourself and keep them hard coded."
    ///
    /// ★ SO IT IS A PERMISSION, NOT A MODE. It does not say "grade everything by
    /// stress"; it says "a solve is allowed to decide the axes I left to it".
    /// Each axis still chooses for itself — that is the "set some values yourself
    /// and keep them hard coded" half — and this switch is what makes the Sim
    /// option available to any of them at all.
    ///
    /// ★ WHY IT IS STORED AND NOT DERIVED. Deriving it (`densityMode == .sim ||
    /// cellSizeMode == .swept`) would make the switch un-turn-off-able: flipping
    /// it off would have to guess which axes to move and back on would have to
    /// guess where to put them. Stored, with `setSimulateStresses` enforcing the
    /// invariant, the user's per-axis choices survive a round trip through OFF.
    ///
    /// ★ DEFAULT TRUE, and that is not a new behaviour: the field-graded density
    /// mode has been the default since it shipped, so an untouched project has
    /// always been asking for a solve. A false default would silently change
    /// every existing project's lattice.
    public var simulateStresses: Bool

    /// ★★ THE MANUAL STRUT THICKNESS, in mm (maintainer, 2026-08-19: "there should
    /// also be a way to manually override the sim's thickness control to whatever
    /// the user sets. Please make it so there is an on/off switch that turns on
    /// the Sim control. Off makes a sliding number value visible; controlling the
    /// thickness of the cell on screen").
    ///
    /// `nil` ⇒ derived, which is every project written before this and every
    /// project with `simulateStresses` on.
    ///
    /// ★ IT IS A THICKNESS, STORED AS A THICKNESS, BUT IT DOES NOT BECOME A
    /// SECOND SOURCE OF TRUTH. The renderer grades from relative DENSITY and
    /// nothing else; a strut radius is `L·√(ρ/K)` and that map is invertible
    /// (`LatticeType.relativeDensity(strutRadiusMM:cellMM:)`). So the slider's
    /// millimetres are converted to the density that produces them and the band
    /// is pinned there. One mechanism, two ways of typing into it — rather than a
    /// thickness path and a density path that can disagree.
    public var manualStrutThicknessMM: Double? = nil

    /// ★ THE RANGE THE THICKNESS SLIDER MAY OFFER, in mm of strut DIAMETER.
    ///
    /// The bottom is one extruded bead — thinner cannot be printed. The top is the
    /// thickness at the certifiable density ceiling, `2·L·√(ρmax/K)`: past it the
    /// struts have merged into something core will not certify as this lattice.
    /// Both ends therefore come from the same two laws the rest of this file uses,
    /// so the slider cannot offer a value the run would refuse.
    public func manualThicknessRangeMM(limits: TopOptKit.LatticeLimits,
                                       lineWidthMM: Double) -> ClosedRange<Double> {
        let lo = Swift.max(0.05, lineWidthMM > 0 ? lineWidthMM : 0.4)
        let rhoMax = limits.certifiable && limits.rhoMax > 0 ? limits.rhoMax : 0.9
        let hi = Swift.max(lo + 0.05, 2 * lattice.strutRadiusMM(relativeDensity: rhoMax,
                                                                cellMM: cellMM))
        return lo...hi
    }

    /// The relative density a hand-set strut thickness produces at this cell —
    /// or nil when the thickness is not in play (the sim is on, or none is set).
    ///
    /// ★ CLAMPED TO THE PRINTABLE FLOOR AND THE CERTIFIABLE CEILING, because a
    /// slider that can ask for a strut the printer cannot lay is a slider that
    /// produces a refused run. The floor is `lineWidth/2` expressed as a density
    /// (see `LatticeType.printabilityDensityFloor`), which is exactly where the
    /// slider's own minimum sits, so the clamp only ever bites on a stale value.
    public func manualThicknessDensity(limits: TopOptKit.LatticeLimits) -> Double? {
        guard !simulateStresses, let mm = manualStrutThicknessMM, mm > 0 else { return nil }
        let rho = lattice.relativeDensity(strutRadiusMM: mm / 2, cellMM: cellMM)
        let floor = lattice.printabilityDensityFloor(lineWidthMM: 0, cellMM: cellMM)
        let hi = limits.certifiable && limits.rhoMax > 0 ? limits.rhoMax : 1
        return Swift.max(Swift.max(0.0001, floor), Swift.min(hi, rho))
    }

    /// ★ THE DEMAND⇢DENSITY CURVE'S EXPONENT — core's `grading.demand_exponent`.
    ///
    ///     rho = rho_hi · (demand / demand_max) ^ gamma
    ///
    /// 1.0 is fully-stressed design on von Mises; 0.5 gives the same grade from
    /// strain-energy demand (core's own words, `grading.hpp:94-100`). It is
    /// stored so the PREVIEW can read the same number the job carries — the
    /// preview hardcoded `1` while this was unsettable, and that was honest then
    /// and would not be once a control exists.
    public var demandExponent: Double = 1

    /// ★ THE INVARIANT, IN ONE PLACE: no axis may sit on a Sim setting while the
    /// permission is off. Turning the switch off MOVES those axes to their
    /// nearest manual equivalent rather than leaving a mode the job cannot
    /// express — core would receive a `grading` block the user has just said
    /// they do not want.
    public mutating func setSimulateStresses(_ on: Bool) {
        simulateStresses = on
        guard !on else { return }
        // Density: the field-graded mode has no meaning without a field.
        if densityMode.needsSimulation { densityMode = .uniform }
        // Cell size: `swept` IS the stress-graded cell ladder.
        if cellSizeMode == .swept { cellSizeMode = .fixed }
    }

    /// ★ WHETHER A SOLVE IS ACTUALLY NEEDED — the permission AND at least one
    /// axis taking it up. The switch being on with every axis pinned by hand is
    /// a legitimate state, and it needs no FEA.
    public var needsStressSolve: Bool {
        simulateStresses
            && (densityMode.needsSimulation || cellSizeMode == .swept)
    }
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
    /// ★ PER-REGION RELATIVE DENSITY (task 2026-08-16-per-sector-density-override),
    /// keyed by the SAME `SelectionGroup.id` as `groupRoles`. This is the one thing
    /// the region layer could not yet say: dial this sector to 25% and its
    /// neighbour to 40% AT THE SAME DEPTH.
    ///
    /// ★ ABSENT MEANS AUTO, and auto means core derives — it does NOT mean zero and
    /// it does NOT mean a default this app picked. An empty dictionary emits no
    /// `relative_density` key at all, so a project that never touches this produces
    /// a byte-identical job (bar R1). The same reason `groupRoles` is empty by
    /// default and the same reason core's sentinel is `> 0`.
    ///
    /// Only an INCLUDE group can carry one: an exclude region is frozen solid and
    /// has no lattice to set a density on. `LatticeRegionEmission` applies that
    /// gate at the single place the emission goes through, so no call site can
    /// forget it, and core refuses the pairing independently.
    public var groupDensities: [UUID: Double]
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

    /// ★ THE PER-PRIMITIVE LATTICE / NO-LATTICE OVERRIDE (task
    /// 2026-08-14-lattice-separation §3c). Keyed by `LatticeSelectableRef.key`.
    /// A primitive with no entry follows its group's `groupRoles` declaration, so
    /// every snapshot written before this task resolves to exactly the roles it
    /// had. Read only through `LatticeSelectableRoles`, never directly.
    public var selectableRoles: [String: LatticeSelectableRole]

    /// ★ THE PER-PRIMITIVE DEPTH — the same override shape as the role, for the
    /// number the 3D depth plane drags (§3d). Absent ⇒ `groupDepthMM` ⇒
    /// `paintDepthMM`, so nothing about an untouched project moves. It is STILL
    /// the protection depth as well: `ProjectModel.faceProtectionSpecs()` and
    /// `latticeJobRegions()` both resolve through `LatticeSlabDepth`, per face
    /// (bar R4).
    public var selectableDepthMM: [String: Double]

    /// ★ THE PER-SELECTABLE DENSITY — the store `LatticeRegionEmission` recorded
    /// as missing (maintainer, 2026-08-17: "There is no *actual* way to modify
    /// the density value when the lattice density setting is set to per-region").
    ///
    /// ★ THE EMISSION SAID SO IN SO MANY WORDS and shipped the gap deliberately:
    /// "a per-selectable density needs its own store AND its own control, and
    /// inventing one here would ship a field with no surface." Both arrive
    /// together now — this is the store, and the drawer's Density row is the
    /// surface. Until now the only density on the wire was keyed by GROUP, so a
    /// per-region field could only have edited every face of the group at once.
    ///
    /// Keyed by `LatticeSelectableRef.key`, exactly like the role and the depth.
    /// Absent ⇒ the group's `groupDensities` ⇒ the mode's own answer ⇒ AUTO, so
    /// every snapshot written before this task emits precisely what it did.
    public var selectableDensity: [String: Double]

    /// ★ THE IN-PLANE EXPAND (maintainer, 2026-08-17: "the primitives are the
    /// same shape as the face that they are derived from. I'd like a way to
    /// expand them with a handle to be able to get the outside walls that might
    /// be otherwise impossible to get latticed (i.e. the chamfer)").
    ///
    /// An OUTWARD margin in mm added to the slab's two in-plane half-extents —
    /// ★ X AND Y ONLY, never the depth, which is its own control and its own
    /// handle ("all the other axis *except* the depth that was set"). A face's
    /// lattice slab is built from that face's own outline, so a chamfer just off
    /// its edge falls outside it; this grows the slab past the outline to take
    /// the surrounding wall in.
    ///
    /// Keyed by `LatticeSelectableRef.key`. Absent ⇒ 0 ⇒ the slab is exactly the
    /// face, which is what every snapshot before this task emitted.
    public var selectableExpandMM: [String: Double]

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

    /// ★★★ "ALLOW SINGLE-CELL MEMBERS" (maintainer, 2026-08-22: "I'd much rather a
    /// specific button to set that allows for a singular cell/member which
    /// automatically requires finish=skin").
    ///
    /// ★ WHY IT IS ITS OWN SWITCH AND NOT A CONSEQUENCE OF THE FINISH. Core lets the
    /// aesthetic floor reach ONE cell only where a boundary finish re-ties the struts a
    /// one-cell-wide member severs — so a finish is REQUIRED. But it is not SUFFICIENT
    /// as a signal: a user picks a finish because they want the look, and acquiring a
    /// structural relaxation as a side effect of a cosmetic choice is the "the picture
    /// changed and nothing said so" failure this branch keeps paying down. One cell
    /// across a member is a real reduction in what the lattice claims; it should be
    /// asked for.
    ///
    /// ★ AND TURNING IT ON WRITES THE FINISH. The dependency is real and one-way, so
    /// the switch satisfies it rather than refusing and making the user go find it —
    /// `none` and `rim` cannot re-tie a severed strut, and Skin is the pattern core
    /// builds. Turning it OFF leaves the finish alone: he may well want the skin for
    /// its own sake.
    /// ★★★ AND IN THE PREVIEW IT NEEDS NO FINISH (2026-08-26).
    ///
    /// Every preview call site used to gate core's one-cell floor on
    /// `singleCellMembers && boundary != .none`, because core will only allow one
    /// cell across a member when a finish re-ties the struts a one-cell member
    /// severs. The effect on screen was that setting **Finish = None** silently
    /// halved every cell on the part — his 12.03 mm wall came back at 6.00 mm and
    /// his 10.31 mm wall at 5.16 mm, twice as many cells each carrying a one-bead
    /// strut — with nothing in the UI saying the toggle had been overruled. Those
    /// are exactly the two numbers his tap callouts kept reporting while he was
    /// calling the wall quilted.
    ///
    /// His rule, stated 2026-08-26, carries no such caveat: *"single-cell/member
    /// means make the largest single cell across the entire model — per voxel."*
    /// And on the same day: *"The algo has not been updated with the needs I've
    /// created in this UI so for now, you can't just pass the algo onto the
    /// preview."* So the PREVIEW honours the toggle as written. Core's own floor is
    /// unchanged — this property is read by the preview's four call sites only, and
    /// the job still asks core.
    public var singleCellMembers: Bool = false
    /// Ask the run for the per-region breakdown in its receipt.
    public var reportRegionCells: Bool

    /// ★ THE GRADING OPTIONS (2026-08-25). `.full` is every existing project's
    /// behaviour; absent from every older snapshot ⇒ decodes to `.full`.
    public var gradingMode: LatticeGradingMode = .full
    /// How the fit-shape grade steps — stepped divisors or dyadic halving.
    public var gradeStepStyle: LatticeGradeStepStyle = .stepped
    /// ★ THE PER-FACE CELL (mm), stated by the user — the dial the two new
    /// grading modes expose ("include a cell size value above density").
    /// Keyed by `LatticeSelectableRef.key`, like the density beside it. Absent
    /// ⇒ derived, and the key is not stored at all. Never a licence to
    /// overshoot: the bake still caps every cell at min(declared depth, its
    /// own wall).
    public var selectableCellMM: [String: Double] = [:]

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
    ///                         ★ AUTO ALSO FITS THE CELL to the region's own
    ///                         thickness (`LatticeRegionCellMode::Fit`), so the
    ///                         cells-per-member floor is cleared by construction
    ///                         rather than by luck. A fixed cell that the region
    ///                         cannot hold is the ONE way this feature refuses,
    ///                         and Auto never asks for one.
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
                shapeFitBandMM: Double = LatticeSettings.defaultShapeFitBandCells,
                minRelativeDensity: Double = 0, maxRelativeDensity: Double = 1,
                region: ManualPrimitive? = nil,
                includePrimitives: [ManualPrimitive] = [],
                // THE DEFAULT IS THE ONE THAT CAN ACTUALLY EMIT (task
                // 2026-08-03-variant-postprocessing-fix, defect 4). It was `.rim`,
                // which on an optimized part is provably zero geometry — see
                // `LatticeCoreCapability.rimEmitsNothingOnVoxelParts`. Core's own job
                // schema has always defaulted to "diagrid" (`job.hpp`); the app was
                // the one overriding it with the choice that does nothing.
                // ★ NONE (maintainer, 2026-08-14): "it should default to
                // 'none'". A bare lattice is the starting point; a rim or a
                // skin is something you choose to add.
                boundary: LatticeBoundaryTreatment = .none,
                // ★ §4b (task 2026-08-12) — AUTO IS THE DEFAULT. A user who sets
                // his faces and presses Auto on everything must get a lattice
                // with no further questions. The DECODE fallbacks below stay
                // `.uniform` / `.fixed` on purpose: those describe what an OLD
                // snapshot actually had, and a default must never rewrite
                // history (the `boundary` precedent).
                densityMode: LatticeDensityMode = .sim,
                simulateStresses: Bool = true,
                paintedIncludeFaces: [Int] = [],
                paintDepthMM: Double = 4,
                groupRoles: [UUID: LatticeGroupRole] = [:],
                groupDensities: [UUID: Double] = [:],
                groupDepthMM: [UUID: Double] = [:],
                selectableRoles: [String: LatticeSelectableRole] = [:],
                selectableDepthMM: [String: Double] = [:],
                selectableDensity: [String: Double] = [:],
                selectableExpandMM: [String: Double] = [:],
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
        self.shapeFitBandMM = shapeFitBandMM
        self.cellMaxMM = cellMaxMM
        self.minRelativeDensity = minRelativeDensity
        self.maxRelativeDensity = maxRelativeDensity
        self.includePrimitives = includePrimitives
        self.boundary = boundary
        self.densityMode = densityMode
        self.simulateStresses = simulateStresses
        self.paintedIncludeFaces = paintedIncludeFaces
        self.paintDepthMM = paintDepthMM
        self.groupRoles = groupRoles
        self.groupDensities = groupDensities
        self.groupDepthMM = groupDepthMM
        self.selectableRoles = selectableRoles
        self.selectableDepthMM = selectableDepthMM
        self.selectableDensity = selectableDensity
        self.selectableExpandMM = selectableExpandMM
        if let r = region, includePrimitives.isEmpty { self.includePrimitives = [r] }
    }

    // Codable by hand: every field newer than the first shipped snapshot decodes
    // with `decodeIfPresent` + its default, so PRE-EXISTING project snapshots (which
    // stored `region`, not `includePrimitives`) still decode — the legacy `region`
    // key migrates into the list (LatticeModeTests.testPreLatticeSnapshotStillDecodes
    // guards the older layer of the same rule).
    private enum CodingKeys: String, CodingKey {
        case enabled, topologyID, cellMM, minRelativeDensity, maxRelativeDensity
        case stageMode                  // Structural / Aesthetic — chosen once (nil ⇒ unasked)
        case algorithm                  // core's LatticeAlgorithm name ("" ⇒ not stated)
        case manualStrutThicknessMM      // the hand-set thickness (nil ⇒ derived)
        case region                     // legacy single-region snapshots
        case includePrimitives, boundary, densityMode, paintedIncludeFaces, paintDepthMM
        case groupRoles
        case groupDensities
        case groupDepthMM        // the ONE dragged depth per group (task 2026-08-12 §0a)
        // The per-SELECTABLE role + depth (task 2026-08-14-lattice-separation
        // §3c/§3d). Named `primitive*` before PR 331 landed and made the unit
        // bigger than a primitive; the legacy keys below decode so a snapshot
        // written against the earlier name still opens with its choices intact.
        case selectableRoles, selectableDepthMM, selectableDensity
        case selectableExpandMM
        case primitiveRoles, primitiveDepthMM     // legacy names, decode only
        case cellSizeMode, cellMinMM, cellMaxMM   // cell-size sweep (bar R6)
        // ★ Absent from every older snapshot ⇒ decodes to its default, so an existing
        // project keeps the grade it has always had.
        case shapeFitBandMM
        // ★ The Sim permission (2026-08-17). Absent from every older
        // snapshot ⇒ decodes to its TRUE default ⇒ an existing project
        // keeps asking for the solve it has always asked for.
        case simulateStresses
        // sub-floor retention (task 2026-08-05-lattice-retention-app-control)
        case retainSubfloorInUnloadedRegions, subfloorStressFraction, singleCellMembers
        case subfloorPerRegion, reportRegionCells
        // the enclosed-void rule's OFF control
        // (task 2026-08-06-arm-projection-and-void-check)
        case requireVoidReachesExterior
        // the per-region lattice density (task 2026-08-13-lattice-as-a-material)
        case frozenRegionDensity
        // the grading options (2026-08-25) — absent ⇒ full / stepped / none stated
        case gradingMode, gradeStepStyle, selectableCellMM
        // ★ ORGANIC (2026-09-02). Absent from every earlier snapshot ⇒ each decodes to
        // its own default ⇒ an existing project emits exactly the job it always has.
        case organicGrowth, organicStrutWidthMM, organicOverhangDeg
        case organicBoundaryFinish, organicShapeFit, organicShapeFitOnly, organicScale
        case organicFittingSeparationsMM, organicPickedSeparationMM
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        topologyID = try c.decodeIfPresent(String.self, forKey: .topologyID) ?? LatticeType.octet.id
        cellMM = try c.decodeIfPresent(Double.self, forKey: .cellMM) ?? LatticeSettings.defaultCellMM
        // ★ ABSENT ⇒ NOT YET ASKED. A pre-mode snapshot must reopen the modal rather
        // than inherit a mode nobody chose — the choice decides what the receipt claims.
        stageMode = try c.decodeIfPresent(LatticeStageMode.self, forKey: .stageMode)
        // Absent in every project saved before the selector existed, and "" is exactly
        // what those projects mean: not stated, so core takes doubled.
        algorithm = try c.decodeIfPresent(String.self, forKey: .algorithm) ?? ""
        // ★ ORGANIC — absent in every snapshot written before these existed, and each
        // default is CORE's own, so a project that never chose organic decodes to the
        // state that writes no organic_* key at all.
        organicGrowth = try c.decodeIfPresent(Bool.self, forKey: .organicGrowth) ?? false
        organicStrutWidthMM = try c.decodeIfPresent(Double.self, forKey: .organicStrutWidthMM) ?? 0
        organicOverhangDeg = try c.decodeIfPresent(Double.self, forKey: .organicOverhangDeg) ?? 0
        organicBoundaryFinish = try c.decodeIfPresent(
            LatticeOrganicFinish.self, forKey: .organicBoundaryFinish) ?? .skin
        organicShapeFit = try c.decodeIfPresent(Bool.self, forKey: .organicShapeFit) ?? false
        organicShapeFitOnly = try c.decodeIfPresent(Bool.self, forKey: .organicShapeFitOnly) ?? false
        organicScale = try c.decodeIfPresent(Double.self, forKey: .organicScale) ?? 1.0
        organicFittingSeparationsMM = try c.decodeIfPresent([Double].self, forKey: .organicFittingSeparationsMM) ?? []
        organicPickedSeparationMM = try c.decodeIfPresent(Double.self, forKey: .organicPickedSeparationMM) ?? 0
        // Absent from every pre-R6 snapshot ⇒ `.fixed` ⇒ those projects keep emitting
        // exactly the job they emitted before (bar R1).
        cellSizeMode = try c.decodeIfPresent(LatticeCellSizeMode.self, forKey: .cellSizeMode) ?? .fixed
        cellMinMM = try c.decodeIfPresent(Double.self, forKey: .cellMinMM) ?? LatticeSettings.defaultCellMinMM
        shapeFitBandMM = try c.decodeIfPresent(Double.self, forKey: .shapeFitBandMM)
            ?? LatticeSettings.defaultShapeFitBandCells
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
        // ★ …and the same default when the key is absent, so a project that
        // never chose a finish opens on none rather than on rim.
        boundary = try c.decodeIfPresent(LatticeBoundaryTreatment.self, forKey: .boundary) ?? .none
        densityMode = try c.decodeIfPresent(LatticeDensityMode.self, forKey: .densityMode) ?? .uniform
        // ★ ABSENT ⇒ TRUE. An older snapshot predates the switch, and the
        // field-graded density mode has been the default since it shipped —
        // so those projects have always been asking for a solve. Defaulting
        // false here would silently change every one of their lattices.
        simulateStresses = try c.decodeIfPresent(Bool.self, forKey: .simulateStresses) ?? true
        // ★ ABSENT ⇒ DERIVED, so every project written before the control existed
        // decodes to exactly the behaviour it had.
        manualStrutThicknessMM = try c.decodeIfPresent(Double.self,
                                                       forKey: .manualStrutThicknessMM)
        paintedIncludeFaces = try c.decodeIfPresent([Int].self, forKey: .paintedIncludeFaces) ?? []
        paintDepthMM = try c.decodeIfPresent(Double.self, forKey: .paintDepthMM) ?? 4
        groupRoles = try c.decodeIfPresent([UUID: LatticeGroupRole].self, forKey: .groupRoles) ?? [:]
        // Absent in every snapshot written before this task ⇒ [:] ⇒ auto everywhere,
        // which is exactly what those projects ran. A default must not rewrite history.
        groupDensities = try c.decodeIfPresent([UUID: Double].self, forKey: .groupDensities) ?? [:]
        // Absent from every pre-task snapshot ⇒ empty ⇒ every group falls back to
        // `paintDepthMM`, which is exactly the depth those projects emitted.
        groupDepthMM = try c.decodeIfPresent([UUID: Double].self, forKey: .groupDepthMM) ?? [:]
        // Absent from every snapshot older than this task, and the default is
        // AUTO for every region, so an old project decodes to exactly what it
        // always meant (bar R1).
        frozenRegionDensity =
            try c.decodeIfPresent([UUID: Double].self, forKey: .frozenRegionDensity) ?? [:]
        // Absent from every snapshot written before the separation task ⇒ empty ⇒
        // every selectable follows its group, which is the ONLY answer those
        // projects ever had (§3c). The `primitive*` fallback reads a snapshot
        // written under the pre-PR-331 name so those choices are not lost either.
        selectableRoles = try c.decodeIfPresent([String: LatticeSelectableRole].self,
                                                forKey: .selectableRoles)
            ?? c.decodeIfPresent([String: LatticeSelectableRole].self,
                                 forKey: .primitiveRoles) ?? [:]
        selectableDepthMM = try c.decodeIfPresent([String: Double].self,
                                                  forKey: .selectableDepthMM)
            ?? c.decodeIfPresent([String: Double].self,
                                 forKey: .primitiveDepthMM) ?? [:]
        // Absent from every snapshot before 2026-08-17 ⇒ empty ⇒ the group's
        // density ⇒ the mode's answer, which is exactly what those emitted.
        selectableDensity = try c.decodeIfPresent([String: Double].self,
                                                  forKey: .selectableDensity) ?? [:]
        // Absent ⇒ 0 ⇒ the slab is exactly the face, as every older snapshot.
        selectableExpandMM = try c.decodeIfPresent([String: Double].self,
                                                   forKey: .selectableExpandMM) ?? [:]
        // Absent from every snapshot written before this task ⇒ off / core's own
        // number ⇒ those projects keep emitting exactly the job they emitted.
        retainSubfloorInUnloadedRegions = try c.decodeIfPresent(
            Bool.self, forKey: .retainSubfloorInUnloadedRegions) ?? false
        subfloorStressFraction = try c.decodeIfPresent(
            Double.self, forKey: .subfloorStressFraction)
        subfloorPerRegion = try c.decodeIfPresent(Bool.self, forKey: .subfloorPerRegion) ?? false
        // Absent from every older snapshot ⇒ off ⇒ core's floor of 2, unchanged.
        singleCellMembers = try c.decodeIfPresent(Bool.self, forKey: .singleCellMembers) ?? false
        reportRegionCells = try c.decodeIfPresent(Bool.self, forKey: .reportRegionCells) ?? false
        // ★ nil → TRUE, and the asymmetry with the four lines above is the point.
        // Those decode to "off" because absent meant off when they were written.
        // This rule is ARMED BY DEFAULT now, so a project saved before this
        // field existed must reopen ARMED — decoding it to false would opt every
        // existing project out of a rule the maintainer turned on, silently.
        requireVoidReachesExterior = try c.decodeIfPresent(
            Bool.self, forKey: .requireVoidReachesExterior) ?? true
        // Absent from every older snapshot ⇒ `.full` / `.stepped` / nothing
        // stated ⇒ existing projects keep the behaviour they have always had.
        gradingMode = try c.decodeIfPresent(LatticeGradingMode.self,
                                            forKey: .gradingMode) ?? .full
        gradeStepStyle = try c.decodeIfPresent(LatticeGradeStepStyle.self,
                                               forKey: .gradeStepStyle) ?? .stepped
        selectableCellMM = try c.decodeIfPresent([String: Double].self,
                                                 forKey: .selectableCellMM) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(topologyID, forKey: .topologyID)
        try c.encode(cellMM, forKey: .cellMM)
        // ★ ORGANIC — written ALWAYS, decoded with defaults: a snapshot round-trips even
        // when the user left a key at core's default. (The job document is where
        // defaults are omitted; the snapshot is not the job.)
        try c.encode(organicGrowth, forKey: .organicGrowth)
        try c.encode(organicStrutWidthMM, forKey: .organicStrutWidthMM)
        try c.encode(organicOverhangDeg, forKey: .organicOverhangDeg)
        try c.encode(organicBoundaryFinish, forKey: .organicBoundaryFinish)
        try c.encode(organicShapeFit, forKey: .organicShapeFit)
        try c.encode(organicShapeFitOnly, forKey: .organicShapeFitOnly)
        try c.encode(organicScale, forKey: .organicScale)
        // Written only when set, so an untouched project's file is byte-identical.
        if !organicFittingSeparationsMM.isEmpty {
            try c.encode(organicFittingSeparationsMM, forKey: .organicFittingSeparationsMM)
        }
        if organicPickedSeparationMM > 0 {
            try c.encode(organicPickedSeparationMM, forKey: .organicPickedSeparationMM)
        }
        try c.encodeIfPresent(stageMode, forKey: .stageMode)
        // Written only when stated, so an untouched project's file is byte-identical
        // to one saved before the selector existed (bar U1).
        if !algorithm.isEmpty { try c.encode(algorithm, forKey: .algorithm) }
        try c.encode(cellSizeMode, forKey: .cellSizeMode)
        try c.encode(cellMinMM, forKey: .cellMinMM)
        try c.encode(shapeFitBandMM, forKey: .shapeFitBandMM)
        try c.encode(cellMaxMM, forKey: .cellMaxMM)
        try c.encode(minRelativeDensity, forKey: .minRelativeDensity)
        try c.encode(maxRelativeDensity, forKey: .maxRelativeDensity)
        try c.encode(includePrimitives, forKey: .includePrimitives)
        try c.encode(boundary, forKey: .boundary)
        try c.encode(densityMode, forKey: .densityMode)
        try c.encode(simulateStresses, forKey: .simulateStresses)
        // Encoded only when set — an untouched project's bytes do not move.
        try c.encodeIfPresent(manualStrutThicknessMM, forKey: .manualStrutThicknessMM)
        try c.encode(paintedIncludeFaces, forKey: .paintedIncludeFaces)
        try c.encode(paintDepthMM, forKey: .paintDepthMM)
        try c.encode(groupRoles, forKey: .groupRoles)
        try c.encode(groupDensities, forKey: .groupDensities)
        try c.encode(groupDepthMM, forKey: .groupDepthMM)
        try c.encode(frozenRegionDensity, forKey: .frozenRegionDensity)
        try c.encode(selectableRoles, forKey: .selectableRoles)
        try c.encode(selectableDepthMM, forKey: .selectableDepthMM)
        try c.encode(selectableDensity, forKey: .selectableDensity)
        try c.encode(selectableExpandMM, forKey: .selectableExpandMM)
        try c.encode(retainSubfloorInUnloadedRegions,
                     forKey: .retainSubfloorInUnloadedRegions)
        try c.encode(singleCellMembers, forKey: .singleCellMembers)
        // encodeIfPresent: "the user has not moved it" must round-trip as ABSENT,
        // not as core's number written into the project — the whole point of the
        // nil is that the app never becomes the author of that constant.
        try c.encodeIfPresent(subfloorStressFraction, forKey: .subfloorStressFraction)
        try c.encode(subfloorPerRegion, forKey: .subfloorPerRegion)
        try c.encode(reportRegionCells, forKey: .reportRegionCells)
        try c.encode(requireVoidReachesExterior, forKey: .requireVoidReachesExterior)
        // Written only when moved off the default, so an untouched project's
        // bytes do not move (bar U1).
        if gradingMode != .full { try c.encode(gradingMode, forKey: .gradingMode) }
        if gradeStepStyle != .stepped {
            try c.encode(gradeStepStyle, forKey: .gradeStepStyle)        }
        if !selectableCellMM.isEmpty {
            try c.encode(selectableCellMM, forKey: .selectableCellMM)
        }
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

    /// ★★ WHAT "AUTO" ACTUALLY MEANS NOW (maintainer, 2026-08-19: "Cell size =
    /// Auto should absolutely be *any* number - as needed based on the stress map,
    /// not just a single cell size. Swept should limit it to a smaller range but
    /// still automatically selected based on the sim, and only *manual* should
    /// force a single number through the entire lattice").
    ///
    /// ★ CORE'S OWN `auto` IS ONE UNIFORM CELL, and says so in a throw:
    /// `plan_cell_sizes` refuses any mode but `Swept` — "the Fixed and Auto paths
    /// are one uniform cell and stay in grade_lattice" (core/src/simp/
    /// cell_plan.cpp:114). So the app's Auto cannot be core's auto and mean what
    /// he asked for.
    ///
    /// ★ BUT CORE ALREADY GRADES, under `swept`: a dyadic ladder `S0·2^L`, and a
    /// block takes the COARSEST level printability asks for, bounded by the
    /// cells-per-member ceiling. That is precisely "coarse where there is no
    /// stress" — low stress ⇒ low density ⇒ thin strut ⇒ unprintable at a fine
    /// cell ⇒ the plan coarsens until it prints. Auto therefore maps onto SWEPT
    /// with a window the app derives, and no new grading law is invented.
    ///
    /// ★ AND THE OBJECTIVE PICKS THE WINDOW (maintainer: "If 'minimize_plastic'
    /// is on, then the goal of the lattice should be to minimize the amount of
    /// plastic used, meaning cells as large as possible and as least dense as
    /// possible … If minimize_plastic is off then the goal is to make it as strong
    /// as possible"):
    ///
    ///   minimize plastic ON  → the full ladder, floor … the coarsest cell that
    ///                          still certifies. The plan then coarsens wherever
    ///                          the stress permits, which is where the material is
    ///                          saved.
    ///   minimize plastic OFF → a degenerate window at the FLOOR: the finest
    ///                          printable cell everywhere, with density still
    ///                          graded from the stress.
    public struct ResolvedCellPlan: Equatable, Sendable {
        public let mode: LatticeCellSizeMode
        public let loMM: Double
        public let hiMM: Double
    }

    public func resolvedCellPlan(bounds b: LatticeBounds,
                                 minimizePlastic: Bool) -> ResolvedCellPlan {
        let floor = LatticeCellEntry.entryFloorMM(b)
        switch cellSizeMode {
        case .fixed, .fit:
            return .init(mode: cellSizeMode, loMM: 0, hiMM: 0)
        case .swept:
            let lo = Swift.max(cellMinMM, floor)
            return .init(mode: .swept, loMM: lo, hiMM: Swift.max(cellMaxMM, lo))
        case .auto:
            // ★ THE COARSE END. The cells-per-member ceiling is the honest cap when
            // core has certified one; without it, three dyadic levels (8×) is the
            // ladder a sweep can actually use before the cell outgrows any real
            // member. Never below the floor.
            let lo = floor
            guard minimizePlastic else {
                return .init(mode: .swept, loMM: lo, hiMM: lo)
            }
            let ceiling = b.cellCeilingMM ?? (lo * 8)
            return .init(mode: .swept, loMM: lo, hiMM: Swift.max(lo, ceiling))
        }
    }

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
                        cellModes: LatticeCellModeCapability = .fromCore,
                        // ★ THE OBJECTIVE SHAPES "AUTO" — see `resolvedCellPlan`.
                        // Defaults to the app's own default so every existing call
                        // site keeps the minimise-plastic behaviour it had.
                        minimizePlastic: Bool = true,
                        // ★ THE LAYER HEIGHT THE JOB WILL CARRY — only the growth
                        // precondition reads it. Defaulted so every existing call site
                        // is unchanged; a 0 here means growth is simply not written.
                        layerHeightMM: Double = 0)
        -> LatticeSpec? {
        guard enabled else { return nil }
        let b = LatticeBounds.compute(settings: self, limits: limits,
                                      generatable: generatable,
                                      memberMM: memberMM, lineWidthMM: lineWidthMM)
        guard b.runnableAsCertified else { return nil }
        // ★★ THE SIM PERMISSION GATES THE `grading` BLOCK (maintainer,
        // 2026-08-17). `setSimulateStresses(false)` already moves every Sim axis
        // to its manual equivalent, so this can only fire if some other path
        // wrote the mode directly. It is here anyway, because the failure it
        // prevents is the one this project keeps paying for: a job that asks for
        // something the user's own switch says they turned off. Belt AND braces
        // is correct when the two live in different files.
        precondition(!(densityMode.needsSimulation && !simulateStresses),
                     "the Sim density mode cannot outlive the Sim permission — "
                     + "see LatticeSettings.setSimulateStresses")
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
        if densityMode == .sim {
            guard lineWidthMM > 0 else { return nil }
            // ★★ §9(b) — THIS IS WHERE THE SWEEP COLLAPSED, AND IT WAS THE WRONG
            // FLOOR.
            //
            // It read `b.cellFloorMM` — core's LIGHT-end printability floor,
            // **4.93 mm** on his part — and pushed BOTH ends of the window up onto
            // it. His 2.0 – 4.0 mm window therefore reached the job as
            // **4.93 – 4.93**: min == max, so `cell_plan_max_level` (a DYADIC
            // ladder, core/src/simp/cell_plan.cpp:43-51) returns 0, one level
            // exists, every block takes it, and the receipt comes back
            // `distinct_cells: 1` with `strut_radius_min_mm == strut_radius_max_mm`
            // == 0.225. That is the entire "a swept window that emits one cell is
            // not a sweep" defect, and it was app-side all along.
            //
            // ★ AND THE APP ALREADY KNEW THE RIGHT ANSWER. PR 310 moved the swept
            // floor to the DENSE-end floor (`cellFloorDensestMM`, ~1.17 mm — his
            // own run records `min_printable_cell_mm: 1.173`), and
            // `LatticeCellEntry.entryFloorMM` has used it for TYPED entry ever
            // since. So the control accepted 2.0 mm and the emission threw it
            // away: two floors, two answers, one silent overwrite. There is one
            // floor now, and it is the one the control is bounded by.
            // ★ THE ONE PLAN — see `resolvedCellPlan`. Auto is core's SWEPT with a
            // window this app derives from the objective, because core's own
            // `auto` is a single uniform cell and cannot grade.
            let plan = resolvedCellPlan(bounds: b, minimizePlastic: minimizePlastic)
            var lo = plan.loMM
            var hi = plan.hiMM
            // Core refuses a non-positive ladder end, so a snapshot carrying one falls
            // back to the fixed cell rather than shipping a job the schema rejects.
            // FIT falls back the same way when the LINKED core does not carry the
            // value: an unknown cell_mode kills the whole job at validation, exactly
            // as an unknown grading key does, so a project snapshot saved against a
            // newer core degrades to the fixed cell instead of dying at the worker.
            var mode: LatticeCellSizeMode = (plan.mode == .swept && !(lo > 0))
                ? .fixed : plan.mode
            if mode == .fit && !cellModes.fit { mode = .fixed }
            // ★★ ORGANIC DOES NOT INHERIT THE OCTET'S WINDOW (reviewer, 2026-09-03).
            // The plan above turns an Auto pick into the octet ladder's per-member
            // SWEPT window. Measured on-device 2026-09-02: the project said
            // `cellSizeMode: auto`, the pane lit "Auto · grade", and the organic job
            // carried `cell_mode: swept, 5.5–6 mm`. For organic that window IS the
            // separation field and the M2's cliff is unmeasured (the fixture
            // fragmented at 5.5–6.0; only 4.0 gave one component). Until the maintainer
            // picks a default, Auto travels as core's own `auto` — a single derived
            // separation, stated as such — and only an EXPLICIT size or window is
            // ever sent. The octet path is untouched (bar U1: byte-identical).
            // ★★ D2 (maintainer, 2026-09-03): ORGANIC CELL MODES ARE AUTO AND FIT.
            // AUTO travels as core's `auto` (core builds the FEA-driven window from
            // the smallest fitting separation to the largest); FIT travels as core's
            // `fit` (one separation, the middle of what fits). Nothing else is an
            // organic mode: an inherited swept window or a fixed cell — and the fit
            // fallbacks above, which degrade to FIXED for the octet — become AUTO here,
            // never a size. No octet window reaches an organic job by this path.
            // (the organic rule is applied once, AFTER every fallback — see below)
            // ★ FIT DERIVES FROM A DECLARED REGION, so core REFUSES the mode on a job
            // that declares none (job.cpp: "a job that declares none states no
            // requirement to fit"). Caught by this task's own schema test, which
            // handed the emitted bytes to core's parser rather than checking a key
            // list — a job.json that dies at validation is not a degraded run, it is
            // no run. The page says so on the control; this is the structural half.
            if mode == .fit && !regions.contains(where: { $0.role == .include }) {
                mode = .fixed
            }
            // ★★ D2 (maintainer, 2026-09-03), applied ONCE after every fallback:
            // ORGANIC CELL MODES ARE AUTO AND FIT. The user's Fit stays Fit — core's
            // `fit` — and is NEVER substituted (ruling, Aug 5: offer, never substitute;
            // the wizard disables Fit with its reason where no region is declared, and
            // the run button refuses it). Anything else — an inherited swept window, a
            // fixed cell, the octet's fit→FIXED fallbacks above — travels as Auto,
            // core's `auto`, with no window and never a size.
            if algorithm == "organic" {
                mode = (cellSizeMode == .fit) ? .fit : .auto
                lo = 0; hi = 0
            }
            // Sub-floor retention rides the GRADED path only — the keys live in the
            // `grading` block, and a uniform lattice job has no grading block at
            // all, so there is nothing for core to read there. The control says so.
            // `mode` (not `cellSizeMode`) carries the fit exclusion, so a spec that
            // fell back to fixed can still arm retention.
            let sub = resolvedSubfloor(capability: capability, cellMode: mode)
            var spec = LatticeSpec(topologyID: topologyID, cellMM: cellMM, strutRadiusMM: 0,
                               generateRelativeDensity: 0,
                               minRelativeDensity: b.densityLo,
                               maxRelativeDensity: b.densityHi,
                               emitSTL: emitSTL, emit3MF: emit3MF,
                               regionScoped: region != nil || !regions.isEmpty,
                               skin: jobSkinResolved,
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
            spec.outerFinish = jobOuterFinishResolved
            // ★ THE ALGORITHM RIDES THE GRADED SPEC. Carried as the raw string,
            // including "" — `gradingDictionary` is the single place that decides
            // whether a key is written, so "not stated" cannot become "doubled" here.
            spec.algorithm = algorithm

            // ★ ORGANIC — copied verbatim; `gradingDictionary()` owns every emission gate.
            spec.organicGrowth = organicGrowth
            spec.organicStrutWidthMM = organicStrutWidthMM
            spec.organicOverhangDeg = organicOverhangDeg
            spec.organicBoundaryFinish = organicBoundaryFinish.jobValue
            spec.organicShapeFit = organicShapeFit
            spec.organicShapeFitOnly = organicShapeFitOnly
            spec.organicScale = organicScale
            spec.organicPickedSeparationMM = organicPickedSeparationMM
            spec.layerHeightMM = layerHeightMM
            spec.stageMode = stageMode
            return spec
        }
        let genRho = b.generateRelativeDensity
        let radius = lattice.strutRadiusMM(relativeDensity: genRho, cellMM: cellMM)
        guard radius > 0 else { return nil }
        var spec2 = LatticeSpec(topologyID: topologyID, cellMM: cellMM, strutRadiusMM: radius,
                           generateRelativeDensity: genRho,
                           minRelativeDensity: b.densityLo, maxRelativeDensity: b.densityHi,
                           emitSTL: emitSTL, emit3MF: emit3MF,
                           regionScoped: region != nil || !regions.isEmpty,
                           skin: jobSkinResolved,
                           minExtrudableWidthMM: lineWidthMM > 0 ? lineWidthMM : nil,
                           // ★★ AN ORGANIC JOB ALWAYS CARRIES THE GRADING BLOCK. Its
                           // algorithm, intent, mode and every organic_* key live there,
                           // and `gradingDictionary()` returns nil for a non-graded spec —
                           // measured 2026-09-03 (D2 test, uniform path): an organic job
                           // under "Density: Auto/Thicker" carried NO grading block, so
                           // core would have run the DEFAULT lattice in silence.
                           graded: algorithm == "organic",
                           regions: regions,
                           // ★ D2 ON THE UNIFORM PATH TOO: an organic job never carries
                           // a fixed cell. The user's Fit stays Fit (never substituted —
                           // the wizard disables it with its reason where no region is
                           // declared, and the run button refuses it); anything else is
                           // Auto.
                           cellSizeMode: algorithm == "organic"
                               ? (cellSizeMode == .fit ? LatticeCellSizeMode.fit.rawValue
                                                       : LatticeCellSizeMode.auto.rawValue)
                               : LatticeCellSizeMode.fixed.rawValue,
                           // The UNIFORM path carries it too. The enclosed-void
                           // rule is about the lattice's pore space, which a
                           // uniform lattice has exactly as much of as a graded
                           // one — carrying it on only one path would make the
                           // rule silently depend on the density mode.
                           requireVoidReachesExterior: requireVoidReachesExterior)
        // ★ THE SOLID COVER RIDES ON `outer_finish`, NOT `skin` — the two are
        // independent axes in core's schema. Set on BOTH construction paths, so
        // a graded job and a uniform one cannot disagree about the cover.
        spec2.outerFinish = jobOuterFinishResolved
        // ★ THE ALGORITHM ON THIS PATH TOO (2026-09-02). `spec` carried it and `spec2`
        // did not, so a stated algorithm was silently dropped from the job on the
        // generatable-topology path — and organic can only be emitted through it.
        // "" is still not written, so an untouched project is unchanged.
        spec2.algorithm = algorithm

        // ★ ORGANIC — copied verbatim; `gradingDictionary()` owns every emission gate.
        spec2.organicGrowth = organicGrowth
        spec2.organicStrutWidthMM = organicStrutWidthMM
        spec2.organicOverhangDeg = organicOverhangDeg
        spec2.organicBoundaryFinish = organicBoundaryFinish.jobValue
        spec2.organicShapeFit = organicShapeFit
        spec2.organicShapeFitOnly = organicShapeFitOnly
        spec2.organicScale = organicScale
        spec2.organicPickedSeparationMM = organicPickedSeparationMM
        spec2.layerHeightMM = layerHeightMM
        spec2.stageMode = stageMode
        return spec2
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
                        cellModes: LatticeCellModeCapability = .fromCore,
                        // ★ LAST, matching the other `runSpec` — see
                        // `resolvedCellPlan`.
                        minimizePlastic: Bool = true,
                        layerHeightMM: Double = 0)
        -> LatticeSpec? {
        let id = topology ?? topologyID
        let limits = TopOptKit.latticeLimits(topology: id)
        let generatable = TopOptKit.latticeGeneratableTopologies.contains(id)
        return runSpec(limits: limits, generatable: generatable, memberMM: memberMM,
                       lineWidthMM: lineWidthMM, emitSTL: emitSTL, emit3MF: emit3MF,
                       regions: regions, capability: capability,
                       cellModes: cellModes, minimizePlastic: minimizePlastic,
                       layerHeightMM: layerHeightMM)
    }

    /// The proxy grading parameters for the current settings, with the density range
    /// already clamped to the core band, so the viewer proxy (requirement 5) shows the
    /// SAME numbers the run would use. `limits` is read from core.
    /// ★★ `lineWidthMM` IS THE PRINTER'S BEAD, AND LEAVING IT AT 0 WAS THE
    /// UNDERSIDE SPECKLE (task 2026-08-20, item 2; maintainer's original report of
    /// specks on the underside of his part).
    ///
    /// ★ THE PREVIEW WAS GRADING BELOW WHAT THE MACHINE CAN LAY. `LatticeBounds`
    /// has always raised the band's floor to the printability floor when given a
    /// line width — "stating a line width must RAISE the floor" — and this call
    /// never gave it one. So the band's bottom fell to core's certifiable minimum
    /// (5.0%), the thin end of the ramp landed inside a declared region, and the
    /// struts there came out THINNER THAN ONE BEAD: sub-pixel geometry that
    /// rendered as speckle and that the run does not build at all. Measured on his
    /// part, 0 -> 54 specks as the thin end moved into the region.
    ///
    /// ★ THE REMEDY IS DENSIFICATION, NOT DELETION, and that is core's order too:
    /// the band floor rises so those cells print, and only a cell that cannot print
    /// at ANY certifiable density is left solid (`fallback_strut_unprintable`).
    /// Deleting first would have shown him less lattice than the run builds.
    ///
    /// Callers with print parameters MUST pass it. The default is 0 so a caller
    /// that genuinely has no printer — the settings page's sample block — still
    /// gets the raw band rather than a floor invented from a guessed nozzle.
    public func proxyParams(limits: TopOptKit.LatticeLimits,
                            lineWidthMM: Double = 0) -> LatticeProxyParams {
        let b = LatticeBounds.compute(settings: self, limits: limits,
                                      lineWidthMM: lineWidthMM)
        // ★★ A HAND-SET THICKNESS PINS THE BAND (maintainer, 2026-08-19). With the
        // sim off there is no field to grade by, so a graded band would be a ramp
        // between two numbers nothing chooses between — the preview must show the
        // ONE lattice the user asked for. Converted through the same law the
        // renderer uses, then clamped to what the machine can actually print.
        if let t = manualThicknessDensity(limits: limits) {
            return LatticeProxyParams(latticeID: topologyID, cellMM: cellMM,
                                      shapeFitBandMM: shapeFitBandMM,
                                      minRelativeDensity: t, maxRelativeDensity: t,
                                      gamma: demandExponent,
                                      uniformRelativeDensity: t)
        }
        return LatticeProxyParams(latticeID: topologyID, cellMM: cellMM,
                                  shapeFitBandMM: shapeFitBandMM,
                                  minRelativeDensity: b.densityLo,
                                  maxRelativeDensity: b.densityHi,
                                  // ★ CORE'S OWN EXPONENT, NOT A HARDCODED 1
                                  // (maintainer, 2026-08-17: "use all variables
                                  // as part of the preview"). `1` was right when
                                  // nothing could set it; core's grading law is
                                  //   rho = rho_hi · (demand/demand_max)^gamma
                                  // with `demand_exponent` defaulting to 1.0, so
                                  // the preview reads the SAME number the job
                                  // carries and a future control moves both.
                                  gamma: demandExponent,
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

    /// ★ §9(f) — IF A CLAMP FIRES IT MUST SAY SO ON SCREEN, WITH THE NUMBER IT
    /// CLAMPED TO.
    ///
    /// The swept window's ends are pushed up onto `entryFloorMM` when they fall
    /// below it (`LatticeSettings.runSpec`). That used to happen against the WRONG
    /// floor and in silence, which is how a 2.0 – 4.0 mm window became 4.93 – 4.93
    /// without a word on screen. Returns nil when nothing was clamped.
    public static func sweptClampNote(minMM: Double, maxMM: Double,
                                      _ b: LatticeBounds?) -> String? {
        let floor = entryFloorMM(b)
        guard minMM < floor - 1e-9 || maxMM < floor - 1e-9 else { return nil }
        return String(format: "Raised to %.2f mm — below that no strut prints at "
                      + "this line width.", floor)
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
        // ★★ AND THE PRINTABILITY FLOOR, WHICH MOVES WITH THE NOZZLE (maintainer,
        // 2026-08-19). Below it the strut is thinner than one extruded bead, so it
        // is not a lattice the machine can make at all — a stricter bound than
        // core's certifiable band and, at a fine cell, a much higher one.
        //
        // ★ IT DEPENDS ON THE CELL TOO, quadratically: see
        // `LatticeType.printabilityDensityFloor`. Both bounds apply, so the floor
        // is whichever is higher, and the reason says which one bit.
        let printFloor = topo.printabilityDensityFloor(lineWidthMM: lineWidthMM,
                                                       cellMM: settings.cellMM)
        if printFloor > lo {
            lo = min(1, printFloor)
            loReason = "thinner than one \(mm(lineWidthMM)) extrusion at a \(mm(settings.cellMM)) cell "
                + "— the printer cannot lay a strut that thin (≥ \(pct(printFloor)))"
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
