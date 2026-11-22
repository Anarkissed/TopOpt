// EditFacesOrphanCard.swift — ★ his iPad 11-16 (the "T"): "I tried undoing the cut … And then when I selected the horizontal
// top line of the "T" the only thing that it selects is the unioned faces of the vertical line now."
//
// He had cut a thin face in two and joined one half into a union. Taking the cut back (the Region tool's dissolve of the cut
// face, or Undo split) dropped the face and its loose half but not the half the union held, so that half stayed, still cut,
// its other half covered by nothing, and a tap there picked it (and so the union). Both are fixed (FaceRegionModel.dissolve /
// revertSplit `includingLent`; SurfaceTint.regionAt); a project saved in between still holds such a piece. Edit faces says so
// in one line beside its rail, with one tap that makes the face whole again (one undo step).
import SwiftUI
import TopOptDesign

extension EditFacesCopy {
    /// The line when a cut piece's other half is gone (never a face number: the face is the one he cut). ★ his 11-22 ("What
    /// does this pop-up even mean? ... word that better and maybe highlight the faces"): the piece is lit on the part (the
    /// first, when there are several) and the line says what happened, what it does and what the button does.
    public static func orphanLine(_ n: Int) -> String {
        (n > 1 ? "The lit piece and \(n - 1) more were" : "The lit piece was")
            + " cut from a face whose other half is gone, so tapping there picks the wrong piece. Make it whole joins it back."
    }
    /// Its one tap.
    public static let orphanFix = "Make it whole"
}

struct EditFacesOrphanCard: View {
    static let width: CGFloat = 300
    var count = 1
    let repair: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Text(EditFacesCopy.orphanLine(count))
                .font(.system(size: 12))
                .foregroundStyle(DS.Color.textPrimary.color)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: repair) {
                Text(EditFacesCopy.orphanFix).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, DS.Space.m).frame(height: 32)
                    .background(Capsule().fill(DS.Color.accent.opacity(0.28).color))
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .background(DSParts.publish("cutOrphanRepairButton"))
        }
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.xs)
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Surface.bar.color.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1))
        .background(DSParts.publish("cutOrphanRepair"))
    }
}
