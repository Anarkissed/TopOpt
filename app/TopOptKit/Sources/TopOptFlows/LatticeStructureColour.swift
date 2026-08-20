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

    /// LOAD-CARRYING cells — those the grading drove past `loadCut` of the band.
    public static let load = RGBAColor(r: 0.24, g: 0.78, b: 0.44)

    /// ★ THE CUT, STATED ONCE. A cell reads as load-carrying above this fraction of
    /// the density band the preview is grading between — not an absolute density,
    /// because the band itself moves with the printer and the topology.
    ///
    /// 0.6 is a judgement: high enough that ordinary fill does not flash green, low
    /// enough that a genuinely thickened run of cells does. It is one constant, and
    /// it is the sort of number worth arguing with once it can be seen.
    public static let loadCut: Double = 0.6
}

/// The three things a strut can be. Stable ids so the key can drill into one.
public enum LatticeStructureClass: String, CaseIterable, Sendable {
    case rim, interior, load

    public var id: UUID {
        switch self {
        case .rim:      return UUID(uuidString: "5747ICE0-0000-0000-0000-000000000001")
                            ?? UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        case .interior: return UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        case .load:     return UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        }
    }

    public var title: String {
        switch self {
        case .rim:      return "Rim & skin"
        case .interior: return "Interior fill"
        case .load:     return "Load-carrying"
        }
    }

    public var colour: RGBAColor {
        switch self {
        case .rim:      return LatticeStructureColour.rim
        case .interior: return LatticeStructureColour.interior
        case .load:     return LatticeStructureColour.load
        }
    }

    /// ★ ONE SENTENCE PER COLOUR, and each says what makes it DIFFERENT from the
    /// other two — not what the row is.
    public var detail: String {
        switch self {
        case .rim:
            return "Struts on the lattice's own edge, run heavier so the boundary "
                 + "holds. This is the rim, diagrid or skin you picked as the finish."
        case .interior:
            return "Ordinary fill everywhere else. Thickness follows the density "
                 + "you set — nothing has asked it to be stronger."
        case .load:
            return "Cells the stress pushed past 60% of the band. Material went "
                 + "here because the solve said the part needs it."
        }
    }
}
