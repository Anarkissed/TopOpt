// SmoothingPage.swift — the third full-screen page (handoff
// 2026-08-02-smoothing-page).
//
// A SIBLING of the TO page and the lattice page, not a third look. Every gap,
// every button height, the panel width and the gizmo corner come from
// `PageChrome`, the ONE chrome geometry all three read (bar AE7). The structure
// mirrors `LatticePage` seam for seam: top-left back/title/working-on column,
// top-right column, top-centre status, a left-edge content panel, a bottom-right
// action cluster. The maintainer's round-3 note was that "all the buttons feel
// different" — the fix is shared constants, not a careful eye.
//
// SELECTIONS ARE THE SHARED LIBRARY (bar AE6). The page does not own a selection
// UX. Its "Protected regions" row opens the SAME `selectionsPanel` the TO page and
// the lattice page mount, over the SAME `project.selection` model. What this page
// adds is a BRUSH, which is not a selection at all — it paints triangles of the
// variant's own surface into smoothing regions, and it cannot touch anything the
// freeze predicates claim.
//
// The page is CHROME ONLY: it renders over the workspace's live stage, which stays
// mounted underneath and draws the variant (or its smoothed twin). One stage,
// never two.

import SwiftUI
import simd
import TopOptDesign
import TopOptKit

public struct SmoothingPage: View {
    @ObservedObject var project: ProjectModel
    @ObservedObject var page: SmoothingPageModel

    /// The brush state. Owned by the host so a stroke on the stage and the panel's
    /// region list are the same value.
    @Binding var brush: SmoothBrushModel
    /// Whether the stage is showing the smoothed geometry or the original.
    @Binding var showingSmoothed: Bool

    let onRecertify: () -> Void
    let onKeep: () -> Void
    let onDiscard: () -> Void
    let onSendToLattice: () -> Void
    let onOpenLibrary: () -> Void
    let onClose: () -> Void
    /// TEST SEAM for the offscreen evidence captures (the LatticePage convention):
    /// ImageRenderer does not render platform-backed containers.
    let staticRender: Bool

    public init(project: ProjectModel, page: SmoothingPageModel,
                brush: Binding<SmoothBrushModel>,
                showingSmoothed: Binding<Bool>,
                onRecertify: @escaping () -> Void,
                onKeep: @escaping () -> Void,
                onDiscard: @escaping () -> Void,
                onSendToLattice: @escaping () -> Void,
                onOpenLibrary: @escaping () -> Void,
                onClose: @escaping () -> Void,
                staticRender: Bool = false) {
        self.project = project
        self.page = page
        self._brush = brush
        self._showingSmoothed = showingSmoothed
        self.onRecertify = onRecertify
        self.onKeep = onKeep
        self.onDiscard = onDiscard
        self.onSendToLattice = onSendToLattice
        self.onOpenLibrary = onOpenLibrary
        self.onClose = onClose
        self.staticRender = staticRender
    }

    private var context: SmoothVariantContext { page.context }

    private var actions: SmoothPageActions {
        SmoothPageActions.compute(brush: brush, working: page.isWorking,
                                  hasReceipt: page.receipt != nil,
                                  hasKept: page.kept != nil,
                                  unavailable: context.unavailable)
    }

    // MARK: body — the LatticePage skeleton, same seams, same order

    public var body: some View {
        GeometryReader { geo in
            let portrait = geo.size.height > geo.size.width
            ZStack(alignment: .topLeading) {
                topLeftColumn
                topRightColumn
                topCentreColumn
                if portrait {
                    panelView(maxHeight: geo.size.height * 0.46)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, DS.Space.l)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, PageChrome.panelBottomClearance)
                } else {
                    panelView(maxHeight: geo.size.height - 200)
                        .frame(width: PageChrome.panelWidth)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .padding(.leading, PageChrome.edge)
                }
                bottomRightCluster
                if let why = context.unavailable { gateOverlay(why) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: top-left

    private var topLeftColumn: some View {
        VStack(alignment: .leading, spacing: PageChrome.gap) {
            HStack(spacing: PageChrome.gap) {
                circleButton(system: "chevron.left", label: "Close smoothing") { onClose() }
                HStack(spacing: DS.Space.m) {
                    Text(project.name.isEmpty ? "Untitled" : project.name)
                        .dsStyle(DS.TypeScale.headline)
                    Rectangle().fill(DS.Color.textPrimary.opacity(0.16).color)
                        .frame(width: 1, height: 20)
                    Text(project.material).dsStyle(DS.TypeScale.body)
                        .foregroundStyle(DS.Color.textTertiary.color)
                }
                .padding(.horizontal, DS.Space.xl2).frame(height: PageChrome.barHeight)
                .background(Capsule().fill(DS.Surface.bar.color)
                    .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
            }
            workingOnBar
            loadCaseBar
        }
        .padding(.leading, PageChrome.edge).padding(.top, PageChrome.topInset)
    }

    private func circleButton(system: String, label: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary.color)
                .frame(width: PageChrome.circleButton, height: PageChrome.circleButton)
                .background(Circle().fill(DS.Surface.bar.color)
                    .overlay(Circle().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// WHICH VARIANT — the lattice page's own identity bar, same shape.
    private var workingOnBar: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "scribble.variable")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(DS.Color.accent.color)
            Text("Working on").dsStyle(DS.TypeScale.caption2).fontWeight(.semibold)
                .foregroundStyle(DS.Color.textQuaternary.color)
            Text(context.title).dsStyle(DS.TypeScale.caption).fontWeight(.bold)
                .foregroundStyle(DS.Color.textPrimary.color)
            divider
            Text(context.subtitle).dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(DS.Color.textTertiary.color)
            if page.kept != nil {
                divider
                Text("smoothing kept").dsStyle(DS.TypeScale.caption2).fontWeight(.bold)
                    .foregroundStyle(DS.Color.okGreen.color)
            }
        }
        .padding(.horizontal, DS.Space.ml).frame(height: PageChrome.infoBar)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control)
            .fill(DS.Surface.bar.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control)
                .strokeBorder(DS.Color.accent.opacity(0.45).color, lineWidth: 1)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Working on \(context.title), \(context.subtitle)")
    }

    /// AE3 made visible: WHICH load case the numbers come from, named on screen so
    /// the retained-job rule is not a claim only the tests can see.
    @ViewBuilder private var loadCaseBar: some View {
        if let lc = context.loadCase {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "doc.text.fill").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DS.Color.textQuaternary.color)
                Text("From the run's own job").dsStyle(DS.TypeScale.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(DS.Color.textQuaternary.color)
                divider
                Text(lc.attribution).dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textTertiary.color)
            }
            .padding(.horizontal, DS.Space.ml).frame(height: PageChrome.infoBar)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control)
                .fill(DS.Surface.bar.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control)
                    .strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
        }
    }

    private var divider: some View {
        Rectangle().fill(DS.Color.textPrimary.opacity(0.12).color)
            .frame(width: 1, height: 15)
    }

    // MARK: top-right — the before/after stage toggle
    //
    // Inset by `PageChrome.gizmoClearance` so it never lands under the position
    // gizmo, which the host mounts in the shared top-right corner (AE7).

    private var topRightColumn: some View {
        VStack(alignment: .trailing, spacing: PageChrome.gap) {
            HStack(spacing: 0) {
                stageTab("Original", on: !showingSmoothed) { showingSmoothed = false }
                stageTab("Smoothed", on: showingSmoothed) { showingSmoothed = true }
            }
            .background(RoundedRectangle(cornerRadius: DS.Radius.control)
                .fill(DS.Surface.panel.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control)
                    .strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
            if page.receipt == nil, page.kept == nil {
                Text("Nothing smoothed yet — both show the variant as the run made it.")
                    .dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textQuaternary.color)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 236, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, PageChrome.edge + PageChrome.gizmoClearance)
        .padding(.top, PageChrome.topInset)
    }

    private func stageTab(_ title: String, on: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).dsStyle(DS.TypeScale.bodyStrong)
                .foregroundStyle((on ? DS.Color.textPrimary : DS.Color.textTertiary).color)
                .padding(.horizontal, DS.Space.xl).frame(height: PageChrome.compactButton)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control)
                    .fill(on ? DS.Color.fillSelected.color : Color.clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show \(title)")
    }

    // MARK: top-centre — status, and the H1 STALE banner

    private var topCentreColumn: some View {
        VStack(spacing: PageChrome.gap) {
            statusBanner
            if let f = page.failure { failureBanner(f) }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.top, PageChrome.topInset)
    }

    private var statusBanner: some View {
        HStack(spacing: DS.Space.m) {
            if page.isWorking {
                ProgressView().tint(DS.Color.accent.color)
            }
            Text(page.statusLine).dsStyle(DS.TypeScale.callout)
                .foregroundStyle(DS.Color.textSecondary.color)
                .lineLimit(3).multilineTextAlignment(.center)
        }
        .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
        .background(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
            .fill(DS.Surface.sheet.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
                .strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
        .frame(maxWidth: 620)
        .dsShadow(DS.Shadow.panel)
    }

    /// H1 / AE5 on screen: the failure NAMED, its cause explained, and what to do.
    /// Never a crash, and never a silent stale number — the receipt below is
    /// separately stamped STALE by `receiptCard`.
    private func failureBanner(_ f: SmoothCertifyFailure) -> some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            ZStack {
                Circle().fill(DS.Color.warning.color).frame(width: 26, height: 26)
                Image(systemName: "exclamationmark").font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(DS.Color.background.color)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(f.title).dsStyle(DS.TypeScale.bodyStrong)
                Text(f.detail).dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textSecondary.color)
                Text(f.suggestion).dsStyle(DS.TypeScale.caption2).fontWeight(.semibold)
                    .foregroundStyle(DS.Color.warning.color)
            }
        }
        .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
        .background(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
            .fill(DS.Surface.sheet.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
                .strokeBorder(DS.Color.warning.opacity(0.5).color, lineWidth: 1)))
        .frame(maxWidth: 620)
        .dsShadow(DS.Shadow.panel)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(f.title). \(f.detail)")
    }

    // MARK: the panel — brush regions, then the receipt

    private func panelView(maxHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            panelHeader
            if staticRender {
                VStack(spacing: DS.Space.s) { paneContent }
                    .padding(.horizontal, DS.Space.l).padding(.bottom, DS.Space.m)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: DS.Space.s) { paneContent }
                        .padding(.horizontal, DS.Space.l).padding(.bottom, DS.Space.m)
                }
                .frame(maxHeight: max(maxHeight, 1))
            }
        }
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel)
            .fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
    }

    private var panelHeader: some View {
        HStack(spacing: DS.Space.sm) {
            Text("Smoothing").dsStyle(DS.TypeScale.title)
            Spacer()
            Button { brush.addRegion() } label: {
                Image(systemName: "plus").font(.system(size: 14, weight: .bold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(DS.Color.fillSelected.color))
            }
            .buttonStyle(.plain)
            .disabled(!brush.canPaint)
            .accessibilityLabel("Add smoothing region")
        }
        .padding(.horizontal, DS.Space.l).padding(.top, DS.Space.l)
        .padding(.bottom, DS.Space.m)
    }

    @ViewBuilder private var paneContent: some View {
        sellCard
        if let why = brush.unusableReason {
            noteCard(why, tint: DS.Color.warning)
        }
        regionsSection
        protectedSection
        if let r = page.receipt {
            receiptCard(r)
        } else if let s = page.staleReceipt {
            receiptCard(s)
        }
    }

    /// The SELL, and it is not the melt. PR 200's own conclusion was that a plain
    /// global smooth buys most of the cosmetic win with none of the honesty.
    private var sellCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WHAT THIS BUYS YOU").font(.system(size: 11, weight: .semibold))
                .tracking(0.7).foregroundStyle(DS.Color.textQuaternary.color)
            Text("Brush smoothing only where it's needed, then RE-CERTIFY. Bolt "
                 + "bores, mating faces, anchors and load faces are held "
                 + "bit-identical — the brush cannot touch them. Min feature width "
                 + "is a hard wall. The margins below are measured on the smoothed "
                 + "shape and on the original, both by the same solver.")
                .dsStyle(DS.TypeScale.caption)
                .foregroundStyle(DS.Color.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control)
            .fill(DS.Color.accent.opacity(0.10).color))
    }

    private func noteCard(_ text: String, tint: RGBA) -> some View {
        Text(text).dsStyle(DS.TypeScale.caption)
            .foregroundStyle(DS.Color.textSecondary.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control)
                .fill(tint.opacity(0.12).color))
    }

    // ── regions: LOCAL strength, inspectable and reversible (item 3) ─────────

    private var regionsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            sectionTitle("BRUSH REGIONS")
            if brush.regions.isEmpty {
                Text("No regions yet. Add one, then brush the areas that need "
                     + "smoothing. Each region carries its own strength.")
                    .dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textQuaternary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(brush.summaries(), id: \.id) { s in
                regionRow(s)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func regionRow(_ s: SmoothBrushModel.RegionSummary) -> some View {
        let active = brush.activeRegionID == s.id
        let color = brush.regions.first { $0.id == s.id }?.color ?? DS.Color.accent
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: DS.Space.s) {
                RoundedRectangle(cornerRadius: 3).fill(color.color)
                    .frame(width: 12, height: 12)
                Text(s.name).dsStyle(DS.TypeScale.callout).fontWeight(.semibold)
                Spacer()
                Text("\(s.triangles) tri · \(s.vertices) vtx")
                    .dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textQuaternary.color)
                Button { brush.removeRegion(s.id) } label: {
                    Image(systemName: "trash").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Color.textTertiary.color)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(s.name)")
            }
            HStack(spacing: DS.Space.s) {
                Text("Strength").dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textQuaternary.color)
                Slider(value: Binding(
                    get: { brush.regions.first { $0.id == s.id }?.strength ?? 0 },
                    set: { brush.setStrength(s.id, $0) }), in: 0...1)
                Text(String(format: "%.2f", s.strength))
                    .dsStyle(DS.TypeScale.caption).fontWeight(.bold)
                    .frame(width: 38, alignment: .trailing)
            }
            // The brush stopping at a frozen surface is REPORTED, not inferred.
            if s.frozenTouched > 0 {
                Text("\(s.frozenTouched) vertices in this stroke are frozen "
                     + "(bore / mating face / anchor) — the brush stopped at them.")
                    .dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if s.inert {
                Text(s.strength <= 0 ? "Strength 0 — this region is off."
                                     : "Nothing brushed into this region yet.")
                    .dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textQuaternary.color)
            }
        }
        .padding(DS.Space.m)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control)
            .fill((active ? DS.Color.fillSelected : DS.Surface.bar).color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control)
                .strokeBorder((active ? color.opacity(0.7) : DS.Color.strokeSubtle).color,
                              lineWidth: 1)))
        .contentShape(Rectangle())
        .onTapGesture { brush.setActive(s.id) }
    }

    /// AE6 — the SAME selections library, not a second one. This row opens the TO
    /// page's own panel; nothing about protected regions is authored here.
    private var protectedSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            sectionTitle("PROTECTED — THE BRUSH CANNOT TOUCH THESE")
            Button(action: onOpenLibrary) {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "lock.fill").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DS.Color.okGreen.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Selections & keep-clear")
                            .dsStyle(DS.TypeScale.callout).fontWeight(.semibold)
                        Text(brush.freeze.isAvailable
                             ? "\(brush.freeze.frozenCount) of \(brush.freeze.vertexCount) "
                               + "vertices frozen · within "
                               + String(format: "%.2f mm", brush.freeze.toleranceMM)
                             : "resolving…")
                            .dsStyle(DS.TypeScale.caption2)
                            .foregroundStyle(DS.Color.textTertiary.color)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DS.Color.textQuaternary.color)
                }
                .padding(DS.Space.m)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control)
                    .fill(DS.Surface.bar.color))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open the shared selections library")
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .semibold)).tracking(0.7)
            .foregroundStyle(DS.Color.textQuaternary.color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // ── THE RECEIPT (bar AE2): before | after, both measured ─────────────────

    private func receiptCard(_ r: SmoothReceipt) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                sectionTitle(r.stale ? "RECEIPT — OUT OF DATE" : "RECEIPT")
                if r.stale {
                    Text("STALE").font(.system(size: 10, weight: .heavy)).tracking(0.6)
                        .foregroundStyle(DS.Color.background.color)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(DS.Color.warning.color))
                }
            }
            if r.stale {
                Text("These are the numbers from the PREVIOUS certification. The "
                     + "smoothing on screen now has NOT been certified.")
                    .dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("").frame(maxWidth: .infinity, alignment: .leading)
                Text("BEFORE").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DS.Color.textQuaternary.color)
                    .frame(width: 72, alignment: .trailing)
                Text("AFTER").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DS.Color.textQuaternary.color)
                    .frame(width: 72, alignment: .trailing)
            }
            ForEach(r.rows, id: \.label) { row in
                HStack {
                    Text(row.label).dsStyle(DS.TypeScale.caption)
                        .foregroundStyle(DS.Color.textPrimary.opacity(0.48).color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(row.beforeText).dsStyle(DS.TypeScale.caption)
                        .foregroundStyle(DS.Color.textTertiary.color)
                        .frame(width: 72, alignment: .trailing)
                    Text(row.afterText).dsStyle(DS.TypeScale.callout).fontWeight(.semibold)
                        .foregroundStyle(rowTint(row).color)
                        .frame(width: 72, alignment: .trailing)
                }
                .frame(minHeight: 26)
            }
            Divider().overlay(DS.Color.strokeSubtle.color)
            footnote(r.minFeatureLine)
            footnote(r.smoothing.frozenLine)
            footnote(r.smoothing.driftLine)
            if let capped = r.smoothing.cappedLine { footnote(capped, warn: true) }
            footnote(r.quantizationLine)
            if !r.smoothing.regionLines.isEmpty {
                footnote("Regions: " + r.smoothing.regionLines.joined(separator: " · "))
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control)
            .fill(DS.Surface.bar.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control)
                .strokeBorder((r.stale ? DS.Color.warning.opacity(0.55)
                                       : DS.Color.strokeSubtle).color, lineWidth: 1)))
    }

    private func rowTint(_ row: SmoothReceipt.Row) -> RGBA {
        if row.worse == true { return DS.Color.warning }
        if row.better == true { return DS.Color.okGreen }
        return DS.Color.textPrimary
    }

    private func footnote(_ t: String, warn: Bool = false) -> some View {
        Text(t).dsStyle(DS.TypeScale.caption2)
            .foregroundStyle((warn ? DS.Color.warning : DS.Color.textQuaternary).color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: bottom-right cluster — the same button shapes as the other two pages

    private var bottomRightCluster: some View {
        let a = actions
        return HStack(spacing: PageChrome.gap) {
            actionButton(a.discard, action: onDiscard)
            actionButton(a.sendToLattice, action: onSendToLattice)
            actionButton(a.keep, action: onKeep)
            actionButton(a.recertify, action: onRecertify)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, PageChrome.edge).padding(.bottom, PageChrome.edge)
    }

    private func actionButton(_ a: SmoothPageActions.Action,
                              action: @escaping () -> Void) -> some View {
        let tint: RGBA = a.primary ? DS.Color.accent : DS.Surface.panel
        return Button {
            guard a.enabled else { return }
            action()
        } label: {
            VStack(spacing: 2) {
                Text(a.label).dsStyle(DS.TypeScale.headline)
                Text(a.sub).font(.system(size: 11.5, weight: .semibold)).opacity(0.72)
                    .lineLimit(2).multilineTextAlignment(.center)
            }
            .foregroundStyle((a.enabled ? DS.Color.textPrimary : DS.Color.textDisabled).color)
            .padding(.horizontal, DS.Space.xl4).frame(height: PageChrome.actionButton)
            .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                .fill(a.enabled ? tint.color : DS.Color.fillDisabled.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                    .strokeBorder(DS.Color.strokeSubtle.color,
                                  lineWidth: a.primary ? 0 : 1)))
            .dsShadow(a.enabled && a.primary ? DS.Shadow.accentGlow : DS.Shadow.panel)
        }
        .buttonStyle(.plain)
        .disabled(!a.enabled)
        .accessibilityLabel(a.label)
        .accessibilityHint(a.sub)
    }

    // MARK: the entry gate — states WHY, never a mute disabled button

    private func gateOverlay(_ why: SmoothUnavailable) -> some View {
        ZStack {
            DS.Color.scrim.color.ignoresSafeArea()
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                HStack(spacing: DS.Space.ml) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 13)
                            .fill(DS.Color.warning.opacity(0.16).color)
                            .frame(width: 42, height: 42)
                        Text("!").font(.system(size: 21, weight: .bold))
                            .foregroundStyle(DS.Color.warning.color)
                    }
                    Text("This variant can’t be smoothed").dsStyle(DS.TypeScale.title)
                }
                Text(why.reason).dsStyle(DS.TypeScale.body)
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onClose) {
                    Text("Back").dsStyle(DS.TypeScale.headline)
                        .foregroundStyle(DS.Color.textPrimary.color)
                        .padding(.horizontal, DS.Space.xl4)
                        .frame(height: PageChrome.actionButton)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                            .fill(DS.Color.accent.color))
                }
                .buttonStyle(.plain)
            }
            .padding(DS.Space.xl4)
            .frame(maxWidth: 560, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.panel)
                .fill(DS.Surface.sheet.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
                    .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
            .dsShadow(DS.Shadow.panel)
        }
    }
}
