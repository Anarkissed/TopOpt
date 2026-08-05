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
// THE PAGE OWNS NO SELECTION UX (bar AE6, still). What it adds is a BRUSH, which
// is not a selection at all — it paints triangles of the variant's own surface
// into smoothing regions, and it cannot touch anything the freeze predicates
// claim.
//
// ROUND 2 (bar L1) took the EDITOR away. Round 1's "Protected regions" row
// mounted the shared `selectionsPanel` over this page; that let a user edit the
// very anchors and keep-clear volumes the brush's freeze mask was computed from,
// leaving strokes on screen measured against a mask that no longer described the
// part. AE6 is unweakened — there is still exactly one `selectionsPanel` in the
// app, and this page still authors no selection state.
//
// AND THE PAGE OWNS ITS BRUSH TOOLS (bar L4). Round 1 borrowed paint on/off, the
// eraser and the disc size from the TO page's paint drawer, which is why the page
// shipped as an OVERLAY: hiding the workspace chrome would have disarmed its own
// brush. `SmoothBrushTools` is on this panel now, so the chrome can go.
//
// The page is CHROME ONLY: it renders over the workspace's live stage, which stays
// mounted underneath and draws the variant (or its smoothed twin). One stage,
// never two.
//
// ── ROUND 3 (task 2026-08-04) CUT IT DOWN ────────────────────────────────────
//
// The maintainer's note was "there is soooooo much text", and he was counting:
// a five-line sell card, a region list with a slider and up to three explanatory
// lines per row, a protected-vertex readout with a four-line paragraph under it,
// the whole receipt, and three notices stacked at the top of the screen at once.
//
// What is left, and why:
//
//   U1  THE REGION CONCEPT IS GONE FROM THE UI. No list, no per-region slider.
//       The model is the interface: brushing an area again deepens it and the
//       tint darkens to match (`SmoothBrushModel.levels`). The region model is
//       kept INTERNALLY, one region per rung, so every downstream seam — the
//       weight vector, the freeze guarantee, the receipt's own region lines —
//       is unchanged code.
//   U2  THE PANEL IS BRUSH CONTROLS AND NOTHING ELSE: paint/erase, the size with
//       a disc drawn at the ACTUAL footprint, and Pencil only.
//   U3  Discard and Lattice this sit ABOVE Re-certify. "Keep smoothing" is
//       deleted; re-certifying is what keeps.
//   U4  The receipt is a DRAWER above Re-certify.
//   U5  ONE note, top-centre, auto-dismissing — `page.topNote`, one value, so
//       two cannot be on screen at once.
//   U6  ONE dismissible notice on entry, and then nothing standing.

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
    /// THE BRUSH'S TOOLS (round-2 bar L4) — paint / erase / orbit and the disc
    /// size, in the page's own panel. Round 1 borrowed the TO page's paint drawer
    /// for these, which is the mechanical reason the page could not hide the TO
    /// chrome: hiding it disarmed the brush.
    @Binding var tools: SmoothBrushTools
    /// Whether the stage is showing the smoothed geometry or the original.
    @Binding var showingSmoothed: Bool

    let onRecertify: () -> Void
    let onDiscard: () -> Void
    let onSendToLattice: () -> Void
    let onClose: () -> Void
    /// TEST SEAM for the offscreen evidence captures (the LatticePage convention):
    /// ImageRenderer does not render platform-backed containers.
    let staticRender: Bool

    public init(project: ProjectModel, page: SmoothingPageModel,
                brush: Binding<SmoothBrushModel>,
                tools: Binding<SmoothBrushTools>,
                showingSmoothed: Binding<Bool>,
                onRecertify: @escaping () -> Void,
                onDiscard: @escaping () -> Void,
                onSendToLattice: @escaping () -> Void,
                onClose: @escaping () -> Void,
                staticRender: Bool = false) {
        self.project = project
        self.page = page
        self._brush = brush
        self._tools = tools
        self._showingSmoothed = showingSmoothed
        self.onRecertify = onRecertify
        self.onDiscard = onDiscard
        self.onSendToLattice = onSendToLattice
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
                topCentreColumn(width: geo.size.width)
                // IN PORTRAIT THE PANEL AND THE DRAWER ARE ALTERNATIVES, not
                // neighbours (bar B4). Landscape has a left column and a free
                // right-hand side, so both fit with room between them. Portrait
                // has neither: the panel is a full-width strip along the bottom
                // and the drawer opens upward from the same corner, so drawing
                // both would put one on top of the other — exactly the overlap
                // the maintainer has been reporting. Reading the receipt and
                // brushing are not simultaneous activities, so the panel yields
                // while the drawer is open and comes straight back when it
                // closes. `SmoothingRound3Tests` computes both rects from the
                // tokens and asserts they cannot intersect in either orientation.
                if portrait, !page.receiptOpen {
                    panelView(maxHeight: geo.size.height * 0.46)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, DS.Space.l)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        // TWO rows of actions (U3), so the clearance is the
                        // two-row one. The one-row constant is what left the
                        // panel running under Discard/Lattice this.
                        .padding(.bottom, PageChrome.panelBottomClearance(
                            actionRows: Self.actionRows))
                } else if !portrait {
                    panelView(maxHeight: geo.size.height - 200)
                        .frame(width: PageChrome.panelWidth)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .padding(.leading, PageChrome.edge)
                }
                bottomRightCluster(
                    maxDrawerHeight: geo.size.height - PageChrome.noteTop
                        - PageChrome.panelBottomClearance(actionRows: Self.actionRows)
                        - PageChrome.gap)
                if page.showsEntryNotice { entryNotice() }
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
            // BAR U6. Round 2 explained the empty state in a sentence —
            // "Nothing smoothed yet — both show the variant as the run made it."
            // — which is a permanent block of prose saying what a disabled
            // control says by itself. There is nothing smoothed to show, so the
            // Smoothed tab is simply off until there is.
            HStack(spacing: 0) {
                stageTab("Original", on: !showingSmoothed, enabled: true) {
                    showingSmoothed = false
                }
                stageTab("Smoothed", on: showingSmoothed && hasSmoothed,
                         enabled: hasSmoothed) {
                    showingSmoothed = true
                }
            }
            .background(RoundedRectangle(cornerRadius: DS.Radius.control)
                .fill(DS.Surface.panel.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control)
                    .strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, PageChrome.edge + PageChrome.gizmoClearance)
        .padding(.top, PageChrome.topInset)
    }

    /// Whether there is a smoothed shape to look at at all.
    private var hasSmoothed: Bool { page.receipt != nil || page.kept != nil }

    private func stageTab(_ title: String, on: Bool, enabled: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).dsStyle(DS.TypeScale.bodyStrong)
                .foregroundStyle((on ? DS.Color.textPrimary
                                     : (enabled ? DS.Color.textTertiary
                                                : DS.Color.textDisabled)).color)
                .padding(.horizontal, DS.Space.xl).frame(height: PageChrome.compactButton)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control)
                    .fill(on ? DS.Color.fillSelected.color : Color.clear))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("Show \(title)")
        .accessibilityHint(enabled ? "" : "nothing smoothed yet")
    }

    // MARK: top-centre — ONE note, never two (bar U5)
    //
    // Round 2 drew a status banner and, under it, a failure banner, while the
    // panel drew a third warning card — the three overlapping notices the
    // maintainer counted. There is now ONE renderer for ONE value: whatever
    // `page.topNote` says, or nothing. Two cannot appear because there is only
    // one thing to draw, and at rest there is nothing.
    //
    // TOP-CENTRE AND CLEAR OF THE PANEL. The column is centred in the page's full
    // width and capped at `noteMaxWidth`, which `SmoothingRound3Tests` checks
    // against the panel's own right edge in BOTH orientations — so the note can
    // never come up behind the left modal.

    /// The widest a note may be. Derived from the tokens rather than picked, so
    /// the clearance assertion has something to check against.
    static let noteMaxWidth: CGFloat = 620

    /// How many rows the bottom-right action cluster occupies (bar U3: Discard +
    /// Lattice this, then Receipt + Re-certify). Named so the panel's clearance
    /// is derived from it rather than assuming one.
    static let actionRows = 2

    @ViewBuilder private func topCentreColumn(width: CGFloat) -> some View {
        if let n = page.topNote {
            noteView(n, width: PageChrome.noteWidth(for: width,
                                                    cap: Self.noteMaxWidth))
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.top, PageChrome.noteTop)
                // The 60 s ceiling, ticked while the page is up. `tick` is a pure
                // clock read, so tests drive it directly.
                .onReceive(Timer.publish(every: 1, on: .main, in: .common)
                    .autoconnect()) { _ in page.tick() }
        }
    }

    @ViewBuilder private func noteView(_ n: SmoothingPageModel.TopNote,
                                       width: CGFloat) -> some View {
        switch n {
        case .failure(let f):
            failureBanner(f).frame(maxWidth: width)
        case .transient(let t):
            noteBanner(t.text, warn: false, width: width)
                .onTapGesture { page.dismissNote() }
        case .working(let s):
            HStack(spacing: DS.Space.m) {
                ProgressView().tint(DS.Color.accent.color)
                Text(s).dsStyle(DS.TypeScale.callout)
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .lineLimit(2).multilineTextAlignment(.center)
            }
            .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
            .background(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
                .fill(DS.Surface.sheet.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
                    .strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
            .frame(maxWidth: width)
            .dsShadow(DS.Shadow.panel)
        }
    }

    private func noteBanner(_ text: String, warn: Bool,
                            width: CGFloat) -> some View {
        Text(text).dsStyle(DS.TypeScale.callout)
            .foregroundStyle(DS.Color.textSecondary.color)
            .lineLimit(3).multilineTextAlignment(.center)
            .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
            .background(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
                .fill(DS.Surface.sheet.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
                    .strokeBorder((warn ? DS.Color.warning.opacity(0.5)
                                        : DS.Color.strokeSubtle).color,
                                  lineWidth: 1)))
            .frame(maxWidth: width)
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
            Text("Brush").dsStyle(DS.TypeScale.title)
            Spacer()
        }
        .padding(.horizontal, DS.Space.l).padding(.top, DS.Space.l)
        .padding(.bottom, DS.Space.m)
    }

    /// BRUSH CONTROLS, AND NOTHING ELSE (bar U2). Round 2's panel also carried a
    /// five-line "WHAT THIS BUYS YOU" card, a region list with a strength slider
    /// per row, a protected-vertex readout with a four-line "fixed for this
    /// variant" paragraph, and the whole receipt. All of it is gone from here:
    /// the regions are the model's own tint now (U1), the receipt is a drawer
    /// (U4), and the protected-areas fact is the one dismissible entry notice
    /// (U6).
    @ViewBuilder private var paneContent: some View {
        toolsSection
    }

    // ── the brush's own tools (round-2 bar L4) ───────────────────────────────
    //
    // ALL OF THEM, IN THIS ONE PANEL. Round 1 had none: paint on/off, the eraser
    // and the disc size all lived in the TO page's paint drawer, so the page only
    // worked with the workspace chrome left on screen underneath it. That is why
    // L1 and L4 are one change — the chrome could not be hidden until the tools
    // moved here.
    //
    // Same squircle, same `PageChrome.compactButton` height, same
    // `PageChrome.gap` spacing as the other two pages' controls.

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: 0) {
                ForEach(SmoothBrushTools.Mode.allCases) { m in
                    modeTab(m)
                }
            }
            .background(RoundedRectangle(cornerRadius: DS.Radius.control)
                .fill(DS.Surface.bar.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control)
                    .strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
            HStack(spacing: PageChrome.gap) {
                sizeButton("minus", enabled: tools.canShrink) { tools.shrink() }
                brushFootprint
                sizeButton("plus", enabled: tools.canGrow) { tools.grow() }
            }
            .frame(maxWidth: .infinity)
            pencilOnlyRow
            Button { brush.clearStrokes() } label: {
                Text("Clear strokes").dsStyle(DS.TypeScale.caption)
                    .foregroundStyle((brush.isEmpty ? DS.Color.textDisabled
                                                    : DS.Color.textSecondary).color)
                    .frame(maxWidth: .infinity)
                    .frame(height: PageChrome.compactButton)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.control)
                        .fill(DS.Surface.bar.color))
            }
            .buttonStyle(.plain)
            .disabled(brush.isEmpty)
            .accessibilityLabel("Clear all strokes")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// THE ACTUAL FOOTPRINT (bar U2), not a number standing in for one. The disc
    /// is drawn at `tools.radiusPoints` in the same screen points the hit test
    /// uses, so what the panel shows is the size of the thing that will land on
    /// the model — `SmoothingRound3Tests` pins the two to the same value.
    private var brushFootprint: some View {
        ZStack {
            Circle()
                .fill(DS.Color.accent.opacity(0.22).color)
                .overlay(Circle().strokeBorder(DS.Color.accent.color, lineWidth: 1.5))
                .frame(width: CGFloat(tools.radiusPoints) * 2,
                       height: CGFloat(tools.radiusPoints) * 2)
            Text("\(Int(tools.radiusPoints))")
                .dsStyle(DS.TypeScale.caption).fontWeight(.bold)
                .foregroundStyle(DS.Color.textPrimary.color)
        }
        .frame(height: CGFloat(SmoothBrushTools.maxRadius) * 2)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Brush size \(Int(tools.radiusPoints)) points")
    }

    /// PENCIL ONLY (bar U2). With it on, a one-finger drag ALWAYS orbits and the
    /// pencil always paints — so turning the part around never costs a mode
    /// switch, which is what round 2's Orbit tab made it cost.
    private var pencilOnlyRow: some View {
        Button { tools.pencilOnly.toggle() } label: {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: tools.pencilOnly
                      ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle((tools.pencilOnly ? DS.Color.accent
                                                       : DS.Color.textTertiary).color)
                Text("Pencil only").dsStyle(DS.TypeScale.callout)
                    .foregroundStyle(DS.Color.textPrimary.color)
                Spacer()
                Image(systemName: "hand.draw")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Color.textQuaternary.color)
            }
            .padding(.horizontal, DS.Space.m)
            .frame(height: PageChrome.compactButton)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control)
                .fill(DS.Surface.bar.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control)
                    .strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pencil only")
        .accessibilityValue(tools.pencilOnly ? "on" : "off")
        .accessibilityHint("One-finger drag orbits; the pencil paints")
    }

    private func modeTab(_ m: SmoothBrushTools.Mode) -> some View {
        let on = tools.mode == m
        return Button { tools.mode = m } label: {
            HStack(spacing: 5) {
                Image(systemName: m.icon).font(.system(size: 11, weight: .bold))
                Text(m.label).dsStyle(DS.TypeScale.caption).fontWeight(.semibold)
            }
            .foregroundStyle((on ? DS.Color.textPrimary : DS.Color.textTertiary).color)
            .frame(maxWidth: .infinity).frame(height: PageChrome.compactButton)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control)
                .fill(on ? DS.Color.fillSelected.color : Color.clear))
        }
        .buttonStyle(.plain)
        .disabled(!brush.canPaint)
        .accessibilityLabel(m.label)
    }

    private func sizeButton(_ icon: String, enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold))
                .foregroundStyle((enabled ? DS.Color.textPrimary
                                          : DS.Color.textDisabled).color)
                .frame(width: 34, height: 34)
                .background(Circle().fill(DS.Surface.bar.color)
                    .overlay(Circle().strokeBorder(DS.Color.strokeSubtle.color,
                                                   lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(icon == "plus" ? "Bigger brush" : "Smaller brush")
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
                    .frame(width: 88, alignment: .trailing)
                Text("AFTER").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DS.Color.textQuaternary.color)
                    .frame(width: 88, alignment: .trailing)
            }
            ForEach(r.rows, id: \.label) { row in
                HStack {
                    Text(row.label).dsStyle(DS.TypeScale.caption)
                        .foregroundStyle(DS.Color.textPrimary.opacity(0.48).color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(row.beforeText).dsStyle(DS.TypeScale.caption)
                        .foregroundStyle(DS.Color.textTertiary.color)
                        .frame(width: 88, alignment: .trailing)
                    Text(row.afterText).dsStyle(DS.TypeScale.callout).fontWeight(.semibold)
                        .foregroundStyle(rowTint(row).color)
                        .frame(width: 88, alignment: .trailing)
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
    //
    // BAR U3, VERBATIM: "Discard" and "Lattice this" go ABOVE "Re-certify", and
    // "Keep smoothing" is deleted — "that's stupid. They just keep smoothing if
    // they want to keep smoothing." A successful re-certification now IS the
    // keep (`SmoothingPageModel.recertify`), so nothing about what travels
    // downstream changed; only the second press is gone.
    //
    // BAR U4: the receipt is a DRAWER above Re-certify, not a permanent panel.
    // It sits in this same column so it opens over the page's own dead space
    // rather than over the model or the brush panel.

    private func bottomRightCluster(maxDrawerHeight: CGFloat) -> some View {
        let a = actions
        return VStack(alignment: .trailing, spacing: PageChrome.gap) {
            if page.receiptOpen, let r = page.receipt ?? page.staleReceipt {
                // CAPPED AND SCROLLABLE. The receipt grows with its footnotes,
                // and a drawer that grows past the top of the screen would push
                // the buttons off the bottom — which is the overlap this drawer
                // exists to avoid, arriving from the other direction.
                Group {
                    if staticRender {
                        receiptCard(r)
                    } else {
                        ScrollView(.vertical, showsIndicators: false) {
                            receiptCard(r)
                        }
                        .frame(maxHeight: max(maxDrawerHeight, 1))
                    }
                }
                .frame(width: PageChrome.receiptDrawerWidth)
            }
            HStack(spacing: PageChrome.gap) {
                actionButton(a.discard, action: onDiscard)
                actionButton(a.sendToLattice, action: onSendToLattice)
            }
            HStack(spacing: PageChrome.gap) {
                receiptToggle
                actionButton(a.recertify, action: onRecertify)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, PageChrome.edge).padding(.bottom, PageChrome.edge)
    }

    /// The drawer's handle. Disabled with a reason when there is no receipt to
    /// open — the page's own rule for every other control.
    private var receiptToggle: some View {
        let has = page.receipt != nil || page.staleReceipt != nil
        return Button {
            guard has else { return }
            page.receiptOpen.toggle()
        } label: {
            VStack(spacing: 2) {
                Text("Receipt").dsStyle(DS.TypeScale.headline)
                Text(has ? (page.receiptOpen ? "hide the numbers"
                                             : "before and after, both measured")
                         : "re-certify to get one")
                    .font(.system(size: 11.5, weight: .semibold)).opacity(0.72)
                    .lineLimit(2).multilineTextAlignment(.center)
            }
            .foregroundStyle((has ? DS.Color.textPrimary : DS.Color.textDisabled).color)
            .padding(.horizontal, DS.Space.xl4).frame(height: PageChrome.actionButton)
            .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                .fill(has ? DS.Surface.panel.color : DS.Color.fillDisabled.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                    .strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
            .dsShadow(DS.Shadow.panel)
        }
        .buttonStyle(.plain)
        .disabled(!has)
        .accessibilityLabel("Receipt")
        .accessibilityValue(page.receiptOpen ? "open" : "closed")
    }

    /// THE ONE STANDING NOTICE (bar U6). Shown on entry, dismissed with OK, and
    /// then the page has no explanatory text standing at all.
    private func entryNotice() -> some View {
        VStack(alignment: .leading, spacing: DS.Space.ml) {
            HStack(spacing: DS.Space.m) {
                Image(systemName: "lock.fill").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(DS.Color.okGreen.color)
                Text(SmoothingPageModel.entryNotice).dsStyle(DS.TypeScale.body)
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { page.dismissEntryNotice() } label: {
                Text("OK").dsStyle(DS.TypeScale.headline)
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .padding(.horizontal, DS.Space.xl4)
                    .frame(height: PageChrome.compactButton)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.control)
                        .fill(DS.Color.accent.color))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("OK")
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel)
            .fill(DS.Surface.sheet.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
