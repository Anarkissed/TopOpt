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

    /// "colorFabb varioShore TPU · has squish data" / "TPU 95A · shape only".
    public static func filament(name: String?, hasData: Bool) -> String {
        guard let name else { return "Pick a filament" }
        let tail = hasData ? " · has squish data" : " · shape only"
        return fit(shortName(name), maxChars - tail.count) + tail
    }
    public static let feel = "Feel"

    // MARK: face rows

    /// A face's short name: a sector's own name ("Top A"), else "Face 3".
    public static func faceName(sector: String?, face: Int) -> String {
        if let s = sector, !s.isEmpty { return fit(s.prefix(1).uppercased() + s.dropFirst(), 20) }
        return "Face \(face)"
    }
    public static let noFace = "Tap a face on the part"

    /// "10 kg from Top" · "6.0 kg of Top's 10 kg" (a group over several faces) · "7.1 kg at an angle".
    public static func weight(kg: Double, group: String?, groupKg: Double, groupRegions: Int, oblique: Bool) -> String {
        let w = kgText(kg)
        guard let group else { return w }
        let g = fit(group, 14)
        if oblique { return fit("\(w) of \(g)'s \(kgText(groupKg)) · at an angle") }
        if groupRegions > 1 { return fit("\(w) of \(g)'s \(kgText(groupKg))") }
        return fit("\(w) from \(g)")
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
    public static let skin = "Solid skin"
    public static func sharesStack(with other: String) -> String { fit("Shares a stack with \(other)") }
    /// The number pad's title when a face with no main-page load is pressed.
    public static let askWeight = "How much weight presses here?"
    /// [Rests] chosen here on a face a main-page Load group presses: said, never hidden.
    public static func pressedOnMainPage(group: String) -> String { fit("\(fit(group, 16)) presses it on the main page") }
    /// A weight of his own the group's replaced (one source of truth: the group).
    public static func relinked(oldKg: Double, group: String) -> String {
        fit("Was \(kgText(oldKg)) · now \(fit(group, 16))'s weight")
    }

    // MARK: More

    public static let temperature = "Nozzle temperature"
    public static let temperatureNoData = "Nozzle temperature · no data"
    public static let topology = "Lattice"
    public static func auto(topology: String, tempC: Double?) -> String {
        fit("Auto: \(topology.capitalized)" + (tempC.map { " at \(Int($0)) °C" } ?? ""))
    }
    public static let autoWaiting = "Auto: weighing the options"
    public static let autoNoData = "Auto: needs squish data"
    public static let walls = "Walls · 1 bead"
    public static let physics = "Physics"

    // MARK: the (i) texts — details only; nothing required lives here

    public enum Info {
        public static let filament = "The filament the lattice is printed in. Only colorFabb varioShore TPU has published squish data: its dents are predicted, with a tier and ± band. Every other filament is \"calibrate first\": the lattice is still built from your curves (shape only), but no squish in mm is predicted until coupons are measured."
        public static let feel = "Springy bounces back and prefers gyroid (lowest energy loss, best recovery). Damped soaks up the push and prefers honeycomb (bigger loop, firmer). Auto weighs both."
        public static let face = "Pressed: this face carries weight and squishes. Rests: it sits on something and carries no squish of its own. A face in a main-page Load group arrives pressed; an Anchor group's faces arrive resting. Tap a face on the part to select it."
        public static let weight = "The weight pressing this face. It comes from the main page's Load group and changing it here changes the group. A group over several faces is split by area, the way the solver spreads it; a press at an angle counts its straight-in part (cos θ)."
        public static let shape = "Curves: the X and Y curves drawn on the face's two edges, always combined — soft only where both say soft. A point nearer the face is squishier. Tap the line to add a point; tap a point for an × to delete it. Stamp: squish by the shape of what presses (next build)."
        public static let deepest = "How far the softest spot sinks under the full weight. Drag the chip on the part: while you drag, a glass prism shows how deep it goes (drawn ×k, the same exaggeration as the dent). It snaps every 0.5 mm and at the lattice depth, and never goes deeper than the lattice. One drag stops where the drawn prism meets the lattice; let go and drag again to go deeper."
        public static let skin = "On: a solid skin covers this face and the squish is under it. Off: the lattice reaches the face, so edges and side walls squish too."
        public static let temperature = "Foaming filaments change softness with nozzle temperature — and not in order. Only the temperatures the filament was tested at are offered; Auto picks one."
        public static let topology = "Auto picks gyroid or honeycomb for the feel you chose. Honeycomb has test data only when pressed along its prism axis, so a side face is gyroid only."
        public static let auto = "Auto weighs every tested temperature and both lattice families for your faces and feel, and says why."
        public static let walls = "Walls are one bead thick. Two-bead walls come after coupon tests."
        public static let physics = "Not a simulation: measured squash curves, looked up and inverted. Numbers are after break-in (a new part is firmer for its first squeezes). Dents have sharper edges than real life, and a small press on a big pad sinks less than shown. No certificate."
        public static let noFace = "Tap a face on the part to select it, then press it or let it rest. Faces from the main page's Load and Anchor groups are already set."
    }
}
