// SegmentedGlass.swift — the design's inset segmented control (ROADMAP M7.2).
//
// The Filament/Resin and kg/lbs toggles in docs/design/TopOpt.dc.html: an inset
// dark track (`rgba(0,0,0,0.3)`, `rgba(255,255,255,0.07)` hairline, `3px` pad,
// `12px` radius) with a selected segment lit `rgba(255,255,255,0.16)`/white and
// unselected segments transparent with `rgba(242,242,245,0.5)` text. Generic over
// any `Hashable` value so callers bind an enum or a String.

import SwiftUI

public struct SegmentedGlass<Value: Hashable>: View {
    /// One selectable segment: its `value` and display `label`.
    public struct Segment: Identifiable {
        public let value: Value
        public let label: String
        public var id: Value { value }
        public init(_ value: Value, _ label: String) {
            self.value = value
            self.label = label
        }
    }

    private let segments: [Segment]
    @Binding private var selection: Value

    public init(_ segments: [Segment], selection: Binding<Value>) {
        self.segments = segments
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(segments) { seg in
                let isOn = seg.value == selection
                Button { selection = seg.value } label: {
                    Text(seg.label)
                        .dsStyle(DS.TypeScale.body)
                        .foregroundStyle(isOn ? DS.Color.textPrimary.color
                                              : DS.Color.textPrimary.opacity(0.5).color)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Space.sm)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: DS.Radius.segment, style: .continuous)
                                    .fill(DS.Color.fillSelected.color)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
                .fill(.black.opacity(0.30))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
                        .strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)
                }
        }
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

private enum PreviewProcess: Hashable { case fdm, sla }

#Preview("SegmentedGlass") {
    struct Demo: View {
        @State private var process: PreviewProcess = .fdm
        @State private var unit = "kg"
        var body: some View {
            ZStack {
                DS.Color.background.color.ignoresSafeArea()
                VStack(spacing: DS.Space.xl2) {
                    SegmentedGlass([.init(.fdm, "Filament (FDM)"), .init(.sla, "Resin (SLA)")],
                                   selection: $process)
                        .frame(width: 420)
                    SegmentedGlass([.init("kg", "kg"), .init("lbs", "lbs")], selection: $unit)
                        .frame(width: 140)
                }
                .padding(DS.Space.page)
            }
        }
    }
    return Demo()
}
