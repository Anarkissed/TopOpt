// PanelAccordion.swift — B2 (round 1, his R2.1: "When in a lattice stage, opening Topology selections automatically closes the
// lattice one and vice-versa"; design-system §4.3).
//
// Where a stage has two left panels (the Topology panel above Selections: Lattice and Flexible), opening one folds the other to
// its header. The Topology panel sits on top, closed by default. The pages that have two panels (B6's Lattice Setup, #362's
// Flexible Setup) hold one of these.

struct PanelAccordion: Equatable {
    enum Panel: Equatable { case topology, selections }

    /// The open panel (nil: both folded to their headers).
    private(set) var open: Panel? = .selections

    func isOpen(_ p: Panel) -> Bool { open == p }

    /// A tap on a panel's header: open it (folding the other), or fold it if it was open.
    mutating func tap(_ p: Panel) { open = open == p ? nil : p }
}
