// PrintOrientationModel — ★ notes27 (builder H, orient-app; his print orientation 11-23, SPEC orient/SPEC.md 2a, 2b, 2d, 2e).
//
// His words (11-23 ~17:10): "I want the part first drawn the way it prints. But there should be an option in the results page
// for "Print orientation recommendation" this will then take into account the "Gravity" position the user put as well as the
// shape of the part and decide which orientation is best". And: "I would ABSOLUTELY love to have manual supports drawn on the
// required places in the file ... that changes with the orientation."
//
// The pure half (no views): which way up a result prints and the turn that draws it that way (the bed under it), the print
// frame core turned a file through (un-baked on load: the app draws in the part's own coordinates, the renderer turns it), the
// engine's ranking (`print_orientation`), the topology re-check (`orientation_recheck`), and the words — never face numbers,
// never "+Z".
import Foundation
import simd

// MARK: - the turn that draws a part the way it prints

public enum PrintDraw {
    /// The screen's up (the viewer's floor is under world −Y, as Setup's gravity settle).
    public static let worldUp = SIMD3<Float>(0, 1, 0)

    /// The rotation that stands the part on the bed: its print `up` (model frame) to the screen's up. The shortest turn; a part
    /// printed upside down (up = −Y) turns half a turn about X (never a degenerate turn).
    public static func settle(up: SIMD3<Float>) -> simd_quatf {
        let l = simd_length(up)
        guard l > 1e-6, l.isFinite else { return simd_quatf(angle: 0, axis: worldUp) }
        let u = up / l
        let d = simd_dot(u, worldUp)
        if d > 1 - 1e-6 { return simd_quatf(angle: 0, axis: worldUp) }
        if d < -1 + 1e-6 { return simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0)) }
        return simd_quatf(from: u, to: worldUp)
    }

    /// What Results draws a result standing on: the up its print file was turned to (the report's `print_frame`), else the
    /// project's one resolver (his chosen face, else against his gravity, else +Z: `BuildOrientation.resolved`).
    public static func up(frame: PrintFrameTurn?, orientation: BuildOrientation, gravity: SIMD3<Float>?) -> SIMD3<Float> {
        if let f = frame { return SIMD3<Float>(Float(f.up.x), Float(f.up.y), Float(f.up.z)) }
        return orientation.resolved(gravity: gravity)
    }

    /// The camera's world→screen projection with the part's turn put in front of it, so an overlay pinned to a point of the part
    /// (model frame) lands on the turned part (`ViewerModelFrame`: the renderer's own model matrix, about the mesh's centre).
    public static func modelProjection(_ p: CameraProjection, centre: SIMD3<Float>, rotation: simd_quatf) -> CameraProjection {
        CameraProjection(viewProjection: p.viewProjection * ViewerModelFrame.matrix(centre: centre, rotation: rotation),
                         viewportSize: p.viewportSize)
    }
}

/// What Results draws a result standing on and what "Print orientation" runs, held by ONE reference (Results' own size must
/// not grow: WorkspaceBodySizeTests).
final class ResultsPrintSource {
    let up: SIMD3<Float>?
    let chosenFace: Bool
    let host: PrintOrientationHost?
    init(up: SIMD3<Float>?, chosenFace: Bool, host: PrintOrientationHost?) { self.up = up; self.chosenFace = chosenFace; self.host = host }
}

// MARK: - the print frame core turned a file through

/// core's print frame (print_frame.hpp): print = R · model + t. A lattice file made with a chosen up stands on that face in the
/// file (baked); its report says how (`print_frame`), and every position in the report is the part's own already.
public struct PrintFrameTurn: Equatable, Sendable {
    public var up: SIMD3<Double>
    /// Row by row.
    public var r: [Double]
    public var t: SIMD3<Double>

    public init(up: SIMD3<Double>, r: [Double], t: SIMD3<Double>) { self.up = up; self.r = r; self.t = t }

    /// The report's block {"up": [3], "rotation_row_major": [9], "translation_mm": [3]}; nil when absent or malformed.
    public static func decode(_ any: Any?) -> PrintFrameTurn? {
        guard let o = any as? [String: Any] else { return nil }
        func nums(_ k: String, _ n: Int) -> [Double]? {
            guard let a = o[k] as? [Any], a.count == n else { return nil }
            let d = a.compactMap { ($0 as? NSNumber)?.doubleValue }
            return d.count == n && d.allSatisfy(\.isFinite) ? d : nil
        }
        guard let u = nums("up", 3), let r = nums("rotation_row_major", 9) else { return nil }
        let t = nums("translation_mm", 3) ?? [0, 0, 0]
        return PrintFrameTurn(up: SIMD3(u[0], u[1], u[2]), r: r, t: SIMD3(t[0], t[1], t[2]))
    }

    /// The print frame of a lattice report (`print_frame`); nil when it names none.
    public static func of(report: Data?) -> PrintFrameTurn? { PrintReportFacts.of(report: report).frame }

    /// core's `print_frame_for_up` (print_frame.cpp), the same numbers: along one of the six axes the exact signed permutation
    /// (a half turn about X for −Z); any other up the shortest turn taking it to +Z (Rodrigues about u × z). `base` (model-frame
    /// vertices, xyz…): the part's lowest point at z = 0 (`print_frame_set_base`); nil leaves t = 0.
    public static func forUp(_ up0: SIMD3<Double>, base: [Float]? = nil) -> PrintFrameTurn? {
        let l = simd_length(up0)
        guard l.isFinite, l > 0 else { return nil }
        let u = up0 / l
        var axis = -1, s = 0
        for a in 0..<3 where abs(abs(u[a]) - 1) <= 1e-6 { axis = a; s = u[a] > 0 ? 1 : -1 }
        var r = [Double](repeating: 0, count: 9)
        var up = u
        if axis < 0 {
            let k0 = SIMD3<Double>(u.y, -u.x, 0)
            let sn = (k0.x * k0.x + k0.y * k0.y).squareRoot(), cs = u.z
            let k = k0 / sn
            let K: [Double] = [0, -k.z, k.y, k.z, 0, -k.x, -k.y, k.x, 0]
            var K2 = [Double](repeating: 0, count: 9)
            for i in 0..<3 { for j in 0..<3 { var acc = 0.0; for m in 0..<3 { acc += K[3 * i + m] * K[3 * m + j] }; K2[3 * i + j] = acc } }
            for i in 0..<9 { r[i] = (i % 4 == 0 ? 1 : 0) + sn * K[i] + (1 - cs) * K2[i] }
        } else {
            up = .zero; up[axis] = Double(s)
            let perm: [[Int]] = [[2, 1, 0], [0, 2, 1], [0, 1, 2]]
            let plus: [[Int]] = [[-1, 1, 1], [1, -1, 1], [1, 1, 1]], minus: [[Int]] = [[1, 1, -1], [1, 1, -1], [1, -1, -1]]
            for a in 0..<3 { r[3 * a + perm[axis][a]] = Double(s > 0 ? plus[axis][a] : minus[axis][a]) }
        }
        var f = PrintFrameTurn(up: up, r: r, t: .zero)
        if let v = base, v.count >= 3 {
            var lo = Double.infinity
            var i = 0
            while i + 2 < v.count {
                lo = Swift.min(lo, f.rot(SIMD3(Double(v[i]), Double(v[i + 1]), Double(v[i + 2]))).z)
                i += 3
            }
            if lo.isFinite { f.t = SIMD3(0, 0, lo == 0 ? 0 : -lo) }
        }
        return f
    }

    /// R · v
    public func rot(_ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(r[0] * v.x + r[1] * v.y + r[2] * v.z, r[3] * v.x + r[4] * v.y + r[5] * v.z, r[6] * v.x + r[7] * v.y + r[8] * v.z)
    }
    /// Rᵀ · v
    public func rotT(_ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(r[0] * v.x + r[3] * v.y + r[6] * v.z, r[1] * v.x + r[4] * v.y + r[7] * v.z, r[2] * v.x + r[5] * v.y + r[8] * v.z)
    }
    /// A point of the file (print frame) in the part's own coordinates: Rᵀ (p − t).
    public func toModel(_ p: SIMD3<Double>) -> SIMD3<Double> { rotT(p - t) }
    /// A point of the part in the file: R p + t.
    public func toPrint(_ p: SIMD3<Double>) -> SIMD3<Double> { rot(p) + t }

    /// The file's vertices (xyz…) back in the part's own coordinates ("a baked file is un-baked on load").
    public func unbake(_ v: inout [Float]) {
        var i = 0
        while i + 2 < v.count {
            let m = toModel(SIMD3(Double(v[i]), Double(v[i + 1]), Double(v[i + 2])))
            v[i] = Float(m.x); v[i + 1] = Float(m.y); v[i + 2] = Float(m.z)
            i += 3
        }
    }
}

// MARK: - what a result's report says about printing (read once per report)

/// A result's report, read for printing: its file's print frame, whether it stands on an edge (held by supports), what the file
/// tells the slicer about supports, the engine's ranking (a lattice file's), and a topology re-check spliced in at Keep.
public struct PrintReportFacts: Equatable, Sendable {
    public var frame: PrintFrameTurn?
    public var onEdge = false
    public var slicerSupports: String?
    public var ranking: PrintOrientationRanking?
    public var recheck: PrintRecheck?
    /// A lattice file's first triangles that are the solid (the rest: its tubes).
    public var baseTriangles: Int?

    public static let none = PrintReportFacts()

    /// Read once per report (Results asks on every redraw): a report naming none of the keys is never parsed.
    public static func of(report: Data?) -> PrintReportFacts {
        guard let d = report, !d.isEmpty else { return .none }
        if let hit = memo.first(where: { $0.data.count == d.count && $0.data == d }) { return hit.facts }
        var f = PrintReportFacts.none
        if keys.contains(where: { d.range(of: $0) != nil }), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            f = decode(o)
        }
        memo = Array(([(d, f)] + memo).prefix(4))
        return f
    }
    private static let keys = ["\"print_frame\"", "\"print_orientation\"", "\"slicer_supports\"", "\"orientation_recheck\""]
        .map { Data($0.utf8) }
    nonisolated(unsafe) private static var memo: [(data: Data, facts: PrintReportFacts)] = []

    public static func decode(_ o: [String: Any]) -> PrintReportFacts {
        var f = PrintReportFacts.none
        f.frame = PrintFrameTurn.decode(o["print_frame"])
        f.slicerSupports = o["slicer_supports"] as? String
        f.onEdge = ((o["painted"] as? [String: Any])?["stand"] as? [String: Any])?["rests_on"] as? String == "edge"
        f.ranking = PrintOrientationRanking.decode(o["print_orientation"])
        f.baseTriangles = (o["base_triangles"] as? NSNumber)?.intValue
        if let r = PrintRecheck.decode(analysis: o) {
            f.recheck = r
            if let st = r.standing {
                f.frame = f.frame ?? st.frame
                f.slicerSupports = f.slicerSupports ?? st.slicerSupports
                f.onEdge = f.onEdge || st.onEdge
            }
        }
        return f
    }
}

// MARK: - the engine's ranking (lattice_file.json "print_orientation")

/// core's P4 ranking: every way the part can rest (its hull's faces, its edges held by supports, and his placement first), the
/// recommendation and why. Every up is in the part's own coordinates.
public struct PrintOrientationRanking: Equatable, Sendable {
    public enum Rests: String, Equatable, Sendable { case face, edge, lowest }
    public struct Strength: Equatable, Sendable {
        public var guessed: Double?
        public var solid: Double?
        public var solidLayers: Double?
        public var struts: Double?
        public var strutsUnder: Int
    }
    public struct Candidate: Equatable, Sendable {
        public var up: SIMD3<Double>
        public var rests: Rests
        public var asPlaced: Bool
        public var offered: Bool
        public var passes: Bool
        public var stands: Bool
        public var strength: Strength
        /// The support the slicer would lay (the part's own, plus the stand supports of an edge), mm³.
        public var supportMM3: Double?
        public var heightMM: Double?
        public var layers: Int?
        public var bedMM2: Double?
        public var heldBySupports: Bool
        public var edgeMM: Double?
    }
    public var requiredMargin: Double
    public var recommended: Int
    public var change: Bool
    /// "best_orientation" or "new_orientation_may_be_stronger".
    public var headline: String
    public var nonePasses: Bool
    /// The reasons, ≤ 5 words each (core's own words).
    public var why: [String]
    public var candidates: [Candidate]

    public var recommendation: Candidate? { candidates.indices.contains(recommended) ? candidates[recommended] : nil }
    public var asPlaced: Candidate? { candidates.first(where: \.asPlaced) ?? candidates.first }
    public var mayBeStronger: Bool { change && headline == "new_orientation_may_be_stronger" }

    public static func decode(_ any: Any?) -> PrintOrientationRanking? {
        guard let o = any as? [String: Any], let rows = o["candidates"] as? [[String: Any]], !rows.isEmpty else { return nil }
        func d(_ x: Any?) -> Double? { (x as? NSNumber).map(\.doubleValue).flatMap { $0.isFinite ? $0 : nil } }
        let cs: [Candidate] = rows.compactMap { c in
            guard let a = c["up"] as? [Any], a.count == 3 else { return nil }
            let u = a.compactMap { ($0 as? NSNumber)?.doubleValue }
            guard u.count == 3 else { return nil }
            let s = c["strength"] as? [String: Any] ?? [:]
            return Candidate(up: SIMD3(u[0], u[1], u[2]), rests: Rests(rawValue: c["rests_on"] as? String ?? "") ?? .face,
                             asPlaced: c["as_placed"] as? Bool ?? false, offered: c["offered"] as? Bool ?? false,
                             passes: c["passes"] as? Bool ?? false, stands: c["stands"] as? Bool ?? true,
                             strength: Strength(guessed: d(s["guessed"]), solid: d(s["solid"]), solidLayers: d(s["solid_interlayer"]),
                                                struts: d(s["struts"]), strutsUnder: (s["struts_under"] as? NSNumber)?.intValue ?? 0),
                             supportMM3: d(c["support_mm3"]), heightMM: d(c["height_mm"]),
                             layers: d(c["layers"]).map { Int($0.rounded()) }, bedMM2: d(c["bed_contact_mm2"]),
                             heldBySupports: c["held_by_supports"] as? Bool ?? false, edgeMM: d(c["edge_mm"]))
        }
        guard !cs.isEmpty else { return nil }
        return PrintOrientationRanking(requiredMargin: d(o["required_margin"]) ?? 1.5,
                                       recommended: (o["recommended"] as? NSNumber)?.intValue ?? 0,
                                       change: o["change"] as? Bool ?? false,
                                       headline: o["headline"] as? String ?? "best_orientation",
                                       nonePasses: o["none_passes"] as? Bool ?? false,
                                       why: (o["why"] as? [String]) ?? [], candidates: cs)
    }

    /// A lattice result's ranking (its report's `print_orientation`); nil for any other report.
    public static func of(report: Data?) -> PrintOrientationRanking? {
        guard let d = report, d.range(of: Data("\"print_orientation\"".utf8)) != nil,
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return decode(o["print_orientation"])
    }
}

// MARK: - the topology re-check (analysis.json "orientation_recheck", core P5)

/// The part standing one way, measured on its file: height and layers, the bed, the painted supports.
public struct PrintStanding: Equatable, Sendable {
    public var heightMM: Double
    public var layers: Int
    public var bedMM2: Double
    public var paintedTriangles: Int
    public var paintedAreaMM2: Double
    public var supportMM3: Double
    public var onEdge: Bool
    /// "painted" | "off" | "needed".
    public var slicerSupports: String
    public var file: String?
    public var frame: PrintFrameTurn?

    static func decode(_ any: Any?) -> PrintStanding? {
        guard let o = any as? [String: Any] else { return nil }
        func d(_ x: Any?) -> Double { (x as? NSNumber)?.doubleValue ?? 0 }
        let p = o["painted"] as? [String: Any] ?? [:]
        let stand = o["stand"] as? [String: Any]
        return PrintStanding(heightMM: d(o["height_mm"]), layers: Int(d(o["layers"]).rounded()), bedMM2: d(o["bed_contact_mm2"]),
                             paintedTriangles: Int(d(p["triangles"])), paintedAreaMM2: d(p["area_mm2"]) + d(stand?["area_mm2"]),
                             supportMM3: d(p["est_volume_mm3"]) + d(stand?["est_volume_mm3"]),
                             onEdge: (stand?["rests_on"] as? String) == "edge",
                             slicerSupports: o["slicer_supports"] as? String ?? "off", file: o["file"] as? String,
                             frame: PrintFrameTurn.decode(o["print_frame"]))
    }
}

/// core's re-check of a topology result standing a new way: the strength measured with the layers across the new up (one
/// solve), and the part standing each way (the new and as it was).
public struct PrintRecheck: Equatable, Sendable {
    public var up: SIMD3<Double>
    public var margin: Double
    public var layerMargin: Double
    public var required: Double
    public var accepted: Bool
    public var standing: PrintStanding?
    public var baseline: PrintStanding?

    public static func decode(analysis: [String: Any]) -> PrintRecheck? {
        guard let o = analysis["orientation_recheck"] as? [String: Any], let dir = o["build_dir"] as? [Any], dir.count == 3,
              let m = (o["margin"] as? NSNumber)?.doubleValue else { return nil }
        let u = dir.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard u.count == 3 else { return nil }
        let base = o["baseline"] as? [String: Any]
        return PrintRecheck(up: SIMD3(u[0], u[1], u[2]), margin: m,
                            layerMargin: (o["interlayer_margin"] as? NSNumber)?.doubleValue ?? m,
                            required: (o["margin_required"] as? NSNumber)?.doubleValue ?? 1.5,
                            accepted: o["accepted"] as? Bool ?? false,
                            standing: PrintStanding.decode(o["standing"]), baseline: PrintStanding.decode(base?["standing"]))
    }
}

// MARK: - the words (his rules: captions ≤ 5 words, detail in an (i), never face numbers, never "+Z")

public enum PrintWay: Equatable, Sendable {
    case asPlaced, chosenFace, onEdge

    /// How a result prints: on an edge when its file stands on one (or the up rests on an edge); a chosen face when he picked
    /// a plate; else as he placed it (against his gravity).
    public static func of(plateUp: SIMD3<Float>?, onEdge: Bool) -> PrintWay {
        if onEdge { return .onEdge }
        if let p = plateUp, p != .zero { return .chosenFace }
        return .asPlaced
    }
}

public enum PrintOrientationWords {
    // the Checks row (spec 2b)
    public static func title(_ w: PrintWay) -> String {
        switch w {
        case .asPlaced: return "Prints as you placed it"
        case .chosenFace: return "Prints on the chosen face"
        case .onEdge: return "On its edge, held by supports"
        }
    }
    /// The Settings "Plate" row's value.
    public static func plateValue(_ o: BuildOrientation) -> String { o.isInferredFromGravity ? "As placed" : "Chosen face" }

    // the supports line, from the file's `slicer_supports`
    public static let painted = "Supports painted for you"
    public static let none = "No supports needed"
    public static let needed = "Supports needed here"
    public static let paintedInfo = "The file turns supports on, only where painted. Bambu, Orca: Type tree (manual). "
        + "PrusaSlicer: For support enforcers only. In Bambu Studio, open the file as a project."
    public static func supports(_ slicer: String?) -> String? {
        switch slicer {
        case "painted": return painted
        case "off": return none
        case "needed": return needed
        default: return nil
        }
    }

    // the flow (spec 2d)
    public static let drawerItem = "Print orientation"
    public static let rowLink = "Print orientation"
    public static let bestTitle = "Best orientation"
    public static let bestCaption = "Prints best as placed"
    public static let newTitle = "A new orientation may be stronger"
    public static let ok = "OK"
    public static let notNow = "Not now"
    public static let cancel = "Cancel"
    public static let check = "Check strength"
    public static let manual = "Manual orientation"
    public static let manualCaption = "Tap a face or edge"
    public static let yourChoice = "Your choice"
    public static let keep = "Keep orientation"
    public static let estimate = "Estimate"
    public static let wouldTipTitle = "It would tip over"
    public static let wouldTipText = "Its centre of weight is not over that face, so it would fall on the bed. Tap a wider "
        + "face, or an edge: an edge is held by supports."
    public static let checkingTitle = "Checking its strength"
    public static let aboutOneMinute = "About 1 minute"
    public static let aboutTenMinutes = "About 10 minutes"
    public static let compareTitle = "Printed this way"
    public static let asPlacedColumn = "As placed"
    public static let newColumn = "New"
    public static let noMacTitle = "Your Mac isn’t answering"
    public static let noMacText = "Checking the strength runs on your Mac. Check that it is on and TopOpt is running there, "
        + "then try again."
    public static let tryAgain = "Try again"
    public static let failedTitle = "The strength couldn’t be checked"
    public static func failedText(_ why: String) -> String {
        (why.isEmpty ? "The check stopped on your Mac." : why) + " Nothing changed. Press Check strength to try again."
    }
    public static let noRankingText = "This result has no ranking yet. Tap Manual orientation to pick the face for the bed, "
        + "then Check strength."

    /// The (i) of the pop-up: the estimate's numbers (his rule: a guess says so).
    public static func estimateLines(_ r: PrintOrientationRanking, _ c: PrintOrientationRanking.Candidate?) -> [String] {
        guard let c else { return [] }
        var out: [String] = []
        if let g = c.strength.guessed { out.append("Strength (estimate): " + StrengthWords.x(g) + " · needs " + StrengthWords.x(r.requiredMargin)) }
        if let s = c.supportMM3 { out.append(String(format: "Supports: %.1f cm³", s / 1000)) }
        if let h = c.heightMM { out.append(String(format: "Height: %.0f mm", h) + (c.layers.map { " · \($0) layers" } ?? "")) }
        if c.heldBySupports { out.append("On an edge, held by supports") }
        return out
    }
}
