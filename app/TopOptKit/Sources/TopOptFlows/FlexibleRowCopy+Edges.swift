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
    public static func inGroup(_ number: Int) -> String { inGroup(name: groupName(number)) }
    /// ★ ROUND 7 (S, 4d): naming the group by his name ("In Thumbs").
    public static func inGroup(name: String) -> String { fit("In \(name)") }
    /// A fillet: the area needs a sharp, straight edge. ★ R7-E1: no strips any more — "A fillet · needs a sharp edge".
    public static let stripFillet = "A fillet \u{00B7} needs a sharp edge"
    /// An edge that is not one straight line.
    public static let stripCurvedEdge = "A curved edge · no straight strip"

    // MARK: the face keeps the rest

    /// ★ "Top keeps the rest · Edge 3"; "Top keeps the rest" when the name is long. ★ R7-E1 (his 2026-10-18 words: "There
    /// shouldn't be a strip width."): no strip / patch words.
    public static func keepsTheRest(name: String, label: String, corner: Bool) -> String {
        let long = "\(name) keeps the rest \u{00B7} \(label)"
        return long.count <= maxChars ? long : fit("\(name) keeps the rest")
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
    /// A press is saved, never sent until core builds press stacks (AP9).
    public static let pressNotSent = "Set up \u{00B7} core support pending"

    // MARK: ★ R7-E1 — the flat prism's words (his rule: one line, ≤ 44 characters)
    public static let insideEdge = "An inside edge \u{00B7} no flat prism"
    public static let insideCorner = "An inside corner \u{00B7} no flat prism"
    public static let flatFarEnd = "Stops here \u{00B7} the far end reaches 0 mm"
    public static let flatShallowest = "Stops here \u{00B7} 0.5 mm is the least"
    public static func flatCrossAll(_ n: Int) -> String { "The flat prism must cross all \(n) faces" }
    public static func flatLatticeEnds(_ mm: Double) -> String { fit("Stops at " + String(format: "%.1f", mm) + " mm \u{00B7} the lattice ends there") }
    public static let stripsAreFlatNow = "Edge strips are flat prisms now \u{00B7} same reach"
    public static let flatDeepestRow = "Deepest squish"
    public static func flatTiltRow(toward face: String) -> String { fit("Tilt toward \(face)") }
    public static func flatTwistRow(end: String) -> String { fit("Twist \(end) deeper") }
    public static func flatUpDownRow(into face: String) -> String { fit("Up/down more into \(face)") }
    public static func flatLeftRightRow(toward face: String) -> String { fit("Left/right toward \(face)") }
    public static func flatTiltWord(corner: Bool) -> String { corner ? "Up/down" : "Tilt" }
    public static func flatTwistWord(corner: Bool) -> String { corner ? "Left/right" : "Twist" }
    public static let flatBackToHalfway = "Back to halfway"
    public static func flatSetMM(_ mm: Double) -> String { "Set " + String(format: "%.1f", mm) + " mm" }

    // MARK: ★ R7-E1 REVIEW (STUBS: the old words)
    public static func flatStartsAt(_ mm: Double) -> String { flatLatticeEnds(mm) }
    public static func flatAngleStops(twist: Bool, corner: Bool, deg: Double) -> String { flatLatticeEnds(0) }
    public static func outOfFlexible(_ name: String) -> String { fit("\(name) was taken out of the Flexible setup") }
}
