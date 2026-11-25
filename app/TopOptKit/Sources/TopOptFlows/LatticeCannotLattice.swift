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

    // MARK: ★ notes28 — a region the PRINT CHECK emptied (builder D, organic-1 5bdca042; 362 11-25)

    /// lattice_file.json's `cannot_lattice` (in its `layout` block; written only when the print check's leave-outs took
    /// nearly all of a cell region's struts): the region (the job's region id; 0 the whole part), its struts, how many the
    /// check left out, and core's one plain line why. The file is still written, with nothing where that region's cells were.
    struct Emptied: Equatable, Sendable {
        var region: Int
        var struts: Int, leftOut: Int
        var why: String
    }

    /// The emptied regions a print file's result names (none: the key is absent, as it is whenever nothing was emptied).
    nonisolated static func emptied(report: Data?) -> [Emptied] {
        guard let d = report, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [] }
        let list = ((o["layout"] as? [String: Any])?["cannot_lattice"] ?? o["cannot_lattice"]) as? [[String: Any]] ?? []
        return list.compactMap { e in
            guard let r = e["region"] as? Int else { return nil }
            return Emptied(region: r, struts: e["struts"] as? Int ?? 0, leftOut: e["left_out"] as? Int ?? 0,
                           why: e["why"] as? String ?? "")
        }
    }

    /// The centred pop-up's text (titled `title`): each emptied region named his way (`name`: his name for its group, or how
    /// many faces it has — never a number), with core's line. nil: nothing was emptied.
    nonisolated static func popUpText(_ emptied: [Emptied], name: (Int) -> String) -> String? {
        guard !emptied.isEmpty else { return nil }
        return emptied.map { "\(name($0.region)): \($0.why)" }.joined(separator: "\n")
    }

    /// A job region his way: the whole part, else the lattice group it belongs to (`LibraryVersionFacts.label`: his name, or
    /// how many faces it has). A region the project no longer has is "A lattice area" — never its number.
    static func regionName(_ region: Int, in p: ProjectModel) -> String {
        if region == 0 { return "The part" }
        guard let gid = LatticeLayoutPreview.regionGroups(p)[Int32(region)],
              let g = p.latticeGroups.first(where: { $0.id == gid }) else { return "A lattice area" }
        return LibraryVersionFacts.label(g)
    }

    /// Raises the pop-up for a landed print file whose check emptied a region. True: it said something.
    @discardableResult
    static func sayEmptied(report: Data?, in p: ProjectModel) -> Bool {
        guard let text = popUpText(emptied(report: report), name: { regionName($0, in: p) }) else { return false }
        AppPopups.shared.show(title, text)
        return true
    }

    /// The Lattice button's normal look, or "Cannot Lattice" (greyed, disabled: a press does nothing) when `cannot`.
    static func look(_ normal: LatticePrintFlow.Look, cannot: Bool) -> LatticePrintFlow.Look {
        guard cannot else { return normal }
        return LatticePrintFlow.Look(title: title, subtitle: line, state: .disabled(line), progress: nil, tap: .normal,
                                     marker: "latticeCannot")
    }
}
