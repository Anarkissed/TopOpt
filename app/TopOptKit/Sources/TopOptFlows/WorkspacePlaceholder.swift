// WorkspacePlaceholder.swift — the M7.3 Continue destination.
//
// M7.3 ends at "Continue → workspace"; the real workspace (Metal viewer, face
// selection, force arrows, Optimize) is M7.4–M7.7. This is a deliberately minimal
// stand-in so the navigation is exercisable end to end now: it shows the project
// name + material chip in the design's top-left pill and a Back control returning
// Home. It is expected to be replaced wholesale by the M7.4 viewer.

import SwiftUI
import TopOptDesign

public struct WorkspacePlaceholder: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            DS.Color.background.color.ignoresSafeArea()

            VStack(spacing: DS.Space.m) {
                Text("Workspace")
                    .dsStyle(DS.TypeScale.title)
                Text("Viewer, face selection and forces arrive in M7.4–M7.7.")
                    .dsStyle(DS.TypeScale.subhead)
                    .foregroundStyle(DS.Color.textTertiary.color)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(DS.Color.textPrimary.color)

            // top-left: back + project / material chip (design workspace chrome)
            HStack(spacing: DS.Space.m) {
                Button { model.backHome() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.Color.textPrimary.color)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(DS.Surface.bar.color)
                            .overlay(Circle().strokeBorder(DS.Color.textPrimary.opacity(0.12).color, lineWidth: 1)))
                }
                .buttonStyle(.plain)

                HStack(spacing: DS.Space.sm) {
                    Text(model.projectName).dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
                    Rectangle().fill(DS.Color.textPrimary.opacity(0.15).color).frame(width: 1, height: 14)
                    Text(model.selectedMaterial ?? "")
                        .dsStyle(DS.TypeScale.caption)
                        .foregroundStyle(DS.Color.textPrimary.opacity(0.5).color)
                }
                .padding(.vertical, 9).padding(.horizontal, DS.Space.l)
                .background(Capsule().fill(DS.Surface.bar.color)
                    .overlay(Capsule().strokeBorder(DS.Color.textPrimary.opacity(0.12).color, lineWidth: 1)))
                .foregroundStyle(DS.Color.textPrimary.color)
            }
            .padding(.top, DS.Space.xl3)
            .padding(.leading, DS.Space.xl4)
        }
    }
}

#Preview("WorkspacePlaceholder") {
    let m = AppModel(materialsPath: nil)
    m.open(RecentProject(name: "Wall Bracket v4", materialName: "PLA", process: .fdm))
    return WorkspacePlaceholder(model: m)
}
