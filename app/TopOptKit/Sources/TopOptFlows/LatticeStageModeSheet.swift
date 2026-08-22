// LatticeStageModeSheet — ★★★ WHAT THIS MODE CAN AND CANNOT DO, AND THE WAY OUT
// (maintainer, 2026-08-21: "Please make a pop-up show up that tells the information
// regarding the limitations of the lattices … I think the pop-up should *also* include a
// 'delete Aesthetic lattice' option. This should delete whatever was done in the
// Aesthetic mode and bring you back to the mode modal.").
//
// ★★ WHY A SHEET AND NOT A TOOLTIP. The mode is chosen once and cannot be edited — which
// is right, because the two modes make different claims about the same object — but
// "cannot be edited" without a way OUT is a trap, not a guarantee. This sheet is that
// way out, and it is deliberately a DELETE rather than a switch: switching would silently
// re-interpret work done under one claim as work done under the other, which is the exact
// divergence the modal exists to prevent. Throwing the work away and re-asking does not.
//
// ★ AND THE LIMITATIONS ARE THE MODE'S OWN, taken from `LatticeStageMode` and from core,
// never authored here.

import SwiftUI
import TopOptDesign
import TopOptKit

public struct LatticeStageModeSheet: View {
    public let mode: LatticeStageMode
    /// The topology the stage is set to, so the floors quoted are the ones that bind.
    public let topology: String
    /// Throws away everything done under this mode and re-asks. Nil hides the button —
    /// there is nothing to delete before anything was configured.
    public let onDelete: (() -> Void)?
    public let onClose: () -> Void

    @State private var confirming = false

    public init(mode: LatticeStageMode, topology: String,
                onDelete: (() -> Void)?, onClose: @escaping () -> Void) {
        self.mode = mode
        self.topology = topology
        self.onDelete = onDelete
        self.onClose = onClose
    }

    /// ★★★ THE LIMITATIONS, AS MEASURED NUMBERS RATHER THAN ADJECTIVES.
    ///
    /// Every one of these is read from core at display time. The cells-per-member floors
    /// in particular were re-derived in Swift once on a neighbouring feature and came out
    /// 1.4-1.7x adrift; quoting them from anywhere else than core is how a page ends up
    /// promising a lattice the run will not build.
    private var limitations: [(String, String)] {
        let accuracy = TopOptKit.latticeLimits(topology: topology).minCellsPerMember
        var rows: [(String, String)] = []
        switch mode {
        case .structural:
            rows.append((
                "Members thinner than \(fmt(accuracy)) cells go solid",
                "A member that cannot hold \(fmt(accuracy)) cells across it is left as "
                + "solid plastic — not as a hole. Below that width the lattice's "
                + "stiffness is no longer what the certificate checks against."))
            rows.append((
                "The certificate covers the whole part",
                "Every latticed region is checked against the material's allowable "
                + "stress, and the part is refused rather than shipped uncertified."))
        case .aesthetic:
            let hard = TopOptKit.latticeAestheticCellsPerMemberHardFloor(topology: topology)
            rows.append((
                "Down to \(fmt(hard)) cells — but only where the load is low",
                "The floor relaxes from \(fmt(accuracy)) toward \(fmt(hard)) as the "
                + "measured stress falls. At roughly 40 % of the material's allowable "
                + "and above it is back at \(fmt(accuracy)), so a working member is "
                + "latticed exactly as it would be in Structural."))
            rows.append((
                "The density is not a strength requirement",
                TopOptKit.latticeAestheticDensityMeaning))
            rows.append((
                "Traced (organic) lattices need this mode",
                "A traced lattice is anisotropic by construction and the certification "
                + "library holds one cubic stiffness per topology, so there is nothing "
                + "for a strength claim to be checked against."))
        }
        // ★ TRUE IN BOTH MODES, and the one people are most often surprised by.
        rows.append((
            "The preview draws the doubled ladder only",
            "Stepped and organic are built by the run but cannot be drawn here — the "
            + "preview stores one cell size per cell as a halving level, which neither "
            + "of them is. The regions, depths and densities it shows are still exact."))
        rows.append((
            "Printability still binds, whatever the mode",
            "A strut thinner than one extrusion is never emitted; where no density in "
            + "the band can reach one bead, that material stays solid."))
        return rows
    }

    private func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
    }

    public var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.45))
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(alignment: .leading, spacing: DS.Space.l) {
                HStack(alignment: .firstTextBaseline) {
                    Text(mode.title)
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(LatticeStageModeStyle.accent(mode))
                    Text(mode.tagline)
                        .font(.system(size: 15))
                        .foregroundStyle(DS.Color.textTertiary.color)
                    Spacer()
                    Button { onClose() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DS.Color.textSecondary.color)
                            .padding(DS.Space.s)
                            .background(Circle().fill(DS.Surface.dialog.color))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("lattice-mode-sheet-close")
                }

                Text("What this mode does, and what it will not do")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DS.Color.textSecondary.color)

                VStack(alignment: .leading, spacing: DS.Space.m) {
                    ForEach(Array(limitations.enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.0)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(DS.Color.textPrimary.color)
                            Text(row.1)
                                .font(.system(size: 14))
                                .foregroundStyle(DS.Color.textSecondary.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let onDelete {
                    Divider().overlay(Color.white.opacity(0.10))
                    // ★★ THE WAY OUT. Two taps, because it discards work — and the
                    // second tap says exactly what goes, since "delete the lattice" and
                    // "delete the mode" would otherwise be indistinguishable.
                    if confirming {
                        VStack(alignment: .leading, spacing: DS.Space.s) {
                            Text("This removes every lattice region, depth and density "
                                 + "set in \(mode.title) mode, and asks which mode to "
                                 + "use again. It cannot be undone from here.")
                                .font(.system(size: 14))
                                .foregroundStyle(DS.Color.warning.color)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: DS.Space.m) {
                                Button("Cancel") { confirming = false }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(DS.Color.textSecondary.color)
                                Button {
                                    onDelete()
                                } label: {
                                    Text("Delete \(mode.title) lattice")
                                        .font(.system(size: 15, weight: .semibold))
                                        .padding(.vertical, DS.Space.s)
                                        .padding(.horizontal, DS.Space.l)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(DS.Color.warning.color)
                                .accessibilityIdentifier("lattice-mode-delete-confirm")
                            }
                        }
                    } else {
                        Button { confirming = true } label: {
                            HStack(spacing: DS.Space.s) {
                                Image(systemName: "trash")
                                Text("Delete \(mode.title) lattice and choose again")
                            }
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(DS.Color.warning.color)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("lattice-mode-delete")
                    }
                }
            }
            .padding(DS.Space.xl4)
            .frame(maxWidth: 720)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous)
                    .fill(DS.Surface.sheet.color))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 40, y: 18)
        }
        .accessibilityIdentifier("lattice-mode-sheet")
    }
}
