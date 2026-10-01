// FlexibleRowCopy — every line the Flexible Settings panel shows, and the (i) text behind it
// (task 2026-09-29-flexible-screens, round 3, item 5; maintainer: "ONE line of text per
// setting, details behind an (i) he won't tap; only what is necessary").
//
// ★ ONE LINE, AT MOST 44 CHARACTERS. Every dynamic line (a filament's name, a group's name,
// a face's name) is FITTED: cut with "…" rather than wrapped — FlexibleRowCopyTests drives
// every catalogue name and an absurdly long group name through it. Nothing REQUIRED is hidden
// behind an (i): the (i) only explains.

import Foundation
import TopOptKit

public enum FlexibleRowCopy {

    public static let maxChars = 44

    /// Cut a line to `maxChars` with an ellipsis (never a newline).
    public static func fit(_ s: String, _ limit: Int = maxChars) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        guard one.count > limit else { return one }
        return String(one.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "colorFabb varioShore TPU (foaming)" → "colorFabb varioShore TPU".
    public static func shortName(_ displayName: String) -> String {
        if let i = displayName.range(of: " (") { return String(displayName[..<i.lowerBound]) }
        return displayName
    }

    // MARK: part rows

    /// "colorFabb varioShore TPU · squish data" / "TPU 95A · no squish data".
    /// ★ NOT "shape only" (verification of round 3): nothing builds a shape-only lattice yet
    /// (batch B's Save & Exit will); until it does the row says what is true today.
    /// ★ AT MOST `filamentChars`: the row also carries the menu and the (i), and must fit the
    /// 400 pt panel in POINTS (FlexibleRowCopyTests measures every catalogue name).
    public static func filament(name: String?, hasData: Bool) -> String {
        guard let name else { return "Pick a filament" }
        let tail = hasData ? " · squish data" : " · no squish data"
        return fit(shortName(name), filamentChars - tail.count) + tail
    }
    public static let filamentChars = 38
    /// The filament list could not be read: said on the row itself, never only behind (i).
    public static let catalogueMissing = "Filament list missing from this build"
    public static let feel = "Feel"
    /// The panel's chip options — one table, so the pixel-width test measures the panel's own.
    public static let feelOptions: [(id: String, label: String)] = [("springy", "Springy"), ("damped", "Damped")]
    public static let roleOptions: [(id: String, label: String)] = [("loaded", "Pressed"), ("resting", "Rests")]
    public static let shapeOptions: [(id: String, label: String)] = [("curves", "Curves"), ("stamp", "Stamp")]
    /// ★ ROUND 4 (D1, his answer 4): the WHOLE model's finish.
    public static let finish = "Finish"
    public static let finishOptions: [(id: String, label: String)] =
        [("none", "None"), ("rim", "Rim"), ("skin", "Skin"), ("covered", "Covered")]
    /// ★ VERIFICATION OF D1: Rim and Skin are the app's drawing until core has a finish (core
    /// brief #16) — the job sends them as None. Said UNDER THE ROW, never only behind the (i).
    /// The line beside the finish's picture for None and Covered (Rim / Skin: `finishPreviewOnly`).
    public static func finishLine(_ f: FlexibleFinish) -> String {
        switch f {
        case .none: return "None: the lattice runs to the surface"
        case .covered: return "Covered: a solid skin all over"
        case .rim, .skin: return finishPreviewOnly(f) ?? ""
        }
    }
    public static func finishPreviewOnly(_ f: FlexibleFinish) -> String? {
        switch f {
        case .rim: return "Rim: preview only · prints as None for now"
        case .skin: return "Skin: preview only · prints as None for now"
        case .none, .covered: return nil
        }
    }
    public static let topologyOptions: [(id: String, label: String)] = [("auto", "Auto"), ("gyroid", "Gyroid"), ("honeycomb", "Honeycomb")]
    public static func temperatureOptions(_ tested: [Double]) -> [(id: String, label: String)] {
        [("auto", "Auto")] + tested.map { (String(Int($0)), "\(Int($0))°") }
    }

    // MARK: face rows

    /// A face's short name: a sector's own name ("Top A"), else "Face 3".
    public static func faceName(sector: String?, face: Int) -> String {
        if let s = sector, !s.isEmpty { return fit(s.prefix(1).uppercased() + s.dropFirst(), 20) }
        return "Face \(face)"
    }
    public static let noFace = "Tap a face on the part"

    /// ★ ROUND 4 (D1): one row of the face LIST — "Top A · Pressed · 10 kg" / "Face 0 · Rests".
    public static func faceRow(name: String, pressed: Bool, kg: Double) -> String {
        fit(pressed ? "\(name) · Pressed · \(kgText(kg))" : "\(name) · Rests")
    }
    public static let facesTitle = "Faces"

    /// ★ ROUND 4 (D1): the Stamp shape's rows (the face's ONE stamp).
    public static func stamp(name: String) -> String { fit("Stamp · \(name)", 34) }
    public static func stampSize(widthMM: Double, lengthMM: Double) -> String {
        fit(String(format: "Size %.0f × %.0f mm", widthMM, lengthMM))
    }
    public static func stampTurn(_ deg: Double) -> String { "Turned \(Int(deg.rounded()))°" }
    public static let stampPress = "Press"
    public static let stampPressOptions: [(id: String, label: String)] = [("soft", "Soft"), ("rigid", "Rigid")]
    public static let stampImport = "Import an SVG or image…"
    public static let stampWidthTitle = "Stamp width"
    public static func stampOffFace(_ n: Double) -> String { fit(String(format: "%.1f N of the stamp lands off the face", n)) }
    /// ★ VERIFICATION OF D1: the main page's lattice sinks the whole face under a stamp today
    /// (core brief #10) — this page's map is the stamp he drew. Said on the panel.
    /// ★ BATCH G VERIFICATION: false since batch G — the main page's 3D sim presses the stamp where
    /// it sits (core's per-column pressure), its neighbours dragged in; said so now.
    public static let stampMainPage = "Main page: the 3D sim presses the stamp"
    /// …and on the main page's dent legend, while a Stamp face's COLUMN squish is shown there (the
    /// fallback after a failed sim — FlexibleMainStage.legendTitle).
    public static let stampMainLegend = "Squish · stamp: whole face"

    /// "10 kg from Top" · "6.0 kg of Top's 10 kg" (a group over several faces) · "7.1 kg at an angle".
    public static func weight(kg: Double, group: String?, groupKg: Double, groupRegions: Int, oblique: Bool) -> String {
        let w = kgText(kg)
        guard let group else { return w }
        let g = fit(group, 14)
        if oblique { return fit("\(w) of \(g)'s \(kgText(groupKg)) · at an angle") }
        if groupRegions > 1 { return fit("\(w) of \(g)'s \(kgText(groupKg))") }
        return fit("\(w) from \(g)")
    }
    /// The More tab's Auto line and whether it is a warning (pure: FlexibleRowCopyTests).
    public static func autoLine(noData: Bool, pressedFaces: Int, chosen: Bool?, reachable: Bool?, error: Bool,
                                topology: String, tempC: Double?) -> (text: String, warning: Bool) {
        if noData { return (autoNoData, false) }
        if error { return (autoNoPick, true) }
        if pressedFaces == 0 { return (autoNoFace, false) }
        guard let chosen else { return (autoWaiting, false) }
        if !chosen { return (autoNoPick, true) }
        if reachable == false { return (autoUnreachable, true) }
        return (auto(topology: topology, tempC: tempC), false)
    }

    /// The weight row of a marked face, exactly as the panel shows it: "from <group>" only
    /// while the face is LINKED to the group that holds it.
    public static func weight(face f: FlexibleFaceSettings, entry e: FlexibleMainPageLoads.Entry?) -> String {
        let fromGroup = f.weightFrom != nil && e?.groupID == f.weightFrom
        return weight(kg: f.weightKg, group: fromGroup ? e?.groupName : nil, groupKg: e?.groupKg ?? 0,
                      groupRegions: e?.groupRegions ?? 0, oblique: fromGroup && (e?.oblique ?? false))
    }
    public static func kgText(_ kg: Double) -> String {
        abs(kg - kg.rounded()) < 0.05 ? "\(Int(kg.rounded())) kg" : String(format: "%.1f kg", kg)
    }
    public static let weightTitle = "Weight"
    public static let shape = "Shape"
    public static func deepest(_ mm: Double) -> String { String(format: "Deepest squish %.1f mm", mm) }
    public static let deepestTitle = "Deepest squish"

    // MARK: ★ squeeze groups (round 4 batch D2)

    public static let groupsTitle = "Squeeze groups"
    public static func groupName(_ number: Int) -> String { "Group \(number)" }
    /// "Squeeze 10 kg" · "Squeeze 7–10 kg" (a project from before groups, faces of their own weights).
    public static func squeeze(_ force: ClosedRange<Double>?) -> String {
        guard let f = force else { return "Squeeze —" }
        if f.upperBound - f.lowerBound < 0.05 { return "Squeeze \(kgText(f.upperBound))" }
        return "Squeeze \(kgNumber(f.lowerBound))–\(kgText(f.upperBound))"
    }
    static func kgNumber(_ kg: Double) -> String {
        abs(kg - kg.rounded()) < 0.05 ? "\(Int(kg.rounded()))" : String(format: "%.1f", kg)
    }
    /// The faces, joined " + ", cut to "Top A + 3 more" when the line would not fit.
    static func faceList(_ names: [String], room: Int) -> String {
        let all = names.joined(separator: " + ")
        if all.count <= room { return all }
        guard names.count > 1 else { return fit(all, max(4, room)) }
        for keep in stride(from: names.count - 1, through: 1, by: -1) {
            let s = names.prefix(keep).joined(separator: " + ") + " + \(names.count - keep) more"
            if s.count <= room { return s }
        }
        // the first name cut to what is left beside "+ N more"; with no room at all, a count
        let more = " + \(names.count - 1) more"
        if room - more.count >= 5 { return fit(names[0], room - more.count) + more }
        return "\(names.count) faces"
    }
    /// ONE line per group, its faces and its ONE force: "Group 1 · Face 3 + Face 5 · Squeeze 10 kg".
    public static func groupLine(number: Int, names: [String], force: ClosedRange<Double>?) -> String {
        let head = "\(groupName(number)) · ", tail = " · \(squeeze(force))"
        return fit(head + faceList(names, room: maxChars - head.count - tail.count) + tail)
    }
    /// ★ D2 REVIEW: a group's HEADER in the face list — "Group 1 · Squeeze" ("Squeeze" with one
    /// pressed face); the force is in its pill (`squeezeValue`) and its faces are listed under it.
    /// D2's one line with the faces AND the force was cut at the force on every iPad.
    public static func groupHeader(number: Int, single: Bool) -> String {
        single ? "Squeeze" : "\(groupName(number)) · Squeeze"
    }
    /// The force in the header's pill: "10 kg" · "6–10 kg" · "—".
    public static func squeezeValue(_ force: ClosedRange<Double>?) -> String {
        guard let f = force else { return "—" }
        if f.upperBound - f.lowerBound < 0.05 { return kgText(f.upperBound) }
        return "\(kgNumber(f.lowerBound))–\(kgText(f.upperBound))"
    }
    /// ★ D2 REVIEW: under a group's header when it will squish less than designed (the lattice
    /// carries every group; the firmer wins): "Squishes ~0.3 of 2.6 mm · Group 2 firmer".
    public static func groupMissLine(asBuiltMM: Double, designedMM: Double, firmer: Int) -> String {
        fit(String(format: "Squishes ~%.1f of %.1f mm · %@ firmer", asBuiltMM, designedMM, groupName(firmer)))
    }
    /// A pinched face whose two-segment design failed: it keeps core's one profile for now.
    public static func pinchedOneProfile(with other: String) -> String { fit("Pinched with \(fit(other, 16)) · one profile for now") }
    /// The squish player's picker: "Group 2 · Face 3 + Face 5" / "Play all" (★ batch G: the groups in
    /// turn — D2's "All at once" is dropped).
    public static func simTitle(number: Int, names: [String]) -> String {
        let head = "\(groupName(number)) · "
        return fit(head + faceList(names, room: 34 - head.count), 34)
    }
    public static let simAll = "Play all"
    public static let simAllShort = "All"
    /// ★ BATCH G VERIFICATION: the picker while "Play all" plays a group's own sim: "All · Group 2".
    public static func playAllPlaying(_ group: String) -> String { "\(simAllShort) · \(group)" }
    /// The face card's group row and its chip that makes a new group.
    public static let groupRow = "Squeeze group"
    public static let newGroupChip = "+ New"
    /// ★ SEPARATE GROUPS SHARE MATERIAL: said in one line (the page's, under the groups).
    public static let groupsShare = "Groups share material: the firmer one wins"
    /// A group that squishes less than it was designed for, because another group's material is
    /// firmer there (the player's line): "Group 2 squishes 1.2 of 3.0 mm · firmer wins".
    public static func groupMisses(number: Int, asBuiltMM: Double, designedMM: Double) -> String {
        fit(String(format: "%@ squishes %.1f of %.1f mm · firmer wins", groupName(number), asBuiltMM, designedMM))
    }
    /// ★ D2 REVIEW: said BEFORE Exit, when separate groups compete for material (the pop-up and
    /// the top line): "Group 1 would squish ~0.3 of 2.6 mm: Group 2 needs firmer material".
    public static func groupCompetes(number: Int, asBuiltMM: Double, designedMM: Double, firmer: Int) -> String {
        String(format: "%@ would squish ~%.1f of %.1f mm: %@ needs firmer material",
               groupName(number), asBuiltMM, designedMM, groupName(firmer))
    }
    /// The same, short (the Settings page's top line: "Ready · …").
    public static func groupMissesEstimate(number: Int, asBuiltMM: Double, designedMM: Double) -> String {
        String(format: "%@ squishes ~%.1f of %.1f mm · firmer wins", groupName(number), asBuiltMM, designedMM)
    }
    /// A pressed face pinched with another of its group (two segments).
    public static func pinched(with other: String) -> String { fit("Pinched with \(fit(other, 16)) · two halves") }

    /// ★ WHAT HE MUST KNOW ABOUT THE SELECTED FACE, ON THE PANEL (verification of round 3: a
    /// refusal, the columns his curve cannot reach and the side-face limit lived only behind
    /// the Deepest-squish (i)). One warning line, the first that applies; the (i) explains.
    public static func faceWarning(refusalCode: String?, refusalReason: String?, unreachedColumns: Int,
                                   side: Bool) -> String? {
        if let code = refusalCode {
            switch code {
            case "temperature_not_tested": return "Temperature not tested · set it to Auto"
            case "topology_no_data", "honeycomb_side_stack", "too_few_rows": return "No data for this lattice · pick Auto"
            case "calibrate_first": return "No squish data for this filament"
            default: return fit("Can't design this face: \(refusalReason ?? code)")
            }
        }
        if unreachedColumns > 0 { return fit("Can't reach your curve on \(unreachedColumns) columns") }
        if side { return "Side face · gyroid only · estimated" }
        return nil
    }
    /// The number pad's title when a face with no main-page load is pressed.
    public static let askWeight = "How much weight presses here?"
    /// [Rests] chosen here on a face a main-page Load group presses: said, never hidden.
    public static func pressedOnMainPage(group: String) -> String { fit("\(fit(group, 16)) presses it on the main page") }
    /// A weight of his own the group's replaced (one source of truth: the group).
    public static func relinked(oldKg: Double, group: String) -> String {
        fit("Was \(kgText(oldKg)) · now \(fit(group, 16))'s weight")
    }

    // MARK: More

    /// ★ SHORT ENOUGH TO READ beside its chips in the 400 pt panel (it read "Nozzle temperat…").
    public static let temperature = "Nozzle °C"
    public static let temperatureNoData = "Nozzle °C · no data"
    public static let topology = "Lattice"
    public static func auto(topology: String, tempC: Double?) -> String {
        fit("Auto: \(topology.capitalized)" + (tempC.map { " at \(Int($0)) °C" } ?? ""))
    }
    public static let autoWaiting = "Auto: weighing the options"
    public static let autoNoData = "Auto: needs squish data"
    public static let autoNoFace = "Auto: press a face first"
    /// ★ SAID ON THE ROW (verification of round 3): Auto that cannot meet the drawing, or
    /// picked nothing, read "Auto: Gyroid at 190 °C" / "weighing the options" forever.
    public static let autoUnreachable = "Auto: can't meet your curve"
    public static let autoNoPick = "Auto: no pick"
    /// Walls and the physics notes, folded into ONE row (only what is necessary).
    public static let physics = "Physics · 1-bead walls"

    // MARK: the (i) texts — details only; nothing required lives here

    public enum Info {
        public static let filament = "The filament the lattice is printed in. Only colorFabb varioShore TPU has published squish data: its dents are predicted, with a tier and ± band. Every other filament is \"calibrate first\": no squish in mm is predicted and no lattice is sized from it until coupons are measured."
        public static let feel = "Springy bounces back and prefers gyroid (lowest energy loss, best recovery). Damped soaks up the push and prefers honeycomb (bigger loop, firmer). Auto weighs both."
        public static let face = "Pressed: this face carries weight and squishes. Rests: it sits on something and carries no squish of its own. A face in a main-page Load group arrives pressed; an Anchor group's faces arrive resting. Tap a face on the part to select it."
        public static let weight = "This face's share of its squeeze group's force. The force is set on the group's row above the faces ([10 kg ✎]) — one force per group, written back to the main page's Load group when it comes from one. A main-page group over several faces is split by area, the way the solver spreads it; a press at an angle counts its straight-in part (cos θ)."
        public static let shape = "Curves: the X and Y curves drawn on the face's two edges, always combined — soft only where both say soft. A point nearer the face is squishier. Tap the line to add a point; tap a point for an × to delete it. Stamp: the face is shaped by ONE stamp — what presses it — and sinks the deepest squish under it; drag its handle on the part to move it. One or the other, never both."
        public static let finish = "The whole part's outside. None: the lattice runs to the surface everywhere. Rim: a solid band along every edge, the faces open. Skin: a thin skin over the lattice with round holes in it. Covered: a solid skin everywhere. Only Covered reaches the solver today; Rim and Skin are drawn by the app (the line under the row says so). Rim's band is 2 mm; Skin is 0.8 mm thick with 3 mm holes (1.5 mm radius) 5 mm apart."
        public static let stamp = "What presses this face: pick one from the list, or import an SVG outline or an image (darker presses harder). Its weight is the face's weight."
        public static let stampSize = "The stamp's real size across; its other side follows its own proportions."
        public static let stampTurn = "Turns the stamp a quarter turn on the face."
        public static let stampPress = "Soft spreads the weight evenly under the stamp (a hand, a foot). Rigid sinks evenly, like a flat plate."
        public static let deepest = "How far the softest spot sinks under the full weight. Drag the chip on the part: while you drag, a glass prism shows how deep it goes (drawn ×k, the same exaggeration as the dent). It snaps every 0.5 mm and at the lattice depth, and never goes deeper than the lattice. One drag stops where the drawn prism meets the lattice; let go and drag again to go deeper."
        public static let temperature = "Foaming filaments change softness with nozzle temperature — and not in order. Only the temperatures the filament was tested at are offered; Auto picks one."
        public static let topology = "Auto picks gyroid or honeycomb for the feel you chose. Honeycomb has test data only when pressed along its prism axis, so a side face is gyroid only."
        public static let noFace = "Tap a face on the part to select it, then press it or let it rest. Faces from the main page's Load and Anchor groups are already set."
        /// ★ ROUND 4 (D2).
        public static let groups = "Faces in one group are squeezed at the same time with the same force — like two hands pressing equally; each face keeps its own curve. The force is the pill beside the group: tap it to change it (it changes the main page's Load group too). To make a group, open a pressed face below and tap + New; tap a group's number to move a face there; × joins a group to the first other one. Two opposite faces in one group are a pinch: each half of the part between them is designed for its own face. Separate groups are separate squeezes: the lattice is built for all of them, and where two groups need the same material the firmer one wins — a group that will squish less than drawn says so under its row. A main-page Load group is one hand: its faces move together and share its weight by area."
        public static let groupRow = "Move this face to another squeeze group, or make a new group from it."
    }
}
