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

            // Cold-launch re-attach (handoffs 119 + 121): a non-blocking top banner
            // offering to reconnect to remote runs that outlived the app. One card for
            // a single outstanding run; a LIST when more than one (a queued sibling, or
            // two projects' runs). Takes no scrim — the user can ignore it and work.
            if !model.pendingReattachJobs.isEmpty {
                Group {
                    if model.pendingReattachJobs.count == 1 {
                        reattachBanner(model.pendingReattachJobs[0])
                    } else {
                        reattachList(model.pendingReattachJobs)
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(1)
            }

            if model.importSheetPresented {
                importOverlay
                    .transition(.opacity)
            }

            // Handoff 134 — the two mesh-import sheets, stacked ABOVE the import
            // sheet so the file row stays visible behind them. Refusal wins when
            // both could somehow be set; a refused file has no unit question.
            if let refusal = model.importRefusal {
                sheetOverlay(onScrimTap: { model.dismissRefusal() }) {
                    ImportRefusalSheet(model: model, refusal: refusal)
                }
                .transition(.opacity)
                .zIndex(2)
            } else if let prompt = model.pendingUnitPrompt {
                sheetOverlay(onScrimTap: { model.cancelUnitPrompt() }) {
                    ImportUnitSheet(model: model, prompt: prompt)
                }
                .transition(.opacity)
                .zIndex(2)
            }

            if model.printParamsSheetPresented, let project = model.project {
                printParamsOverlay(project)
                    .transition(.opacity)
            }
        }
        .toast($model.toast)
        .task {
            model.loadMaterials()
            // Ask for notification permission at app runtime (not in AppModel.init,
            // which headless tests exercise) so a remote run finishing in the
            // foreground — or landing via re-attach — can post a local completion
            // banner (handoff 121, requirement 5).
            LocalRunNotifier.requestAuthorization()
        }
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
                    Button { withAnimation(DS.Motion.sheetIn) { model.dismissReattach(job) } } label: {
                        Text("Dismiss").dsStyle(DS.TypeScale.bodyStrong)
                            .foregroundStyle(DS.Color.textSecondary.color)
                            .padding(.vertical, DS.Space.sm).padding(.horizontal, DS.Space.l)
                            .background(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    Button { withAnimation(DS.Motion.sheetIn) { model.reattach(job) } } label: {
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

    /// The re-attach LIST (handoff 121): shown when more than one remote run was
    /// outstanding at launch. One compact row per job — Re-attach, Move-to-front (a
    /// quick job shouldn't wait behind an 8-hour Fine run), and Dismiss — plus a
    /// "Dismiss all" footer.
    private func reattachList(_ jobs: [PersistedRemoteJob]) -> some View {
        VStack {
            VStack(spacing: DS.Space.sm) {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(DS.Color.accent.color)
                    Text("\(jobs.count) runs still on your Mac").dsStyle(DS.TypeScale.headline)
                        .foregroundStyle(DS.Color.textPrimary.color)
                }
                Text("These runs were in flight when the app last closed. Re-attach to "
                   + "follow one and get its result, or move a quick job ahead of a long one.")
                    .dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(jobs, id: \.jobID) { job in
                    reattachRow(job)
                }

                Button { withAnimation(DS.Motion.sheetIn) { model.dismissAllReattach() } } label: {
                    Text("Dismiss all").dsStyle(DS.TypeScale.caption)
                        .foregroundStyle(DS.Color.textSecondary.color)
                        .padding(.top, DS.Space.xxs)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, DS.Space.ml).padding(.horizontal, DS.Space.xl)
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

    /// One row in the re-attach list: the project + its age, and the three actions.
    private func reattachRow(_ job: PersistedRemoteJob) -> some View {
        HStack(spacing: DS.Space.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(job.projectName ?? "Remote run").dsStyle(DS.TypeScale.bodyStrong)
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .lineLimit(1)
                Text(rowSubtitle(job)).dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Space.sm)
            Button { model.moveReattachJobToFront(job) } label: {
                Image(systemName: "arrow.up.to.line")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .padding(DS.Space.xs)
            }
            .buttonStyle(.plain)
            .help("Move to front of the Mac's queue")
            Button { withAnimation(DS.Motion.sheetIn) { model.dismissReattach(job) } } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .padding(DS.Space.xs)
            }
            .buttonStyle(.plain)
            Button { withAnimation(DS.Motion.sheetIn) { model.reattach(job) } } label: {
                Text("Re-attach").dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .padding(.vertical, DS.Space.xs).padding(.horizontal, DS.Space.m)
                    .background(Capsule().fill(DS.Color.accent.opacity(0.22).color)
                        .overlay(Capsule().strokeBorder(DS.Color.accent.opacity(0.6).color, lineWidth: 1)))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, DS.Space.xs).padding(.horizontal, DS.Space.sm)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
            .fill(DS.Color.strokePanel.opacity(0.10).color))
    }

    private func rowSubtitle(_ job: PersistedRemoteJob) -> String {
        let age = job.submittedAt.map { AppModel.relativeAge(Date().timeIntervalSince($0)) }
        return [age, job.host].compactMap { $0 }.joined(separator: " · ")
    }

    /// The shared scrim + glass-card presentation the import sheets use
    /// (handoff 134 factored it out so the unit and refusal sheets present
    /// identically to the import sheet rather than approximating it).
    private func sheetOverlay<Content: View>(onScrimTap: @escaping () -> Void,
                                             @ViewBuilder content: () -> Content) -> some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(DS.Color.scrim.color)
                .ignoresSafeArea()
                .onTapGesture(perform: onScrimTap)
            GlassSheet { content() }
                .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
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
