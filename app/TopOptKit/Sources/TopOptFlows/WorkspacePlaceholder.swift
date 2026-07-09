// WorkspacePlaceholder.swift — the workspace stage (M7.4 Metal viewer v1).
//
// M7.3 landed here as an empty stand-in; M7.4 fills the stage with the Metal
// viewer: the imported tessellated mesh under matcap-style shading on the design's
// dark stage, with an orbit + pinch-zoom camera and the design's tool-hint copy.
// Selection, the tools palette, force arrows and Optimize are M7.5–M7.7 and are
// deliberately absent here (the top-left back + project/material chip chrome and
// the bottom hint are all that the viewer step needs).
//
// The type keeps its M7.3 name/`init(model:)` because RootView and the existing
// TopOptFlowsTests.testScreensInstantiate construct `WorkspacePlaceholder(model:)`.

import SwiftUI
import TopOptKit
import TopOptDesign

public struct WorkspacePlaceholder: View {
    @ObservedObject var model: AppModel
    /// The render-ready mesh, built once from the retained import (normals + bounds
    /// are derived off `importedMesh`); nil until/unless a part is present.
    @State private var viewerMesh: ViewerMesh?

    public init(model: AppModel) { self.model = model }

    /// Identity that changes when a different part is imported, so the viewer mesh
    /// is rebuilt only then (not on every SwiftUI update).
    private var meshID: String {
        guard let m = model.importedMesh else { return "none" }
        return "\(m.vertexCount)-\(m.triangleCount)"
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            // Dark stage: the Metal viewer full-bleed, dark background behind it in
            // case Metal is unavailable.
            DS.Color.background.color.ignoresSafeArea()
            MetalMeshView(mesh: viewerMesh)
                .ignoresSafeArea()

            chrome
            hint
        }
        .task(id: meshID) { rebuildMesh() }
    }

    private func rebuildMesh() {
        guard let m = model.importedMesh else { viewerMesh = nil; return }
        viewerMesh = ViewerMesh(vertices: m.vertices, indices: m.indices, faceIDs: m.faceIDs)
    }

    // top-left: back + project / material chip (design workspace chrome)
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

    // bottom-center: the orbit tool-hint pill (design toolHints.orbit)
    private var hint: some View {
        Text("Drag to orbit · pinch or scroll to zoom")
            .dsStyle(DS.TypeScale.caption)
            .foregroundStyle(DS.Color.textPrimary.opacity(0.55).color)
            .padding(.vertical, 6).padding(.horizontal, DS.Space.m)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(DS.Color.textPrimary.opacity(0.07).color, lineWidth: 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, DS.Space.xl3)
    }
}

#Preview("Workspace — empty stage") {
    let m = AppModel(materialsPath: nil)
    m.open(RecentProject(name: "Wall Bracket v4", materialName: "PLA", process: .fdm))
    return WorkspacePlaceholder(model: m)
}
