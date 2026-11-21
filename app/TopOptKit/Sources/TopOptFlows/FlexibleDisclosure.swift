// FlexibleDisclosure — a row whose details open BELOW its title (task
// 2026-09-29-flexible-screens, round 4 batch D1; his img 7: "For the Auto and Physics I think
// it should be a carrot, where tapping it opens up the details below the title. Please make
// it obvious that tapping makes it open up for details.").
//
// ★ THE WHOLE ROW IS THE BUTTON: its one line and, trailing, a caret in a round button that
// points DOWN (it opens below) and turns to point up when open. The details were behind an (i)
// popover floating beside the panel (img 7); they now open inline, in the panel's own scroll.

import SwiftUI
import TopOptDesign

struct FlexDisclosureRow<Detail: View>: View {
    let line: String
    var id: String
    var warning = false
    let detail: Detail
    @State private var open: Bool

    init(_ line: String, id: String, warning: Bool = false, initiallyOpen: Bool = false,
         @ViewBuilder detail: () -> Detail) {
        self.line = line; self.id = id; self.warning = warning
        self.detail = detail()
        self._open = State(initialValue: initiallyOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(spacing: DS.Space.s) {
                    Text(line)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(warning ? DS.Color.warning.color : DS.Color.textPrimary.color)
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .layoutPriority(1)
                    Spacer(minLength: DS.Space.xs)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DS.Color.accent.color)
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(DS.Color.fillSubtle.color))
                        .frame(width: 44, height: 36)
                }
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(id)
            .accessibilityValue(open ? "open" : "closed")
            .accessibilityHint(open ? "Hides the details" : "Shows the details")
            if open {
                detail
                    .padding(.leading, DS.Space.s)
                    .transition(.opacity)
                    .accessibilityIdentifier("\(id)-details")
            }
        }
    }
}
