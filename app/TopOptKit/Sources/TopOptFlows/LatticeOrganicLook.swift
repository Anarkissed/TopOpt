// LatticeOrganicLook — ★ ORGANIC, CUT 1 (his 11-18: "Preview PLUS settings simultaneously"): his 13 Organic controls, saved
// with the project, and their mapping to the engine's OrganicAsk (LatticeReview 11-18 08:54Z; memory organic-cut1-controls-
// mapping). Five take his four modes, in his order ("set the two sweeps *first* in line"): Auto Sweep (a range the app works
// out, shown in the fields), Manual Sweep (a range he types), Auto (one number the app works out), Manual (one number he
// types); only the Sweeps follow a gradient, greyed only when BOTH gradients (shape, stress) are off (his "correct").
// Every saved field is optional (an old project decodes), nil = Auto.
import Foundation
import TopOptKit

public struct LatticeOrganicLook: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case traced, grown
        public var title: String { self == .traced ? "Traced" : "Grown" }
    }
    /// His four modes, in his order.
    public enum Four: String, Codable, CaseIterable, Sendable {
        case autoSweep, manualSweep, auto, manual
        public var title: String {
            switch self {
            case .autoSweep: return "Auto Sweep"
            case .manualSweep: return "Manual Sweep"
            case .auto: return "Auto"
            case .manual: return "Manual"
            }
        }
        public var isSweep: Bool { self == .autoSweep || self == .manualSweep }
        public var isAuto: Bool { self == .autoSweep || self == .auto }
    }
    /// One swept setting: its mode and what he typed (a Sweep's light and heavy ends, or one number). nil = not typed.
    public struct Swept: Codable, Equatable, Sendable {
        public var mode: Four?
        public var light: Double?, heavy: Double?, single: Double?
        public init(mode: Four? = nil, light: Double? = nil, heavy: Double? = nil, single: Double? = nil) {
            self.mode = mode; self.light = light; self.heavy = heavy; self.single = single
        }
    }

    public var mode: Mode?
    public var cell: Swept?, strut: Swept?, wallGap: Swept?, crossGap: Swept?, tieGap: Swept?
    public var wallSeeds: Bool?, crossingVines: Bool?, flatTies: Bool?
    public var seeds: Double?, roots: Double?, runMax: Int?, topBranches: Double?
    public var stressFollow: Bool?, gradeToShape: Bool?, shapeReach: Double?, detectFloating: Bool?
    /// ★ his 11-18: the gradient — stress and shape (nil / true), or shape alone (false)
    public var followStress: Bool?
    public var linkWidth: Double?, unbracedMax: Double?, spacingExponent: Double?
    public init() {}

    // MARK: the resolved values (nil = Auto, his judged stand jobs' values)

    public var modeValue: Mode { mode ?? .grown }
    /// ★ His ruling 11-18: Grade to shape has no off switch in cut 1 (never run off); its reach is the control.
    public var gradeToShapeValue: Bool { true }
    /// ★ his 11-18: stress and shape, or shape alone (offered once the engine's key is run on his stand).
    public var followStressValue: Bool { followStress ?? true }
    /// His rule: the Sweeps are greyed only when BOTH gradients are off (shape is always on in cut 1, so never).
    public var sweepsAllowed: Bool { gradeToShapeValue || followStressValue }
    /// Cell size or strut thickness takes Auto's numbers (Auto or Auto Sweep).
    public var usesAuto: Bool { four(cell, offered: Self.cellModes).isAuto || four(strut).isAuto }
    /// ★ HIS RULING 11-18 ("It shouldn't be an option if we can't do it or haven't tested"): no single-number Auto
    /// anywhere; Cell size only as a Sweep (a single cell size was never run, and with it no heavy end acts).
    public static let cellModes: [Four] = [.autoSweep, .manualSweep]
    public static var otherModes: [Four] { offered(.manualNumbers) ? [.autoSweep, .manualSweep, .manual] : [.autoSweep, .manualSweep] }

    /// The options his controls hold (all offered: his correction 11-18 below).
    public enum Option: String, CaseIterable, Sendable {
        case wallSeedsOff, crossingVinesOff, flatTiesOff, stressFollowOff, detectFloatingOff, roots, topBranches
        case seeds, linkWidth, unbracedOther, shapeReach, manualNumbers
        /// ★ his 11-18: "a choice between stress and shape gradient or shape gradient alone" (engine key organic_follow_stress)
        case shapeOnly
    }
    /// ★ HIS CORRECTION 11-18: "NO! Don't! I will test when it is on the iPad! I meant specifically regarding the Auto
    /// singular part. Please leave the other settings alone." Every setting is offered as designed; he tests them on the
    /// iPad (the Gradient line too, since the engine's organic_follow_stress, OP6, merged in 3aa1e8f1).
    public static func offered(_ o: Option) -> Bool { true }
    /// A swept setting's mode, one of the modes offered; Auto Sweep unless set.
    public func four(_ s: Swept?, offered: [Four] = otherModes) -> Four {
        let m = s?.mode ?? .autoSweep
        return offered.contains(m) ? m : .autoSweep
    }

    /// The Auto numbers of a gap control: (single = Auto, Auto Sweep = light to heavy), in local spacings.
    public struct GapAuto: Sendable { public let single: Double, light: Double, heavy: Double }
    public static let wallGapAuto = GapAuto(single: 2.5, light: 2.5, heavy: 1.0)
    public static let crossGapAuto = GapAuto(single: 2.5, light: 2.5, heavy: 1.0)
    public static let tieGapAuto = GapAuto(single: 1.0, light: 1.0, heavy: 0.5)

    /// The Auto Sweep limits for cell size and strut thickness: core's, per region, before the lay (Session::sweep_limits,
    /// OP5; one source).
    public struct Limits: Equatable, Sendable {
        public var strutLowerMM: Double, strutUpperMM: Double, strutAutoMM: Double
        public var cellLowerMM: Double, cellUpperMM: Double, cellAutoMM: Double
        public var measured: Bool
        public init(strutLowerMM: Double, strutUpperMM: Double, strutAutoMM: Double, cellLowerMM: Double, cellUpperMM: Double,
                    cellAutoMM: Double, measured: Bool = true) {
            self.strutLowerMM = strutLowerMM; self.strutUpperMM = strutUpperMM; self.strutAutoMM = strutAutoMM
            self.cellLowerMM = cellLowerMM; self.cellUpperMM = cellUpperMM; self.cellAutoMM = cellAutoMM
            self.measured = measured
        }
        /// One region's limits as core measured them.
        public init(_ m: LatticeLayoutSession.SweepLimits) {
            self.init(strutLowerMM: m.strutLowerMM, strutUpperMM: m.strutUpperMM, strutAutoMM: m.strutAutoMM,
                      cellLowerMM: m.cellLowerMM, cellUpperMM: m.cellUpperMM, cellAutoMM: m.cellAutoMM, measured: m.measured)
        }
    }

    /// ★ The engine's ask, from his controls (LatticeReview 11-18 08:54Z). `limits` nil (a region core cannot measure, a
    /// curved shell): Auto falls back to Manual's typed numbers or core's defaults, and the page says why.
    public func ask(limits: Limits?, layerMM: Double = 0.2) -> LatticeLayoutSession.Organic {
        var o = LatticeLayoutSession.Organic()
        let grown = modeValue == .grown
        o.mode = grown ? .grown : .traced
        o.followStress = followStressValue   // OP6: stress and shape, or shape only
        // the swept settings
        let cellMode = four(cell, offered: Self.cellModes), strutMode = four(strut)
        var cellLight = 8.0, cellHeavy = 3.0, cellSingle: Double?
        switch cellMode {
        case .autoSweep: if let l = limits { cellLight = l.cellUpperMM; cellHeavy = l.cellLowerMM }
        case .manualSweep: cellLight = cell?.light ?? limits?.cellUpperMM ?? 8; cellHeavy = cell?.heavy ?? limits?.cellLowerMM ?? 3
        case .auto: cellSingle = limits?.cellAutoMM ?? cell?.single
        case .manual: cellSingle = cell?.single ?? limits?.cellAutoMM
        }
        if let c = cellSingle {   // (not offered: his ruling 11-18)
            o.spacingMM = c; cellLight = c; cellHeavy = c
        } else {
            o.spacingMinMM = Swift.min(cellLight, cellHeavy); o.spacingMaxMM = Swift.max(cellLight, cellHeavy)
            if cellMode == .manualSweep, let e = spacingExponent { o.spacingExponent = e }
        }
        switch strutMode {
        case .autoSweep: o.widthMM = limits?.strutLowerMM ?? 0; o.widthHeavyMM = limits?.strutUpperMM ?? 0
        case .manualSweep: o.widthMM = strut?.light ?? limits?.strutLowerMM ?? 0; o.widthHeavyMM = strut?.heavy ?? limits?.strutUpperMM ?? 0
        case .auto: o.widthMM = limits?.strutAutoMM ?? strut?.single ?? 0
        case .manual: o.widthMM = strut?.single ?? limits?.strutAutoMM ?? 0
        }
        func gap(_ s: Swept?, _ a: GapAuto) -> (Double, Double) {
            switch four(s) {
            case .autoSweep: return (a.light, a.heavy)
            case .manualSweep: return (s?.light ?? a.light, s?.heavy ?? a.heavy)
            case .auto: return (a.single, 0)
            case .manual: return (s?.single ?? a.single, 0)
            }
        }
        // Grown's seeds, vines, roots, branches
        let walls = grown && (wallSeeds ?? true)
        o.wallsOut = walls
        (o.wallGap, o.wallGapHeavy) = walls ? gap(wallGap, Self.wallGapAuto) : (0, 0)
        o.wallCross = walls && (crossingVines ?? true) ? 1 : 0   // never 2 (LatticeReview)
        (o.crossGap, o.crossGapHeavy) = o.wallCross == 1 ? gap(crossGap, Self.crossGapAuto) : (2.5, 0)
        o.tieLevel = flatTies ?? true
        o.ties = true
        (o.tieGap, o.tieGapHeavy) = o.tieLevel ? gap(tieGap, Self.tieGapAuto) : (1.0, 0)
        if grown {
            o.footGap = seeds ?? 2.5
            o.rootRun = roots ?? 0
            o.topRun = topBranches ?? 0
            o.runMax = Int32(runMax ?? 1)
            o.stressGoal = stressFollow ?? true
            o.prune = true
        }
        // shape, floating parts, links, braces
        o.shapeFit = gradeToShapeValue
        o.shapeReach = shapeReach ?? 1
        o.memberCap = false
        o.holdParts = detectFloating ?? true
        if o.holdParts {
            o.partToFloor = true
            o.partReachMM = 1.5 * Swift.max(cellLight, cellHeavy)
            o.partSupportMM = 0.75 * Swift.min(cellLight, cellHeavy)
        }
        o.linkWidth = linkWidth ?? 1
        o.unbracedMax = unbracedMax ?? 10
        // always sent (LatticeReview): the flat floor, the stress reference
        o.bedFloorMM = 4 * layerMM
        o.referenceMPa = 0
        o.percentile = 0.95
        return o
    }
}
