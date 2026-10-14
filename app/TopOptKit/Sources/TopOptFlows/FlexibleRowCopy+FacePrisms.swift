// FlexibleRowCopy+FacePrisms — the words of round 7 batch M1 (the face-prism is the lattice; one group per export). One
// line each, ≤ 44 characters where it is a row (his rule), plain words. In its own file so the other round-7 batches'
// copy never meets it.

import Foundation

extension FlexibleRowCopy {
    /// ★ M1 (1a, ruling 4): no face is set to Lattice — no lattice on the Flexible stage; the pill and the Export step's
    /// line both say it, and the one fix (Selections' Lattice chip, or the Squish page's [Lattice under it]).
    public static let noFacePrism = "Set a face to Lattice in Selections first"

    /// ★ M1 (H15'): the main page's [Prisms] row in the ONE legend card — the picked group's LATTICE face-prisms (no squish
    /// prism or squish number on the main page: his 2026-10-14 answer, the squish number is the Squish page's).
    public static let mainFacePrismsRow = "Face-prism = where the lattice goes"
    /// The card's header when that row is all it carries.
    public static let mainFacePrismsTab = "FACE-PRISMS"

    /// ★ M1 (5, the reviewer's ruling 4 on an edges group beside face groups): core designs ONE squeeze group per job and
    /// takes no edge press yet, so an export makes one group — SAID before anything is sent, in his plain words.
    public static func exportMakesOnly(_ group: String) -> String { "This export makes \(group) only." }
    /// …and with two or more face groups beside the edges group (each [Send …] button makes one).
    public static let exportMakesOneEach = "Each export makes one group only."
    /// The second line, always under it while an edges group sits beside face groups.
    public static let edgesExportSeparately = "Edges and faces go in separate exports for now."
    /// The main page's pill (a preview: its tap opens the Export step on the line above).
    public static let edgesBesidePill = "Preview \u{00B7} one group per export"
}

extension FlexibleRowCopy.Info {
    /// ★ M1: the legend card's (i) with only the [Prisms] row in it.
    public static let mainFacePrisms = "A face-prism is the lattice under a face: only inside a face-prism does the part become lattice. It is drawn from the face to its depth — the depth set in Selections, the same number its row shows. Pick a group in Selections to see its face-prisms; [Prisms] adds this row and X-ray. The squish is set on the Squish page."
}
