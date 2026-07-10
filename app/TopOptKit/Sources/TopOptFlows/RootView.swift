// RootView.swift — the M7.3 flow shell.
//
// Hosts the screen switch (Home ⇄ Workspace), presents the import sheet over the
// design's dimmed+blurred scrim, and shows the AppModel's toast. This is the one
// view the app target embeds (see /app/TopOpt/ContentView.swift); everything else
// hangs off the injected AppModel. Materials load on first appearance.

import SwiftUI
import TopOptDesign

public struct RootView: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        ZStack {
            switch model.screen {
            case .home:
                HomeView(model: model)
            case .workspace:
                WorkspacePlaceholder(model: model)
            }

            if model.importSheetPresented {
                importOverlay
                    .transition(.opacity)
            }
        }
        .toast($model.toast)
        .task { model.loadMaterials() }
        // The design is a dark-glass system: pin the scheme so default-coloured text
        // stays light and `Material` backings render dark, regardless of the device's
        // light/dark setting (otherwise labels + glass go unreadable in light mode).
        .preferredColorScheme(.dark)
    }

    private var importOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(DS.Color.scrim.color)
                .ignoresSafeArea()
                .onTapGesture { model.cancelImport() }
            GlassSheet { ImportSheet(model: model) }
                .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
        .animation(DS.Motion.sheetIn, value: model.importSheetPresented)
    }
}

#Preview("RootView") {
    RootView(model: AppModel(materialsPath: nil))
}
