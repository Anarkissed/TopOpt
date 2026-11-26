// LatticeDiagnosisCard — ★ notes30 X2 (his yes, 11-26): the Lattice page's warning triangle ("How to fix this") opens the app's
// one centred card (AppPopups.help: "Tap anywhere to continue", any tap closes it), like every (i) — it was a popover beside
// the glyph, the last one N1 kept (notes29). The card says every failure with its fix first and its numbers
// (`LatticeFaceDiagnosis.popoverText`); the fixes that name a Lattice page setting (the cell size, the density) are its
// buttons, each a 44 pt button going to that setting lit with what to try (the app's one way to a setting,
// WorkspacePlaceholder.openSettingToChange), so a value is never applied blind. A face's depth is said: its field is on the
// face rows just above the glyph.
import Foundation

@MainActor
enum LatticeDiagnosisCard {
    /// The card's title (five words at most).
    static let title = "How to fix this"

    /// Open the card for `d`; `go` takes a fix's button to its setting.
    static func open(_ d: LatticeFaceDiagnosis, go: @escaping (LatticeFaceDiagnosis.Change) -> Void) {
        let acts = d.changes.map { c in (title: c.title, run: { go(c) }) }
        AppPopups.shared.help(title, d.popoverText, action: acts.first, second: acts.count > 1 ? acts[1] : nil,
                              third: acts.count > 2 ? acts[2] : nil)
    }
}
