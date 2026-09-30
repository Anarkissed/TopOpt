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

/// The (i): a 28 pt glyph in a 44 pt target that opens a popover with the long text.
struct FlexInfoButton<Extra: View>: View {
    let title: String
    let text: String
    let extra: Extra
    var id: String = "flexible-info"
    @State private var shown = false

    init(title: String, text: String, id: String = "flexible-info", @ViewBuilder extra: () -> Extra) {
        self.title = title; self.text = text; self.id = id; self.extra = extra()
    }

    var body: some View {
        Button { shown = true } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(DS.Color.textTertiary.color)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
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

/// One row: its ONE line (never wrapped), its control, and its (i).
struct FlexRow<Control: View, Extra: View>: View {
    let line: String
    let info: String
    var id: String = "flexible-row"
    let control: Control
    let extra: Extra

    init(_ line: String, info: String, id: String = "flexible-row",
         @ViewBuilder control: () -> Control, @ViewBuilder extra: () -> Extra) {
        self.line = line; self.info = info; self.id = id; self.control = control(); self.extra = extra()
    }

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Text(line)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary.color)
                .lineLimit(1).minimumScaleFactor(0.85)
                .layoutPriority(1)
            Spacer(minLength: DS.Space.xs)
            control
            FlexInfoButton(title: line, text: info, id: "\(id)-info") { extra }
        }
        .frame(minHeight: 36)
        .accessibilityIdentifier(id)
    }
}

extension FlexRow where Extra == EmptyView {
    init(_ line: String, info: String, id: String = "flexible-row", @ViewBuilder control: () -> Control) {
        self.init(line, info: info, id: id, control: control) { EmptyView() }
    }
}

extension FlexRow where Control == EmptyView, Extra == EmptyView {
    init(_ line: String, info: String, id: String = "flexible-row") {
        self.init(line, info: info, id: id, control: { EmptyView() }) { EmptyView() }
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
