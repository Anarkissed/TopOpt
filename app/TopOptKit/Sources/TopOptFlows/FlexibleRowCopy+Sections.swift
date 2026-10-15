// FlexibleRowCopy+Sections — the words of round 7 batch M2 (lattice sections under a face-prism, Flexible-only sectors).
// Every line ≤ 44 characters (FlexibleRowCopy.fit), plain words.

import Foundation

extension FlexibleRowCopy {
    /// A tap on the solid part of a face only partly inside a face-prism (his img3 words; one fix: [Go to Lattice]).
    public static let solidHere = "Solid here · only face-prisms get latticed"
    /// The fix's button: the main Lattice page (where face-prisms are set).
    public static let goToLattice = "Go to Lattice"
    /// A face a curved / bolt / holed face-prism meets only partly (D4): kept whole, said.
    public static let curvedNotYet = "Curved lattice here · not yet"
    /// The Squish page's legend row while a face is cut into sections.
    public static let sectionLegend = "Violet = lattice · tap to pick"
    /// An edge pick whose lattice on a member face lies in two places (D6).
    public static func latticeInTwoPlaces(_ label: String) -> String { fit("\(label) · its lattice is in two places") }
    /// An edge pick on a face with no lattice under it (D6).
    public static func noLatticeAt(_ label: String) -> String { fit("No lattice at \(label) · set a face-prism") }
    /// A section's name: "Face 1 · lattice" (one section), "Face 1 · lattice A" (two or more, by position).
    public static func sectionName(root: String, index: Int, of count: Int) -> String {
        guard count > 1 else { return "\(root) · lattice" }
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return "\(root) · lattice \(index < letters.count ? String(letters[index]) : String(index + 1))"
    }
    /// The carry's toast: a stamp whose centre lies on solid stays stored; the section is Curves.
    public static func stampStays(_ name: String) -> String { "Stamp on solid · the lattice part is Curves" }
    /// The carry's toast: a face pressed whole now presses its lattice only.
    public static func nowPressesLattice(_ name: String) -> String { fit("\(name) now presses its lattice only") }
    /// The one-time move of I2's strips off the Surface stage.
    public static let stripsMoved = "Edge strips now live on Flexible only"
    /// A chain of I2's he uses on another stage stays there.
    public static func cutStaysOnSurface(_ label: String) -> String { fit("\(label)'s cut stays on Surface: you use it there") }
}
