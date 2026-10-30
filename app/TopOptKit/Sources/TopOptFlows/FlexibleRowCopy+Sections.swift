// FlexibleRowCopy+Sections — the words of round 7 batch M2 (lattice sections under a face-prism, Flexible-only sectors).
// Every line ≤ 44 characters (FlexibleRowCopy.fit), plain words.

import Foundation

extension FlexibleRowCopy {
    /// A tap on the solid part of a face only partly inside a face-prism (his img3 words; one fix: [Go to Lattice]).
    public static let solidHere = "Solid here · only face-prisms get latticed"
    /// The fix's button: the main Lattice page (where face-prisms are set).
    public static let goToLattice = "Go to Lattice"
    /// ★ U21 BATCH E (his Img11/12: "if we are going to say 'you need to lattice this first' then it should do so for every
    /// face"): the ONE sentence for any face, or part of a face, with no lattice of its own — a tap on it, a pressed face's
    /// pop-up and pill, the no-face-prism stage. (The plan's "… · set a face-prism first" is 48 characters with "Face 5": the
    /// "first" is dropped to keep his 44, the edge picker's own "· set a face-prism".)
    public static func noLatticeUnder(_ name: String) -> String {
        let head = "No lattice under ", tail = " \u{00B7} set a face-prism"
        return head + fit(name, maxChars - head.count - tail.count) + tail   // the NAME is fitted, the what-to-do kept
    }
    /// A face a curved / bolt / holed face-prism meets only partly (D4): kept whole, said.
    public static let curvedNotYet = "Curved lattice here · not yet"
    /// The Squish page's legend row while a face is cut into sections.
    public static let sectionLegend = "Violet = lattice · tap to pick"
    /// An edge pick whose lattice on a member face lies in two places (D6).
    /// ★ R7-E3 (carry-over (b), plain words for E1b's "its lattice is in two places"): the cut would split its lattice in two.
    public static func latticeInTwoPlaces(_ label: String) -> String { fit("\(label) · \(splitsTheLattice)") }
    public static let splitsTheLattice = "would split its lattice in two"
    /// ★ R7-E3 (b): a depth stop for that reason — "Max 18.1 mm · deeper splits the lattice in two" was 46 characters (his rule is 44).
    public static func maxDepthSplits(_ mm: Double) -> String { fit("Max " + String(format: "%.1f", mm) + " mm \u{00B7} deeper splits its lattice") }
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
