// FlexibleRowCopy+Edges — the lines of round 6 item 2's edges/corners groups (task 2026-10-08). His rule: ONE line per
// setting, at most 44 characters (FlexibleRowCopy.fit), nothing required behind an (i).

import Foundation

extension FlexibleRowCopy {

    // MARK: [+ New] asks which

    public static let newKindFaces = "Faces"
    public static let newKindEdges = "Edges/corners"

    // MARK: the pick card

    /// "Edge 3" / "Corner 1" / "Fillet 9": a candidate by its number in the list.
    public static func candidateLabel(_ c: FlexibleEdgeCandidates.Candidate) -> String {
        switch c.kind {
        case .corner: return "Corner \(c.number)"
        case .edge: return "Edge \(c.number)"
        case .blend: return "Fillet \(c.number)"
        }
    }

    /// "Corner · Face 1 + Face 2 + Face 3": a candidate's row (its number is the dot beside it).
    public static func candidateRow(_ c: FlexibleEdgeCandidates.Candidate, names: [String]) -> String {
        let head: String
        switch c.kind {
        case .corner: head = "Corner"
        case .edge: head = "Edge"
        case .blend: head = "Fillet"
        }
        return fit(head + " \u{00B7} " + names.joined(separator: " + "), 36)
    }

    /// The pick card's one line: what to do, and how many are picked.
    public static func edgePickLine(picked: Int, loading: Bool) -> String {
        if loading { return "Reading the edges and corners…" }
        return picked == 0 ? "Tap edges or corners · on the part or here" : "Tap edges or corners · \(picked) picked"
    }
    /// [Done · 2 picked]
    public static func edgePickDone(_ n: Int) -> String { n == 0 ? "Done" : "Done \u{00B7} \(n) picked" }
    public static let edgePickCancel = "Cancel"
    public static let edgePickChecking = "Asking core about each press…"
    /// A tap on the model that hit no edge or corner.
    public static let edgePickMiss = "Tap an edge or a corner"
    /// [Done] with nothing picked.
    public static let edgePickNone = "Pick an edge or a corner first"
    /// [Done] with no force: the pad asks (a press never invents a weight).
    public static let edgePickWeightAsk = "How much weight presses here?"
    /// The part is opening (or changed while core was asked): nothing was stored.
    public static let edgePickOpening = "The part is still opening · try again"
    /// Core refused the press, with no words of its own.
    public static let coreRefuses = "Core can't build this press"

    // MARK: greyed lines

    /// A candidate whose member is in another edges/corners group's press already.
    public static func inGroup(_ number: Int) -> String { "In \(groupName(number))" }
    /// A fillet: the area needs a sharp, straight edge.
    public static let stripFillet = "A fillet · strips need a sharp edge"
    /// An edge that is not one straight line.
    public static let stripCurvedEdge = "A curved edge · no straight strip"

    // MARK: the face keeps the rest

    /// ★ "Top keeps the rest · strip taken for Edge 3" (a corner: "patch"); the short form when the name is long.
    public static func keepsTheRest(name: String, label: String, corner: Bool) -> String {
        let what = corner ? "patch" : "strip"
        let long = "\(name) keeps the rest \u{00B7} \(what) taken for \(label)"
        if long.count <= maxChars { return long }
        return fit("\(name) keeps the rest \u{00B7} \(what) for \(label)")
    }

    // MARK: the edges group's tab

    /// The rail tab's detail: "2 edges · 1 corner".
    public static func edgesDetail(edges: Int, corners: Int) -> String {
        var parts: [String] = []
        if edges > 0 { parts.append(edges == 1 ? "1 edge" : "\(edges) edges") }
        if corners > 0 { parts.append(corners == 1 ? "1 corner" : "\(corners) corners") }
        return parts.isEmpty ? "empty" : parts.joined(separator: " \u{00B7} ")
    }
    /// The toast after [Done] when no face kept a rest: "Group 4 · 1 edge".
    public static func edgesGroupMade(_ number: Int, edges: Int, corners: Int) -> String {
        fit("\(groupName(number)) \u{00B7} " + edgesDetail(edges: edges, corners: corners))
    }
    /// The press's width row.
    public static let stripWidthRow = "Strip width"
    public static let patchSizeRow = "Patch size"
    /// A press is saved, never sent until core builds press stacks (AP9).
    public static let pressNotSent = "Set up \u{00B7} core support pending"
}
