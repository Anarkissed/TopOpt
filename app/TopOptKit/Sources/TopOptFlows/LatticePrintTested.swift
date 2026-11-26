// LatticePrintTested.swift — ★ notes28 (362's ruling 2026-11-24, maintainer-approved; his rule "NOT PRINT-TESTED"): every
// strut type but the octet and BCC + Z wears "Not print-tested" under its card on the Lattice page until he marks it tested.
// The mark is the app's (AppSettings.latticePrintTested), never a project's. The tag's tap is its (i): a centred pop-up (his
// rule for long reading) saying how it goes — print the type's sample coupon — with the one action that clears it.
//
// There is no coupon print flow in the app to hand this to (the Lattice page's Sample DRAWS core's coupon, `lattice_sample`,
// and nothing exports it); builder D adds a print coupon per type in the engine.

import SwiftUI
import TopOptDesign

/// The tag under a type's card: nothing once the type is print-tested.
struct LatticePrintTestedTag: View {
    let id: String
    let name: String
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        if LatticeTypeCatalog.showsNotPrintTested(id, tested: settings.latticePrintTested) {
            Button {
                let id = self.id
                // ★ notes29 (his 11-25): an (i)'s centred notification ("Tap anywhere to continue"), its action kept
                AppPopups.shared.help(LatticeTypeCatalog.notPrintTestedCaption, LatticeTypeCatalog.notPrintTestedInfo(name),
                                      action: (title: Self.markTitle, run: { AppSettings.shared.markPrintTested(id) }))
            } label: {
                HStack(spacing: 3) {
                    Text(LatticeTypeCatalog.notPrintTestedCaption).font(.system(size: 10, weight: .medium)).lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(DS.Color.warning.color)
                    AppInfoGlyph()   // ★ notes29: the one (i)'s glyph
                }
                .frame(maxWidth: .infinity, minHeight: 44)   // his 44 pt target
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .latticeID("wizard-type-untested-\(id)")
        }
    }

    /// The pop-up's one action.
    static let markTitle = "Mark as tested"
}
