// LatticeThinWallReasons.swift — ★ notes25 (D8, his 11-23 on "Structural can't lattice the glowing walls"): "I want the user to
// *understand* why that particular wall/area is difficult to lattice correctly. Don't assume they know anything about
// lattices." The pop-up's body under its title: three short reasons, each with its own (i) (InfoTip, the app's (i)); one line
// on what Aesthetic does instead; the cell-size hint in a Manual cell mode only (his 11-09); and "Learn more", which opens the
// page on Structural and Aesthetic in the centred help card (AppPopups.help, as the Organic glossary opens). Never open by
// default (his help rule). The words are LatticeThinWallPrompt's.

import SwiftUI
import TopOptDesign
import TopOptKit

struct LatticeThinWallReasons: View {
    let finding: LatticeStructuralThinWalls.Finding
    let lattice: LatticeSettings
    /// The old bake's own cells per member, where it found the walls (the new engine's finding carries its number).
    var oldBakeCells: Double? = nil
    /// ★ notes30 X2 (cell advice): the smallest cell laid and what the walls hold (the solid reason's depth ask).
    var cells: SolidReason.Depth? = nil

    /// The cells across a wall Structural asked for: the engine's number, else the old bake's, else core's floor.
    var cellsAcross: Int {
        finding.cellsAcross
            ?? Int((oldBakeCells ?? TopOptKit.latticeLimits(topology: lattice.topologyID).minCellsPerMember).rounded())
    }
    /// Aesthetic's number for this lattice (the engine's one rule).
    var aestheticCells: Int {
        var a = lattice
        a.stageMode = .aesthetic
        return Int(LatticeLayoutPreview.minCellsAcross(a))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            let reasons = LatticeThinWallPrompt.reasons(finding, cellsAcross: cellsAcross)
            ForEach(Array(reasons.enumerated()), id: \.offset) { i, r in
                HStack(alignment: .center, spacing: DS.Space.xs) {
                    Text(r.line)
                        .dsStyle(DS.TypeScale.caption).fontWeight(.semibold)
                        .foregroundStyle(DS.Color.textPrimary.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    InfoTip(key: "thin-walls-why-\(i + 1)", text: r.why, label: r.whyTitle)
                }
                .background(CornerPairStyle.publish("lattice-thin-walls-reason-\(i + 1)"))
                .accessibilityElement(children: .contain)
            }
            Text(LatticeThinWallPrompt.aestheticLine(cellsAcross: aestheticCells))
                .dsStyle(DS.TypeScale.footnote)
                .foregroundStyle(DS.Color.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.Space.xs)
                .background(CornerPairStyle.publish("lattice-thin-walls-aesthetic"))
            // ★ D10: Fixed and Swept only (Fit is not by hand); ★ notes30 X2: only where a smaller cell lays, else Allow quilt's
            if let hint = LatticeThinWallPrompt.cellLine(lattice, cells: cells) {
                Text(hint)
                    .dsStyle(DS.TypeScale.footnote)
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(CornerPairStyle.publish("lattice-thin-walls-hint"))
            }
            Button { AppPopups.shared.help(LatticeThinWallPrompt.pageTitle, LatticeThinWallPrompt.page()) } label: {
                Text(LatticeThinWallPrompt.learnMore).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Color.accent.color)
                    .frame(minWidth: DSParts.target, minHeight: DSParts.target, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(CornerPairStyle.publish("lattice-thin-walls-learn"))
            .accessibilityIdentifier("lattice-thin-walls-learn")
        }
    }
}
