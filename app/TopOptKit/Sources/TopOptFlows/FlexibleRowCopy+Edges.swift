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
    public static let stripCurvedEdge = "A curved edge \u{00B7} no flat prism"   // ★ R7-E1 review: no strip

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

    // MARK: ★ R7-E1 REVIEW — the stops said whole (his rule: one line, ≤ 44)
    /// A new pick the lattice stops below 3 mm starts at the stop: "Starts at 2.8 mm · the lattice ends there".
    public static func flatStartsAt(_ mm: Double) -> String { fit("Starts at " + String(format: "%.1f", mm) + " mm \u{00B7} the lattice ends there") }
    /// An angle the lattice stops, said as the angle (never a depth): "Twist stops at 6.2° · lattice ends".
    public static func flatAngleStops(twist: Bool, corner: Bool, deg: Double) -> String {
        let word = twist ? flatTwistWord(corner: corner) : flatTiltWord(corner: corner)
        return fit("\(word) stops at " + FlexNumberSpec.format(deg, decimals: 1) + "\u{00B0} \u{00B7} lattice ends")
    }
    /// Both angles moved and the lattice stopped them part way.
    public static let flatAngleStopsBoth = "Angle stops here \u{00B7} the lattice ends there"
    /// A candidate member taken out of the Flexible setup — one line, whole ("Face 1 · lattice A is out of Flexible").
    public static func outOfFlexible(_ name: String) -> String { fit("\(name) is out of Flexible") }

    // MARK: ★ R7-E2 — sent to core (his rule: one line, ≤ 44; the reviewer's: shared_footprint in plain words)

    /// Two entries share surface (core's A3): "Edge 16 and Face 3 share 85 mm²".
    public static func sharedFootprint(_ a: String, _ b: String, mm2: Double) -> String {
        let n = String(format: "%.0f", mm2.rounded())
        let tail = " share \(n) mm\u{00B2}"
        let room = maxChars - tail.count - " and ".count
        return fit(fit(a, room / 2) + " and " + fit(b, room - Swift.min(a.count, room / 2)) + tail)
    }
    /// A press core is designing (its stack read, its design not in yet).
    public static let pressDesigning = "Set up \u{00B7} core is designing it"
    /// A press core would not design: "Not sent · no squish data for it".
    public static func pressNotDesigned(_ why: String) -> String { fit("Not sent \u{00B7} \(why)") }
    /// A region that would be in two entries.
    public static func pressTwoEntries(_ name: String) -> String { fit("Not sent \u{00B7} \(name) is pressed twice") }
    /// Two presses of one group pushing the same material along one axis (core's one_profile_per_stack).
    public static func pressConflict(_ a: String, _ b: String) -> String { fit("\(fit(a, 16)) and \(fit(b, 16)) press one stack") }
    /// Core's side label for a press sent along a side (core's FaceFrame.side — more than 15° off build Z).
    public static let sidePress = "Side press \u{00B7} gyroid only \u{00B7} estimate"
    /// ★ The ruling's sentence (2026-10-07, item 5), whole — the limits sheet, the Export caption's (i), the side label's (i).
    public static let angledEstimateSentence = "Squish data were measured pressing straight down; angled presses are estimates until they're measured."
    /// The same, in one line (the once-per-session pop-up and the Export caption).
    public static let angledEstimateShort = "Angled presses are estimates until measured"
    /// ★ HIS ANSWER (2026-10-18 ~16:50): the twist ships with its honest line — how far core's profile is off the flat prism.
    public static func twistOff(_ percent: Double) -> String { fit("Twisted \u{00B7} squish shape up to \(Int(percent.rounded()))% off") }
    /// A corner core's map cannot follow within 2 %.
    public static func cornerOff(_ percent: Double) -> String { fit("Tipped \u{00B7} squish shape up to \(Int(percent.rounded()))% off") }
    /// Step ② for an edges group: "Group 3 · 5 lb · 2 edges · bead 0.45 mm" (its weight, its edges and corners, the bead).
    public static func edgesJobSummary(group: String, weight: String, edges: Int, corners: Int, beadMM: Double) -> String {
        [group, weight, edgesDetail(edges: edges, corners: corners), String(format: "bead %.2f mm", beadMM)].joined(separator: " \u{00B7} ")
    }
}
