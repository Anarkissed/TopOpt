// FlexibleCornerPair — A1's CORNER PAIR on the main Lattice page: the Setup chip and the Lattice split button, and the one
// panel above them (task 2026-09-29-flexible-screens, round 7, batch R7-D1: his pick 1).
//
// His pick (2026-10-14): "I like A2 but with the corner pair from A1 on the main Lattice screen (see image 1)" — "the Setup
// chip '▦ Fast · ↑ +Z · ↓ −Z ⌃' (unfolds into one-line rows: Quality, Plate up, Gravity, Print parameters) + the 'Lattice'
// split button (main = the next step in one tap, status line under it …; its ⌃ opens the card with Preview → Core → Export
// …). Blockers pop at once above the pair." His answers: "DROP both the muted Optimize row and the iPad/Mac compute chip".
//
// ★ H30 mounts it INSIDE #354's bottomBar on the Flexible stage, in place of [iPad][Print Parameters][Lattice pill]
// [Optimize]: the bar's own BottomBarHeightKey measures it, so the legends and the player clear it through #354's
// bottomBarClearance, and BottomBarMeasurementTests is unchanged.
// ★ ITS PANELS (the Setup tray, the Lattice card, the blocker callout) are OVERLAYS of the pair, 12 pt above it,
// right-aligned on 24, 420 wide (336 on the mini), as tall as their content and never above the views row's foot + 12
// (past that they scroll) — never in layout, so the bar's measured height never changes (FlexibleChromeStateTests). ONE at a
// time (FlexibleChromeState): opening one folds the other; a tap on the part, a stage change, the Squish page and gravity
// setup fold them all.

import SwiftUI
import TopOptDesign

/// The main page's viewport, as the views row measures it (the pair sits inside #354's bar and cannot measure it).
@MainActor
public final class FlexibleChromeGeometry: ObservableObject {
    @Published public internal(set) var viewport: CGSize = .zero
    public init() {}
    func note(_ v: CGSize) { if v != viewport, v.width > 0, v.height > 0 { viewport = v } }
}

public struct FlexibleCornerPair: View {
    @ObservedObject var main: FlexibleMainStage
    @ObservedObject var project: ProjectModel
    let app: AppModel
    let openSquish: () -> Void
    let changeGravity: () -> Void
    @ObservedObject private var chrome: FlexibleChromeState
    @ObservedObject private var geometry: FlexibleChromeGeometry
    @StateObject private var tray = FlexibleSetupTrayState()

    public init(main: FlexibleMainStage, project: ProjectModel, app: AppModel, openSquish: @escaping () -> Void,
                changeGravity: @escaping () -> Void) {
        self.main = main; self.project = project; self.app = app; self.openSquish = openSquish; self.changeGravity = changeGravity
        self._chrome = ObservedObject(wrappedValue: main.chrome)
        self._geometry = ObservedObject(wrappedValue: main.chromeGeometry)
    }

    /// Test control only: the panels placed IN layout (the bar would measure them — the defect the overlay avoids).
    @MainActor static var controlPanelInLayout = false
    /// Test control only: the blocker rule fed the status its onChange closure captured (the first build: no pop on his pad).
    @MainActor static var controlCapturedStatus = false

    private var viewport: CGSize { geometry.viewport == .zero ? CGSize(width: 1032, height: 1376) : geometry.viewport }

    public var body: some View {
        let pair = HStack(alignment: .bottom, spacing: FlexibleChromeLayout.pairGap) {
            FlexibleSetupChipView(project: project, open: chrome.open == .setup) {
                tray.page = .rows
                chrome.toggle(.setup)
            }
            .background(FlexibleCornerPairStyle.publish("setupChip"))
            if let m = main.model {
                FlexibleLatticeSplit(model: m, run: main.coreRun, main: main, chrome: chrome, project: project, viewport: viewport,
                                     openSquish: openSquish)
            } else {
                FlexibleLatticeButtonView(status: FlexibleMainStatus.of(model: nil), state: .idle, line: FlexibleMainStatus.notOpened,
                                          width: FlexibleChromeLayout.latticeButtonSize(viewport).width, cardOpen: false,
                                          main: { chrome.foldAll(); openSquish() }, caret: {})
                    .background(FlexibleCornerPairStyle.publish("latticeSplit"))
            }
        }
        if Self.controlPanelInLayout {
            VStack(alignment: .trailing, spacing: FlexibleChromeLayout.panelGap) { panel; pair }
        } else {
            pair.overlay(alignment: .bottomTrailing) {
                panel.offset(y: -(PageChrome.actionButton + FlexibleChromeLayout.panelGap))
            }
        }
    }

    @ViewBuilder private var panel: some View {
        let w = FlexibleChromeLayout.panelWidth(viewport)
        let maxH = FlexibleChromeLayout.panelMaxHeight(viewport)
        switch chrome.open {
        case .setup:
            FlexibleCornerPairStyle.panel(width: w, maxHeight: maxH) {
                FlexibleSetupTray(project: project, tray: tray, chrome: chrome, app: app, changeGravity: changeGravity,
                                  narrow: FlexibleChromeLayout.panelIsNarrow(w))
            }
            .background(FlexibleCornerPairStyle.publish("setupTray"))
            .accessibilityIdentifier("flexible-setup-tray")
        case .latticeCard:
            if let m = main.model {
                FlexibleLatticeCardMount(model: m, run: main.coreRun, main: main, chrome: chrome, project: project, width: w, maxHeight: maxH)
                    .background(FlexibleCornerPairStyle.publish("latticeCard"))
            } else {
                // before the stage's model arrives (the first frames): the steps, nothing to send yet
                FlexibleLatticeCardView(run: main.coreRun, status: FlexibleMainStatus.of(model: nil), state: .idle,
                                        preview: FlexibleLatticeCard.previewLine(state: .idle, project: project), width: w, maxHeight: maxH,
                                        close: { chrome.close(.latticeCard) })
                    .background(FlexibleCornerPairStyle.publish("latticeCard"))
            }
        case .callout:
            if let m = main.model {
                FlexibleCalloutMount(model: m, main: main, chrome: chrome, width: w, openSquish: openSquish)
                    .background(FlexibleCornerPairStyle.publish("callout"))
            }
        default:
            EmptyView()
        }
    }
}

/// The split, observing the model and core's run (their changes redraw only the pair), and the blocker rule.
private struct FlexibleLatticeSplit: View {
    @ObservedObject var model: FlexibleStageModel
    @ObservedObject var run: FlexibleCoreRun
    let main: FlexibleMainStage
    @ObservedObject var chrome: FlexibleChromeState
    let project: ProjectModel
    let viewport: CGSize
    let openSquish: () -> Void

    var body: some View {
        let s = main.cornerStatus(model)
        let st = FlexibleLatticeButton.state(s, phase: run.phase, answerIsCurrent: main.answerIsCurrent(model))
        let line = FlexibleLatticeButton.line(s, state: st, runLine: run.line)
        FlexibleLatticeButtonView(status: s, state: st, line: line, width: FlexibleChromeLayout.latticeButtonSize(viewport).width,
                                  cardOpen: chrome.open == .latticeCard,
                                  main: { FlexibleLatticeButton.perform(FlexibleLatticeButton.action(st), chrome: chrome, hooks: main.cornerHooks(openSquish: openSquish)) },
                                  caret: { FlexibleLatticeButton.caret(chrome: chrome, hooks: main.cornerHooks(openSquish: openSquish)) })
            .background(FlexibleCornerPairStyle.publish("latticeSplit"))
            // (the status asked afresh in each: an onChange closure may hold the update before the change — the hosted test's
            // red control, `controlCapturedStatus`, is the closure's own `s`)
            .onAppear { main.noteCallout(main.cornerStatus(model)) }
            .onChange(of: s.fix?.id) { _ in main.noteCallout(FlexibleCornerPair.controlCapturedStatus ? s : main.cornerStatus(model)) }
            .onChange(of: s.tone) { _ in main.noteCallout(FlexibleCornerPair.controlCapturedStatus ? s : main.cornerStatus(model)) }
    }
}

/// The card, over the live status and core's run.
private struct FlexibleLatticeCardMount: View {
    @ObservedObject var model: FlexibleStageModel
    @ObservedObject var run: FlexibleCoreRun
    let main: FlexibleMainStage
    let chrome: FlexibleChromeState
    let project: ProjectModel
    let width: CGFloat
    let maxHeight: CGFloat

    var body: some View {
        let s = main.cornerStatus(model)
        let st = FlexibleLatticeButton.state(s, phase: run.phase, answerIsCurrent: main.answerIsCurrent(model))
        FlexibleLatticeCardView(run: run, status: s, state: st, preview: FlexibleLatticeCard.previewLine(state: st, project: project),
                                width: width, maxHeight: maxHeight,
                                close: { chrome.close(.latticeCard) },
                                send: { main.sendFromCard() },
                                showFix: { chrome.show(.callout) })
    }
}

/// The callout over the live issue (it closes itself once the issue is gone).
private struct FlexibleCalloutMount: View {
    @ObservedObject var model: FlexibleStageModel
    let main: FlexibleMainStage
    let chrome: FlexibleChromeState
    let width: CGFloat
    let openSquish: () -> Void

    var body: some View {
        let s = main.cornerStatus(model)
        if s.tone == .fix, let issue = s.fix {
            FlexibleBlockerCalloutView(model: model, issue: issue, width: width, close: { chrome.close(.callout) },
                                       squish: {
                                           chrome.foldAll()
                                           FlexibleBlockerCallout.goToSquish(openFix: { main.openFix() }, openSquish: openSquish)
                                       })
        } else if s.tone == .fix {
            // a fault with no Squish-page fix (the part could not be opened, a failed build): its line, nothing to press
            FlexibleCornerPairStyle.panel(width: width, maxHeight: 200) {
                HStack(spacing: DS.Space.s) {
                    Text(s.line).font(.system(size: 14)).foregroundStyle(DS.Color.warning.color).said(s.line)
                    Spacer(minLength: 0)
                    FlexibleCornerPairStyle.x44("xmark", label: "Dismiss", id: "flexible-callout-close") { chrome.close(.callout) }
                }
            }
            .accessibilityIdentifier("flexible-blocker-callout")
        }
    }
}

/// The pair's shared looks (DS tokens only).
enum FlexibleCornerPairStyle {
    /// A panel's glass: Surface.panel, radius 22, the panel hairline; its body scrolls past `maxHeight`.
    static func panel<C: View>(width: CGFloat, maxHeight: CGFloat, @ViewBuilder _ content: () -> C) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: max(0, maxHeight - 2 * DS.Space.m))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, DS.Space.ml).padding(.vertical, DS.Space.m)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .dsShadow(DS.Shadow.panel)
    }

    /// A 44 × 44 icon button (fold, back, dismiss).
    static func x44(_ icon: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.Color.textSecondary.color)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    /// A small bordered button ("Change", "Show the fix"), 44 tall to the finger.
    static func small(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                .padding(.horizontal, DS.Space.m)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 12).fill(DS.Color.fillSubtle.color)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1)))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .saidWhole(title)
        .accessibilityIdentifier(id)
    }

    /// A fix button (the first one filled).
    static func big(_ title: String, primary: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(primary ? FlexibleStageStyle.onAccent : DS.Color.textPrimary.color)
                .lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, DS.Space.l)
                .frame(minWidth: 44, minHeight: 44)
                .background(Capsule().fill(primary ? FlexibleStageStyle.accent : DS.Color.chipSolid.color))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .saidWhole(title, minScale: 0.8)
        .accessibilityIdentifier(id)
    }

    /// The frame a view publishes for the hosted tests and the Squish page's keep-outs (FlexibleKeepOutKey, global).
    static func publish(_ key: String) -> some View {
        GeometryReader { g in Color.clear.preference(key: FlexibleKeepOutKey.self, value: [key: g.frame(in: .global)]) }
            .allowsHitTesting(false)
    }
}
