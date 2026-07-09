// WorkspacePlaceholder.swift — the workspace stage (M7.4 viewer + M7.5 selection).
//
// M7.4 filled the stage with the Metal viewer; M7.5 adds face selection: the
// left Selections panel (design), the bottom Orbit/Faces/Force tool segment, and
// tap-to-select wiring. Tapping the model in Faces mode resolves the tapped B-rep
// face (id-buffer pass, CPU-pick fallback) and toggles its whole face loop into the
// active group. Force arrows + weights are M7.6 (the Force tool is present but
// inert here); Optimize is M7.7.
//
// The type keeps its M7.3 name/`init(model:)` because RootView and the existing
// TopOptFlowsTests.testScreensInstantiate construct `WorkspacePlaceholder(model:)`.
// The selection logic it drives (SelectionModel / FaceTopology / FacePicker) is
// unit-tested headlessly; this SwiftUI shell is maintainer device QA.

import SwiftUI
import TopOptKit
import TopOptDesign

public struct WorkspacePlaceholder: View {
    @ObservedObject var model: AppModel
    /// The render-ready mesh, built once from the retained import; nil until a part
    /// is present.
    @State private var viewerMesh: ViewerMesh?
    /// The face-selection groups (design `groups` + `activeGroupId`).
    @State private var selection = SelectionModel()
    /// The active interaction tool (design bottom-centre segment).
    @State private var tool: WorkspaceTool = .orbit

    public init(model: AppModel) { self.model = model }

    /// Identity that changes when a different part is imported, so the viewer mesh
    /// is rebuilt only then (not on every SwiftUI update).
    private var meshID: String {
        guard let m = model.importedMesh else { return "none" }
        return "\(m.vertexCount)-\(m.triangleCount)"
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            DS.Color.background.color.ignoresSafeArea()
            MetalMeshView(mesh: viewerMesh,
                          selection: selection,
                          faceToolActive: tool == .face,
                          onPickFace: handlePick)
                .ignoresSafeArea()

            chrome
            if viewerMesh != nil { selectionsPanel }
            toolbar
        }
        .task(id: meshID) { rebuildMesh() }
    }

    private func rebuildMesh() {
        guard let m = model.importedMesh else { viewerMesh = nil; return }
        viewerMesh = ViewerMesh(vertices: m.vertices, indices: m.indices, faceIDs: m.faceIDs)
        selection = SelectionModel()   // a fresh part starts with no groups
    }

    /// Tapped-face callback from the viewer: toggle the tapped face's whole loop
    /// (the hole, or just the face) into the active group.
    private func handlePick(_ faceID: FaceID) {
        guard let mesh = viewerMesh else { return }
        selection.pickFaces(FaceTopology.loop(fromFace: faceID, in: mesh))
    }

    // MARK: top-left chrome (back + project / material chip)

    private var chrome: some View {
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

    // MARK: left Selections panel (design)

    private var selectionsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Color.textPrimary.opacity(0.7).color)
                    Text("Selections").dsStyle(DS.TypeScale.bodyStrong).fontWeight(.bold)
                }
                Spacer()
                Button { selection.addGroup(); tool = .face } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DS.Color.textPrimary.color)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(DS.Color.fillSubtle.color)
                            .overlay(Circle().strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DS.Space.l).padding(.top, DS.Space.ml).padding(.bottom, DS.Space.m)

            Divider().overlay(DS.Color.strokeSubtle.color)

            if selection.isEmpty {
                Text("Choose **Faces** below, then tap the model to select anchor or load faces. Groups appear here.")
                    .dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textQuaternary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(DS.Space.xl)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(selection.groups) { g in groupRow(g) }
                    }
                }
            }
        }
        .frame(width: 308, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel).fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
        .padding(.top, 82)
        .padding(.leading, DS.Space.xl4)
        .frame(maxHeight: 520, alignment: .top)
    }

    private func groupRow(_ g: SelectionGroup) -> some View {
        let active = g.id == selection.activeGroupID
        return HStack(alignment: .top, spacing: DS.Space.s) {
            RoundedRectangle(cornerRadius: 4).fill(g.color.color)
                .frame(width: 11, height: 11)
                .shadow(color: g.color.opacity(0.4).color, radius: 4)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                TextField("Group", text: binding(for: g))
                    .textFieldStyle(.plain)
                    .font(.system(size: DS.TypeScale.callout.size, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                Text(g.faceLabel)
                    .dsStyle(DS.TypeScale.footnote)
                    .foregroundStyle(DS.Color.textQuaternary.color)
            }
            Spacer(minLength: 0)
            Button { selection.remove(g.id) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.opacity(0.4).color)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 11).padding(.leading, DS.Space.l).padding(.trailing, DS.Space.m)
        .background(active ? DS.Color.fillSubtle.color : .clear)
        .overlay(alignment: .leading) {
            Rectangle().fill(active ? g.color.color : .clear).frame(width: 3)
        }
        .contentShape(Rectangle())
        .onTapGesture { selection.setActive(g.id) }
        .overlay(alignment: .bottom) { Divider().overlay(DS.Color.strokeSubtle.color) }
    }

    private func binding(for g: SelectionGroup) -> Binding<String> {
        Binding(get: { selection.groups.first { $0.id == g.id }?.name ?? g.name },
                set: { selection.rename(g.id, to: $0) })
    }

    // MARK: bottom-centre tool segment + hint (design)

    private var toolbar: some View {
        VStack(spacing: DS.Space.sm) {
            Text(tool.hint)
                .dsStyle(DS.TypeScale.caption)
                .foregroundStyle(DS.Color.textPrimary.opacity(0.55).color)
                .padding(.vertical, 6).padding(.horizontal, DS.Space.m)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(DS.Color.textPrimary.opacity(0.07).color, lineWidth: 1))

            HStack(spacing: DS.Space.xxs) {
                ForEach(WorkspaceTool.allCases, id: \.self) { t in
                    Button { tool = t } label: {
                        Text(t.title)
                            .dsStyle(DS.TypeScale.callout).fontWeight(.semibold)
                            .foregroundStyle((t == tool ? DS.Color.textPrimary : DS.Color.textSecondary).color)
                            .padding(.vertical, 11).padding(.horizontal, DS.Space.xl2)
                            .background(Capsule().fill(t == tool ? DS.Color.fillSelected.color : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(5)
            .background(Capsule().fill(DS.Surface.panel.color)
                .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
            .dsShadow(DS.Shadow.panel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, DS.Space.xl5)
    }
}

#Preview("Workspace — empty stage") {
    let m = AppModel(materialsPath: nil)
    m.open(RecentProject(name: "Wall Bracket v4", materialName: "PLA", process: .fdm))
    return WorkspacePlaceholder(model: m)
}
