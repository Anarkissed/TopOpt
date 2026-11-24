// LatticeCannotLattice.swift — ★ his iPad notes 2026-11-23 evening (img 4: "Structural can't lattice the glowing walls"; img 5:
// "100 % of the lattice you asked for is solid"): when the chosen lattice cannot lattice anything, the big Lattice button says
// "Cannot Lattice", greyed and not pressable. It said "Lattice · Stepped waits on a strength check" (another, older reason).
//
// The condition is the solid notice's own (`SolidReason`, the new engine's verdict after each lay, `LatticeLayoutPreview`):
// shown, and saying 100 % — nothing he asked for is laid. Not while a lay runs (that notice is the last lay's), and never
// over "Refresh Lattice" or a run in flight. When he switches to a lattice that can (Aesthetic) or changes a setting, the
// next lay's notice decides again and the button is "Lattice" once anything is laid.
//
// Merge note for 362: the Lattice button's own looks (Lattice / Make print accurate / Approved) are LatticePrintFlow's; this
// only replaces the NORMAL look it is handed (WorkspacePlaceholder.latticeRunButton, the `cannot` line and the
// `normal: LatticeCannotLattice.look(normal, cannot: cannot)` argument), so the flow's Making / Approved still win over it.

import Foundation

@MainActor
enum LatticeCannotLattice {
    static let title = "Cannot Lattice"
    /// The button's second line (at most 5 words).
    static let line = "All of it stays solid"
    /// The share the notice must say for "Cannot Lattice": all of it (as the notice rounds it).
    static let solidPercent = 100

    /// Whether nothing of the asked-for lattice can be laid: the notice is up and says 100 %.
    static func applies(_ reason: SolidReason?) -> Bool {
        guard let r = reason else { return false }
        return SolidReason.percent(r.share) >= solidPercent
    }

    /// The Lattice button's normal look, or "Cannot Lattice" (greyed, disabled: a press does nothing) when `cannot`.
    static func look(_ normal: LatticePrintFlow.Look, cannot: Bool) -> LatticePrintFlow.Look {
        guard cannot else { return normal }
        return LatticePrintFlow.Look(title: title, subtitle: line, state: .disabled(line), progress: nil, tap: .normal,
                                     marker: "latticeCannot")
    }
}
