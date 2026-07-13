// PrintParamsSheet.swift — the M7.params PRINT PARAMETERS sheet.
//
// Matches docs/design/PrintParams_TopOpt.dc.html's PRINT PARAMETERS modal sheet:
// title + subtitle, a "Default" reset, a 2-column grid of Layer height / Wall loops
// / Top shell layers / Bottom shell layers, a full-width Infill density row (number
// + slider) and an Infill pattern picker, then a primary Done. Styled with the DS
// glass tokens; RootView presents it centered over the design's blurred scrim.
//
// It edits the open project's `printParams` LIVE (bindings write straight through),
// so leaving the sheet — Done or scrim-tap — keeps the edits; AppModel.closePrintParams
// clamps + persists. Only the modal sheet from that mockup is in scope (M7.params);
// the rest of that file is a stale prototype and is ignored.

import SwiftUI
import TopOptDesign

public struct PrintParamsSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var project: ProjectModel

    public init(model: AppModel, project: ProjectModel) {
        self.model = model
        self.project = project
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Space.m),
                                GridItem(.flexible(), spacing: DS.Space.m)],
                      alignment: .leading, spacing: DS.Space.ml) {
                decimalField("Layer height", suffix: "mm",
                             value: binding(\.layerHeightMM), step: 0.02)
                intField("Wall loops", value: binding(\.wallLoops))
                intField("Top shell layers", value: binding(\.topLayers))
                intField("Bottom shell layers", value: binding(\.bottomLayers))
            }
            .padding(.top, DS.Space.xl3)

            infillRow.padding(.top, DS.Space.ml)
            patternRow.padding(.top, DS.Space.ml)

            HStack {
                Spacer()
                PillButton("Done", style: .primary) { model.closePrintParams() }
            }
            .padding(.top, DS.Space.xl5)
        }
        .padding(DS.Space.xl6)
        .frame(width: 560, alignment: .leading)
        .foregroundStyle(DS.Color.textPrimary.color)
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Space.ml) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Print Parameters").dsStyle(DS.TypeScale.title)
                Text("The optimizer accounts for how the part will actually print.")
                    .dsStyle(DS.TypeScale.subhead)
                    .foregroundStyle(DS.Color.textTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.s)
            Button { project.printParams = .fdmDefault } label: {
                Text("Default")
                    .dsStyle(DS.TypeScale.subhead).fontWeight(.semibold)
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .padding(.vertical, 9).padding(.horizontal, DS.Space.l)
                    .background(Capsule().fill(DS.Color.fillSubtle.color)
                        .overlay(Capsule().strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1)))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: infill density (tap-to-edit number + steppers + slider)

    /// Infill density: a whole-% slider paired with a precise entry — tap the value
    /// to type an exact %, or use the − / + steppers. The slider was hard to drag
    /// precisely at step 5 (M7.params c); it now steps by 1, and the number is the
    /// authoritative precise input so you never have to fight the thumb.
    private var infillRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Text("Infill density").dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textTertiary.color)
                Spacer()
                infillStepper
            }
            Slider(value: infillSliderBinding, in: 0...100, step: 1)
                .tint(DS.Color.accent.color)
        }
    }

    /// The − / value / + control. The value is a live `TextField` (tap to type an
    /// exact %); the steppers nudge by 1, clamped to 0–100 so they never run past
    /// the range. Free-typed out-of-range values are clamped on sheet close.
    private var infillStepper: some View {
        HStack(spacing: DS.Space.xs) {
            stepButton("minus") { stepInfill(-1) }
            HStack(spacing: 1) {
                TextField("", value: binding(\.infillPercent), format: .number)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .multilineTextAlignment(.trailing)
                    .frame(width: 34)
                    .font(DS.TypeScale.caption.font).fontWeight(.bold)
                    .foregroundStyle(DS.Color.accent.color)
                Text("%").dsStyle(DS.TypeScale.caption).fontWeight(.bold)
                    .foregroundStyle(DS.Color.accent.color)
            }
            .padding(.vertical, 6).padding(.horizontal, DS.Space.s)
            .background(fieldBackground)
            stepButton("plus") { stepInfill(1) }
        }
    }

    private func stepButton(_ systemName: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(DS.Color.textPrimary.color)
                .frame(width: 32, height: 32)
                .background(Circle().fill(DS.Color.fillSubtle.color)
                    .overlay(Circle().strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1)))
        }
        .buttonStyle(.plain)
    }

    /// Step infill by ±1, clamped to 0–100 (headless logic in `PrintParams`).
    private func stepInfill(_ delta: Int) {
        project.printParams.infillPercent = project.printParams.steppingInfill(by: delta)
    }

    /// The slider reads the value pinned into its 0–100 track (the tap-to-edit field
    /// can briefly hold an out-of-range value); writing snaps to the whole-% step.
    private var infillSliderBinding: Binding<Double> {
        Binding(get: { project.printParams.infillSliderValue },
                set: { project.printParams.infillPercent = Int($0.rounded()) })
    }

    // MARK: infill pattern

    private var patternRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("Infill pattern").dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(DS.Color.textTertiary.color)
            Menu {
                ForEach(PrintParams.patternOptions, id: \.self) { p in
                    Button(p.capitalized) { project.printParams.infillPattern = p }
                }
            } label: {
                HStack {
                    Text(project.printParams.infillPattern.capitalized)
                        .dsStyle(DS.TypeScale.body)
                        .foregroundStyle(DS.Color.textPrimary.color)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Color.textTertiary.color)
                }
                .padding(.vertical, 11).padding(.horizontal, DS.Space.m)
                .background(fieldBackground)
            }
        }
    }

    // MARK: field builders

    /// A labelled integer field (design: numeric input in the grid).
    private func intField(_ label: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(label).dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(DS.Color.textTertiary.color)
            TextField("", value: value, format: .number)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .font(DS.TypeScale.bodyStrong.font)
                .foregroundStyle(DS.Color.textPrimary.color)
                .padding(.vertical, 11).padding(.horizontal, DS.Space.m)
                .background(fieldBackground)
        }
    }

    /// A labelled decimal field with a trailing unit (design: layer height in mm).
    private func decimalField(_ label: String, suffix: String,
                              value: Binding<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(label).dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(DS.Color.textTertiary.color)
            HStack(spacing: DS.Space.s) {
                TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .font(DS.TypeScale.bodyStrong.font)
                    .foregroundStyle(DS.Color.textPrimary.color)
                Text(suffix).dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textQuaternary.color)
            }
            .padding(.vertical, 11).padding(.horizontal, DS.Space.m)
            .background(fieldBackground)
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
            .fill(DS.Color.fillSubtle.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
                .strokeBorder(DS.Color.textPrimary.opacity(0.11).color, lineWidth: 1))
    }

    /// A binding straight through to the project's live `printParams` field.
    private func binding<V>(_ kp: WritableKeyPath<PrintParams, V>) -> Binding<V> {
        Binding(get: { project.printParams[keyPath: kp] },
                set: { project.printParams[keyPath: kp] = $0 })
    }
}

#Preview("PrintParamsSheet") {
    let m = AppModel(materialsPath: nil)
    m.open(RecentProject(name: "Wall Bracket v4", materialName: "PLA", process: .fdm))
    return ZStack {
        DS.Color.background.color.ignoresSafeArea()
        DS.Color.scrim.color.ignoresSafeArea()
        GlassSheet { PrintParamsSheet(model: m, project: m.project!) }
    }
}
