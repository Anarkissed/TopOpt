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
        case .corner: return "Corner \(c.shownNumber)"   // ★ R7-E3 (a): the part's one number, as on its tag
        case .edge: return "Edge \(c.shownNumber)"
        case .blend: return "Fillet \(c.shownNumber)"
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
        // ★ R7-E1b (his answer: no list): the part is where he taps
        return picked == 0 ? "Tap a lit edge or corner on the part" : "Tap lit edges or corners · \(picked) picked"
    }
    /// ★ R7-E1b: an edge or corner added to an existing group, and the open edges group's own line.
    public static func edgeAdded(_ label: String, to group: String) -> String { fit("\(label) added to \(group)") }
    public static let edgeAddLine = "Tap a lit edge or corner to add it"
    /// ★ R7-E3: the open edges group with nothing lit — a tap on the part still adds; [+] lights what can be pressed.
    public static let edgeAddTapLine = "Tap an edge or corner, or + to see them"
    public static let edgeAddPlus = "Show the edges and corners to add"
    public static let edgeAddDone = "Done"
    public static func openGroup(_ name: String) -> String { fit("Open \(name)", 24) }
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
    /// ★ R7-E2 PARKED (his words 2026-10-19: "The back-end will come AFTER …"): a press is the shape only for now — kept out of
    /// every request to core (FlexibleBackend.sendsPresses off). His line was 45 characters; "for now" is what "Shape only" says.
    public static let pressShapeOnly = "Shape only \u{00B7} core support comes later"

    // MARK: ★ R7-E1 — the flat prism's words (his rule: one line, ≤ 44 characters)
    public static let insideEdge = "An inside edge \u{00B7} no flat prism"
    public static let insideCorner = "An inside corner \u{00B7} no flat prism"
    public static let flatFarEnd = "Stops here \u{00B7} the far end reaches 0 mm"
    public static let flatShallowest = "Stops here \u{00B7} 0.5 mm is the least"
    public static func flatCrossAll(_ n: Int) -> String { "The flat prism must cross all \(n) faces" }
    public static func flatLatticeEnds(_ mm: Double) -> String { fit("Stops at " + String(format: "%.1f", mm) + " mm \u{00B7} the lattice ends there") }
    public static let stripsAreFlatNow = "Edge strips are flat prisms now \u{00B7} same reach"
    public static let flatDeepestRow = "Deepest squish"
    // ★ R7-E1b (his 2026-10-19 note: "'Tilt' generally comes off as up/down to many … you have 'Tilt' going left/right and 'Twist'
    // going up/down. Please reverse this."): the words follow the arrow's motion ON THE PART — "Tilt" moves it up/down, "Twist"
    // left/right. On a steep edge (his Edge 16 and 18, the pad's 20 mm sides) tipping toward a face is left/right and deepening one
    // end is up/down, so the two words swap there; on a level edge they stay. `steep`: FlexibleFlatPrismAngles.Frame.thetaIsTwist.
    public static func flatTiltRow(toward face: String, steep: Bool = false) -> String { fit("\(flatTiltWord(corner: false, steep: steep)) toward \(face)") }
    public static func flatTwistRow(end: String, steep: Bool = false) -> String { fit("\(flatTwistWord(corner: false, steep: steep)) \(end) deeper") }
    public static func flatUpDownRow(into face: String) -> String { fit("Up/down more into \(face)") }
    public static func flatLeftRightRow(toward face: String) -> String { fit("Left/right toward \(face)") }
    /// The word of θ (tip toward a face) and of φ (along the edge). RED CONTROL `controlOldWords`: E1's (θ always "Tilt").
    public static func flatTiltWord(corner: Bool, steep: Bool = false) -> String { corner ? "Up/down" : (steep && !controlOldWords ? "Twist" : "Tilt") }
    public static func flatTwistWord(corner: Bool, steep: Bool = false) -> String { corner ? "Left/right" : (steep && !controlOldWords ? "Tilt" : "Twist") }
    nonisolated(unsafe) static var controlOldWords = false
    public static let flatBackToHalfway = "Back to halfway"
    public static func flatSetMM(_ mm: Double) -> String { "Set " + String(format: "%.1f", mm) + " mm" }
    /// ★ R7-E1b: a stop's fixes — deeper (a twist's far end) and the face-prism the lattice comes from.
    public static func flatDeepenTo(_ mm: Double) -> String { "Deepen to " + String(format: "%.1f", mm) + " mm" }
    public static func deepenFacePrism(_ mm: Double) -> String { fit("Deepen the face-prism to " + String(format: "%.1f", mm) + " mm") }

    // MARK: ★ R7-E1 REVIEW — the stops said whole (his rule: one line, ≤ 44)
    /// A new pick the lattice stops below 3 mm starts at the stop: "Starts at 2.8 mm · the lattice ends there".
    public static func flatStartsAt(_ mm: Double) -> String { fit("Starts at " + String(format: "%.1f", mm) + " mm \u{00B7} the lattice ends there") }
    /// An angle the lattice stops, said as the angle (never a depth): "Twist stops at 6.2° · lattice ends".
    public static func flatAngleStops(twist: Bool, corner: Bool, deg: Double, steep: Bool = false) -> String {
        let word = twist ? flatTwistWord(corner: corner, steep: steep) : flatTiltWord(corner: corner, steep: steep)
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
    /// ★ R7-E4: a corner's one curve (core holds one for the corner).
    public static let cornerOneCurve = "Corner \u{00B7} one curve for all 3 sides"
    /// The curve's two views, as the icons' spoken labels.
    public static let pressViewTop = "View from the top"
    public static let pressView45 = "View 45\u{00B0} from the side"
    /// The flat press's stamp row: "Stamp · Palm on the edge" (a corner: "on the corner").
    public static func pressStamp(name: String, corner: Bool) -> String {
        let tail = corner ? " on the corner" : " on the edge"
        return fit("Stamp \u{00B7} " + fit(name, 34 - tail.count) + tail, 34)
    }
}
