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
    /// True iff a sub-region primitive scoped the preview (vs the whole part). Carried
    /// for the run report's honesty note; the region itself does not reach the job (the
    /// worker lattices the whole solid interior — core job carries no region yet).
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

    public init(topologyID: String, cellMM: Double, strutRadiusMM: Double,
                generateRelativeDensity: Double, minRelativeDensity: Double,
                maxRelativeDensity: Double, emitSTL: Bool = true, emit3MF: Bool = false,
                regionScoped: Bool = false,
                skin: String = LatticeBoundaryTreatment.rim.jobSkinValue,
                minExtrudableWidthMM: Double? = nil,
                graded: Bool = false) {
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
    /// The density RANGE the lattice grades between (relative density, dimensionless).
    /// Stored as the user's raw pick; CLAMPED to the core band [rhoMin, rhoMax] at use
    /// (`LatticeBounds`). The neutral open defaults (0…1) carry no band number.
    public var minRelativeDensity: Double
    public var maxRelativeDensity: Double
    /// The lattice-INCLUDE region primitives ("Material, latticed"), reusing the
    /// manual-primitive value type + gizmo (bolt = cylinder region, face = slab
    /// region). Empty ⇒ the whole solid part — which is exactly the extent the
    /// worker generates today. These scope the PREVIEW + the report's honesty note;
    /// the core job schema carries no region yet (the reported gap).
    public var includePrimitives: [ManualPrimitive]
    /// Boundary treatment (three-way; maps 1:1 onto `job.lattice.skin`, bar B7).
    public var boundary: LatticeBoundaryTreatment
    /// Density mode (uniform run fill vs field-graded preview, bar B6).
    public var densityMode: LatticeDensityMode
    /// Faces painted "Material, latticed" (lattice-include). Preview-scope only —
    /// no job carrier exists (the reported gap). The EXCLUDE paint role has a real
    /// carrier and deliberately does NOT live here: it drives the existing protect
    /// affix (`loads.face_protections`, FrozenSolid) so there is ONE protect concept.
    public var paintedIncludeFaces: [Int]
    /// Depth (mm) the painted include faces reach into the part (preview-scope).
    public var paintDepthMM: Double

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
                minRelativeDensity: Double = 0, maxRelativeDensity: Double = 1,
                region: ManualPrimitive? = nil,
                includePrimitives: [ManualPrimitive] = [],
                boundary: LatticeBoundaryTreatment = .rim,
                densityMode: LatticeDensityMode = .uniform,
                paintedIncludeFaces: [Int] = [],
                paintDepthMM: Double = 4) {
        self.enabled = enabled
        self.topologyID = topologyID
        self.cellMM = cellMM
        self.minRelativeDensity = minRelativeDensity
        self.maxRelativeDensity = maxRelativeDensity
        self.includePrimitives = includePrimitives
        self.boundary = boundary
        self.densityMode = densityMode
        self.paintedIncludeFaces = paintedIncludeFaces
        self.paintDepthMM = paintDepthMM
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
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        topologyID = try c.decodeIfPresent(String.self, forKey: .topologyID) ?? LatticeType.octet.id
        cellMM = try c.decodeIfPresent(Double.self, forKey: .cellMM) ?? LatticeSettings.defaultCellMM
        minRelativeDensity = try c.decodeIfPresent(Double.self, forKey: .minRelativeDensity) ?? 0
        maxRelativeDensity = try c.decodeIfPresent(Double.self, forKey: .maxRelativeDensity) ?? 1
        if let list = try c.decodeIfPresent([ManualPrimitive].self, forKey: .includePrimitives) {
            includePrimitives = list
        } else if let legacy = try c.decodeIfPresent(ManualPrimitive.self, forKey: .region) {
            includePrimitives = [legacy]
        } else {
            includePrimitives = []
        }
        boundary = try c.decodeIfPresent(LatticeBoundaryTreatment.self, forKey: .boundary) ?? .rim
        densityMode = try c.decodeIfPresent(LatticeDensityMode.self, forKey: .densityMode) ?? .uniform
        paintedIncludeFaces = try c.decodeIfPresent([Int].self, forKey: .paintedIncludeFaces) ?? []
        paintDepthMM = try c.decodeIfPresent(Double.self, forKey: .paintDepthMM) ?? 4
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(topologyID, forKey: .topologyID)
        try c.encode(cellMM, forKey: .cellMM)
        try c.encode(minRelativeDensity, forKey: .minRelativeDensity)
        try c.encode(maxRelativeDensity, forKey: .maxRelativeDensity)
        try c.encode(includePrimitives, forKey: .includePrimitives)
        try c.encode(boundary, forKey: .boundary)
        try c.encode(densityMode, forKey: .densityMode)
        try c.encode(paintedIncludeFaces, forKey: .paintedIncludeFaces)
        try c.encode(paintDepthMM, forKey: .paintDepthMM)
    }

    /// The starting cell size (mm): the octet cell PR-201 print-tested, reused from the
    /// viewer proxy's own default so the preview is continuous. A default START value
    /// the user edits — deliberately NOT a certifiable limit (limits come from core).
    public static let defaultCellMM: Double = LatticeProxyParams().cellMM

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
    public func runSpec(limits: TopOptKit.LatticeLimits, generatable: Bool,
                        memberMM: Double = 0,
                        lineWidthMM: Double = 0, emitSTL: Bool = true,
                        emit3MF: Bool = false) -> LatticeSpec? {
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
        if densityMode == .auto {
            guard lineWidthMM > 0 else { return nil }
            return LatticeSpec(topologyID: topologyID, cellMM: cellMM, strutRadiusMM: 0,
                               generateRelativeDensity: 0,
                               minRelativeDensity: b.densityLo,
                               maxRelativeDensity: b.densityHi,
                               emitSTL: emitSTL, emit3MF: emit3MF,
                               regionScoped: region != nil,
                               skin: boundary.jobSkinValue,
                               minExtrudableWidthMM: lineWidthMM,
                               graded: true)
        }
        let genRho = b.generateRelativeDensity
        let radius = lattice.strutRadiusMM(relativeDensity: genRho, cellMM: cellMM)
        guard radius > 0 else { return nil }
        return LatticeSpec(topologyID: topologyID, cellMM: cellMM, strutRadiusMM: radius,
                           generateRelativeDensity: genRho,
                           minRelativeDensity: b.densityLo, maxRelativeDensity: b.densityHi,
                           emitSTL: emitSTL, emit3MF: emit3MF, regionScoped: region != nil,
                           skin: boundary.jobSkinValue,
                           minExtrudableWidthMM: lineWidthMM > 0 ? lineWidthMM : nil)
    }

    /// Convenience: read the certifiable limits AND the generatable set from core
    /// for this topology, then build the run spec. `topology` is accepted
    /// (defaulting to `topologyID`) so a caller can be explicit; it must match
    /// `topologyID`. Used by `AppModel.makeRunRequest`.
    public func runSpec(topology: String? = nil, memberMM: Double = 0,
                        lineWidthMM: Double = 0, emitSTL: Bool = true,
                        emit3MF: Bool = false) -> LatticeSpec? {
        let id = topology ?? topologyID
        let limits = TopOptKit.latticeLimits(topology: id)
        let generatable = TopOptKit.latticeGeneratableTopologies.contains(id)
        return runSpec(limits: limits, generatable: generatable, memberMM: memberMM,
                       lineWidthMM: lineWidthMM, emitSTL: emitSTL, emit3MF: emit3MF)
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
    ///   - lineWidthMM: the user's outer extrusion line width (mm) — the strut
    ///     printability floor. Pass 0 to skip the strut-printability check.
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

        // Strut printability from the user's own line width. The densest grading end
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
            cellCeilingMM: ceiling, cellsAcrossMember: cells, cellOverCeiling: overCeiling,
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
