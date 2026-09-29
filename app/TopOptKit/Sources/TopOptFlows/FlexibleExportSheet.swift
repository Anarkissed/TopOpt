// FlexibleExportSheet — the Export modal (task 2026-09-29-flexible-screens; maintainer: "an
// 'export' button that will pull up a modal to either export gcode or an stl").
//
// ★ BOTH CARDS ARE DISABLED UNTIL CORE HAS THE FLEXIBLE LATTICE (maintainer, 2026-09-29:
// "The exports aren't supposed to happen until core gets to it. So we don't need to worry
// about exports or sizes"). The app's own STL exporter was removed with this round (it is
// recoverable at 85b1bdc0); the modal keeps its place so the flow reads the same when core
// lands, and says in plain words why nothing can be exported yet. Disabled look: the
// G-code button's existing fillDisabled / textDisabled tokens.

import SwiftUI
import TopOptDesign

public struct FlexibleExportSheet: View {
    /// What every card says while the exports wait on core.
    public static let notReady = "Not ready yet — comes from core\u{2019}s Flexible lattice"

    let summary: String
    let onClose: () -> Void

    public init(summary: String, onClose: @escaping () -> Void) {
        self.summary = summary
        self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).overlay(Color.black.opacity(0.45)).ignoresSafeArea()
                .onTapGesture { onClose() }
            VStack(alignment: .leading, spacing: DS.Space.l) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Export").font(.system(size: 27, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                    Text(summary).font(.system(size: 15)).foregroundStyle(DS.Color.textTertiary.color).lineLimit(1)
                    Spacer()
                    Button { onClose() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DS.Color.textSecondary.color).padding(DS.Space.s)
                            .background(Circle().fill(DS.Surface.dialog.color))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("flexible-export-close")
                }
                HStack(alignment: .top, spacing: DS.Space.m) {
                    card("STL", "The part with its lattice, one closed solid", button: "Export STL",
                         id: "flexible-export-stl-disabled")
                    card("G-code", "The print file for your printer", button: "Export G-code",
                         id: "flexible-export-gcode-disabled")
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Space.xl4)
            .frame(maxWidth: 820)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous).fill(DS.Surface.sheet.color))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 40, y: 18)
        }
        .accessibilityIdentifier("flexible-export-sheet")
    }

    private func card(_ title: String, _ tagline: String, button: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.xs) {
                Circle().fill(DS.Color.textTertiary.color).frame(width: 10, height: 10)
                Text(title).font(.system(size: 21, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
            }
            Text(tagline).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Color.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.notReady)
                .font(.system(size: 14)).foregroundStyle(DS.Color.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Space.m)
            Text(button)
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.Color.textDisabled.color)
                .frame(maxWidth: .infinity).padding(.vertical, DS.Space.s + 6)
                .background(Capsule().fill(DS.Color.fillDisabled.color))
                .accessibilityIdentifier(id)
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Surface.dialog.color))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .stroke(DS.Color.textTertiary.color.opacity(0.35), lineWidth: 1))
    }
}
