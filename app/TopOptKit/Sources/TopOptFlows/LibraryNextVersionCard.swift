// LibraryNextVersionCard.swift — "Optimize as vN" (approved Library mockup 2026-10-25, screen 6; his
// decision 3). Shown instead of today's re-run card once he has grouped: the name is filled in (the
// naming rule) and editable; what changed since the version he came from; one tap runs the draft. The
// version he came from is left as it ran.
//
// No destructive re-run in Library mode (reviewer ruling 2026-10-26 00:08): Optimize never overwrites.
// A stopped run goes back to draft and Optimize on a draft runs in place; to redo a finished version's
// run he makes "New draft from vN". Before he groups, today's RerunCard (with Re-run here) is unchanged.

import SwiftUI
import TopOptDesign

struct LibraryNextVersionCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var project: ProjectModel
    let close: () -> Void
    let optimize: (String?) -> Void
    @State private var name = ""
    @State private var edited = false

    var body: some View {
        let preview = model.nextVersionPreview()
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: DS.Space.ml) {
                Text("Optimize as v\(preview?.number.description ?? "")").dsStyle(DS.TypeScale.title)
                // his decision 11: the number it will get and where it comes from ("v4.1 · from v4")
                Text("v\(preview?.number.description ?? "") · from v\(preview?.from?.description ?? "") — v\(preview?.from?.description ?? "") stays as it is.")
                    .dsStyle(DS.TypeScale.callout).foregroundStyle(DS.Color.textSecondary.color)
                HStack(spacing: DS.Space.s) {
                    TextField("Name", text: Binding(get: { edited ? name : (preview?.name ?? "") },
                                                    set: { name = $0; edited = true }))
                        .textFieldStyle(.plain).font(DS.TypeScale.bodyStrong.font)
                        .accessibilityIdentifier("next-version-name")
                    if edited {
                        Button { edited = false; name = "" } label: {
                            Label("Automatic", systemImage: "sparkles").font(DS.TypeScale.caption.font.weight(.semibold))
                                .padding(.horizontal, DS.Space.sm).frame(height: 32)
                                .background(RoundedRectangle(cornerRadius: 10).fill(DS.Color.fillSubtle.color))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, DS.Space.ml).frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.3)))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DS.Color.accentDeepEdge.color, lineWidth: 1))
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    if let changes = preview?.changes, !changes.isEmpty {
                        ForEach(Array(changes.enumerated()), id: \.offset) { _, c in
                            Label(c.text, systemImage: c.kind == .added ? "plus.square.fill" : c.kind == .removed ? "minus.square.fill" : "arrow.right.square.fill")
                                .font(DS.TypeScale.callout.font)
                        }
                    } else {
                        Text("Same settings").dsStyle(DS.TypeScale.callout).foregroundStyle(DS.Color.textSecondary.color)
                    }
                }
                .padding(DS.Space.ml).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.3)))
                HStack(spacing: DS.Space.sm) {
                    Spacer()
                    Button("Cancel", action: close)
                        .buttonStyle(.plain).font(DS.TypeScale.bodyStrong.font)
                        .padding(.horizontal, DS.Space.l).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 14).fill(DS.Color.fillSubtle.color))
                    Button("Optimize v\(preview?.number.description ?? "")") { optimize(edited ? name : preview?.name) }
                        .buttonStyle(.plain).font(DS.TypeScale.bodyStrong.font).foregroundStyle(.white)
                        .padding(.horizontal, DS.Space.xl).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 14).fill(DS.Color.okGreen.color))
                        .dsShadow(DS.Shadow(color: DS.Color.okGreen.opacity(0.4), radius: 24, y: 6))
                        .accessibilityIdentifier("next-version-optimize")
                }
            }
            .padding(DS.Space.xl2)
            .frame(width: 600)
            .background(RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous).fill(DS.Surface.sheet.color))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous).strokeBorder(DS.Color.strokeSheet.color, lineWidth: 1))
        }
        .accessibilityIdentifier("library-next-version-card")
    }
}
