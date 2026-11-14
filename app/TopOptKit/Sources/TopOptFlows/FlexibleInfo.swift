// FlexibleInfo — the (i) beside every Flexible row, and the one-line row itself (task
// 2026-09-29-flexible-screens, round 3, item 5).
//
// ★ HIS RULE: one line of text per setting; the details live behind an (i) he may never tap,
// and nothing REQUIRED lives there. The (i) opens a popover with the row's long text
// (FlexibleRowCopy.Info) and, where there is one, core's own detail (reasons, bands, stack
// facts) — the long captions the panel used to carry.

import SwiftUI
import TopOptDesign
import TopOptKit

/// The (i): a 15 pt glyph in a 44 pt target (it was 32 × 32) that opens a popover with the long text.
struct FlexInfoButton<Extra: View>: View {
    let title: String
    let text: String
    let extra: Extra
    var id: String = "flexible-info"
    @State private var shown = false

    init(title: String, text: String, id: String = "flexible-info", @ViewBuilder extra: () -> Extra) {
        self.title = title; self.text = text; self.id = id; self.extra = extra()
    }

    /// The hit target (pt): the HIG's 44.
    static var target: CGFloat { 44 }

    var body: some View {
        Button { shown = true } label: {
            // ★ B9 LOOK (design-system §4.21): the one (i) — InfoTip's 22 pt circle and serif "i"
            Text("i")
                .font(.system(size: 13, weight: .bold, design: .serif))
                .foregroundStyle(DS.Color.textTertiary.color)
                .frame(width: InfoTip.circle, height: InfoTip.circle)
                .overlay(Circle().strokeBorder(DS.Color.textTertiary.color, lineWidth: 1.2))
                .frame(width: FlexInfoButton.target, height: FlexInfoButton.target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .flexibleProbe(id)
        .popover(isPresented: $shown) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                    FlexCaption(text: text, colour: DS.Color.textSecondary.color)
                    extra
                }
                .padding(DS.Space.l)
                .frame(width: 380, alignment: .leading)
            }
            .frame(maxHeight: 520)
            .background(DS.Surface.sheet.color)
        }
    }
}

extension FlexInfoButton where Extra == EmptyView {
    init(title: String, text: String, id: String = "flexible-info") {
        self.init(title: title, text: text, id: id) { EmptyView() }
    }
}

/// One row: its ONE line (never wrapped), its (i), and its control. `warning` colours the
/// line when it says something he must act on (Auto that cannot meet the curve…).
/// ★ B9 LOOK (design-system §4.4's setting row, as Topology's Settings): the label in the body's type, its (i) right after it,
/// the control at the right, 44 pt tall — the (i) column at the far right went.
struct FlexRow<Control: View, Extra: View>: View {
    let line: String
    let info: String
    var id: String = "flexible-row"
    var warning = false
    let control: Control
    let extra: Extra

    init(_ line: String, info: String, id: String = "flexible-row", warning: Bool = false,
         @ViewBuilder control: () -> Control, @ViewBuilder extra: () -> Extra) {
        self.line = line; self.info = info; self.id = id; self.warning = warning
        self.control = control(); self.extra = extra()
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(line)
                .font(.system(size: 13.5))
                .foregroundStyle(warning ? DS.Color.warning.color : DS.Color.textPrimary.color)
                .lineLimit(1).minimumScaleFactor(0.85)
                .layoutPriority(1)
            FlexInfoButton(title: line, text: info, id: "\(id)-info") { extra }
            Spacer(minLength: DS.Space.xs)
            control
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier(id)
        .flexibleProbe(id)
    }
}

extension FlexRow where Extra == EmptyView {
    init(_ line: String, info: String, id: String = "flexible-row", warning: Bool = false, @ViewBuilder control: () -> Control) {
        self.init(line, info: info, id: id, warning: warning, control: control) { EmptyView() }
    }
}

extension FlexRow where Control == EmptyView, Extra == EmptyView {
    init(_ line: String, info: String, id: String = "flexible-row", warning: Bool = false) {
        self.init(line, info: info, id: id, warning: warning, control: { EmptyView() }) { EmptyView() }
    }
}

/// The one-line warning under a row (the selected face's refusal, unreached columns…): said
/// on the panel, the (i) only explains.
struct FlexWarningLine: View {
    let text: String
    var id: String = "flexible-row-warning"
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.warning.color)
            .lineLimit(1).minimumScaleFactor(0.85)
            .accessibilityIdentifier(id)
            .flexibleProbe(id)
    }
}

/// ★ R7-E1b (his 2026-10-19 note: "There should be some sort red notification explaining why something can't go as far as the user
/// wanted"): a held depth or angle, said in RED in one line — the bound that stopped it, with its number.
struct FlexStopLine: View {
    static var colour: RGBA { DS.Color.danger }
    let text: String
    var id: String = "flexible-flat-stop-line"
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Self.colour.color)
            .lineLimit(1).minimumScaleFactor(0.85)
            .accessibilityIdentifier(id)
            .flexibleProbe(id)
    }
}

/// Long text inside an (i) popover (the only place a caption lives now).
struct FlexInfoText: View {
    let text: String
    var warning = false
    init(_ text: String, warning: Bool = false) { self.text = text; self.warning = warning }
    var body: some View {
        FlexCaption(text: text, colour: warning ? DS.Color.warning.color : DS.Color.textSecondary.color)
    }
}
