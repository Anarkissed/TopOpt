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
    /// ★ Look, 1 to 100 % (nil = 50): this look's own (per group, or the whole part's).
    public var lookPercent: Double?
    /// ★ His 11-18: "Simulate stresses on unstressed walls" (Organic, Aesthetic only; nil = off). Each wall's number of
    /// foci is set in Selections (LatticeSettings.selectableSyntheticFoci, default organicSyntheticFoci = 3).
    public var syntheticStresses: Bool?
    /// ★ His 11-19 note: an Organic group's finish is "None/Skin/Solid. Rim should be hidden." (nil = the part's finish)
    public enum Finish: String, Codable, CaseIterable, Sendable {
        case none, skin, solid
        public var title: String { switch self { case .none: return "None"; case .skin: return "Skin"; case .solid: return "Solid" } }
    }
    public var finish: Finish?
    /// ★ His 11-20 skin note (via LatticeReview 01:49Z): "skin thickness and density of skin tendrils should be added as
    /// manual variables". The engine's OJ8 keys: `skin_width_mm` 0 to 3 mm (nil or 0 = Auto: the thinner vine's width) and
    /// `skin_density` a whole number 1 to 6 (nil = 3, the old engine's joining; 1 nearest neighbours only, 6 the widest).
    /// Shown in Manual under a Skin finish; Auto sends neither.
    public var skinWidthMM: Double?
    public var skinDensity: Int?
    public var skinDensityValue: Int { skinDensity ?? Self.skinDensityAuto }
    public static let skinDensityAuto = 3, skinDensityRange = 1...6, skinWidthMaxMM = 3.0
    public static let skinWidthInfo = "How thick the skin's strands are. Auto makes them as thick as the thinner vine they join."
    public static let skinDensityInfo = "How many strands each landing on the face joins: 1 joins only nearest neighbours, "
        + "6 the most. 3 is the usual."
    /// ★ Cut 2 (his 11-19, via LatticeReview 19:51Z): depth variation, "a single on/off that limits to 1mm". On sends
    /// `organic_face_relief_mm` 1.0 (vines keep their round tops up to 1 mm outside an open face), off sends 0 (every vine
    /// cut flush at the face). "Default is not flush" (on). Loaded and fixed faces stay flush whatever it says.
    public var depthVariation: Bool?
    public var depthVariationValue: Bool { depthVariation ?? true }
    /// ★ Cut 2 (his 11-19): "Make the extra spacing between vines an on/off check as well with an (i) that notes it will likely
    /// lose strength." On sends `organic_strand_keep` 0.9, off 0.5. His default: "On in Aesthetic only".
    public var extraSpacing: Bool?
    public func extraSpacingValue(aesthetic: Bool) -> Bool { extraSpacing ?? aesthetic }
    public static let faceReliefOnMM = 1.0, strandKeepOn = 0.9, strandKeepOff = 0.5
    /// ★ Whether the engine takes the cut 2 keys: ON since claude/organic-engine is merged (11-20); the two rows are offered.
    nonisolated(unsafe) public static var cut2Wired = true
    public static let depthVariationInfo = "On: vines keep their round tops up to 1 mm outside an open face. Off: every vine "
        + "is cut flush at the face. Faces that carry a load or are fixed are always flush."
    public static let extraSpacingInfo = "Leaves more room between the vines. It will likely lose strength: fine for "
        + "Aesthetic, and it may still work in Structural if there is strength to spare."
    /// ★ Whether the engine takes a group's own Organic finish (OJ1/OJ2/OJ8): ON since claude/organic-engine is merged (11-20).
    nonisolated(unsafe) public static var finishWired = true
    public init() {}
    public var lookPercentValue: Double { Swift.min(Swift.max(lookPercent ?? 50, 1), 100) }

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
    /// The page's (i) on Look (Organic, Auto): his 11-18 "Look should change ALL the variables by messing with the cell range".
    public static let lookInfo = "Look moves the whole cell range: 50 % is the range measured for your part, higher is "
        + "finer (smaller cells), lower is more open. Everything counted in cells follows it; strut thickness does not. "
        + "Manual shows every Organic setting, starting from the range Look gives."
    /// ★ His 11-18 iPad notes: on the page's Auto only Look shows, and every other setting is Auto.
    public func effective(pageManual: Bool) -> LatticeOrganicLook {
        guard !pageManual else { return self }
        var auto = LatticeOrganicLook()
        auto.lookPercent = lookPercent   // Auto keeps its Look
        auto.finish = finish             // ★ cut 2: and its Finish (the row shows in Auto too); the skin's numbers are Manual's
        return auto
    }
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
        /// ★ Cut 2, OG1: the gap the engine keeps between struts (0: off). No cell may be smaller than the thin strut plus it.
        public var gapMM: Double = 0
        public init(strutLowerMM: Double, strutUpperMM: Double, strutAutoMM: Double, cellLowerMM: Double, cellUpperMM: Double,
                    cellAutoMM: Double, measured: Bool = true, gapMM: Double = 0) {
            self.strutLowerMM = strutLowerMM; self.strutUpperMM = strutUpperMM; self.strutAutoMM = strutAutoMM
            self.cellLowerMM = cellLowerMM; self.cellUpperMM = cellUpperMM; self.cellAutoMM = cellAutoMM
            self.measured = measured; self.gapMM = gapMM
        }
        /// One region's limits as core measured them.
        public init(_ m: LatticeLayoutSession.SweepLimits) {
            self.init(strutLowerMM: m.strutLowerMM, strutUpperMM: m.strutUpperMM, strutAutoMM: m.strutAutoMM,
                      cellLowerMM: m.cellLowerMM, cellUpperMM: m.cellUpperMM, cellAutoMM: m.cellAutoMM, measured: m.measured,
                      gapMM: m.gapMM)
        }

        /// ★ The whole part's limits (LatticeReview's ruling 3): the UNION over the measured regions — the smallest lower
        /// end, the largest upper end, for cells and struts alike; Auto the middle (struts in whole lines, cells to 0.5 mm).
        /// nil: no region measured (Auto is unavailable; Manual Sweep is typed).
        public static func union(_ all: [Limits], lineMM: Double) -> Limits? {
            let m = all.filter(\.measured)
            guard let first = m.first else { return nil }
            var u = first
            for l in m.dropFirst() {
                u.strutLowerMM = Swift.min(u.strutLowerMM, l.strutLowerMM); u.strutUpperMM = Swift.max(u.strutUpperMM, l.strutUpperMM)
                u.cellLowerMM = Swift.min(u.cellLowerMM, l.cellLowerMM); u.cellUpperMM = Swift.max(u.cellUpperMM, l.cellUpperMM)
                u.gapMM = Swift.max(u.gapMM, l.gapMM)
            }
            if m.count > 1 {
                u.strutAutoMM = Check.lines((u.strutLowerMM + u.strutUpperMM) / 2, lineMM: lineMM)
                u.cellAutoMM = Check.half((u.cellLowerMM + u.cellUpperMM) / 2)
            }
            return u
        }

        /// ★ LOOK (his 11-18: "Look should change ALL the variables by messing with the cell range"; LatticeReview's ruling
        /// 2): both cell ends times one factor f — p <= 50: 2^((50 - p) / 49) (1 % gives 2); p >= 50: 2^(-(p - 50) / 50)
        /// (100 % gives 0.5) — to the nearest 0.5 mm, the lower end never under the smallest printable cell (1.535 x the
        /// thin strut) nor, cut 2's gap rule (OG1), under the thin strut plus the gap (up to 0.5 mm: the engine refuses less),
        /// the upper never under the lower. Struts are not moved. At 50 % the measured limits themselves.
        public func looked(percent p: Double) -> Limits {
            let pc = Swift.min(Swift.max(p, 1), 100)
            let f = pc <= 50 ? pow(2, (50 - pc) / 49) : pow(2, -(pc - 50) / 50)
            var l = self
            l.cellLowerMM = Swift.max(Check.half(cellLowerMM * f), Check.smallestCellMM(thinStrutMM: strutLowerMM, gapMM: gapMM))
            l.cellUpperMM = Swift.max(l.cellLowerMM, Check.half(cellUpperMM * f))
            l.cellAutoMM = Swift.max(l.cellLowerMM, Check.half((l.cellLowerMM + l.cellUpperMM) / 2))
            return l
        }
    }

    /// ★ What a typed number must be (LatticeReview's ruling 4, organic-app-rulings.md; the engine's own rules, sheet D):
    /// one plain line, or nil when it is fine. The app refuses ONLY these. (The engine's own texts replace these when its
    /// validation call lands: E1.)
    public enum Check {
        static func n(_ v: Double) -> String { StrengthCheckDocs.number(v) }
        /// Whole printed lines, at least one.
        public static func lines(_ v: Double, lineMM: Double) -> Double { Swift.max(1, (v / lineMM).rounded()) * lineMM }
        /// To the nearest 0.5 mm.
        public static func half(_ v: Double) -> Double { (v * 2).rounded() / 2 }
        /// The smallest printable cell: 0.5 x sqrt(3 pi) x the thin strut (1.535 x), up to the next 0.5 mm (1.5 mm at 0.9).
        public static func smallestCellMM(thinStrutMM t: Double) -> Double { (2 * 0.5 * (3 * Double.pi).squareRoot() * t).rounded(.up) / 2 }
        /// ★ Cut 2, OG1: and the smallest cell that leaves `gapMM` between struts of the thin width (core's gap_cell_mm: the
        /// thin strut + the gap, up to the next 0.5 mm; 2 mm at 0.9 mm and a 0.675 mm gap). The larger of the two.
        public static func gapCellMM(thinStrutMM t: Double, gapMM g: Double) -> Double {
            g > 0 ? ((t + g) * 2 - 1e-9).rounded(.up) / 2 : 0
        }
        public static func smallestCellMM(thinStrutMM t: Double, gapMM g: Double) -> Double {
            Swift.max(smallestCellMM(thinStrutMM: t), gapCellMM(thinStrutMM: t, gapMM: g))
        }
        /// The engine's gap between struts (organic_gap_lines 1.5, the app sends no other): 1.5 printed lines.
        public static let gapLines = 1.5
        /// Cell size, a Sweep (rule b, c): the small end above 0 and at least the smallest printable cell, and (cut 2) at
        /// least the cell that leaves the gap between struts (`gapMM`, 0: no gap rule); large >= small.
        public static func cell(small: Double, large: Double, thinStrutMM: Double, gapMM: Double = 0) -> String? {
            if !(small > 0) { return "Cell size: the small end must be above 0 mm" }
            let printFloor = smallestCellMM(thinStrutMM: thinStrutMM), gapFloor = gapCellMM(thinStrutMM: thinStrutMM, gapMM: gapMM)
            if small < Swift.max(printFloor, gapFloor) - 1e-9 {
                return gapFloor > printFloor
                    ? "Cell size: at least \(n(gapFloor)) mm, the smallest cell that leaves a \(n(gapMM)) mm gap between \(n(thinStrutMM)) mm struts"
                    : "Cell size: at least \(n(printFloor)) mm, the smallest cell that prints with \(n(thinStrutMM)) mm struts"
            }
            if large < small - 1e-9 { return "Cell size: the second number must be at least the first" }
            return nil
        }
        /// Strut thickness (rule a): the thin end at least two printed lines; the thick end at least the thin end.
        public static func strut(thin: Double, thick: Double?, thinnestMM: Double) -> String? {
            if thin < thinnestMM - 1e-9 { return "Strut thickness: at least \(n(thinnestMM)) mm, two printed lines" }
            if let k = thick, k < thin - 1e-9 { return "Strut thickness: the second number must be at least the first" }
            return nil
        }
        /// A gap in local spacings (rule d): the wide end above 0; the close end 0 (off) or above 0 and up to the wide end.
        public static func gap(_ name: String, close: Double?, wide: Double) -> String? {
            if !(wide > 0) { return "\(name): must be above 0" }
            if let c = close, c < 0 || c > wide + 1e-9 { return "\(name): the first number is 0 (off) or up to the second" }
            return nil
        }
        /// Longest strut without a joint (rule f): 0 (off) or 4 to 40 strut widths.
        public static func unbraced(_ v: Double) -> String? {
            v == 0 || (4...40).contains(v) ? nil : "Longest strut without a joint: 0 (off) or 4 to 40 strut widths"
        }
        public static func link(_ v: Double) -> String? { (0.5...2).contains(v) ? nil : "Link thickness: 0.5 to 2 times the strut" }
        public static func atLeastZero(_ name: String, _ v: Double) -> String? { v >= 0 ? nil : "\(name): 0 or above" }
        public static func runsPerEnd(_ v: Double) -> String? {
            v >= 1 && v == v.rounded() ? nil : "Runs per end: a whole number, 1 or more"
        }
        /// ★ OJ8: skin thickness 0 (Auto) to 3 mm, the engine's range (skin_width_range).
        public static func skinWidth(_ v: Double) -> String? {
            (0...LatticeOrganicLook.skinWidthMaxMM).contains(v) ? nil : "Skin thickness: 0 (Auto) to \(n(LatticeOrganicLook.skinWidthMaxMM)) mm"
        }
    }

    /// ★ The engine's ask, from his controls (LatticeReview 11-18 08:54Z). `limits` nil (a region core cannot measure, a
    /// curved shell): Auto falls back to Manual's typed numbers or core's defaults, and the page says why.
    public func ask(limits: Limits?, layerMM: Double = 0.2, aesthetic: Bool = false,
                    flushFaces: [Int32] = []) -> LatticeLayoutSession.Organic {
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
        o.layerMM = layerMM   // ★ sheet H2: the printer's layer, not 0.2 always
        o.referenceMPa = 0
        o.percentile = 0.95
        // ★ Cut 2 (his 11-19 switches; "ALWAYS send both keys"): depth variation (on 1 mm, off flush), the loaded and fixed
        // faces always flush, and the extra spacing between vines (on 0.9, off 0.5; on in Aesthetic only by default)
        o.faceReliefMM = depthVariationValue ? Self.faceReliefOnMM : 0
        o.reliefExcludeFaces = flushFaces
        o.strandKeep = extraSpacingValue(aesthetic: aesthetic) ? Self.strandKeepOn : Self.strandKeepOff
        return o
    }
}
