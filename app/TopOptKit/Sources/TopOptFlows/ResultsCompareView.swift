// ResultsCompareView — ★ Compare on Results (his mockup, approved 2026-10-27, screens 3–5).
//
// Full screen, the app's grid and floating glass. Two versions side by side — or, with three or more, a switch at the
// bottom right (two columns: one pair at a time · three columns: all at once). Every panel turns with the others (one
// shared camera). "Use this" follows ResultsCompareSession; Details rises as a sheet over the bottom of the SAME screen.

import SwiftUI
import TopOptDesign
import TopOptKit

struct ResultsCompareView: View {
    @ObservedObject var model: ResultsModel
    let rows: [ResultsVersionRow]
    @Binding var session: ResultsCompareSession?
    @Binding var scenarioPick: String?
    let close: () -> Void
    /// Results opens on this tab (a pick that ends Compare).
    let use: (Int) -> Void

    @StateObject private var camera = OrbitCameraModel()
    @State private var mode: ResultsViewMode = .solid
    @State private var detailsOpen = false
    @State private var detailsTab: ResultsDetailsTab = .strength
    static let sheetHeight: CGFloat = 400

    var body: some View {
        ZStack(alignment: .top) {
            DS.Color.background.color.ignoresSafeArea()
            if let s = session {
                VStack(spacing: DS.Space.m) {
                    topBar
                    HStack(spacing: DS.Space.m) {
                        ForEach(Array(s.shown.enumerated()), id: \.offset) { slot, tab in panel(tab, slot: slot, s) }
                    }
                    .frame(maxHeight: .infinity)
                    // the versions shrink above Details when it rises (his screen 4) — their "Use this" stays reachable
                    Color.clear.frame(height: detailsOpen ? Self.sheetHeight : 52)
                }
                .padding(.horizontal, PageChrome.edge).padding(.top, PageChrome.edge).padding(.bottom, PageChrome.edge)
                if detailsOpen { detailsSheet(s).transition(.move(edge: .bottom)) }
                VStack {
                    Spacer()
                    ZStack {
                        if !detailsOpen { detailsButton }
                        if s.offersLayouts { HStack { Spacer(); layoutSwitch(s) } }
                    }
                }
                .padding(PageChrome.edge)
            }
        }
        .background(ResultsChrome.publish("compareScreen"))
        .animation(DS.Motion.sheetIn, value: detailsOpen)
    }

    private var topBar: some View {
        HStack(spacing: DS.Space.m) {
            Button(action: close) {
                Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color).frame(width: 44, height: 44)
                    .background(Circle().fill(ResultsChrome.fill.color).overlay(Circle().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
            }
            .buttonStyle(.plain).accessibilityLabel("Back to Results").accessibilityIdentifier("compare-back")
            HStack(spacing: DS.Space.m) {
                Text("Compare versions").dsStyle(DS.TypeScale.bodyStrong).foregroundStyle(DS.Color.textPrimary.color)
                if let s = session, s.offersLayouts {
                    Text(s.layout == .pair ? "pick one of each pair" : "all at once")
                        .font(.system(size: 14)).foregroundStyle(DS.Color.textSecondary.color)
                }
            }
            .padding(.horizontal, DS.Space.l).frame(height: 44)
            .background(Capsule().fill(ResultsChrome.fill.color).overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
            Spacer()
            let sc = model.scenarios(for: model.selected)
            if sc.count >= 2 { ResultsScenarioPicker(scenarios: sc, pick: $scenarioPick) }
            ResultsViewModePicker(modes: model.hasStress ? [.stress, .solid, .xray] : [.solid, .xray], mode: $mode)   // icons
        }
    }

    private func row(_ tab: Int) -> ResultsVersionRow? { rows.first { $0.tabIndex == tab } }
    private func tabVM(_ tab: Int) -> ResultVariantVM? { model.tabs.first { $0.index == tab } }

    @ViewBuilder private func panel(_ tab: Int, slot: Int, _ s: ResultsCompareSession) -> some View {
        let r = row(tab)
        let vm = tabVM(tab)
        ZStack(alignment: .top) {
            if let vm, let mesh = model.compareMesh(vm) {
                MetalMeshView(mesh: mesh, camera: camera,
                              stressTints: mode == .stress ? model.compareStressTints(vm) : nil,
                              bodyAlpha: mode == .xray ? 0.3 : 1)
            } else {
                Text("This version’s shape isn’t on this device").font(.system(size: 14))
                    .foregroundStyle(DS.Color.textTertiary.color).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(spacing: 0) {
                HStack {
                    Menu {
                        ForEach(rows.filter { $0.tabIndex != nil }) { o in
                            Button(o.title) { if let t = o.tabIndex { session?.show(t, in: slot) } }
                        }
                    } label: {
                        HStack(spacing: DS.Space.s) {
                            Text(r?.title ?? "Version").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(DS.Color.textPrimary.color).padding(.horizontal, DS.Space.l).frame(height: 40)
                        .background(Capsule().fill(ResultsChrome.fill.color).overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    Spacer()
                    if r?.recommended == true {
                        Text("RECOMMENDED").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(DS.Color.accent.color)
                    }
                }
                .padding(DS.Space.m)
                Spacer()
                strip(r, tab: tab)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(r?.recommended == true ? DS.Color.accent.color : DS.Color.strokePanel.color,
                                                                lineWidth: r?.recommended == true ? 2 : 1))
        .background(ResultsChrome.publish("comparePanel-\(slot)"))
    }

    private func strip(_ r: ResultsVersionRow?, tab: Int) -> some View {
        HStack(spacing: DS.Space.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r?.massLabel ?? "—").font(.system(size: 21, weight: .bold)).foregroundStyle(DS.Color.textPrimary.color)
                Text(r?.headline ?? "").font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color)
            }
            Rectangle().fill(DS.Color.strokePanel.color).frame(width: 1, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(r?.margin.map { ResultsVersions.x($0) } ?? "—").font(.system(size: 21, weight: .bold))
                        .foregroundStyle(DS.Color.textPrimary.color)
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Color.okGreen.color)
                }
                Text(worst(tab)).font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color).lineLimit(1)
                // ★ his ruling 2026-10-28: a version in pieces carries its flag here too
                if let p = tabVM(tab).flatMap({ model.piecesFlag($0) }) {
                    Text(p.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.warning.color).lineLimit(1)
                        .accessibilityIdentifier("compare-pieces-\(tab)")
                }
            }
            Spacer(minLength: DS.Space.s)
            Button { useTapped(tab) } label: {
                Text("Use this").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                    .padding(.horizontal, DS.Space.l).frame(height: 44)
                    .background(Capsule().fill(DS.Color.fillSubtle.color).overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
            }
            .buttonStyle(.plain)
            .background(ResultsChrome.publish("compareUse-\(tab)"))
            .accessibilityIdentifier("compare-use-\(tab)")
        }
        .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
        .background(RoundedRectangle(cornerRadius: 16).fill(ResultsChrome.fill.color)
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .padding(DS.Space.m)
    }

    private func worst(_ tab: Int) -> String {
        let sc = model.scenarios(for: tabVM(tab))
        guard sc.count >= 2, let g = sc.first(where: \.governs) else { return "your load" }
        return "worst: " + g.name
    }

    private func useTapped(_ tab: Int) {
        session?.use(tab)
        if let c = session?.chosen { use(c) }
    }

    private var detailsButton: some View {
        Button { detailsOpen = true } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "chevron.up").font(.system(size: 12, weight: .bold))
                Text("Details").dsStyle(DS.TypeScale.bodyStrong)
            }
            .foregroundStyle(DS.Color.textPrimary.color).padding(.horizontal, DS.Space.xl).frame(height: 48)
            .background(Capsule().fill(ResultsChrome.fill.color).overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .background(ResultsChrome.publish("compareDetailsButton"))
        .accessibilityIdentifier("compare-details")
    }

    private func layoutSwitch(_ s: ResultsCompareSession) -> some View {
        HStack(spacing: DS.Space.xxs) {
            layoutButton(.pair, columns: 2, label: "Compare two at a time", s)
            layoutButton(.all, columns: 3, label: "Compare all at once", s)
        }
        .padding(DS.Space.xxs)
        .background(Capsule().fill(ResultsChrome.fill.color).overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .background(ResultsChrome.publish("compareLayout"))
    }

    private func layoutButton(_ l: ResultsCompareSession.Layout, columns: Int, label: String, _ s: ResultsCompareSession) -> some View {
        let on = s.layout == l
        return Button { session?.setLayout(l) } label: {
            HStack(spacing: 2.5) {
                ForEach(0..<columns, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2).strokeBorder(lineWidth: 1.6).frame(width: columns == 2 ? 10 : 7, height: 17)
                }
            }
            .foregroundStyle((on ? DS.Color.textPrimary : DS.Color.textTertiary).color)
            .frame(width: 52, height: 44)
            .background(Capsule().fill(on ? DS.Color.fillSubtle.color : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
        .background(ResultsChrome.publish(l == .pair ? "compareLayoutPair" : "compareLayoutAll"))
    }

    /// Details, expanded IN PLACE: one column per shown version, scrolling.
    private func detailsSheet(_ s: ResultsCompareSession) -> some View {
        VStack {
            Spacer()
            VStack(spacing: 0) {
                Button { detailsOpen = false } label: {
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold))
                        Text("Details").dsStyle(DS.TypeScale.bodyStrong)
                    }
                    .foregroundStyle(DS.Color.textPrimary.color).frame(maxWidth: .infinity).frame(height: 48).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityIdentifier("compare-details-close")
                Divider().overlay(DS.Color.strokeSubtle.color)
                HStack(spacing: DS.Space.xs) {
                    ForEach(ResultsDetailsTab.allCases, id: \.self) { t in
                        Button { detailsTab = t } label: {
                            Text(t.rawValue).font(.system(size: 14, weight: t == detailsTab ? .semibold : .regular))
                                .foregroundStyle((t == detailsTab ? DS.Color.textPrimary : DS.Color.textSecondary).color)
                                .padding(.horizontal, DS.Space.m).frame(height: 36)
                                .background(Capsule().fill(t == detailsTab ? DS.Color.fillSubtle.color : Color.clear))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s)
                ScrollView { table(s).padding(.horizontal, DS.Space.l).padding(.bottom, DS.Space.l) }
            }
            .frame(height: Self.sheetHeight - DS.Space.m)
            .resultsPanel()
            .background(ResultsChrome.publish("compareDetails"))
        }
        .padding(PageChrome.edge)
    }

    /// The table: the union of the shown versions' rows for the tab, one column each.
    @ViewBuilder private func table(_ s: ResultsCompareSession) -> some View {
        let cols: [[ResultsDetailRow]] = s.shown.map { tab in model.detailRows(detailsTab, for: tab, version: row(tab)) }
        var labels: [String] = []
        let _ = cols.forEach { c in c.forEach { if !labels.contains($0.label) { labels.append($0.label) } } }
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.m) {
                Text("").frame(width: 160, alignment: .leading)
                ForEach(s.shown, id: \.self) { tab in
                    Text(row(tab)?.title ?? "").font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle((row(tab)?.recommended == true ? DS.Color.accent : DS.Color.textPrimary).color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 10)
            Divider().overlay(DS.Color.strokeSubtle.color)
            ForEach(labels, id: \.self) { label in
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
                    Text(label).font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color).frame(width: 160, alignment: .leading)
                    ForEach(Array(cols.enumerated()), id: \.offset) { _, c in
                        Text(c.filter { $0.label == label }.map(\.value).joined(separator: "\n").ifEmpty("—"))
                            .font(.system(size: 13.5)).foregroundStyle(DS.Color.textPrimary.color)
                            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 10)
                Divider().overlay(DS.Color.strokeSubtle.color)
            }
        }
    }
}

private extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}
