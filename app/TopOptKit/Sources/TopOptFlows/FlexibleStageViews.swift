// FlexibleStageViews — the Settings page's two VIEWS (task 2026-09-29-flexible-screens, round 6, item 3; his
// img3: "There should also be a view that turns on/off ALL squish prisms. And another view that shows all
// grouped faces/edges/corners, highlighting them per group colour").
//
// ★ [Prisms] draws every pressed face's prism, faint, with its mm (FlexibleDepthPrism.renderItems,
// FlexibleStageViewTags); [Groups] every group's glass and Rests' (FlexibleGroupWalls), the open group
// brighter, a number disc where a colour is shared. Two 40 pt view buttons UNDER THE GIZMO (the main page's
// view row's metrics: `PageChrome.belowGizmo`, trailing on `edge`, `DS.Space.s` apart); their frame
// (`frame(viewport:)`) is a keep-out for the legend and for everything drawn on the part (the chips, the
// tags, the curves, the stamp's handle — FlexibleStagePage.stageKeepOut).
// ★ SESSION DISPLAY STATE (FlexibleStageModel.views): never a setting, never the lattice's key, never an
// action — Exit stays "Exit". The main page reads the same model's.

import SwiftUI
import TopOptDesign

/// The Settings page's views (session display state — never a setting).
public struct FlexibleStageViews: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// Every pressed face's prism, faint, with its mm.
    public static let prisms = FlexibleStageViews(rawValue: 1 << 0)
    /// Every group's glass, the open group brighter.
    public static let groups = FlexibleStageViews(rawValue: 1 << 1)

    /// The buttons, in order (icon, label, accessibility id). ★ R6 REVIEW (the verifier: the glyphs did not say what
    /// they do — stacked layers, an apps grid): [Prisms] is "down to a depth" in the prisms' own purple; [Groups] is
    /// his first three groups' colours as three dots (`glyphColours`; its SF name is the accessibility fallback only).
    /// ★ ROUND 7, R7-V (his img3 and img4, 2026-10-14): [Heat] (the main page's glyph — a tap: the current group's heat or
    /// none, a 3 s hold: every group's; its bit is `heatOff`, the page opening with the current group's), [Bend] (the
    /// current group at full depth, every face at once, frozen) and [Play] (the sim and its bar; shared with the main page).
    static let buttons: [(view: FlexibleStageViews, icon: String, label: String, id: String)] = [
        (.prisms, "arrow.down.to.line", "Prisms", "flexible-settings-view-prisms"),
        (.groups, "circle.grid.2x2", "Groups", "flexible-settings-view-groups"),
        (.heatOff, "thermometer.medium", "Heat", "flexible-settings-view-heat"),
        (.bend, "rectangle.compress.vertical", "Bend", "flexible-settings-view-bend"),
        (.play, "play.fill", "Play", "flexible-settings-view-play"),
    ]
    static let buttonSize: CGFloat = 40
    /// [Prisms]' SF symbol (its glyph's, and the accessibility fallback) — ★ S1b: the main page's [Prisms] too.
    static let prismsIcon = "arrow.down.to.line"
    /// ★ S1b: [Prisms]' glyph, ONE for both pages — "down to a depth" in the prisms' own purple when on.
    static func prismsGlyph(on: Bool) -> AnyView {
        AnyView(Image(systemName: prismsIcon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(on ? FlexibleStageStyle.facePrismKnob.color : DS.Color.textTertiary.color))
    }
    /// ★ R6 REVIEW: the [Groups] glyph's three dots — his first three groups' colours, the palette's after them.
    @MainActor static func glyphColours(model: FlexibleStageModel) -> [RGBA] {
        let gs = model.squeezeGroups.prefix(3).map { model.groupColour($0) }
        return gs + FlexibleGroupColour.allCases.map(\.rgba).filter { c in !gs.contains { $0 == c } }.prefix(3 - gs.count)
    }

    /// Where the buttons sit in the page's frame: under the gizmo's touch square, trailing on `edge`.
    static func frame(viewport: CGSize) -> CGRect {
        let n = CGFloat(buttons.count)
        let w = n * buttonSize + (n - 1) * DS.Space.s
        return CGRect(x: viewport.width - PageChrome.edge - w, y: PageChrome.belowGizmo, width: w, height: buttonSize)
    }
}

extension FlexibleStageModel {
    /// A view button: on ⇄ off. (★ R7-V: [Heat]'s button is `heatTapped` / `heatHeld` — its bit means hidden.)
    public func toggleView(_ v: FlexibleStageViews) {
        if views.contains(v) { views.remove(v) } else { views.insert(v) }
        // RED CONTROL: the views written into the settings (an action, a modified page)
        if controlViewsInSettings {
            edit({ s in var c = s.groupColours ?? [:]; c["views"] = String(views.rawValue); s.groupColours = c }, recompute: false)
            actionSerial += 1
        }
    }
}

/// [Prisms] [Groups] [Heat] [Bend] [Play], under the gizmo (FlexibleViewColumn mounts it). Icons only.
struct FlexibleStageViewButtons: View {
    @ObservedObject var model: FlexibleStageModel
    /// Test control only (R7-V review): no "every group" mark on [Heat] (R7-V's first build — the glyph alone).
    @MainActor static var controlNoHeatAllBadge = false

    var body: some View {
        HStack(spacing: DS.Space.s) {
            ForEach(FlexibleStageViews.buttons, id: \.id) { b in
                let on = Self.isOn(b.view, model.views)
                FlexibleViewButton(icon: icon(b), label: b.label, on: on, action: { tapped(b.view) }, glyph: glyph(b.view, on: on),
                                   onLongPress: b.view == .heatOff ? { held() } : nil)
                    // ★ R7-V REVIEW: [Heat] under his 3 s hold carries his groups' three dots ("every group" at a glance);
                    // [Play] carries the sims' status while its bar is hidden (FlexiblePlayBadge)
                    .overlay(alignment: .topTrailing) {
                        if b.view == .heatOff, model.views.heatScope == .all, !Self.controlNoHeatAllBadge {
                            FlexibleHeatAllBadge(colours: FlexibleStageViews.glyphColours(model: model))
                        }
                        if b.view == .play { FlexiblePlayBadge(status: playStatus) }
                    }
                    .accessibilityValue(b.view == .heatOff ? heatValue : (b.view == .play ? playValue(on) : (on ? "On" : "Off")))
                    .accessibilityHint(b.view == .heatOff ? FlexibleRowCopy.heatHint : "")
                    .accessibilityIdentifier(b.id)
            }
        }
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["viewButtons": g.frame(in: .global)])
        }.allowsHitTesting(false))
        .padding(.top, PageChrome.belowGizmo)
        .padding(.trailing, PageChrome.edge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    /// ★ R7-V: a button is lit while its view shows — [Heat] while any heat shows (its bit means hidden).
    static func isOn(_ v: FlexibleStageViews, _ views: FlexibleStageViews) -> Bool {
        v == .heatOff ? views.heatScope != .off : views.contains(v)
    }
    /// ★ R7-V REVIEW: the sims' status on [Play] — from the line its hidden bar would carry (the open group's 3D sim running,
    /// or failed).
    private var playStatus: FlexiblePlayStatus {
        FlexiblePlayStatus.settings(note: FlexibleSettingsSquish.note(model: model, fe: false))
    }
    private func playValue(_ on: Bool) -> String {
        switch playStatus {
        case .working: return (on ? "On" : "Off") + " · " + FlexibleRowCopy.playWorking
        case .failed: return (on ? "On" : "Off") + " · " + FlexibleRowCopy.playFailed
        case .idle: return on ? "On" : "Off"
        }
    }
    /// [Heat]'s glyph: fuller for every group's heat (his hold).
    private func icon(_ b: (view: FlexibleStageViews, icon: String, label: String, id: String)) -> String {
        b.view == .heatOff && model.views.heatScope == .all ? "thermometer.high" : b.icon
    }
    private var heatValue: String {
        switch model.views.heatScope {
        case .off: return "Off"
        case .group: return FlexibleRowCopy.heatGroup
        case .all: return FlexibleRowCopy.heatAll
        }
    }
    /// A tap: [Heat] cycles (shown → hidden → the current group's); the others on ⇄ off. An edges/corners group has
    /// nothing to heat or bend yet — the page says so once.
    private func tapped(_ v: FlexibleStageViews) {
        if v == .heatOff {
            var next = model.views
            next.heatTapped()
            model.views = next
            if next.heatScope != .off { sayEdgesPending(FlexibleRowCopy.noHeatYet) }
            return
        }
        model.toggleView(v)
        if v == .bend, model.views.contains(.bend) { sayEdgesPending(FlexibleRowCopy.noBendYet) }
    }
    /// His 3 s hold on [Heat]: every group's heat.
    private func held() {
        var next = model.views
        next.heatHeld()
        model.views = next
    }
    private func sayEdgesPending(_ line: String) {
        if model.playingGroup?.kind == .edges { model.toast = line }
    }

    /// ★ R6 REVIEW: what each button shows — the prisms' purple arrow down to a line; his groups' three colours.
    private func glyph(_ v: FlexibleStageViews, on: Bool) -> AnyView? {
        guard v == .prisms || v == .groups else { return nil }   // ★ R7-V: Heat, Bend and Play are their SF icons
        if v == .groups {
            let cs = FlexibleStageViews.glyphColours(model: model)
            return AnyView(ZStack {
                ForEach(Array(cs.enumerated()), id: \.offset) { i, c in
                    Circle().fill(c.color).frame(width: 9, height: 9)
                        .offset(x: [-5.5, 5.5, 0][i % 3], y: [3.5, 3.5, -5.5][i % 3])
                }
            }
            .opacity(on ? 1 : 0.6))
        }
        return FlexibleStageViews.prismsGlyph(on: on)   // ★ S1b: the one [Prisms] glyph (the main page's too)
    }
}

/// ★ ROUND 6 (item 3): the legend card's view rows (the Settings page's ONE card), one line each — the Prisms
/// row "▮ Prism = squish shown ×k" (the swatch is the prism's own purple) and the Groups row, its discs.
enum FlexibleLegendViewRows {
    /// The Groups row shows at most this many discs, then "+N".
    static let maxDiscs = 7

    static func prisms(k: Int) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(FlexibleStageStyle.facePrismToken.color).frame(width: 10, height: 12)
            Text(FlexibleRowCopy.legendPrismsRow(k))
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["legendPrismsRow": g.frame(in: .global)])
        }.allowsHitTesting(false))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("flexible-legend-prisms-row")
    }

    /// ★ ROUND 7 (M2, his img3 words): where a tap works on the Squish page — the lattice sections' violet.
    static var sections: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(FlexibleStageStyle.facePrismToken.color.opacity(0.6)).frame(width: 10, height: 12)
            Text(FlexibleRowCopy.sectionLegend)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["legendSectionsRow": g.frame(in: .global)])
        }.allowsHitTesting(false))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("flexible-legend-sections-row")
    }

    @MainActor
    static func groups(model: FlexibleStageModel) -> some View {
        let gs = model.squeezeGroups
        let rests = model.settings.faces.contains { !$0.isLoaded }
        return HStack(spacing: 4) {
            Text(FlexibleRowCopy.legendGroupsRow)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                .lineLimit(1)
            ForEach(gs.prefix(maxDiscs), id: \.id) { g in
                FlexibleGroupNumberDisc(colour: model.groupColour(g), number: g.number, size: 16)
            }
            if gs.count > maxDiscs {
                Text("+\(gs.count - maxDiscs)").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Color.textSecondary.color)
            }
            if rests {
                Circle().fill(DS.Color.accentCyan.color)
                    .overlay(Text("R").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(FlexibleGroupNumbers.ink.color))
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(FlexibleRowCopy.railRests)
            }
        }
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["legendGroupsRow": g.frame(in: .global)])
        }.allowsHitTesting(false))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flexible-legend-groups-row")
    }
}
