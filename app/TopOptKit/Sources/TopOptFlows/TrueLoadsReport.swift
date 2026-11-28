// TrueLoadsReport — the app's side of the TO rebuild's stages 1 and 2 ("For #362" in
// docs/design/to-rebuild/stages/stage-1-true-loads.md): the report keys core writes only while their switches are on
// (core/src/settings/report.cpp):
//   "as_drawn"          {margin, required, passes}: a reduction run that kept no version, and how the part as drawn stands.
//                       Too weak as drawn → ONE centred pop-up offering Strengthen (agreed 2026-11-25).
//   "pads"              [{face_id | region_id, thickness_mm, pad_mm, automatic}]: the pad each fixed or loaded face got
//                       (Auto = the automatic pad at strength 0.2, his yes 2026-11-26; Manual = a typed depth in mm).
//   "too_small"         {thickest_mm, needed_mm, line_width_mm, nozzle_that_fits_mm}: ONE pop-up recommending the nozzle
//                       that fits — 0.6, 0.4 or 0.2 mm only — or resin when it is 0.
//   "strength_reading"  and "drawn_part" {printed_grams, solid_grams} (stage 2): each version's grams are PRINTED grams.
//   a refused version whose rejection_reason is "the load has no path to a mount" (the connection rule): plain words on that
//                       version; the design let go of the load, the solver ran fine.
// Every key is absent unless its switch is on: a report without them decodes to an empty value and every caller then
// behaves exactly as before. Pure values and words, asserted headlessly (Notes30TrueLoadsTests); RunModel, RunScreen and
// the Results details read them. HIS RULES on every string here: captions ≤ 5 words, detail behind an (i), errors in centred
// pop-ups, positive words, never a face number.

import Foundation

public struct TrueLoadsReport: Equatable, Sendable {
    /// `as_drawn`: the part as drawn, certified, on a reduction run that kept no version.
    public struct AsDrawn: Equatable, Sendable {
        public let margin: Double
        public let required: Double
        public let passes: Bool
    }
    /// One `pads` entry. Exactly one of `faceID` / `regionID` is set (core's face id on the run, or a cut piece's region id).
    public struct Pad: Equatable, Sendable {
        public let faceID: Int?
        public let regionID: Int?
        /// The plastic measured behind the face (mm); 0 = not measured (a typed pad).
        public let thicknessMM: Double
        public let padMM: Double
        public let automatic: Bool
    }
    /// `too_small`: the part's thickest section is under three line widths.
    public struct TooSmall: Equatable, Sendable {
        public let thickestMM: Double
        public let neededMM: Double
        public let lineWidthMM: Double
        /// Core's nozzle that fits (0 = none: resin).
        public let nozzleThatFitsMM: Double
    }
    /// `strength_reading`: which form of the strength reading the job used (stage 2).
    public struct StrengthReading: Equatable, Sendable {
        public let sizeMM: Double
        public let voxelMM: Double
        public let needsVoxelMM: Double
        public let overSize: Bool
    }
    /// `drawn_part`: the part as drawn, printed at the job's walls and infill, and printed solid (stage 2).
    public struct DrawnPart: Equatable, Sendable {
        public let printedGrams: Double
        public let solidGrams: Double
    }

    public var asDrawn: AsDrawn?
    public var pads: [Pad] = []
    public var tooSmall: TooSmall?
    public var strengthReading: StrengthReading?
    public var drawnPart: DrawnPart?
    /// The volume fractions core asked for of the versions refused because the load lost its path to every anchor.
    public var noPathVolumeFractions: [Double] = []

    public init() {}

    /// Core's reason for a version whose load reaches no anchor (pipeline.hpp kLoadUnheldReason), word for word.
    public static let noPathReason = "the load has no path to a mount"

    /// Stage 2's switch was on: each version's `mass_grams` (and so every gram the results show) is printed grams.
    public var printedGrams: Bool { strengthReading != nil || drawnPart != nil }

    /// Nothing here: the report came from a build with every switch off.
    public var isEmpty: Bool { self == TrueLoadsReport() }

    public static func decode(reportJSON: Data?) -> TrueLoadsReport {
        guard let d = reportJSON, let r = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            return TrueLoadsReport()
        }
        return decode(report: r)
    }

    public static func decode(report r: [String: Any]) -> TrueLoadsReport {
        var t = TrueLoadsReport()
        if let a = r["as_drawn"] as? [String: Any] {
            let m = num(a["margin"]), req = num(a["required"])
            t.asDrawn = AsDrawn(margin: m, required: req, passes: a["passes"] as? Bool ?? (m >= req))
        }
        t.pads = (r["pads"] as? [[String: Any]] ?? []).compactMap { p in
            let face = (p["face_id"] as? NSNumber)?.intValue, region = (p["region_id"] as? NSNumber)?.intValue
            guard face != nil || region != nil else { return nil }
            return Pad(faceID: face, regionID: face == nil ? region : nil, thicknessMM: num(p["thickness_mm"]),
                       padMM: num(p["pad_mm"]), automatic: p["automatic"] as? Bool ?? false)
        }
        if let s = r["too_small"] as? [String: Any] {
            t.tooSmall = TooSmall(thickestMM: num(s["thickest_mm"]), neededMM: num(s["needed_mm"]),
                                  lineWidthMM: num(s["line_width_mm"]), nozzleThatFitsMM: num(s["nozzle_that_fits_mm"]))
        }
        if let s = r["strength_reading"] as? [String: Any] {
            t.strengthReading = StrengthReading(sizeMM: num(s["size_mm"]), voxelMM: num(s["voxel_mm"]),
                                                needsVoxelMM: num(s["needs_voxel_mm"]), overSize: s["over_size"] as? Bool ?? false)
        }
        if let d = r["drawn_part"] as? [String: Any] {
            t.drawnPart = DrawnPart(printedGrams: num(d["printed_grams"]), solidGrams: num(d["solid_grams"]))
        }
        // a refused version is a report-only row (core never accepts one whose load reaches no anchor)
        let refused = r["rejected_variants"] as? [[String: Any]] ?? []
        t.noPathVolumeFractions = refused.filter { ($0["rejection_reason"] as? String) == noPathReason }
            .map { num($0["volume_fraction"]) }
        return t
    }

    private static func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
}

// MARK: - the one pop-up when a run keeps no version

/// What a run that kept no version says in its one centred pop-up, when a true-loads key explains it. nil: today's words.
public enum TrueLoadsFailure: Equatable, Sendable {
    /// The part as drawn is too weak for the load: offer Strengthen.
    case asDrawn(margin: Double, required: Double)
    /// The part is too small for the nozzle: recommend the nozzle that fits, or resin.
    case tooSmall(TrueLoadsReport.TooSmall)
    /// The last version tried cut the load's path to every anchor (the connection rule).
    case noPath

    /// The explanation for a run that kept no version, in order: too weak as drawn, too small for the nozzle, the last
    /// version tried let go of its load. `terminalVF`: the volume fraction core asked for of the last version tried.
    public static func of(_ t: TrueLoadsReport, terminalVF: Double?) -> TrueLoadsFailure? {
        if let a = t.asDrawn, !a.passes { return .asDrawn(margin: a.margin, required: a.required) }
        if let s = t.tooSmall { return .tooSmall(s) }
        if let vf = terminalVF, t.noPathVolumeFractions.contains(where: { abs($0 - vf) < 1e-6 }) { return .noPath }
        return nil
    }

    public var title: String {
        switch self {
        case .asDrawn: return TrueLoadsWords.asDrawnTitle
        case .tooSmall(let s): return TrueLoadsWords.tooSmallTitle(s)
        case .noPath: return TrueLoadsWords.noPathTitle
        }
    }

    public var message: String {
        switch self {
        case let .asDrawn(m, r): return TrueLoadsWords.asDrawnText(margin: m, required: r)
        case .tooSmall(let s): return TrueLoadsWords.tooSmallText(s)
        case .noPath: return TrueLoadsWords.noPathText
        }
    }

    /// Only the too-weak pop-up offers Strengthen.
    public var offersStrengthen: Bool { if case .asDrawn = self { return true } else { return false } }
}

// MARK: - the words (every string the true-loads keys put on the screen)

public enum TrueLoadsWords {
    // ── as drawn (A-05) ──
    public static let asDrawnTitle = "Your part needs strengthening"
    public static func asDrawnText(margin: Double, required: Double) -> String {
        "As drawn, your part holds " + StrengthWords.x(margin) + " its load, and your safety margin asks for "
            + StrengthWords.x(required) + ". Strengthen redesigns it to reach that, adding as little plastic as it can."
    }
    /// The pop-up's button: the setup's own [Minimize │ Strengthen] word.
    public static let strengthenButton = "Strengthen"

    // ── too small for the nozzle ──
    /// The nozzles the app ever recommends (his 2026-11-26: 0.6, 0.4 and 0.2 mm).
    public static let nozzles: [Double] = [0.6, 0.4, 0.2]
    /// Core's nozzle held to those three: the largest of them that fits (core's own list is the same); nil = resin.
    public static func nozzle(_ s: TrueLoadsReport.TooSmall) -> Double? {
        nozzles.first { $0 <= s.nozzleThatFitsMM + 1e-9 }
    }
    static func mm(_ v: Double, decimals: Int = 2) -> String { String(format: "%.\(decimals)f mm", v) }
    static func nozzleMM(_ n: Double) -> String { String(format: "%.1f mm", n) }

    public static func tooSmallTitle(_ s: TrueLoadsReport.TooSmall) -> String {
        nozzle(s).map { "Try a " + nozzleMM($0) + " nozzle" } ?? "Try resin printing"
    }
    public static func tooSmallText(_ s: TrueLoadsReport.TooSmall) -> String {
        let room = "Your part’s thickest section is " + mm(s.thickestMM) + ". A " + mm(s.lineWidthMM) + " line needs "
            + mm(s.neededMM) + " to leave room for a cut. "
        return room + (nozzle(s).map { "A " + nozzleMM($0) + " nozzle fits it." } ?? "Resin printing makes parts this fine.")
    }

    // ── the load lost its path (the connection rule) ──
    public static let noPathTitle = "The load lost its path"
    /// The pop-up's words; the line under them (`noPathLine`, the run's cards) says which version.
    public static let noPathText = "The solver ran fine: the design itself let go of the load."
    /// The line under a run's versions (results and the pop-up's cards), once.
    public static let noPathLine = "A version cut the load’s path to its anchors, so it was set aside"

    // ── the pads (Details › Run) ──
    public static let padLabel = "Pad depth"
    /// "Auto · 1.2–4.5 mm", "Auto · 2.4 mm", "3.0 mm" (typed), or the range when Auto and typed are mixed.
    public static func padValue(_ pads: [TrueLoadsReport.Pad]) -> String? {
        guard let lo = pads.map(\.padMM).min(), let hi = pads.map(\.padMM).max() else { return nil }
        let span = hi - lo < 0.05 ? String(format: "%.1f mm", hi) : String(format: "%.1f–%.1f mm", lo, hi)
        return pads.allSatisfy(\.automatic) ? "Auto \u{00B7} " + span : span
    }
    public static let padInfoLead = "The solid pad kept behind each anchor and load face, so the part holds firmly there. "
        + "Auto sizes each pad from the plastic behind its face; Manual uses the depth you typed."
    /// The (i): the lead, then one line per face by its plain name ("Top face: 2.4 mm, 12.0 mm of plastic behind it").
    /// `names` is parallel to `pads` (nil: "A face" / "A cut piece", never a number).
    public static func padInfo(_ pads: [TrueLoadsReport.Pad], names: [String?]) -> String {
        let lines = pads.enumerated().map { i, p -> String in
            let who = (names.indices.contains(i) ? names[i] : nil) ?? (p.regionID != nil ? "A cut piece" : "A face")
            let how = p.automatic && p.thicknessMM > 0
                ? String(format: ", %.1f mm of plastic behind it", p.thicknessMM) : (p.automatic ? "" : ", typed")
            return who + ": " + String(format: "%.1f mm", p.padMM) + how
        }
        return padInfoLead + "\n\n" + lines.joined(separator: "\n")
    }

    // ── printed grams (stage 2) ──
    /// A version's grams when they are printed grams: "85 g printed".
    public static func printed(_ massLabel: String) -> String { massLabel + " printed" }
    public static let drawnPartLabel = "Part as drawn"
    @MainActor public static func drawnPartValue(_ d: TrueLoadsReport.DrawnPart) -> String? {
        d.printedGrams > 0 ? printed(ResultsModel.massLabel(d.printedGrams)) : nil
    }
    @MainActor public static func drawnPartInfo(_ d: TrueLoadsReport.DrawnPart) -> String {
        "What your part as drawn weighs, printed with your walls and infill."
            + (d.solidGrams > 0 ? " Printed solid, it weighs " + ResultsModel.massLabel(d.solidGrams) + "." : "")
    }
}

// MARK: - the pads' plain names

extension ProjectModel {
    /// A pad's place by its plain name — the face's own name or FaceNames' ("Top face", "Hole, ⌀ 8 mm"), a cut piece's
    /// name — or nil. Never a number (his rule): a stored name that is only a number ("Face 12", "Region 104") is nil.
    public func padPlaceName(_ pad: TrueLoadsReport.Pad) -> String? {
        func plain(_ s: String?) -> String? {
            guard let s, !s.isEmpty, s.range(of: #"^(Face|Region) \d+$"#, options: .regularExpression) == nil else { return nil }
            return s
        }
        if let rid = pad.regionID { return plain(faceRegions.region(rid)?.name) }
        guard let fid = pad.faceID else { return nil }
        // the run's face id is the re-imported one: the face of an anchor or load group the run sent as it (a pad is only
        // ever on one of those), else nil: never a guess that could name another face
        guard let face = selection.groups.flatMap(\.faces).first(where: { Int(self.runFaceID($0)) == fid }) else {
            return nil
        }
        if let own = plain(faceRegions.faceNames[Int32(face)]) { return own }
        guard let m = viewerMesh else { return nil }
        return plain(FaceNames.name(face, in: m, frame: .init(gravity: force.gravity)))
    }
}
