// LatticeFileFacts.swift — ★ HIS 11-21 ("It should also show all the information associated to the final result"): a Lattice
// run's result on Results says what the Mac made and found, in plain words — the print file, the strengthening (Organic on
// Structural), the layer check and the strength check's weakest strut — as lines in the checks list and rows in Details.
//
// Read from the run's own report (`lattice_file.json`, with the app's `organic_strengthen` block beside it), so a saved result
// says the same when it is opened again. Pure: LatticeFileFactsTests reads his 2040 stand's report shape.

import Foundation

public struct LatticeFileFacts: Equatable, Sendable {
    public struct Weakest: Equatable, Sendable {
        public var margin: Double
        /// core's word for what loads it: "tension", "compression", "bending", "buckling".
        public var by: String
        public var widthMM: Double
        public var lengthMM: Double
        public var atMM: SIMD3<Double>?
    }
    public struct Strengthening: Equatable, Sendable {
        public var rounds: Int
        public var passing: Bool
        public var seconds: Double
        /// Struts thickened and braced, over every round.
        public var thickened: Int
        public var braced: Int
        /// Struts thickened past his thickest strut (the cap's doing), and the widest.
        public var pastLimit: Int
        public var pastLimitWidestMM: Double
    }

    // the file
    public var fileName: String
    public var fileBytes: Int
    public var triangles: Int
    public var struts: Int
    public var strands: Int
    public var bridges: Int
    public var posts: Int
    public var postsMM: Double
    public var slicerSupportsOff: Bool
    public var fileSeconds: Double?
    // the layer check
    public var printClean: Bool
    public var layers: Int
    public var midairStarts: Int
    public var longestBridgeMM: Double
    public var firstLayerMM2: Double
    public var thinIslands: Int
    // the strength check
    public var strutsJudged: Int
    public var weakest: Weakest?
    public var solidInPlane: Double?
    public var solidLayers: Double?
    public var passesAtInfill: Int?
    /// The share of the load the lattice's struts carry (0…1).
    public var loadOnStruts: Double?
    public var strengthening: Strengthening?
    /// ★ notes25 C3: the struts the final check found short of the margin (`struts.under_safety`).
    public var strutsShort: Int? = nil

    /// A Lattice run's report (it has `layout` and `mesh`), else nil.
    public static func decode(_ r: [String: Any]) -> LatticeFileFacts? {
        guard let layout = r["layout"] as? [String: Any], let mesh = r["mesh"] as? [String: Any] else { return nil }
        let p = r["print_check"] as? [String: Any] ?? [:]
        let s = r["strength"] as? [String: Any] ?? [:]
        let struts = s["struts"] as? [String: Any] ?? [:]
        let solid = s["solid_margin"] as? [String: Any] ?? [:]
        let frame = s["frame"] as? [String: Any] ?? [:]
        let ms = r["ms"] as? [String: Any] ?? [:]
        let weakest = (s["weakest"] as? [[String: Any]])?.first.map { w -> Weakest in
            let at = (w["at"] as? [NSNumber]).flatMap { $0.count == 3 ? SIMD3($0[0].doubleValue, $0[1].doubleValue, $0[2].doubleValue) : nil }
            return Weakest(margin: num(w["margin"]), by: w["by"] as? String ?? "", widthMM: num(w["width_mm"]),
                           lengthMM: num(w["length_mm"]), atMM: at)
        }
        let file = (r["file"] as? String).map { ($0 as NSString).lastPathComponent } ?? LatticeFileJob.outputName
        return LatticeFileFacts(
            fileName: file, fileBytes: int(r["file_bytes"]), triangles: int(mesh["triangles"]),
            struts: int(layout["bars"]), strands: int(layout["strands"]), bridges: int(mesh["bridges"]),
            posts: int(mesh["posts"]), postsMM: num(mesh["posts_mm"]), slicerSupportsOff: (r["slicer_supports"] as? String) == "off",
            fileSeconds: (ms["total"] as? NSNumber).map { $0.doubleValue / 1000 },
            printClean: p["clean"] as? Bool ?? false, layers: int(p["layers"]), midairStarts: int(p["midair_starts"]),
            longestBridgeMM: num(p["longest_bridge_reach_mm"]), firstLayerMM2: num(p["first_layer_mm2"]),
            thinIslands: int(p["thin_islands"]),
            strutsJudged: int(struts["judged"]), weakest: weakest,
            solidInPlane: (solid["in_plane"] as? NSNumber)?.doubleValue, solidLayers: (solid["interlayer"] as? NSNumber)?.doubleValue,
            passesAtInfill: (solid["passes_at_infill_percent"] as? NSNumber)?.intValue,
            loadOnStruts: (frame["load_share"] as? NSNumber)?.doubleValue,
            strengthening: strengthening(r[LatticeFileButton.strengthenKey] as? [String: Any]),
            strutsShort: (struts["under_safety"] as? NSNumber)?.intValue)
    }

    static func strengthening(_ o: [String: Any]?) -> Strengthening? {
        guard let o, o["code"] != nil else { return nil }
        let rounds = o["rounds"] as? [[String: Any]] ?? []
        var thick = 0, braced = 0, past = 0, widest = 0.0
        for r in rounds {
            let a = r["added"] as? [String: Any] ?? [:]
            thick += int(a["struts_widened"])
            braced += int(a["struts_braced"])
            let lim = (a["limit"] as? [String: Any])?["past_limit"] as? [String: Any]
            past = Swift.max(past, int(lim?["struts"]))
            widest = Swift.max(widest, num(lim?["widest_mm"]))
        }
        // rounds_fixed: the rounds that added to the struts (the last check that passed adds nothing)
        let n = (o["rounds_fixed"] as? NSNumber)?.intValue ?? rounds.filter { $0["added"] != nil }.count
        return Strengthening(rounds: n, passing: o["passing"] as? Bool ?? false, seconds: num(o["seconds"]),
                             thickened: thick, braced: braced, pastLimit: past, pastLimitWidestMM: widest)
    }

    // MARK: the words

    /// The checks list's lines, under the strength lines: the strengthening, the file, the layer check.
    public var checks: [ResultsCheck] {
        var out: [ResultsCheck] = []
        // ★ notes25 C3 (4): only numbers true for the FINAL lattice — the struts still short, the braces, the thickest strut now
        // (the per-round "thickened" sum counted a strut once per round, and "past your thickest" mixed two rounds: gone)
        if let g = strengthening, g.rounds > 0 {
            var more: [String] = []
            if g.braced > 0 { more.append(Self.number(g.braced) + " braced") }
            if g.pastLimitWidestMM > 0 { more.append("thickest now " + StrengthWords.mm(g.pastLimitWidestMM)) }
            let short = strutsShort.map { $0 > 0 ? Self.count($0, "strut") + " still short" : "Every strut holds" }
            out.append(ResultsCheck(kind: g.passing ? .ok : .warn,
                                    title: "Strengthened \u{00B7} " + Self.count(g.rounds, "round"),
                                    detail: g.passing ? "Weak struts thickened until they hold" : (short ?? "Some struts are still short"),
                                    more: more.isEmpty ? nil : more.joined(separator: " \u{00B7} "), tab: .strength))
        }
        let size = fileBytes > 0 ? " \u{00B7} " + Self.bytes(fileBytes) : ""
        out.append(ResultsCheck(kind: .ok, title: "Print file ready",
                                detail: fileKind + size,   // ★ notes25 C3: no strut count (the file's bars are another unit)
                                more: slicerSupportsOff ? "Turn supports off in your slicer" : nil, tab: .printing))
        out.append(printClean
            ? ResultsCheck(kind: .ok, title: "Prints layer by layer", detail: "Nothing starts in mid-air", tab: .printing)
            : ResultsCheck(kind: .warn, title: "Check the layers", detail: midairStarts > 0
                ? Self.count(midairStarts, "place") + " start in mid-air" : "The layer check found a problem", tab: .printing))
        return out
    }

    private var fileKind: String { fileName.lowercased().hasSuffix(".3mf") ? "3MF" : "STL" }

    /// The Details rows of one tab.
    public func rows(_ t: ResultsDetailsTab) -> [ResultsDetailRow] {
        var r: [ResultsDetailRow] = []
        func add(_ l: String, _ v: String?) { if let v, !v.isEmpty { r.append(ResultsDetailRow(label: l, value: v)) } }
        switch t {
        case .strength:
            // ★ notes25 C3 (6): the strength rows are the governing answer's (LatticeStrengthAnswer.rows); here only what the
            // strengthening left: its rounds and the braces
            if let g = strengthening, g.rounds > 0 {
                add("Strengthened", Self.count(g.rounds, "round") + (g.braced > 0 ? " \u{00B7} " + Self.number(g.braced) + " braced" : ""))
            }
        case .printing:
            add("Print file", fileName + (fileBytes > 0 ? " \u{00B7} " + Self.bytes(fileBytes) : ""))
            if strands > 0 { add("Strands", Self.number(strands)) }   // ★ notes25 C3 (7): the bars are in Run
            if bridges > 0 { add("Bridges", Self.number(bridges)) }
            if posts > 0 { add("Posts", Self.number(posts) + String(format: " \u{00B7} %.0f mm in all", postsMM)) }
            if triangles > 0 { add("Triangles", Self.number(triangles)) }
            if layers > 0 { add("Layers", Self.number(layers)) }
            if firstLayerMM2 > 0 { add("On the bed", String(format: "%.0f mm\u{00B2}", firstLayerMM2)) }
            if longestBridgeMM > 0 { add("Longest bridge", String(format: "%.1f mm", longestBridgeMM)) }
            if thinIslands > 0 { add("Thin islands", Self.number(thinIslands) + " (small spots in a layer)") }
            if slicerSupportsOff { add("Slicer", "Supports off") }
        case .run:
            if struts > 0 { add("Bars in the file", Self.number(struts)) }   // ★ notes25 C3 (7)
            if let g = strengthening, g.seconds > 0 { add("Strengthening", Self.duration(g.seconds)) }
            if let s = fileSeconds, s > 0 { add("Making the file", Self.duration(s)) }
        case .scenarios:
            break
        }
        return r
    }

    static func number(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    static func count(_ n: Int, _ noun: String) -> String { number(n) + " " + noun + (n == 1 ? "" : "s") }
    static func bytes(_ b: Int) -> String { String(format: "%.1f MB", Double(b) / 1_000_000) }
    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 60 ? "\(t / 60) min \(t % 60) s" : "\(t) s"
    }
}

private func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
private func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
