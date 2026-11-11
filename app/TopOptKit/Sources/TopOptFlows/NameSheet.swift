// NameSheet — design-system §4.11 (Sheets: "Used for: … the Library's name and rename sheets"): a name is asked for in a
// Sheet, never in a system alert (U6 / U7, OneWayToSayNoTests). B10 (the uniformity sweep): the workspace's Rename project.
//
// The §4.11 sheet: the GlassSheet card (radius 28, the sheet surface) over the scrim, its title at 20/700, one name field
// (the selected state: an accent edge), Cancel on the left and the one primary bottom-right (LibraryChosenExport's layout).
// A tap on the scrim is Cancel. Frames: "nameSheet", "nameSheetField", "nameSheetCancel", "nameSheetPrimary", and "sheet"
// (the notification lane keeps clear of it, U17).

import SwiftUI
import TopOptDesign

/// The sheet's card: a title, an optional line under it, the name, Cancel │ the primary.
struct NameSheet: View {
    let title: String
    var subtitle: String? = nil
    var placeholder: String = "Name"
    @Binding var name: String
    let primary: String
    /// An empty name is a choice (a version's "Automatic" name); otherwise the primary waits for one.
    var allowsEmpty = false
    let cancel: () -> Void
    let done: () -> Void
    @FocusState private var focused: Bool

    static let width: CGFloat = 460

    var canSave: Bool { allowsEmpty || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).dsStyle(DS.TypeScale.title)
            if let subtitle {
                Text(subtitle).dsStyle(DS.TypeScale.subhead).foregroundStyle(DS.Color.textTertiary.color).padding(.top, 3)
            }
            TextField(placeholder, text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary.color)
                .focused($focused)
                .onSubmit { if canSave { done() } }
                .padding(.horizontal, DS.Space.ml)
                .frame(height: 48)
                .background(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).fill(DS.Color.fillSubtle.color)
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
                        .strokeBorder(DS.Color.accent.color, lineWidth: 1.5)))
                .background(DSParts.publish("nameSheetField"))
                .padding(.top, DS.Space.xl2)
            HStack(spacing: DS.Space.m) {   // §4.11: Cancel on the left, the one primary bottom-right
                PillButton("Cancel", style: .secondary) { cancel() }
                    .background(DSParts.publish("nameSheetCancel"))
                Spacer()
                PillButton(primary, style: .primary, isEnabled: canSave) { if canSave { done() } }
                    .background(DSParts.publish("nameSheetPrimary"))
            }
            .padding(.top, DS.Space.xl5)
        }
        .padding(DS.Space.xl6)
        .frame(width: Self.width, alignment: .leading)
        .onAppear { focused = true }
    }
}

/// The name sheet over the page: the scrim (a tap on it is Cancel) and the card, centred.
struct NameSheetLayer: View {
    let title: String
    var subtitle: String? = nil
    var placeholder: String = "Name"
    @Binding var name: String
    let primary: String
    var allowsEmpty = false
    let cancel: () -> Void
    let done: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).overlay(DS.Color.scrim.color).ignoresSafeArea()
                .onTapGesture { cancel() }
            GlassSheet {
                NameSheet(title: title, subtitle: subtitle, placeholder: placeholder, name: $name, primary: primary,
                          allowsEmpty: allowsEmpty, cancel: cancel, done: done)
            }
            .background(DSParts.publish("nameSheet"))
            .background(CornerPairStyle.publish("sheet"))   // (U17: the lane keeps its notifications off the sheet)
            .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
    }
}
