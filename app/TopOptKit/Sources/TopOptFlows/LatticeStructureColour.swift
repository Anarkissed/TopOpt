// LatticeStructureColour — ★ ONE TABLE, READ BY THE MARCH AND BY THE KEY
// (maintainer, 2026-08-19: "I thought they were tinted for different *types* of
// lattice structures. Something like the Rim was blue, the regular cells were
// purple, the weight taking cells were green").
//
// ★★ WHY THE HUE CHANGED MEANING. It used to be the owning GROUP's colour, so a
// strut told you which faces had been selected — a fact the Selections list already
// shows, and one that says nothing about the lattice. On a page whose whole subject
// IS the lattice, that channel is better spent on what a strut IS. Density keeps
// the lightness axis inside each hue, so nothing was given up to make room.
//
// ★ AND IT IS ONE TABLE ON PURPOSE. The shader reads these through
// `LSDFUniforms.rimColor` / `loadColor` / `denseColor`, and the legend reads the
// very same constants. A second copy for the key is how a legend ends up describing
// a picture the renderer stopped drawing.

import Foundation

public enum LatticeStructureColour {
    /// The pale end every hue washes out to as density falls.
    public static let pale = RGBAColor(r: 0.92, g: 0.93, b: 0.97)

    /// BOUNDARY work — rim, diagrid and skin: the heavier struts where the lattice
    /// meets its own edge.
    public static let rim = RGBAColor(r: 0.26, g: 0.60, b: 0.98)

    /// ORDINARY interior fill.
    public static let interior = RGBAColor(r: 0.49, g: 0.42, b: 0.86)

    /// The GRADE TO SHAPE: cells the band thickens toward the solid outline. Drawn
    /// as a ramp from the interior hue (no raise) to this (the quilt against the
    /// outline), so the tint itself is the gradient (his 2026-09-16 ask).
    public static let grade = RGBAColor(r: 0.18, g: 0.80, b: 0.66)

    // ★★ THERE WAS A THIRD CLASS, AND IT WAS REMOVED (maintainer, 2026-08-19: "Yes,
    // I agree. Remove the green load carrying lattice type").
    //
    // "Load-carrying" was any cell whose density passed 0.6 of the band. That is
    // redundant twice over: lightness ALREADY encodes density continuously, so green
    // drew a hard threshold across smooth data; and with the stress map on the struts,
    // "where is the load going" is answered properly, in MPa, without inventing a cut
    // that would need defending every time someone asked "why 0.6?".
    //
    // What is left is a real structural distinction — boundary work versus fill —
    // which is NOT derivable from density. Hue = what it is, lightness = how much
    // material, stress = where the load goes. Three channels, no overlap.
}

/// The three things a strut can be. Stable ids so the key can drill into one.
public enum LatticeStructureClass: String, CaseIterable, Sendable {
    case rim, interior, grade

    public var id: UUID {
        switch self {
        case .rim:      return UUID(uuidString: "5747ICE0-0000-0000-0000-000000000001")
                            ?? UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        case .interior: return UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        case .grade:    return UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        }
    }

    public var title: String {
        switch self {
        case .rim:      return "Rim & skin"
        case .interior: return "Interior fill"
        case .grade:    return "Grade to shape"
        }
    }

    public var colour: RGBAColor {
        switch self {
        case .rim:      return LatticeStructureColour.rim
        case .interior: return LatticeStructureColour.interior
        case .grade:    return LatticeStructureColour.grade
        }
    }

    /// One short line under the name (the (i) at its end opens `detail`).
    public var brief: String {
        switch self {
        case .rim:      return "The outline and any finish"
        case .interior: return "Ordinary fill"
        case .grade:    return "Thickens toward the outline"
        }
    }

    /// The colour a ramp to this class starts from (nil ⇒ a flat swatch).
    public var gradientFrom: RGBAColor? {
        self == .grade ? LatticeStructureColour.interior : nil
    }

    /// ★ ONE SENTENCE PER COLOUR, and each says what makes it DIFFERENT from the
    /// other two — not what the row is.
    public var detail: String {
        switch self {
        case .rim:
            return "The solid outline around each latticed face, and any rim, "
                 + "diagrid or skin finish: the heavier work where the lattice meets its edge."
        case .interior:
            return "Ordinary fill. Thickness follows the density — pale is thin, "
                 + "deep is thick. Turn the stress view on to see where the load goes."
        case .grade:
            return "Cells the grade band thickens toward the solid outline. The tint "
                 + "deepens from the band's inner edge to the quilt against the outline."
        }
    }
}
