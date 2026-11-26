// LatticeDensityDial — ★ notes29 (his iPad notes on release 20, 2026-11-25): "Every single lattice type was quilted ...
// set up tests to find the EXACT density and size at which each lattice type becomes a quilt and limit both when 'Allow
// quilt' is turned off. The 'Density' grade percentage should then be limited within that, with a notification popping up
// if they try to go further (like 100%) saying that it can't until 'Allow Quilt' is turned back on."
//
// The Density percent the page shows and takes is his own ruling of 2026-08-25 ("Make 1% be the printability floor. Make
// 100% be the quilt"), linear in strut width on the cell it is read on (`ProjectModel.latticeDensityBandDiametersMM`):
// 100 % is the TYPE'S OWN quilt, where its neighbouring struts fuse (core's lattice_quilt_limits touch, through the engine:
// `LatticeLayoutSession.typeFacts`), never another type's number and never over 100 %.
//
// ★ notes29b (his question the same day: "Are you saying that no matter what happens, all Small cells in thin walls are going
// to be quilted?"): with Allow quilt off the limit is the QUILT, not the open look. The engine never lays a strut at the touch
// or past it: it stops one printed line short of it (core's lattice_quilt_off_strut_mm: touch x cell - one line width, so a
// line of air is left between the closest struts and every gap prints open). The page stops there too (`offMostPercent`,
// just under 100 %), and only a percent past THAT raises the centred pop-up (AppPopups) that says Allow quilt must be on. The
// open look is still what the lattice lays on its own (core's dial 1 with Allow quilt off); a percent past it is laid as
// asked, up to the limit. With Allow quilt on, up to 100 %.
//
// Core's own dial (StrutSpec::dial, R10) is 0.01 at the thinnest strut the engine lays and 1 at the open look with Allow
// quilt off (past 1: on in the same steps of width, up to the limit) or at the quilt with it on; `coreDial` turns the
// page's percent into it, so the strut core lays is the strut the percent names.
import Foundation
import TopOptKit

public enum LatticeDensityDial {
    /// The type's two limits, strut width over cell (core's lattice_quilt_limits through the engine's type facts): the open
    /// look (what the lattice lays on its own) and the quilt (where its struts fuse: 100 %). nil: the engine does not lay
    /// the type (a sheet, an unknown id), and no strut limit is said for it.
    public static func limits(topology: String) -> (openLook: Double, quilt: Double)? {
        let f = LatticeLayoutSession.typeFacts(topology.isEmpty ? "octet" : topology)
        guard f.lays, f.touch > 0, f.openLook > 0, f.openLook < f.touch else { return nil }
        return (f.openLook, f.touch)
    }

    /// ★ notes29b: the widest strut Allow quilt off lays on a cell of `cellMM`, mm: one printed line short of the quilt (core's
    /// lattice_quilt_off_strut_mm, kQuiltOffGapLines = 1: touch x cell - one line width), or the open look where that is
    /// wider (core's set_struts keeps the open look: only on cells under about 3 mm with one-line struts). nil: no limit.
    public static func offMostMM(cellMM: Double, topology: String, lineWidthMM: Double) -> Double? {
        guard cellMM > 0, let q = limits(topology: topology) else { return nil }
        return Swift.max(q.quilt * cellMM - Swift.max(0, lineWidthMM), q.openLook * cellMM)
    }

    /// The percent a strut of `strutMM` is on a cell of `cellMM` (1 ... 100, never over), or nil when the type has no band.
    public static func percent(strutMM: Double, cellMM: Double, topology: String, lineWidthMM: Double) -> Double? {
        guard cellMM > 0, strutMM > 0,
              let b = ProjectModel.latticeDensityBandDiametersMM(topology: topology, lineWidthMM: lineWidthMM, cellMM: cellMM),
              b.hi > b.lo else { return nil }
        return 1 + 99 * Swift.max(0, Swift.min(1, (strutMM - b.lo) / (b.hi - b.lo)))
    }

    /// The open look's percent on a cell of `cellMM`: what the lattice lays on its own (core's dial 1 with Allow quilt off).
    /// Not a limit (★ notes29b). nil: the type is not the engine's.
    public static func openLookPercent(cellMM: Double, topology: String, lineWidthMM: Double) -> Double? {
        guard let q = limits(topology: topology) else { return nil }
        return percent(strutMM: q.openLook * cellMM, cellMM: cellMM, topology: topology, lineWidthMM: lineWidthMM)
    }

    /// ★ notes29b: the most the percent may be with Allow quilt off on a cell of `cellMM`: one printed line short of the quilt,
    /// just under 100 %. nil: no limit is known (the type is not the engine's), and nothing is refused.
    public static func offMostPercent(cellMM: Double, topology: String, lineWidthMM: Double) -> Double? {
        guard let most = offMostMM(cellMM: cellMM, topology: topology, lineWidthMM: lineWidthMM) else { return nil }
        return percent(strutMM: most, cellMM: cellMM, topology: topology, lineWidthMM: lineWidthMM)
    }

    /// The page's percent as core's dial (StrutSpec::dial, R10: 0.01 the thinnest strut; 1 the open look with Allow quilt off,
    /// the quilt with it on). The percent is read on `cellMM` (the cell core reads its dial on: the part's or the region's
    /// largest). ★ notes29b: with Allow quilt off a percent past the open look is core's dial past 1, in the same steps of
    /// width, held at the limit (one printed line short of the quilt; the page refuses past it before it gets here).
    public static func coreDial(percent pct: Double, cellMM: Double, topology: String, lineWidthMM: Double,
                                            minStrutLines: Double, allowQuilt: Bool) -> Double {
        let plain = Swift.min(1, Swift.max(0.01, pct / 100))
        guard cellMM > 0, let q = limits(topology: topology),
              let b = ProjectModel.latticeDensityBandDiametersMM(topology: topology, lineWidthMM: lineWidthMM, cellMM: cellMM),
              b.hi > b.lo else { return plain }
        var d = b.lo + (Swift.max(1, Swift.min(100, pct)) - 1) / 99 * (b.hi - b.lo)
        let thinnest = Swift.max(lineWidthMM, minStrutLines * lineWidthMM)
        let widest = Swift.max(thinnest, (allowQuilt ? q.quilt : q.openLook) * cellMM)
        guard widest > thinnest else { return 1 }
        if allowQuilt { return 0.01 + 0.99 * Swift.max(0, Swift.min(1, (d - thinnest) / (widest - thinnest))) }
        if let most = offMostMM(cellMM: cellMM, topology: topology, lineWidthMM: lineWidthMM) { d = Swift.min(d, Swift.max(most, widest)) }
        return 0.01 + 0.99 * Swift.max(0, (d - thinnest) / (widest - thinnest))
    }

    /// The cell the page's percents are read on: the largest cell the page resolves (as `LatticeLayoutPreview.partWide`
    /// sends it: Max cell, the core's dial reads on the largest cell, R10).
    public static func pageCellMM(_ l: LatticeSettings, lineWidthMM: Double) -> Double {
        let bead = lineWidthMM > 0 ? lineWidthMM : 0.45
        let bounds = LatticeBounds.compute(settings: l, limits: TopOptKit.latticeLimits(topology: l.topologyID), lineWidthMM: bead)
        let plan = l.resolvedCellPlan(bounds: bounds, minimizePlastic: false)
        return plan.hiMM > 0 ? plan.hiMM : (l.cellMaxMM > 0 ? l.cellMaxMM : 8)
    }

    /// The Lattice page's Density boxes (Grade from, Grade to): what a stored density shows, and what a typed percent
    /// stores. `allowQuilt`: the switch as the engine reads it (Auto never quilts).
    public struct Page: Sendable {
        public let topology: String
        public let lineWidthMM: Double
        public let cellMM: Double
        public let allowQuilt: Bool
        public init(_ l: LatticeSettings, lineWidthMM: Double, allowQuilt: Bool) {
            topology = l.topologyID.isEmpty ? "octet" : l.topologyID
            self.lineWidthMM = lineWidthMM > 0 ? lineWidthMM : 0.45
            cellMM = LatticeDensityDial.pageCellMM(l, lineWidthMM: lineWidthMM)
            self.allowQuilt = allowQuilt
        }
        /// A stored density as the box's fraction (its percent / 100: 1 = the type's quilt); the density itself when the
        /// type has no band.
        public func shown(_ rho: Double) -> Double {
            guard rho > 0, let p = ProjectModel.latticeDensityPercent(rho: rho, cellMM: cellMM, topology: topology,
                                                                      lineWidthMM: lineWidthMM) else { return rho }
            return p / 100
        }
        /// The most the box may say with the switch as it is (percent): ★ notes29b one printed line short of the quilt with
        /// Allow quilt off (just under 100), else 100.
        public var most: Double {
            allowQuilt ? 100
                : (LatticeDensityDial.offMostPercent(cellMM: cellMM, topology: topology, lineWidthMM: lineWidthMM)?
                    .rounded(.down) ?? 100)
        }
        /// A typed percent as the density to store; nil when refused (Allow quilt off and past the limit: the centred pop-up
        /// says so).
        @MainActor public func typed(_ pct: Double) -> Double? {
            guard LatticeDensityDial.accept(pct, allowQuilt: allowQuilt, cellMM: cellMM, topology: topology,
                                            lineWidthMM: lineWidthMM) else { return nil }
            return ProjectModel.latticeDensityForPercent(Swift.min(100, Swift.max(1, pct)), cellMM: cellMM,
                                                         topology: topology, lineWidthMM: lineWidthMM) ?? pct / 100
        }
    }

    /// The pop-up's words (a title of at most five words; plain sentences), and its (i).
    public static let refusedTitle = "Struts would fuse"
    public static func refusedText(limit: Double) -> String {
        "Past \(Int(limit.rounded(.down))) % the struts would touch and fuse into a quilt. To go further, turn Allow quilt on."
    }
    public static let refusedInfoButton = "Why?"
    public static func refusedInfo(topology: String) -> String {
        let name = LatticeType.displayName(forID: topology.isEmpty ? "octet" : topology)
        return "100 % is where \(name) struts touch their neighbours and fuse into a solid quilt. With Allow quilt off the "
            + "struts stop one printed line short of that, so a gap of at least one line stays open between them and prints. "
            + "Turn Allow quilt on to go all the way to 100 %."
    }

    /// Is `pct` allowed? ★ notes29b: with Allow quilt off a percent past the limit (one printed line short of the quilt) is
    /// refused, and the centred pop-up says why, with an (i) for the reason.
    @MainActor @discardableResult
    public static func accept(_ pct: Double, allowQuilt: Bool, cellMM: Double, topology: String, lineWidthMM: Double) -> Bool {
        guard !allowQuilt, pct > 0,
              let limit = offMostPercent(cellMM: cellMM, topology: topology, lineWidthMM: lineWidthMM),
              pct > limit.rounded(.down) + 1e-9 else { return true }
        let info = refusedInfo(topology: topology)
        AppPopups.shared.show(refusedTitle, refusedText(limit: limit),
                              log: "density \(pct) % past the quilt-off limit \(limit) % (\(topology), \(cellMM) mm cell)",
                              action: (title: refusedInfoButton, run: { AppPopups.shared.help(refusedTitle, info) }))
        return false
    }
}
