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
    /// Autosave the in-progress project when the app leaves the foreground, so
    /// edits survive relaunch even without navigating Home (M7.x-persist-b).
    @Environment(\.scenePhase) private var scenePhase

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        ZStack {
            switch model.screen {
            case .home:
                HomeView(model: model)
            case .workspace:
                if let project = model.project {
                    WorkspacePlaceholder(model: model, project: project)
                } else {
                    HomeView(model: model)   // no active project — shouldn't happen
                }
            }

            // Cold-launch re-attach (handoff 119): a non-blocking top banner offering
            // to reconnect to a remote run that outlived the app. Sits above the
            // screen but takes no scrim — the user can ignore it and keep working.
            if let job = model.pendingReattach {
                reattachBanner(job)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
            }

            if model.importSheetPresented {
                importOverlay
                    .transition(.opacity)
            }

            if model.printParamsSheetPresented, let project = model.project {
                printParamsOverlay(project)
                    .transition(.opacity)
            }
        }
        .toast($model.toast)
        .task { model.loadMaterials() }
        .onChange(of: scenePhase) { newPhase in
            if newPhase != .active { model.persistCurrentProject() }
        }
        // The design is a dark-glass system: pin the scheme so default-coloured text
        // stays light and `Material` backings render dark, regardless of the device's
        // light/dark setting (otherwise labels + glass go unreadable in light mode).
        .preferredColorScheme(.dark)
    }

    /// The cold-launch re-attach banner (handoff 119). Non-blocking, top-anchored,
    /// styled like the workspace's panel notices.
    private func reattachBanner(_ job: PersistedRemoteJob) -> some View {
        VStack {
            VStack(spacing: DS.Space.sm) {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(DS.Color.accent.color)
                    Text("Run still on your Mac").dsStyle(DS.TypeScale.headline)
                        .foregroundStyle(DS.Color.textPrimary.color)
                }
                Text(AppModel.reattachBannerText(for: job))
                    .dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Space.sm) {
                    Button { withAnimation(DS.Motion.sheetIn) { model.dismissReattach() } } label: {
                        Text("Dismiss").dsStyle(DS.TypeScale.bodyStrong)
                            .foregroundStyle(DS.Color.textSecondary.color)
                            .padding(.vertical, DS.Space.sm).padding(.horizontal, DS.Space.l)
                            .background(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    Button { withAnimation(DS.Motion.sheetIn) { model.reattach() } } label: {
                        Text("Re-attach").dsStyle(DS.TypeScale.bodyStrong)
                            .foregroundStyle(DS.Color.textPrimary.color)
                            .padding(.vertical, DS.Space.sm).padding(.horizontal, DS.Space.l)
                            .background(Capsule().fill(DS.Color.accent.opacity(0.22).color)
                                .overlay(Capsule().strokeBorder(DS.Color.accent.opacity(0.6).color, lineWidth: 1)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, DS.Space.xs)
            }
            .padding(.vertical, DS.Space.ml).padding(.horizontal, DS.Space.xl3)
            .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall).fill(DS.Surface.panel.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                    .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
            .dsShadow(DS.Shadow.panel)
            .frame(maxWidth: 460)
            .padding(.top, DS.Space.xl4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
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

    private func printParamsOverlay(_ project: ProjectModel) -> some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(DS.Color.scrim.color)
                .ignoresSafeArea()
                .onTapGesture { model.closePrintParams() }
            GlassSheet { PrintParamsSheet(model: model, project: project) }
                .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
        .animation(DS.Motion.sheetIn, value: model.printParamsSheetPresented)
    }
}

#Preview("RootView") {
    RootView(model: AppModel(materialsPath: nil))
}
