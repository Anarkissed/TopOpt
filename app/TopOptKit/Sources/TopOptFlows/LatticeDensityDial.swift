// LatticeDensityDial — ★ notes29 (his iPad notes on release 20, 2026-11-25): "Every single lattice type was quilted ...
// set up tests to find the EXACT density and size at which each lattice type becomes a quilt and limit both when 'Allow
// quilt' is turned off. The 'Density' grade percentage should then be limited within that, with a notification popping up
// if they try to go further (like 100%) saying that it can't until 'Allow Quilt' is turned back on."
//
// The Density percent the page shows and takes is his own ruling of 2026-08-25 ("Make 1% be the printability floor. Make
// 100% be the quilt"), linear in strut width on the cell it is read on (`ProjectModel.latticeDensityBandDiametersMM`):
// 100 % is the TYPE'S OWN quilt, where its neighbouring struts fuse (core's lattice_quilt_limits touch, through the engine:
// `LatticeLayoutSession.typeFacts`), never another type's number and never over 100 %. With Allow quilt off the engine
// never lays a strut past the type's open look (core's lattice_quilt_limits open_look, under its quilt, its channels and its
// see-through), so the page stops there: a percent past it is refused with a centred pop-up (AppPopups) that says Allow
// quilt must be on to go further. With Allow quilt on, up to 100 %.
//
// Core's own dial (StrutSpec::dial, R10) is 0.01 at the thinnest strut the engine lays and 1 at the widest Allow quilt
// allows (the open look off, the quilt on); `coreDial` turns the page's percent into it, so the strut core lays is the
// strut the percent names.
import Foundation
import TopOptKit

public enum LatticeDensityDial {
    /// The type's two limits, strut width over cell (core's lattice_quilt_limits through the engine's type facts): the open
    /// look (the widest with Allow quilt off) and the quilt (where its struts fuse: 100 %). nil: the engine does not lay
    /// the type (a sheet, an unknown id), and no strut limit is said for it.
    public static func limits(topology: String) -> (openLook: Double, quilt: Double)? {
        let f = LatticeLayoutSession.typeFacts(topology.isEmpty ? "octet" : topology)
        guard f.lays, f.touch > 0, f.openLook > 0, f.openLook < f.touch else { return nil }
        return (f.openLook, f.touch)
    }

    /// The percent a strut of `strutMM` is on a cell of `cellMM` (1 ... 100, never over), or nil when the type has no band.
    public static func percent(strutMM: Double, cellMM: Double, topology: String, lineWidthMM: Double) -> Double? {
        guard cellMM > 0, strutMM > 0,
              let b = ProjectModel.latticeDensityBandDiametersMM(topology: topology, lineWidthMM: lineWidthMM, cellMM: cellMM),
              b.hi > b.lo else { return nil }
        return 1 + 99 * Swift.max(0, Swift.min(1, (strutMM - b.lo) / (b.hi - b.lo)))
    }

    /// The most the percent may be with Allow quilt off on a cell of `cellMM`: the type's open look there. nil: no limit is
    /// known (the type is not the engine's), and nothing is refused.
    public static func openLookPercent(cellMM: Double, topology: String, lineWidthMM: Double) -> Double? {
        guard let q = limits(topology: topology) else { return nil }
        return percent(strutMM: q.openLook * cellMM, cellMM: cellMM, topology: topology, lineWidthMM: lineWidthMM)
    }

    /// The page's percent as core's dial (StrutSpec::dial, R10: 0.01 the thinnest strut, 1 the widest the switch allows).
    /// The percent is read on `cellMM` (the cell core reads its dial on: the part's or the region's largest); with Allow quilt
    /// off a percent past the open look is held at core's 1 (the page refuses it before it gets here).
    public static func coreDial(percent pct: Double, cellMM: Double, topology: String, lineWidthMM: Double,
                                            minStrutLines: Double, allowQuilt: Bool) -> Double {
        let plain = Swift.min(1, Swift.max(0.01, pct / 100))
        guard cellMM > 0, let q = limits(topology: topology),
              let b = ProjectModel.latticeDensityBandDiametersMM(topology: topology, lineWidthMM: lineWidthMM, cellMM: cellMM),
              b.hi > b.lo else { return plain }
        let d = b.lo + (Swift.max(1, Swift.min(100, pct)) - 1) / 99 * (b.hi - b.lo)
        let thinnest = Swift.max(lineWidthMM, minStrutLines * lineWidthMM)
        let widest = Swift.max(thinnest, (allowQuilt ? q.quilt : q.openLook) * cellMM)
        let t = widest > thinnest ? Swift.max(0, Swift.min(1, (d - thinnest) / (widest - thinnest))) : 1
        return 0.01 + 0.99 * t
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
        /// The most the box may say with the switch as it is (percent): the open look's with Allow quilt off, else 100.
        public var most: Double {
            allowQuilt ? 100
                : (LatticeDensityDial.openLookPercent(cellMM: cellMM, topology: topology, lineWidthMM: lineWidthMM)?
                    .rounded(.down) ?? 100)
        }
        /// A typed percent as the density to store; nil when refused (Allow quilt off and past the open look: the centred
        /// pop-up says so).
        @MainActor public func typed(_ pct: Double) -> Double? {
            guard LatticeDensityDial.accept(pct, allowQuilt: allowQuilt, cellMM: cellMM, topology: topology,
                                            lineWidthMM: lineWidthMM) else { return nil }
            return ProjectModel.latticeDensityForPercent(Swift.min(100, Swift.max(1, pct)), cellMM: cellMM,
                                                         topology: topology, lineWidthMM: lineWidthMM) ?? pct / 100
        }
    }

    /// The pop-up's words (a title of at most five words; plain sentences).
    public static let refusedTitle = "Struts would fuse"
    public static func refusedText(limit: Double) -> String {
        "Past \(Int(limit.rounded(.down))) % the struts touch and close into a quilt. To go further, turn Allow quilt back on."
    }

    /// Is `pct` allowed? With Allow quilt off a percent past the open look is refused, and the centred pop-up says why.
    @MainActor @discardableResult
    public static func accept(_ pct: Double, allowQuilt: Bool, cellMM: Double, topology: String, lineWidthMM: Double) -> Bool {
        guard !allowQuilt, pct > 0,
              let limit = openLookPercent(cellMM: cellMM, topology: topology, lineWidthMM: lineWidthMM),
              pct > limit.rounded(.down) + 1e-9 else { return true }
        AppPopups.shared.show(refusedTitle, refusedText(limit: limit),
                              log: "density \(pct) % past the open look \(limit) % (\(topology), \(cellMM) mm cell)")
        return false
    }
}
